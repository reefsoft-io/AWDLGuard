import Darwin
import HelperInterface

/// The app's view of the privileged helper.
public enum HelperState: Equatable, Sendable {
    case notInstalled
    /// Registering the helper with launchd failed, with the system's message.
    case installFailed(String)
    /// Registered, but the user hasn't allowed it in System Settings yet.
    case needsApproval
    case connecting
    case connected(InterfaceObservation)
    /// Registered and enabled, but it stopped answering requests.
    case notResponding
    /// Unregistering and registering the helper again, to restart it.
    case repairing
}

/// What the menu shows as the current state: the decision checked against what the helper
/// actually observed. It never reports suppression without the helper confirming awdl0 is down.
public struct Status: Equatable, Sendable {
    public enum Tone: Sendable {
        /// The helper confirmed awdl0 is down as decided.
        case suppressed
        /// AWDL is allowed, as decided.
        case allowed
        /// Waiting for the helper.
        case pending
        /// The decision isn't in effect, or the helper can't be reached.
        case problem
    }

    /// What the user can do about a helper problem, offered with the status.
    public enum Remedy: Sendable {
        case install
        case approve
        case repair
    }

    public let tone: Tone
    public let title: String
    public let detail: String
    public let remedy: Remedy?

    private init(tone: Tone, title: String, detail: String, remedy: Remedy? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.remedy = remedy
    }

    public init(decision: Decision, helper: HelperState) {
        switch helper {
        case .notInstalled:
            self.init(tone: .problem, title: "Helper Required", detail: "Needed to control AWDL", remedy: .install)
        case .installFailed(let message):
            self.init(tone: .problem, title: "Couldn't Install Helper", detail: message, remedy: .install)
        case .needsApproval:
            self.init(tone: .problem, title: "Approval Required", detail: "Turn on background activity", remedy: .approve)
        case .connecting:
            self.init(tone: .pending, title: "Connecting…", detail: decision.explanation)
        case .notResponding:
            self.init(tone: .problem, title: "Helper Not Responding", detail: "Repair to restart it", remedy: .repair)
        case .repairing:
            self.init(tone: .pending, title: "Repairing…", detail: "Restarting helper")
        case .connected(let observation):
            self = decision.isSuppressed
                ? Self.suppressing(observation, decision: decision)
                : Self.allowing(observation, decision: decision)
        }
    }

    private static func suppressing(_ observation: InterfaceObservation, decision: Decision) -> Status {
        // The helper refuses to suppress when it can't record that it did.
        if let failure = observation.failure, failure.operation == .recordState {
            return Status(tone: .problem, title: "Couldn't Turn Off", detail: describe(failure))
        }
        if !observation.isSuppressing {
            return Status(tone: .pending, title: "Turning Off…", detail: decision.explanation)
        }
        if let failure = observation.failure {
            return Status(tone: .problem, title: "Couldn't Turn Off", detail: describe(failure))
        }
        switch observation.isInterfaceUp {
        case false? where !observation.isWatching:
            return Status(tone: .problem, title: "Not Watching AWDL", detail: "Repair to keep it off", remedy: .repair)
        case false?:
            return Status(tone: .suppressed, title: "AWDL Off", detail: offDetail(observation, decision: decision))
        case true?:
            return Status(tone: .problem, title: "AWDL Still On", detail: "macOS kept it on")
        case nil:
            return Status(tone: .problem, title: "Status Unavailable", detail: "Couldn't check AWDL")
        }
    }

    /// Why AWDL is off, or, once macOS has fought back, how often it was turned back off.
    private static func offDetail(_ observation: InterfaceObservation, decision: Decision) -> String {
        switch observation.reactivationCount {
        case 0: decision.explanation
        case 1: "Re-enabled by macOS once"
        case let count: "Re-enabled by macOS \(count) times"
        }
    }

    private static func allowing(_ observation: InterfaceObservation, decision: Decision) -> Status {
        // Another user, or another copy of the app, still wants AWDL off; the helper keeps
        // it off until that session lets go.
        if observation.isSuppressing && observation.isHeldForOthers {
            return Status(tone: .allowed, title: "AWDL Off", detail: "Kept off for another user")
        }
        if observation.isSuppressing {
            return Status(tone: .pending, title: "Turning On…", detail: decision.explanation)
        }
        // A failure to record suppression only concerns turning AWDL off, and the helper
        // clears it with the next request.
        if let failure = observation.failure, failure.operation != .recordState {
            return Status(tone: .problem, title: "Couldn't Turn On", detail: describe(failure))
        }
        // macOS turns AWDL off by itself at times, for example with Wi-Fi off, so off while
        // allowed is information, not a fault.
        if observation.isInterfaceUp == false {
            return Status(tone: .allowed, title: "AWDL Off", detail: "Turned off by macOS")
        }
        return Status(tone: .allowed, title: "AWDL On", detail: decision.explanation)
    }

    /// A failed system call as the user reads it, for example "Operation not permitted
    /// while turning AWDL off (error 1)".
    private static func describe(_ failure: InterfaceFailure) -> String {
        let action =
            switch failure.operation {
            case .readFlags: "checking AWDL"
            case .bringDown: "turning AWDL off"
            case .bringUp: "turning AWDL on"
            case .watchChanges: "watching AWDL"
            case .recordState: "saving AWDL state"
            }
        return "\(String(cString: strerror(failure.code))) while \(action) (error \(failure.code))"
    }
}
