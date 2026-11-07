import Foundation

/// The helper's bundle identifier, launchd label and Mach service name are all the app's
/// bundle identifier plus `suffix`. The helper's launchd plist must use the same name.
public enum HelperIdentity {
    private static let suffix = ".Helper"

    public static func helperIdentifier(appIdentifier: String) -> String {
        appIdentifier + suffix
    }

    public static func appIdentifier(helperIdentifier: String) -> String? {
        guard helperIdentifier.hasSuffix(suffix) else { return nil }
        return String(helperIdentifier.dropLast(suffix.count))
    }
}

/// The one message the app sends: whether this session wants the helper to hold awdl0
/// down. It lasts until the session ends.
///
/// The helper replies with an `InterfaceObservation`. Sending the same request again is
/// harmless.
public struct SuppressionRequest: Codable, Sendable, Equatable {
    public var isSuppressed: Bool

    public init(isSuppressed: Bool) {
        self.isSuppressed = isSuppressed
    }
}

/// What the helper last saw on awdl0.
///
/// Sent as the reply to every `SuppressionRequest`, and pushed to the app whenever macOS
/// changes the interface. "Up" and "down" refer to awdl0's `IFF_UP` flag, which is the only
/// thing the helper can verify.
public struct InterfaceObservation: Codable, Sendable, Equatable {
    /// Whether the helper is currently holding awdl0 down, for any session.
    public var isSuppressing: Bool
    /// Whether awdl0 is held down for another session: another user, or another copy of
    /// the app. Set for each recipient.
    public var isHeldForOthers: Bool
    /// awdl0's `IFF_UP` flag, read back after the helper acted. Nil when it couldn't be read.
    public var isInterfaceUp: Bool?
    /// Times macOS brought awdl0 back up during the current suppression.
    public var reactivationCount: Int
    /// Whether the helper is still watching the routing socket, so it can take awdl0 back
    /// down when macOS brings it up. Once false it stays false until the helper restarts.
    public var isWatching: Bool
    /// Why the last attempt to change or read awdl0 failed. The next clean pass clears it,
    /// except a failure to record suppression, which lasts until the next request.
    public var failure: InterfaceFailure?

    public init(
        isSuppressing: Bool,
        isHeldForOthers: Bool = false,
        isInterfaceUp: Bool?,
        reactivationCount: Int = 0,
        isWatching: Bool = true,
        failure: InterfaceFailure? = nil
    ) {
        self.isSuppressing = isSuppressing
        self.isHeldForOthers = isHeldForOthers
        self.isInterfaceUp = isInterfaceUp
        self.reactivationCount = reactivationCount
        self.isWatching = isWatching
        self.failure = failure
    }
}

/// A failed system call on awdl0, with its `errno`. Its description is for logs; the app
/// words it for the user.
public struct InterfaceFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    public enum Operation: String, Codable, Sendable {
        case readFlags
        case bringDown
        case bringUp
        /// Opening the routing socket, at helper start. The helper exits on it.
        case watchChanges
        /// Writing the record that the helper is holding awdl0 down.
        case recordState
    }

    public var operation: Operation
    public var code: Int32

    public init(operation: Operation, code: Int32) {
        self.operation = operation
        self.code = code
    }

    /// For example "bringDown failed: Operation not permitted (errno 1)".
    public var description: String {
        "\(operation.rawValue) failed: \(String(cString: strerror(code))) (errno \(code))"
    }
}
