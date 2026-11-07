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
        // The helper may have been approved, turned off or removed in System Settings.
        .onAppear { model.helper.refresh() }
    }

    /// Closes the menu and brings the window forward. A menu bar app isn't active while its
    /// menu is open, so the window would otherwise open behind the app in the foreground.
    private func show(_ id: String) {
        let wasOpen = AppWindow.find(id)?.isVisible == true
        dismiss()
        openWindow(id: id)
        NSApp.activate()
        if !wasOpen { AppWindow.centreOnPointerScreen(id) }
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
        }
    }
}

/// About AWDL Guard in the app menu, shown while the App Rules window is open.
private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About AWDL Guard") { openWindow(id: AppWindow.about) }
    }
}

/// The app's windows, found by their scene id.
@MainActor
enum AppWindow {
    static let rules = "rules"
    static let about = "about"

    /// SwiftUI names a scene's window after its id, with a suffix.
    static func find(_ id: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(id) == true }
    }

    /// Centres a window that's just been opened on the screen with the pointer, the one
    /// whose menu bar was just clicked, rather than wherever it was last.
    static func centreOnPointerScreen(_ id: String) {
        // SwiftUI creates the window on the next pass of the run loop.
        DispatchQueue.main.async {
            guard let window = find(id),
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
        if let window = AppWindow.find(AppWindow.rules), window.isVisible || window.isMiniaturized { return true }
        DispatchQueue.main.async { NSApp.deactivate() }
        return false
    }

    /// Finder makes an app it opens the active one. AWDL Guard starts as just its menu bar
    /// item, so it hands focus straight back to the app that had it, unless its menu or a
    /// window is already in use.
    private func returnFocus() {
        guard NSApp.isActive, NSApp.keyWindow == nil else { return }
        NSApp.deactivate()
    }
}
