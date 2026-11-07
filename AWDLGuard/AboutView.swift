import SwiftUI

/// The About window, laid out like the system's: icon, name, version, copyright, then the
/// credits on one centred line.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
                .padding(.bottom, 6)
            Text("AWDL Guard")
                .font(.title2.weight(.bold))
            Text("Version \(Self.info("CFBundleShortVersionString")) (\(Self.info("CFBundleVersion")))")
                .font(.callout)
            Text(Self.info("NSHumanReadableCopyright"))
                .font(.callout)
            HStack(spacing: 4) {
                Text("Based on")
                CreditLink(title: "AWDL Control", url: "https://github.com/james-howard/AWDLControl")
                Text("by James Howard, after an idea from")
                CreditLink(title: "awdlkiller", url: "https://github.com/jamestut/awdlkiller")
                Text("by James Nugraha")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 28)
    }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
    }
}

/// A credited project's name: an underlined link with the pointing-hand cursor. Markdown
/// links inside Text can't change the cursor, so each link is its own view.
struct CreditLink: View {
    let title: String
    let url: String

    var body: some View {
        Link(title, destination: URL(string: url)!)
            .underline()
            .foregroundStyle(Theme.accentText)
            .pointerStyle(.link)
            .help(url)
    }
}
