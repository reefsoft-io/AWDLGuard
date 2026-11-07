import AppKit
import GuardPolicy
import HelperInterface
import ServiceManagement
import SwiftUI

/// The menu bar window: the current state and its controls, the app settings, and the
/// way into App Rules. It sits on the system's glass menu window, so everything inside
/// uses plain fills. Helper install, approval and repair appear in the status card,
/// where the problem is shown, rather than as a second set of controls.
struct MenuPanel: View {
    @Bindable var model: AppModel
    var openRules: () -> Void
    var openAbout: () -> Void
    var hideMenuBarItem: () -> Void
    /// Holding Option swaps Quit for Hide Menu Bar Item, like an alternate menu item.
    @State private var isOptionHeld = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AWDL Guard")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 4)

            // The global choice comes first, then what it produces now, then the one app
            // it currently concerns, so the mode never reads as that app's setting.
            ModePicker(mode: $model.mode)

            StatusCard(status: model.status, action: helperAction)

            if let foreground = model.foreground, model.mode == .automatic {
                MenuSection(title: "App in foreground") {
                    ForegroundRow(model: model, foreground: foreground)
                }
            }

            // A setting, so it's a row with its state always visible, like the app above.
            LoginItemRow(state: model.loginItem, setOpensAtLogin: model.setOpensAtLogin)

            Divider().padding(.horizontal, -4)

            HStack(spacing: 6) {
                MenuRow(title: "App Rules…", systemImage: "square.grid.2x2", action: openRules)
                IconButton(title: "About", systemImage: "info.circle", action: openAbout)
                if isOptionHeld {
                    IconButton(title: "Hide Menu Bar Item", systemImage: "eye.slash", action: hideMenuBarItem)
                } else {
                    IconButton(title: "Quit", systemImage: "power") { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .tint(Theme.accent)
        .onModifierKeysChanged(mask: .option, initial: true) { _, keys in
            isOptionHeld = keys.contains(.option)
        }
    }

    /// The fix for a helper problem, shown in the status card.
    private var helperAction: StatusCard.Action? {
        let helper = model.helper
        return switch model.status.remedy {
        case .install: StatusCard.Action(title: "Install…") { helper.install() }
        case .approve: StatusCard.Action(title: "Open Settings…") { helper.openApproval() }
        case .repair: StatusCard.Action(title: "Repair") { Task { await helper.repair() } }
        case nil: nil
        }
    }
}

/// Open at Login, with the state the system reports. When it's on but turned off in
/// System Settings, the row says where to allow it and offers the way there.
struct LoginItemRow: View {
    let state: LoginItemState
    let setOpensAtLogin: @MainActor @Sendable (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Toggle(isOn: Binding(get: { state != .off }, set: setOpensAtLogin)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open at Login")
                    if state == .needsApproval {
                        Text("Allow under Open at Login")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if state == .needsApproval {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Open Settings…").frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(isCompact: true))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))
    }
}

/// A plain button that shows a light fill in `shape` while the pointer is over it.
struct HoverButtonStyle<S: Shape>: ButtonStyle {
    let shape: S

    func makeBody(configuration: Configuration) -> some View {
        Highlight(label: configuration.label, isPressed: configuration.isPressed, shape: shape)
    }

    private struct Highlight: View {
        let label: Configuration.Label
        let isPressed: Bool
        let shape: S
        @State private var isHovered = false

        var body: some View {
            label
                .opacity(isPressed ? 0.6 : 1)
                .background(isHovered ? Theme.cardFill : .clear, in: shape)
                .contentShape(shape)
                .onHover { isHovered = $0 }
        }
    }
}

/// A small round footer action, labelled by its tooltip.
struct IconButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(HoverButtonStyle(shape: Circle()))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A small caption over a group in the menu.
struct MenuSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
        }
    }
}

/// The state, verified against the helper. The antenna is green only when the helper
/// confirmed awdl0 is down, and red when the decision isn't in effect.
struct StatusCard: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let status: Status
    var action: Action?

    /// The same icon column, spacing and padding as `ForegroundRow`, so the icon and the
    /// text line up with the app icon and name below. Title and detail are one line each,
    /// so every state has the same layout and nothing moves between them.
    private static let iconSize: CGFloat = 32
    private nonisolated static let symbolSize: CGFloat = 24
    private nonisolated static let capHeight: CGFloat = NSFont.systemFont(ofSize: symbolSize, weight: .bold).capHeight

    var body: some View {
        VStack(spacing: 10) {
            row
            // The fix for a helper problem goes under the state it fixes, so the row keeps
            // the same layout in every state.
            if let action {
                Button(action: action.perform) {
                    Text(action.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(AccentButtonStyle(isCompact: true))
            }
        }
        .padding(10)
        .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))
        .animation(.snappy, value: status.tone)
    }

    private var row: some View {
        HStack(spacing: 10) {
            // The antenna in every state, as tall as the two lines of text beside it, in one
            // solid colour. Off is its slash variant, so the replace transition draws the
            // slash on; while waiting for the helper its waves light up outwards in a loop.
            Image(systemName: "antenna.radiowaves.left.and.right")
                .symbolVariant(status.tone == .suppressed ? .slash : .none)
                .font(.system(size: Self.symbolSize, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(glyphStyle)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .variableColor.iterative.dimInactiveLayers.nonReversing,
                    options: .repeat(.continuous), isActive: status.tone == .pending)
                // Centre the glyph the way text does, on the font's cap height above the
                // baseline, not on the image's box: the slash variant's box is 5 pt taller
                // because the slash sticks out, so box-centring dropped the antenna 2.5 pt.
                .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - Self.capHeight / 2 }
                .frame(width: Self.iconSize, height: Self.iconSize)
                // The title and detail say the same, and VoiceOver would read the symbol's name.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(status.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(status.detail)
            .accessibilityElement(children: .combine)
        }
    }

    /// The glyph alone carries the state, always at full strength: green when AWDL is
    /// confirmed off, red when the decision isn't in effect, the text colour otherwise.
    private var glyphStyle: Color {
        switch status.tone {
        case .suppressed: Theme.vividAccent
        case .problem: .red
        case .allowed, .pending: .primary
        }
    }
}

/// The app in the foreground, with the same switch as its row in App Rules: on turns AWDL
/// off while it's in the foreground. The switch starts from game detection; changing it
/// saves a rule, using the identity macOS reports, so a Windows game needs no file hunting.
struct ForegroundRow: View {
    let model: AppModel
    let foreground: Foreground

