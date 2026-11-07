import AppKit
import GuardPolicy
import SwiftUI

@main
struct AWDLGuardApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        let model = delegate.model

        Window("AWDL Guard", id: AppWindow.rules) {
            MainView(model: model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640, height: 520)
        // The app starts as just its menu bar item, and the window opens centred each time.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
        }

        Window("About AWDL Guard", id: AppWindow.about) {
            AboutView()
                .toolbar(removing: .title)
                .containerBackground(.regularMaterial, for: .window)
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra(
            isInserted: Binding(
                get: { !model.isMenuBarItemHidden },
                set: { isInserted in
                    // The user dragged the item out of the menu bar. It's the app's only way in,
                    // so the app quits. Hiding it from the menu sets the flag first instead.
                    if !isInserted, !model.isMenuBarItemHidden { NSApp.terminate(nil) }
                })
        ) {
            MenuContent(model: model)
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolVariant(model.status.tone == .suppressed ? .slash : .none)
                .accessibilityLabel("AWDL Guard, \(model.status.title)")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu panel, with the window and hide actions it starts.
private struct MenuContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MenuPanel(
            model: model,
            openRules: { show(AppWindow.rules) },
            openAbout: { show(AppWindow.about) },
            hideMenuBarItem: confirmHide
        )
        // The helper or the login item may have been changed in System Settings.
        .onAppear { model.refreshSystemState() }
    }

    /// Closes the menu, then brings the window forward.
    private func show(_ id: String) {
        dismiss()
        AppWindow.show(id, using: openWindow)
    }

    private func confirmHide() {
        dismiss()
        // After the menu has closed, so the alert isn't attached to it.
        DispatchQueue.main.async {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Hide Menu Bar Item?"
            alert.informativeText =
                "AWDL Guard keeps running in its current mode. Open it from Finder to show the menu bar item again."
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { model.isMenuBarItemHidden = true }
            // Give focus back to the app that had it, as at launch, unless a window is open.
            if !AppWindow.isOpen(AppWindow.rules), !AppWindow.isOpen(AppWindow.about) { NSApp.deactivate() }
        }
    }
}

/// About AWDL Guard in the app menu, shown while the AWDL Guard window is open.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About AWDL Guard") { AppWindow.show(AppWindow.about, using: openWindow) }
    }
}

/// The app's windows, found by their scene id.
@MainActor
enum AppWindow {
    static let rules = "rules"
    static let about = "about"

    /// Opens a window, or brings it forward, and makes AWDL Guard active, since a menu bar
    /// app isn't active while its menu is open. A window that wasn't open is centred on the
    /// screen with the pointer, rather than wherever it was last.
    static func show(_ id: String, using openWindow: OpenWindowAction) {
        let wasOpen = isOpen(id)
        openWindow(id: id)
        NSApp.activate()
        if !wasOpen { centreOnPointerScreen(id) }
    }

    /// Whether the window is on screen or in the Dock, minimised.
    static func isOpen(_ id: String) -> Bool {
        windows(id).contains { $0.isVisible || $0.isMiniaturized }
    }

    /// SwiftUI names a scene's window after its id, with a suffix, and may keep closed ones.
    private static func windows(_ id: String) -> [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    private static func centreOnPointerScreen(_ id: String) {
        // SwiftUI creates the window on the next pass of the run loop.
        DispatchQueue.main.async {
            guard let window = windows(id).first(where: \.isVisible),
                let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            else { return }
            let area = screen.visibleFrame
            window.setFrameOrigin(
                NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
        }
    }
}

/// Keeps AWDL Guard in the background when it starts or is opened again from Finder.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    /// True just after launch, while the activation Finder gives an app it opens may still
    /// arrive.
    private var isLaunching = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !isLoginLaunch { model.isMenuBarItemHidden = false }
        returnFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.isLaunching = false }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if isLaunching { returnFocus() }
    }

    /// Opening AWDL Guard from Finder while it runs shows a hidden menu bar item again,
    /// and otherwise leaves the app in the foreground alone.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.isMenuBarItemHidden = false
        // With the window open the app is in the Dock, and clicking it there behaves as usual.
        if AppWindow.isOpen(AppWindow.rules) { return true }
        DispatchQueue.main.async { NSApp.deactivate() }
        return false
    }

    /// A hidden menu bar item stays hidden only for a launch at login. Opened any other way,
    /// AWDL Guard shows it again, as the Hide alert promises. The launch's open-application
    /// event says which; it's available from `applicationDidFinishLaunching`, not before.
    private var isLoginLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Finder makes an app it opens the active one. AWDL Guard starts as just its menu bar
    /// item, so it hands focus straight back to the app that had it, unless its menu or a
    /// window is already in use.
    private func returnFocus() {
        guard NSApp.isActive, NSApp.keyWindow == nil else { return }
        NSApp.deactivate()
    }
}
