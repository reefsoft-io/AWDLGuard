/// The user's overall choice in the menu.
public enum Mode: String, Codable, CaseIterable, Sendable {
    /// Suppress while a game or a rule's app is in the foreground, on Wi-Fi.
    case automatic
    /// Never suppress.
    case allow
    /// Always suppress, whatever is in the foreground and whatever the network.
    case suppress
}

/// Whether AWDL should be suppressed right now, and why. This is the app's only policy:
/// everything that sends requests to the helper or explains state reads it.
public struct Decision: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case allowedByMode
        case suppressedByMode
        case rule(appName: String)
        case game(appName: String)
        case excludedByRule(appName: String)
        /// A game or rule's app is in the foreground, but not on Wi-Fi.
        case notOnWiFi
        case noTrigger
    }

    public let reason: Reason

    public init(reason: Reason) {
        self.reason = reason
    }

    /// Derived from the reason, so a decision can't contradict itself.
    public var isSuppressed: Bool {
        switch reason {
        case .suppressedByMode, .rule, .game: true
        case .allowedByMode, .excludedByRule, .notOnWiFi, .noTrigger: false
        }
    }

    /// Manual modes win. In automatic mode the app's rule wins over game detection, and
    /// suppression also needs Wi-Fi, since AWDL only competes with Wi-Fi traffic.
    public init(mode: Mode, app: ForegroundApp?, rules: [AppRule], isOnWiFi: Bool) {
        self.init(reason: Self.reason(mode: mode, app: app, rules: rules, isOnWiFi: isOnWiFi))
    }

    private static func reason(mode: Mode, app: ForegroundApp?, rules: [AppRule], isOnWiFi: Bool) -> Reason {
        switch mode {
        case .allow: return .allowedByMode
        case .suppress: return .suppressedByMode
        case .automatic: break
        }
        guard let app else { return .noTrigger }

        let trigger: Reason
        if let rule = rules.rule(for: app) {
            guard rule.isSuppressing else { return .excludedByRule(appName: rule.name) }
            trigger = .rule(appName: rule.name)
        } else if app.isGame {
            trigger = .game(appName: app.name)
        } else {
            return .noTrigger
        }
        return isOnWiFi ? trigger : .notOnWiFi
    }

    /// One line explaining the decision.
    public var explanation: String {
        switch reason {
        case .allowedByMode, .suppressedByMode: "All apps"
        case .rule(let name), .game(let name): "\(name) in foreground"
        case .excludedByRule(let name): "Allowed for \(name)"
        case .notOnWiFi: "Not on Wi-Fi"
        case .noTrigger: "No game in foreground"
        }
    }
}
