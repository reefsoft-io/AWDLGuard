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

    public var isSuppressed: Bool
    public var reason: Reason

    public init(isSuppressed: Bool, reason: Reason) {
        self.isSuppressed = isSuppressed
        self.reason = reason
    }

    /// Manual modes win. In automatic mode the app's rule wins over game detection, and
    /// suppression also needs Wi-Fi, since AWDL only competes with Wi-Fi traffic.
    public init(mode: Mode, app: ForegroundApp?, rules: [AppRule], isOnWiFi: Bool) {
        switch mode {
        case .allow:
            self.init(isSuppressed: false, reason: .allowedByMode)
            return
        case .suppress:
            self.init(isSuppressed: true, reason: .suppressedByMode)
            return
        case .automatic:
            break
        }

        guard let app else {
            self.init(isSuppressed: false, reason: .noTrigger)
            return
        }

        let trigger: Reason
        if let rule = rules.rule(for: app) {
            guard rule.isSuppressing else {
                self.init(isSuppressed: false, reason: .excludedByRule(appName: rule.name))
                return
            }
            trigger = .rule(appName: rule.name)
        } else if app.isGame {
            trigger = .game(appName: app.name)
        } else {
            self.init(isSuppressed: false, reason: .noTrigger)
            return
        }

        self = isOnWiFi
            ? Decision(isSuppressed: true, reason: trigger)
            : Decision(isSuppressed: false, reason: .notOnWiFi)
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
