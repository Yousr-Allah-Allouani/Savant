import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        switch cleaned.count {
        case 3:
            red = Double((value >> 8) & 0xF) / 15.0
            green = Double((value >> 4) & 0xF) / 15.0
            blue = Double(value & 0xF) / 15.0
            alpha = 1.0
        case 6:
            red = Double((value >> 16) & 0xFF) / 255.0
            green = Double((value >> 8) & 0xFF) / 255.0
            blue = Double(value & 0xFF) / 255.0
            alpha = 1.0
        case 8:
            red = Double((value >> 24) & 0xFF) / 255.0
            green = Double((value >> 16) & 0xFF) / 255.0
            blue = Double((value >> 8) & 0xFF) / 255.0
            alpha = Double(value & 0xFF) / 255.0
        default:
            red = 0.78
            green = 0.83
            blue = 0.75
            alpha = 1.0
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    static func spaceColor(lightHex: String, darkHex: String, scheme: ColorScheme) -> Color {
        Color(hex: scheme == .dark ? darkHex : lightHex)
    }

    #if os(macOS)
    /// Linearly interpolates between two colors in sRGB. `t` is clamped to [0, 1].
    /// Used for progressive space-color transitions during a swipe.
    func mixed(with other: Color, by t: CGFloat) -> Color {
        let t = max(0, min(1, t))
        guard
            let a = NSColor(self).usingColorSpace(.sRGB),
            let b = NSColor(other).usingColorSpace(.sRGB)
        else { return self }
        return Color(
            .sRGB,
            red: Double(a.redComponent * (1 - t) + b.redComponent * t),
            green: Double(a.greenComponent * (1 - t) + b.greenComponent * t),
            blue: Double(a.blueComponent * (1 - t) + b.blueComponent * t),
            opacity: Double(a.alphaComponent * (1 - t) + b.alphaComponent * t)
        )
    }
    #endif
}

extension ShapeStyle where Self == Color {
    static var savantInk: Color {
        Color.primary.opacity(0.86)
    }

    static var savantSubtleInk: Color {
        Color.primary.opacity(0.58)
    }
}
