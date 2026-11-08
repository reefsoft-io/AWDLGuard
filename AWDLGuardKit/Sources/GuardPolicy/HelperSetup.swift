import HelperInterface

/// What macOS reports about the helper's registration.
public enum Registration: Sendable, Equatable {
    /// Not registered, or the registration's launchd plist is missing.
    case notRegistered
    /// Registered, and waiting for the user under Background App Activity.
    case requiresApproval
    case enabled
}

/// What to try again after a failure.
public enum Retry: Sendable, Equatable {
    /// Registering left the helper unregistered.
    case register
    /// The helper never answered, so its registration is replaced.
    case reregister
}

/// Where the helper's setup is. The phase is the one record of it: every timer and the
/// session belong to the phase that started them, and events for an earlier one are ignored.
public enum HelperPhase: Sendable, Equatable {
    /// Nothing in progress; the next refresh decides.
    case idle
    case registering(failures: Int)
    /// The first half of replacing the registration, with a timeout in case it never
    /// finishes.
    case unregistering(failures: Int)
    /// Waiting for macOS to finish removing the old job: registering straight after
    /// unregistering is refused ("Job is not allowed to bootstrap").
    case settling(failures: Int)
    /// Registered, polling until the user approves it; macOS posts nothing when they do.
    case awaitingApproval(failures: Int)
    /// A session is open and hasn't answered yet.
    case connecting(session: Int, failures: Int, unanswered: Int)
    case connected(session: Int, observation: InterfaceObservation, unanswered: Int)
    case waitingToRetry(failures: Int, retry: Retry)
    /// The attempts are used up; Repair starts again.
    case failed

    /// What the menu shows for this phase.
    public var state: HelperState {
        switch self {
        case .idle, .registering, .unregistering, .settling, .connecting, .waitingToRetry: .connecting
        case .awaitingApproval: .needsApproval
        case .connected(_, let observation, _): .connected(observation)
        case .failed: .failed
        }
    }
}

public enum HelperEvent: Sendable, Equatable {
    /// The registration as read at launch, when the menu opens, or after a session that
    /// worked ended.
    case refreshed(Registration)
    /// The phase's timer fired, with the registration read then.
    case timerFired(Registration)
    /// Registering finished, with the registration read afterwards: it can report an error
    /// and still succeed, so the registration decides, not the error.
    case registerFinished(Registration)
    case unregisterFinished
    /// The decision changed, so the helper needs a new request.
    case decisionChanged
    case replied(session: Int, InterfaceObservation)
    case pushed(session: Int, InterfaceObservation)
    /// The session ended, a request couldn't be sent, or a reply couldn't be read.
    case sessionEnded(session: Int)
    case repairRequested
}

public enum HelperEffect: Sendable, Equatable {
    case register
    case unregister
    case openSession(Int)
    case closeSession
    case sendRequest(Int)
    /// Starts the phase's timer, replacing any running one.
    case startTimer(Duration)
    case cancelTimer
    /// Opens Login Items in System Settings.
    case openSettings
    /// Read the registration and send `.refreshed`. Always the last effect.
    case refresh
}

/// The app's setup of the privileged helper: registering it, waiting for approval,
/// connecting, and recovering by itself. Pure: the app performs the effects and feeds back
/// the events.
public struct HelperSetup: Sendable {
    /// Failed attempts in a row before the app stops and offers Repair.
    public static let maxFailures = 4
    public static let settleDelay: Duration = .seconds(1)
    public static let approvalPoll: Duration = .seconds(2)
    /// A request unanswered for this long, not counting sleep, ends the session.
    public static let replyTimeout: Duration = .seconds(10)
    /// An unregister that hasn't finished by then is treated as finished, so the setup
    /// can't wait on it forever.
    public static let unregisterTimeout: Duration = .seconds(10)

