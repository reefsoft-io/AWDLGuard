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
        didSet { saveRules() }
    }

    /// Whether the user hid the menu bar item. AWDL Guard keeps running in its mode, and
    /// opening it from Finder shows the item again.
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
        static let isMenuBarItemHidden = "isMenuBarItemHidden"
    }

    init() {
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Keys.mode).flatMap(Mode.init(rawValue:)) ?? .automatic
        rules =
            defaults.data(forKey: Keys.rules).flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? []
        isMenuBarItemHidden = defaults.bool(forKey: Keys.isMenuBarItemHidden)
        helper = HelperConnection(appIdentifier: Bundle.main.bundleIdentifier ?? "io.reefsoft.AWDLGuard")
        helper.wantsSuppression = { [unowned self] in decision.isSuppressed }

        observeApps()
        observeNetwork()
        observeDecision()
        helper.refresh()
    }

    // MARK: Rules

    /// Adds a rule for a Mac app bundle or a Windows `.exe` chosen in Finder.
    func addRule(forFileAt url: URL) {
        if url.pathExtension.lowercased() == "app" {
            guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return }
            rules.add(.macApp(bundleIdentifier: bundleIdentifier), name: AppInfo.displayName(ofAppAt: url))
        } else if AppTarget.isWindowsExecutable(url.lastPathComponent) {
            rules.add(
                .windowsApp(executableName: url.lastPathComponent), name: url.deletingPathExtension().lastPathComponent,
                fileURL: url)
        }
    }

    func removeRule(_ rule: AppRule) {
        rules.removeAll { $0.id == rule.id }
    }

    private func saveRules() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(rules), forKey: Keys.rules)
        } catch {
            assertionFailure("Couldn't encode rules: \(error)")
        }
    }

    // MARK: Login item

    /// Whether AWDL Guard opens at login; the system's registration is the only record.
    var opensAtLogin: Bool {
        get { access(keyPath: \.opensAtLogin); return SMAppService.mainApp.status == .enabled }
        set {
            withMutation(keyPath: \.opensAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    log.error("Couldn't change login item: \(error, privacy: .public)")
                }
            }
        }
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
            MainActor.assumeIsolated { self?.runningTargets[app.processIdentifier] = nil }
        }
    }

    private func updateForeground(_ running: NSRunningApplication?) {
        guard let running, running.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        foreground = Foreground(running: running, app: AppInfo.app(running))
    }

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnWiFi = Self.usesWiFi(path)
            Task { @MainActor in self?.isOnWiFi = isOnWiFi }
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
