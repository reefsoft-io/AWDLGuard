/// What each connected app session asks of the helper, by session number.
///
/// awdl0 is held down while any session wants that. A session's request lasts until the
/// session ends, so an app that quits or crashes withdraws it without doing anything.
public struct SessionRequests: Equatable, Sendable {
    private var isSuppressedBySession: [Int: Bool] = [:]

    public init() {}

    /// Records whether session `id` wants awdl0 held down.
    public mutating func set(_ isSuppressed: Bool, for id: Int) {
        isSuppressedBySession[id] = isSuppressed
    }

    public mutating func remove(_ id: Int) {
        isSuppressedBySession[id] = nil
    }

    /// Whether any session wants awdl0 held down.
    public var isSuppressionWanted: Bool {
        isSuppressedBySession.values.contains(true)
    }

    /// Whether some session other than `id` wants awdl0 held down.
    public func isHeldForOthers(excluding id: Int) -> Bool {
        isSuppressedBySession.contains { $0.key != id && $0.value }
    }

    public var isEmpty: Bool {
        isSuppressedBySession.isEmpty
    }
}