    /// 1 s after the first failure, then 2 s, then 4 s.
    public static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds(1 << max(failures - 1, 0))
    }

    public private(set) var phase: HelperPhase = .idle
    /// The number of the last session opened, so each new one is distinct.
    private var lastSession = 0

    public init() {}

    /// What the menu shows.
    public var state: HelperState { phase.state }

    public mutating func handle(_ event: HelperEvent) -> [HelperEffect] {
        switch (phase, event) {
        case (.idle, .refreshed(let registration)):
            return decide(registration, failures: 0)

        case (.registering(let failures), .registerFinished(let registration)):
            switch registration {
            case .enabled:
                return connect(failures: failures)
            case .requiresApproval:
                // The app's first registration needs approval: open the way there. A retry
                // doesn't open Settings again; the card asks instead.
                phase = .awaitingApproval(failures: failures)
                return (failures == 0 ? [.openSettings] : []) + [.startTimer(Self.approvalPoll)]
            case .notRegistered:
                return fail(failures, retry: .register)
            }

        case (.unregistering(let failures), .unregisterFinished), (.unregistering(let failures), .timerFired):
            phase = .settling(failures: failures)
            return [.startTimer(Self.settleDelay)]

        case (.settling(let failures), .timerFired):
            phase = .registering(failures: failures)
            return [.register]

        case (.awaitingApproval, .timerFired(.requiresApproval)):
            return [.startTimer(Self.approvalPoll)]
        case (.awaitingApproval, .refreshed(.requiresApproval)):
            return []
        // Failures carry through approval: only an answer from the helper clears them.
        case (.awaitingApproval(let failures), .refreshed(let registration)),
            (.awaitingApproval(let failures), .timerFired(let registration)):
            return decide(registration, failures: failures)

        case let (.connecting(session, _, unanswered), .replied(from, observation)) where from == session,
            let (.connected(session, _, unanswered), .replied(from, observation)) where from == session:
            return answered(session, observation, unanswered: max(unanswered - 1, 0))
        case let (.connecting(session, _, unanswered), .pushed(from, observation)) where from == session,
            let (.connected(session, _, unanswered), .pushed(from, observation)) where from == session:
            phase = .connected(session: session, observation: observation, unanswered: unanswered)
            return []

        // It never answered: replace its registration.
        case let (.connecting(session, failures, _), .sessionEnded(ended)) where ended == session:
            return [.closeSession] + fail(failures, retry: .reregister)
        case let (.connecting(_, failures, _), .timerFired):
            return [.closeSession] + fail(failures, retry: .reregister)

        // It worked and went away, or hung: reconnecting launches it again.
        case let (.connected(session, _, _), .sessionEnded(ended)) where ended == session:
            phase = .idle
            return [.closeSession, .cancelTimer, .refresh]
        case (.connected, .timerFired):
            phase = .idle
            return [.closeSession, .cancelTimer, .refresh]

        case (.connecting(let session, let failures, let unanswered), .decisionChanged):
            phase = .connecting(session: session, failures: failures, unanswered: unanswered + 1)
            return [.sendRequest(session)] + (unanswered == 0 ? [.startTimer(Self.replyTimeout)] : [])
        case (.connected(let session, let observation, let unanswered), .decisionChanged):
            phase = .connected(session: session, observation: observation, unanswered: unanswered + 1)
            return [.sendRequest(session)] + (unanswered == 0 ? [.startTimer(Self.replyTimeout)] : [])

        case (.connecting, .refreshed(let registration)) where registration != .enabled,
            (.connected, .refreshed(let registration)) where registration != .enabled:
            return [.closeSession] + decide(registration, failures: 0)

        case (.waitingToRetry(let failures, let retry), .timerFired(let registration)):
            if registration == .enabled && retry == .reregister {
                phase = .unregistering(failures: failures)
                return [.startTimer(Self.unregisterTimeout), .unregister]
            }
            return decide(registration, failures: failures)

        // Opening the menu tries once more, for example after the user turned the app off
        // and on under Background App Activity. Another failure returns here.
        case (.failed, .refreshed(let registration)):
            return decide(registration, failures: Self.maxFailures - 1)

        // An operation is already under way; its result arrives in its own phase.
        case (.registering, .repairRequested), (.unregistering, .repairRequested), (.settling, .repairRequested):
            return []
        case (_, .repairRequested):
            phase = .unregistering(failures: 0)
            return [.closeSession, .startTimer(Self.unregisterTimeout), .unregister]

        default:
            return []
        }
    }

    private mutating func decide(_ registration: Registration, failures: Int) -> [HelperEffect] {
        switch registration {
        case .notRegistered:
            phase = .registering(failures: failures)
            return [.cancelTimer, .register]
        case .requiresApproval:
            phase = .awaitingApproval(failures: failures)
            return [.startTimer(Self.approvalPoll)]
        case .enabled:
            return connect(failures: failures)
        }
    }

    private mutating func connect(failures: Int) -> [HelperEffect] {
        lastSession += 1
        phase = .connecting(session: lastSession, failures: failures, unanswered: 1)
        return [.openSession(lastSession), .sendRequest(lastSession), .startTimer(Self.replyTimeout)]
    }

    private mutating func answered(
        _ session: Int, _ observation: InterfaceObservation, unanswered: Int
    ) -> [HelperEffect] {
        phase = .connected(session: session, observation: observation, unanswered: unanswered)
        // The wait is timed from the last reply while requests are still out.
        return unanswered > 0 ? [.startTimer(Self.replyTimeout)] : [.cancelTimer]
    }

    private mutating func fail(_ failures: Int, retry: Retry) -> [HelperEffect] {
        let failures = failures + 1
        guard failures < Self.maxFailures else {
            phase = .failed
            return [.cancelTimer]
        }
        phase = .waitingToRetry(failures: failures, retry: retry)
        return [.startTimer(Self.retryDelay(afterFailures: failures))]
    }
}
