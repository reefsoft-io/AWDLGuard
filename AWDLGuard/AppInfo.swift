import AppKit
import GuardPolicy
import UniformTypeIdentifiers

/// What the system knows about apps: their identity as a rule sees it, icons, names and
/// where they are on disk.
enum AppInfo {
    /// A running app as the suppression decision sees it.
    static func app(_ running: NSRunningApplication) -> ForegroundApp {
        ForegroundApp(
            name: running.localizedName ?? running.executableURL?.lastPathComponent ?? "Unknown App",
            bundleIdentifier: running.bundleIdentifier,
            executableName: running.executableURL?.lastPathComponent,
            isGame: running.bundleURL.map(declaresGame) ?? false)
    }

    /// What a rule would match for a running app, without reading its Info.plist.
    static func target(_ running: NSRunningApplication) -> AppTarget? {
        AppTarget(bundleIdentifier: running.bundleIdentifier, executableName: running.executableURL?.lastPathComponent)
    }

    /// macOS decides Game Mode from the same two Info.plist keys.
    static func declaresGame(_ bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app", let info = Bundle(url: bundleURL)?.infoDictionary else { return false }
        return info["LSApplicationCategoryType"] as? String == "public.app-category.games"
            || info["LSSupportsGameMode"] as? Bool == true
    }

    static func icon(for target: AppTarget) -> NSImage {
        switch target.kind {
        case .macApp:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.value) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSWorkspace.shared.icon(for: .application)
        case .windowsApp:
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: "exe") ?? .executable)
        }
    }

    /// A rule's subtitle, when it adds something: the .exe a Windows rule matches, or that a
    /// Mac app is a detected game, so turning it off reads as an exception.
    static func kindDescription(for rule: AppRule) -> String? {
        switch rule.target.kind {
        case .windowsApp:
            return "Windows Game · \(rule.target.value)"
        case .macApp:
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.target.value)
            return url.map(declaresGame) == true ? "Game" : nil
        }
    }

    /// Where the rule's app is on disk, for Show in Finder: a Mac app found by bundle
    /// identifier, or the .exe chosen in Finder. Nil for a Windows game added from the menu.
    static func location(of rule: AppRule) -> URL? {
        switch rule.target.kind {
        case .macApp: NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.target.value)
        case .windowsApp: rule.fileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }
    }

    /// The icon for an app that has no details yet, looked up once.
    @MainActor static let genericIcon = NSWorkspace.shared.icon(for: .application)

    /// The app's own name, without ".app" even when Finder shows extensions.
    static func displayName(ofAppAt url: URL) -> String {
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

/// What the system knows about a rule's app, looked up once for its row: these are
/// LaunchServices, Info.plist and disk reads.
///
/// `@unchecked Sendable` because NSImage isn't marked Sendable; these images are made once
/// and only read after.
struct RuleDetails: @unchecked Sendable {
    let target: AppTarget
    /// The rule's chosen file these details were built from, so a change is noticed.
    let fileURL: URL?
    let icon: NSImage
    let kind: String?
    let location: URL?

    init(rule: AppRule) {
        target = rule.target
        fileURL = rule.fileURL
        icon = AppInfo.icon(for: rule.target)
        kind = AppInfo.kindDescription(for: rule)
        location = AppInfo.location(of: rule)
    }
}
