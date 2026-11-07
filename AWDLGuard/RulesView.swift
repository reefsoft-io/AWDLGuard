import AppKit
import GuardPolicy
import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Rules

/// The main window's content: the user's per-app choices.
struct RulesList: View {
    @Bindable var model: AppModel
    @Binding var isAdding: Bool

    var body: some View {
        if model.rules.isEmpty {
            ContentUnavailableView {
                Label("No App Rules Yet", systemImage: "square.grid.2x2")
            } description: {
                Text("Games already turn AWDL off on their own. Add an app to include it, or a game to leave it out.")
            } actions: {
                Button { isAdding = true } label: {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(AccentButtonStyle())
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    RulesLegend()
                        .padding(.bottom, 8)
                    ForEach(order) { rule in
                        RuleRow(
                            rule: binding(for: rule),
                            isInForeground: model.foreground.map { rule.target.matches($0.app) } == true
                        ) {
                            model.removeRule(rule)
                        }
                    }
                }
                .animation(.snappy, value: order.map(\.id))
                .padding(20)
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
    }

    private var order: [AppRule] { model.rules.displayOrder(running: model.running) }

    /// The stored rule with `rule`'s id, so a row edits the rule itself, not its place in
    /// the display order.
    private func binding(for rule: AppRule) -> Binding<AppRule> {
        Binding(
            get: { model.rules.first { $0.id == rule.id } ?? rule },
            set: { newValue in
                if let index = model.rules.firstIndex(where: { $0.id == rule.id }) {
                    model.rules[index] = newValue
                }
            })
    }
}

/// The key to the rows' switches, above the list. The window title and the switches
/// themselves carry the rest, so there's no heading or explanation.
struct RulesLegend: View {
    var body: some View {
        HStack(spacing: 18) {
            legend(isOn: true, text: "AWDL off while in foreground")
            legend(isOn: false, text: "AWDL stays on")
        }
        .font(.callout)
        .padding(.horizontal, 4)
    }

    private func legend(isOn: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                .frame(width: 22, height: 13)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 9).padding(2)
                }
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

struct RuleRow: View {
    @Binding var rule: AppRule
    /// Marks the rule that's deciding right now, linking the list to the menu.
    let isInForeground: Bool
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AppInfo.icon(for: rule.target))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.name)
                        .font(.body.weight(.medium))
                    if isInForeground {
                        Text("In Foreground")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: .capsule)
                    }
                }
                if let kind = AppInfo.kindDescription(for: rule) {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .red)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Remove")
            .accessibilityLabel("Remove \(rule.name)")
            Toggle("Turn AWDL off while \(rule.name) is in the foreground", isOn: $rule.isSuppressing)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            if isInForeground {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1.5)
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            let location = AppInfo.location(of: rule)
            Button("Show in Finder") {
                if let location { NSWorkspace.shared.activateFileViewerSelecting([location]) }
            }
            .disabled(location == nil)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

// MARK: - Add app

/// Choosing a Mac app or a CrossOver Windows game, with a guide for finding the right `.exe`.
struct AddAppSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AppTarget.Kind = .macApp

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add App")
                        .font(.title2.weight(.bold))
                    Text("Choose an app to turn AWDL off while it's in the foreground.")
                        .foregroundStyle(.secondary)
                }

                CapsulePicker(
                    selection: $kind,
                    options: [(.macApp, "Mac App"), (.windowsApp, "Windows Game")])

                Group {
                    switch kind {
                    case .macApp: macGuide
                    case .windowsApp: windowsGuide
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb")
                        .foregroundStyle(Theme.accentText)
                    Text("Shortcut: with the app open, flip its switch under **App in foreground** in the menu bar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
            .padding(24)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(NeutralButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(kind == .macApp ? "Choose App…" : "Choose .exe…", action: choose)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
        .animation(.snappy(duration: 0.2), value: kind)
    }

    private var macGuide: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "app.badge.checkmark")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accentText)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick it from your Applications folder.")
                Text("Games are already detected. Add one only to leave it out.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var windowsGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the game's .exe file in its CrossOver bottle:")
                .foregroundStyle(.secondary)
            GuideStep(number: 1, text: "In CrossOver, select the bottle and click **Open C: Drive**.")
            GuideStep(number: 2, text: "Steam games are in **Program Files (x86) › Steam › steamapps › common**.")
            GuideStep(number: 3, text: "Open the game's folder and pick its .exe, such as **Against the Storm.exe**.")
            GuideStep(number: 4, text: "Avoid launchers, crash reporters and files in **Redist** folders.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .macApp:
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(filePath: "/Applications")
            panel.message = "Choose a Mac app"
        case .windowsApp:
            panel.allowedContentTypes = [UTType(filenameExtension: "exe") ?? .executable]
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/CrossOver/Bottles")
            panel.message = "Choose the game's .exe"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addRule(forFileAt: url)
        dismiss()
    }
}

struct GuideStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: .circle)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The secondary action beside an `AccentButtonStyle` button: same shape and size, neutral fill.
struct NeutralButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.1), in: .capsule)
            .contentShape(.capsule)
    }
}

/// The primary action: NVIDIA green with black text, which keeps contrast on this green.
struct AccentButtonStyle: ButtonStyle {
    /// The smaller size used inside a card.
    var isCompact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(isCompact ? .callout.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, isCompact ? 12 : 16)
            .padding(.vertical, isCompact ? 5 : 7)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: .capsule)
            .contentShape(.capsule)
    }
}
