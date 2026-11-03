import AppKit
import SwiftUI

/// Solid colours only: icons are dimmed with a fixed grey rather than opacity.
enum Palette {
    static let icon = Color(light: 0x6E6E73, dark: 0xA1A1A6)
    static let track = Color(light: 0xCFCFD6, dark: 0x4C4C52)
    /// Hover fill for rows and footer buttons, a tint of the text colour so it sits on the glass.
    static let rowHover = Color.primary.opacity(0.07)
    static let problemFill = Color(light: 0xF6F1E8, dark: 0x33302B)
    static let warning = Color(light: 0xC9781A, dark: 0xF0A43C)

    private static let normal = Color(light: 0x2C2C30, dark: 0xE8E8EC)
    private static let high = Color(light: 0xD98A1C, dark: 0xF0A43C)
    private static let critical = Color(light: 0xD8433E, dark: 0xF2615C)

    static func bar(for percent: Double) -> Color {
        if percent >= 90 { return critical }
        if percent >= 70 { return high }
        return normal
    }

    /// Text colour for a percentage: plain until it gets close to the limit.
    static func emphasis(for percent: Double) -> AnyShapeStyle {
        if percent >= 90 { return AnyShapeStyle(critical) }
        if percent >= 70 { return AnyShapeStyle(high) }
        return AnyShapeStyle(.primary)
    }

    static let avatars: [Color] = [0xD97757, 0x3F7AE0, 0x2E9469, 0x8360D6, 0x1A94A8, 0xC9507F].map { Color(nsColor: NSColor(hex: $0)) }

    static func avatar(_ index: Int) -> Color { avatars[abs(index) % avatars.count] }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
