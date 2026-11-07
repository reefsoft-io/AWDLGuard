import AppKit
import SwiftUI

/// The app's colour tokens. NVIDIA green is the only accent; everything else is system
/// neutral so the app sits quietly in the menu bar.
enum Theme {
    /// NVIDIA green, for fills: the selected mode, switches, the primary button.
    static let accent = Color(red: 0x76 / 255, green: 0xB9 / 255, blue: 0x00 / 255)
    /// The accent at more brightness, keeping its hue and full saturation, for the status
    /// icon: a thin glyph reads darker than a filled control.
    static let vividAccent: Color = {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        NSColor(accent).usingColorSpace(.sRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(hue: hue, saturation: saturation, brightness: min(brightness * 1.18, 1))
    }()
    /// Text and symbols on an accent fill. White on this green measures about 2.4:1; black about 8.7:1.
    static let onAccent = Color.black
    /// Green for text and symbols on the window background: darker in light mode for contrast.
    static let accentText = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0x76 / 255, green: 0xB9 / 255, blue: 0x00 / 255, alpha: 1)
                : NSColor(red: 0x4A / 255, green: 0x75 / 255, blue: 0x00 / 255, alpha: 1)
        })
    /// Background of a card or row on the menu or window.
    static let cardFill = Color.primary.opacity(0.06)
    static let cardRadius: CGFloat = 12
}
