import AppKit
import GuardPolicy
import Network
import Observation
import ServiceManagement
import os

/// The app's state: the user's mode and rules, what's in the foreground and running, the
/// network, and the helper. `decision` is derived from these and sent to the helper
/// whenever it changes.
@MainActor @Observable
final class AppModel {
    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode) }
    }

    var rules: [AppRule] {
        didSet {
            saveRules()
            updateRuleDetails()
        }
    }

    /// Whether the user hid the menu bar item. AWDL Guard keeps running in its mode. Any
    /// launch other than at login shows the item again.
    var isMenuBarItemHidden: Bool {
        didSet { UserDefaults.standard.set(isMenuBarItemHidden, forKey: Keys.isMenuBarItemHidden) }
    }

    /// The frontmost app other than AWDL Guard itself, so opening its menu or window
    /// doesn't change the decision.
    private(set) var foreground: Foreground?
    /// What a rule would match for each running app, by process, kept by launch and quit
    /// notifications, for listing the rules of open apps first.
    private var runningTargets: [pid_t: AppTarget] = [:]
    private(set) var isOnWiFi = false
    /// Whether AWDL Guard opens at login, as the system last reported it.
    private(set) var loginItem: LoginItemState
    /// What the system knows about each rule's app, for its row in App Rules. Looked up in
    /// the background, so rows never query the system while drawing.
    private(set) var ruleDetails: [AppTarget: RuleDetails] = [:]
    let helper: HelperConnection

    var running: Set<AppTarget> { Set(runningTargets.values) }

    var decision: Decision {
        Decision(mode: mode, app: foreground?.app, rules: rules, isOnWiFi: isOnWiFi)
    }

    var status: Status {
        Status(decision: decision, helper: helper.state)
    }

    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private let log = Logger(subsystem: "io.reefsoft.AWDLGuard", category: "app")

    private enum Keys {
        static let mode = "mode"
        static let rules = "rules"
        /// Copies of stored rules that couldn't all be read, oldest first, so nothing is lost.
        static let unreadableRules = "rules.unreadable"
        static let isMenuBarItemHidden = "isMenuBarItemHidden"
    }

    init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .automatic
        rules = []
        isMenuBarItemHidden = defaults.bool(forKey: Keys.isMenuBarItemHidden)
        loginItem = LoginItemState(SMAppService.mainApp.status)
        helper = HelperConnection(appIdentifier: Bundle.main.bundleIdentifier ?? "io.reefsoft.AWDLGuard")
        helper.wantsSuppression = { [unowned self] in decision.isSuppressed }

        loadRules()
        observeApps()
        observeNetwork()
        observeDecision()
        helper.refresh()
    }

    /// Rereads what the user may have changed in System Settings. Called when the menu opens.
    func refreshSystemState() {
        helper.refresh()
        loginItem = LoginItemState(SMAppService.mainApp.status)
    }

    // MARK: Rules

    /// Adds a rule for a Mac app bundle or a Windows `.exe` chosen in Finder.
    func addRule(forFileAt url: URL) throws(AddRuleError) {
        if url.pathExtension.lowercased() == "app" {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { throw .noBundleIdentifier }
            rules.add(.macApp(bundleIdentifier: bundleIdentifier), name: AppInfo.displayName(ofAppAt: url))
        } else if AppTarget.isWindowsExecutable(url.lastPathComponent) {
            rules.add(
                .windowsApp(executableName: url.lastPathComponent),
                name: AppTarget.windowsAppName(url.lastPathComponent), fileURL: url)
        } else {
            throw .unsupportedFile
        }
    }

    func removeRule(_ rule: AppRule) {
        rules.removeAll { $0.id == rule.id }
    }

    /// Loads the stored rules. Entries that can't be read are skipped, and the stored data
    /// is first added to a list of copies, so the save that follows can't lose them.
    private func loadRules() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Keys.rules) else { return }
        let (stored, unreadableCount) = [AppRule].decoding(data)
        if unreadableCount > 0 {
            log.error("Skipped \(unreadableCount) unreadable stored rules; kept a copy in \(Keys.unreadableRules)")
            let copies = defaults.array(forKey: Keys.unreadableRules) as? [Data] ?? []
            defaults.set(copies + [data], forKey: Keys.unreadableRules)
        }
        rules = stored
    }

    private func saveRules() {
        do {
            UserDefaults.standard.set(try rules.encoded(), forKey: Keys.rules)
        } catch {
            log.error("Couldn't save rules: \(error, privacy: .public)")
        }
    }

    /// Whether the AWDL Guard window, which shows the rules, is open. Rule details are only
    /// looked up while it is. Opening it looks every rule up again, since apps may have been
    /// installed, moved or removed.
    var isRulesWindowOpen = false {
        didSet { if isRulesWindowOpen, !oldValue { lookUpDetails(for: rules) } }
    }

    /// Looks up details for rules that are new or whose chosen file changed, and drops
    /// details for removed rules.
    private func updateRuleDetails() {
        let current = Set(rules.map(\.target))
        ruleDetails = ruleDetails.filter { current.contains($0.key) }
        guard isRulesWindowOpen else { return }
        lookUpDetails(for: rules.filter { rule in ruleDetails[rule.target].map { $0.fileURL != rule.fileURL } ?? true })
    }

    private func lookUpDetails(for rules: [AppRule]) {
        guard !rules.isEmpty else { return }
        Task {
            let details = await Task.detached(priority: .userInitiated) {
                rules.map { RuleDetails(rule: $0) }
            }.value
            // Keep only details that still describe a rule as it is now; a later lookup
            // may have started for a rule that changed meanwhile.
            for detail in details
            where self.rules.contains(where: { $0.target == detail.target && $0.fileURL == detail.fileURL }) {
                ruleDetails[detail.target] = detail
            }
        }
    }

    // MARK: Login item

    /// Registers or unregisters AWDL Guard as a login item, then rereads what the system
    /// reports, which may be that it needs approval.
    func setOpensAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Couldn't change login item: \(error, privacy: .public)")
        }
        loginItem = LoginItemState(SMAppService.mainApp.status)
    }

    // MARK: Inputs

    private func observeApps() {
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications { runningTargets[app.processIdentifier] = AppInfo.target(app) }
        updateForeground(workspace.frontmostApplication)

        let center = workspace.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
            [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.updateForeground(app) }
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) {
            [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.runningTargets[app.processIdentifier] = AppInfo.target(app) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
            [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated { self?.appTerminated(app) }
        }
    }

    private func updateForeground(_ running: NSRunningApplication?) {
        guard let running, running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        foreground = Foreground(running: running, app: AppInfo.app(running))
    }

    /// A foreground app that quits stops deciding. If AWDL Guard itself is now in front,
    /// for example because its window was behind a game, nothing is in the foreground.
    private func appTerminated(_ app: NSRunningApplication) {
        runningTargets[app.processIdentifier] = nil
        guard app.processIdentifier == foreground?.running.processIdentifier else { return }
        foreground = nil
        // The quitting app may still be reported as frontmost for a moment.
        if let frontmost = NSWorkspace.shared.frontmostApplication, frontmost.processIdentifier != app.processIdentifier {
            updateForeground(frontmost)
        }
    }

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnWiFi = Self.usesWiFi(path)
            // The monitor runs on the main queue.
            MainActor.assumeIsolated { self?.isOnWiFi = isOnWiFi }
        }
        pathMonitor.start(queue: .main)
    }

    /// Wi-Fi is the primary path, or carries a VPN with no wired interface ahead of it.
    nonisolated private static func usesWiFi(_ path: NWPath) -> Bool {
        if path.usesInterfaceType(.wiredEthernet) { return false }
        if path.usesInterfaceType(.wifi) { return true }
        for interface in path.availableInterfaces {
            switch interface.type {
            case .wiredEthernet: return false
            case .wifi: return true
            default: continue
            }
        }
        return false
    }

    /// Sends the decision to the helper each time it changes. `Observations` may yield on
    /// any change to the inputs, such as each app switch, so repeats are skipped here.
    private func observeDecision() {
        let changes = Observations { [unowned self] in decision.isSuppressed }
        Task { [weak self] in
            var lastSent: Bool?
            for await isSuppressed in changes where isSuppressed != lastSent {
                lastSent = isSuppressed
                self?.helper.send()
            }
        }
    }
}

/// The frontmost app, with the running-application handle the menu uses for its icon.
struct Foreground {
    let running: NSRunningApplication
    let app: ForegroundApp
}

/// Whether AWDL Guard opens at login.
enum LoginItemState {
    case off
    case on
    /// Registered, but turned off under Open at Login in System Settings.
    case needsApproval

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .on
        case .requiresApproval: self = .needsApproval
        default: self = .off
        }
    }
}

/// Why a chosen file can't become a rule.
enum AddRuleError: Error {
    case noBundleIdentifier
    case unsupportedFile

    var message: String {
        switch self {
        case .noBundleIdentifier: "This app can't be identified, so it can't have a rule."
        case .unsupportedFile: "Choose a Mac app or a Windows .exe file."
        }
    }
}
