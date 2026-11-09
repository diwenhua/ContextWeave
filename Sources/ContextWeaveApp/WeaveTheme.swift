import SwiftUI
import AppKit

enum Weave {
    static let canvas = Color.adaptive(light: 0xF3F0E8, dark: 0x12161C)
    static let sidebar = Color.adaptive(light: 0xE8E2D6, dark: 0x191E26)
    static let card = Color.adaptive(light: 0xFFFCF7, dark: 0x222833)
    static let thread = Color.adaptive(light: 0x0E6E66, dark: 0x67E0C6)
    static let ink = Color.adaptive(light: 0x1B2430, dark: 0xE8E2D6)
    static let muted = Color.adaptive(light: 0x5E6874, dark: 0xA7A194)
    static let codex = Color.adaptive(light: 0x2E4478, dark: 0xA9B8EA)
    static let harness = Color.adaptive(light: 0xA15C22, dark: 0xE7B06A)
    static let cursor = Color.adaptive(light: 0x5B4B8A, dark: 0xC4B5FD)
    static let cursorBadge = Color.adaptive(light: 0x5B4B8A, dark: 0x3B3156)
    static let line = Color.primary.opacity(0.08)

    static func agent(_ name: String) -> Color {
        switch name {
        case "dsh": harness
        case "cursor": cursor
        default: codex
        }
    }
}

private extension Color {
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return NSColor(hex: match == .darkAqua ? dark : light)
        }))
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
