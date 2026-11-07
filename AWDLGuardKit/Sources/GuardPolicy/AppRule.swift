import Foundation

/// The app in the foreground, as far as the suppression decision cares.
public struct ForegroundApp: Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?
    /// File name of the running executable. For a CrossOver game this is the Windows
    /// executable, such as "Against the Storm.exe", and the app has no bundle identifier.
    public var executableName: String?
    /// The app's Info.plist declares it a game, by category or by Game Mode support.
    public var isGame: Bool

    public init(name: String, bundleIdentifier: String?, executableName: String?, isGame: Bool) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.executableName = executableName
        self.isGame = isGame
    }
}

/// Which app a rule applies to.
///
/// CrossOver runs Windows programs from a temporary folder whose name changes on every
/// launch, with no bundle identifier, so a Windows app is identified by its executable's
/// file name alone (compared without case).
public struct AppTarget: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case macApp
        case windowsApp
    }

    public let kind: Kind
    /// The bundle identifier of a Mac app, or the executable file name of a Windows app as
    /// first chosen. Equality and matching ignore case for Windows names.
    public let value: String

    private init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func macApp(bundleIdentifier: String) -> AppTarget {
        AppTarget(kind: .macApp, value: bundleIdentifier)
    }

    public static func windowsApp(executableName: String) -> AppTarget {
        AppTarget(kind: .windowsApp, value: executableName)
    }

    private var key: String {
        kind == .windowsApp ? value.lowercased() : value
    }

    public static func == (lhs: AppTarget, rhs: AppTarget) -> Bool {
        lhs.kind == rhs.kind && lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(key)
    }

    /// The target that would match `app`, or nil if a rule can't identify it.
    public init?(_ app: ForegroundApp) {
        self.init(bundleIdentifier: app.bundleIdentifier, executableName: app.executableName)
    }

    /// The target that would match a running app with this identity, or nil if a rule
    /// can't identify it.
    public init?(bundleIdentifier: String?, executableName: String?) {
        if let bundleIdentifier {
            self = .macApp(bundleIdentifier: bundleIdentifier)
        } else if let executableName, Self.isWindowsExecutable(executableName) {
            self = .windowsApp(executableName: executableName)
        } else {
            return nil
        }
    }

    public static func isWindowsExecutable(_ fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".exe")
    }

    /// A Windows app's name for display: its file name without ".exe", in any case. A name
    /// that is only ".exe" stays as it is.
    public static func windowsAppName(_ fileName: String) -> String {
        guard isWindowsExecutable(fileName), fileName.count > 4 else { return fileName }
        return String(fileName.dropLast(4))
    }
}

/// The user's choice for one app: suppress AWDL while it's in the foreground, or never suppress
/// for it. Turning a detected game off makes the rule an exclusion.
public struct AppRule: Identifiable, Hashable, Codable, Sendable {
    /// Which app the rule is for, and its id: there is one rule per app.
    public let target: AppTarget
    public var name: String
    public var isSuppressing: Bool
    /// Where a Windows game's .exe was chosen in Finder, for Show in Finder. Not used for
    /// matching, and nil when the rule came from the running app, whose path is temporary.
    /// Mac apps are found by bundle identifier instead.
    public var fileURL: URL?

    public var id: AppTarget { target }

    public init(target: AppTarget, name: String, isSuppressing: Bool = true, fileURL: URL? = nil) {
        self.target = target
        self.name = name
        self.isSuppressing = isSuppressing
        self.fileURL = fileURL
    }

    /// A rule for a running app, using the identity macOS reports for it. A Windows app is
    /// named without its ".exe". Nil for an app a rule can't identify.
    public init?(_ app: ForegroundApp, isSuppressing: Bool = true) {
        guard let target = AppTarget(app) else { return nil }
        let name = target.kind == .windowsApp ? AppTarget.windowsAppName(app.name) : app.name
        self.init(target: target, name: name, isSuppressing: isSuppressing)
    }
}

extension [AppRule] {
    /// Adds a rule for `target`, or turns an existing one back on, keeping one rule per app.
    public mutating func add(_ target: AppTarget, name: String, fileURL: URL? = nil) {
        if let index = firstIndex(where: { $0.target == target }) {
            self[index].isSuppressing = true
            if let fileURL { self[index].fileURL = fileURL }
        } else {
            append(AppRule(target: target, name: name, fileURL: fileURL))
        }
    }

    /// Adds a rule for a running app. Does nothing for an app a rule can't identify.
    public mutating func add(_ app: ForegroundApp) {
        guard let rule = AppRule(app) else { return }
        add(rule.target, name: rule.name)
    }

    /// Whether automatic mode suppresses for `app`: its rule if it has one, otherwise
    /// whether it's a detected game.
    public func suppresses(_ app: ForegroundApp) -> Bool {
        rule(for: app)?.isSuppressing ?? app.isGame
    }

    /// Records the user's choice for `app` as its rule, creating the rule if needed.
    /// Turning a detected game off this way makes an exclusion.
    public mutating func setSuppresses(_ isSuppressing: Bool, for app: ForegroundApp) {
        guard let rule = AppRule(app, isSuppressing: isSuppressing) else { return }
        if let index = firstIndex(where: { $0.target == rule.target }) {
            self[index].isSuppressing = isSuppressing
        } else {
            append(rule)
        }
    }

    /// The order rules are shown in: rules for running apps first, then the rest, each
    /// group alphabetical, and equal names by app. Derived for display; the stored order is
    /// untouched.
    public func displayOrder(running: Set<AppTarget>) -> [AppRule] {
        sorted { first, second in
            let isFirstRunning = running.contains(first.target)
            let isSecondRunning = running.contains(second.target)
            if isFirstRunning != isSecondRunning { return isFirstRunning }
            switch first.name.localizedStandardCompare(second.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame:
                return (first.target.kind.rawValue, first.target.value.lowercased())
                    < (second.target.kind.rawValue, second.target.value.lowercased())
            }
        }
    }

    public func rule(for app: ForegroundApp) -> AppRule? {
        guard let target = AppTarget(app) else { return nil }
        return first { $0.target == target }
    }
}

// MARK: - Storage

extension [AppRule] {
    /// The stored form of the rules.
    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Reads stored rules entry by entry, so one unreadable entry doesn't lose the others,
    /// and keeps the first rule for each app. `unreadableCount` counts the entries skipped,
    /// or is 1 when the data isn't a list of rules at all.
    public static func decoding(_ data: Data) -> (rules: [AppRule], unreadableCount: Int) {
        guard let entries = try? JSONDecoder().decode([StoredEntry].self, from: data) else { return ([], 1) }
        var rules: [AppRule] = []
        var targets: Set<AppTarget> = []
        var unreadableCount = 0
        for entry in entries {
            guard let rule = entry.rule else {
                unreadableCount += 1
                continue
            }
            if targets.insert(rule.target).inserted { rules.append(rule) }
        }
        return (rules, unreadableCount)
    }
}

/// One stored rule, or nil if it can't be read.
private struct StoredEntry: Decodable {
    let rule: AppRule?

    init(from decoder: any Decoder) throws {
        rule = try? AppRule(from: decoder)
    }
}