    var body: some View {
        let app = foreground.app
        let rule = model.rules.rule(for: app)
        let canHaveRule = AppTarget(app) != nil
        HStack(spacing: 10) {
            Image(nsImage: foreground.running.icon ?? AppInfo.genericIcon)
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(rule?.name ?? app.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(basis(app: app, rule: rule, canHaveRule: canHaveRule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle(
                "Turn AWDL off while \(rule?.name ?? app.name) is in the foreground",
                isOn: Binding(
                    get: { model.rules.suppresses(app) },
                    set: { model.rules.setSuppresses($0, for: app) })
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(!canHaveRule)
        }
        .padding(10)
        .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// The app's kind, as in its App Rules row, and whether it has a rule. The switch shows
    /// the rest.
    private func basis(app: ForegroundApp, rule: AppRule?, canHaveRule: Bool) -> String {
        guard canHaveRule else { return "Not Supported" }
        let kind = AppTarget(app)?.kind == .windowsApp ? "Windows Game" : app.isGame ? "Game" : "App"
        return rule == nil ? kind : "\(kind) · In App Rules"
    }
}

/// Automatic / Allow / Suppress.
struct ModePicker: View {
    @Binding var mode: Mode

    var body: some View {
        CapsulePicker(selection: $mode, options: Mode.allCases.map { ($0, $0.title) })
            .accessibilityLabel("Mode")
    }
}

/// A full-width segmented choice with the selection filled in NVIDIA green.
struct CapsulePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let isSelected = selection == value
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = value }
                } label: {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.onAccent : .primary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.accent)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.cardFill, in: .capsule)
        .accessibilityElement(children: .contain)
    }
}

extension Mode {
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .allow: "Allow"
        case .suppress: "Suppress"
        }
    }
}

/// A full-width footer action with an icon and a title.
struct MenuRow: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .buttonStyle(HoverButtonStyle(shape: Capsule()))
    }
}

#Preview("Status") {
    ScrollView {
        VStack(spacing: 10) {
            ForEach(Array(previewStatuses.enumerated()), id: \.offset) { _, status in
                StatusCard(
                    status: status,
                    action: status.remedy.map { _ in StatusCard.Action(title: "Fix…") {} })
            }
        }
        .padding(14)
        .frame(width: 320)
    }
    .frame(height: 700)
}

/// Every state the status card can show, built from the real decision and helper values.
private let previewStatuses: [Status] = {
    let suppress = Decision(reason: .game(appName: "GeForce NOW"))
    let allow = Decision(reason: .noTrigger)
    func connected(_ observation: InterfaceObservation) -> HelperState { .connected(observation) }
    let states: [(Decision, HelperState)] = [
        (suppress, connected(InterfaceObservation(isSuppressing: false, isInterfaceUp: true))),
        (suppress, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: false))),
        (
            suppress,
            connected(
                InterfaceObservation(
                    isSuppressing: true, isInterfaceUp: true, failure: InterfaceFailure(operation: .bringDown, code: EPERM)))
        ),
        (suppress, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: nil))),
        (allow, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: false))),
        (
            allow,
            connected(
                InterfaceObservation(
                    isSuppressing: false, isInterfaceUp: false, failure: InterfaceFailure(operation: .bringUp, code: EPERM)))
        ),
        (allow, connected(InterfaceObservation(isSuppressing: false, isInterfaceUp: false))),
        (suppress, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: false, reactivationCount: 4))),
        (suppress, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: true))),
        (
            suppress,
            connected(
                InterfaceObservation(
                    isSuppressing: false, isInterfaceUp: true,
                    failure: InterfaceFailure(operation: .recordState, code: EROFS)))
        ),
        (suppress, connected(InterfaceObservation(isSuppressing: true, isInterfaceUp: false, isWatching: false))),
        (allow, connected(InterfaceObservation(isSuppressing: true, isHeldForOthers: true, isInterfaceUp: false))),
        (allow, connected(InterfaceObservation(isSuppressing: false, isInterfaceUp: true))),
        (suppress, .connecting),
        (suppress, .repairing),
        (suppress, .notInstalled),
        (suppress, .installFailed("The operation couldn't be completed.")),
        (suppress, .needsApproval),
        (suppress, .notResponding),
    ]
    return states.map { Status(decision: $0.0, helper: $0.1) }
}()
