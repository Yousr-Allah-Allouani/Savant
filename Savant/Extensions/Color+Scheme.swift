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

    /// WCAG relative luminance in [0, 1]. Used to choose readable ink over an
    /// arbitrary space-color fill (pale pastels vs dark-mode tones).
    var relativeLuminance: Double {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
            + 0.7152 * lin(c.greenComponent)
            + 0.0722 * lin(c.blueComponent)
    }

    /// Readable text/glyph color for content drawn on a selected pill filled
    /// with `self`. Compares the WCAG contrast ratio of near-black vs white
    /// against the fill and returns whichever reads better — so the selected
    /// row stays legible on a cream theme *and* a dark navy theme. Near-black
    /// (rather than pure black) softens the result on light fills.
    var selectionInk: Color {
        let lum = relativeLuminance
        let contrastWhite = 1.05 / (lum + 0.05)
        let contrastBlack = (lum + 0.05) / 0.05
        return contrastBlack >= contrastWhite ? Color.black.opacity(0.85) : .white
    }

    /// Elevated, space-tinted fill for a *selected* row/tile pill (Arc-style
    /// lift). It sits LIGHTER than the space-tinted sidebar background so the
    /// pill reads as a raised card rather than melting into the surface, while
    /// keeping a hint of the space hue so selection stays themed. Pair with
    /// `.selectionInk` (computed on the returned color) for readable text and
    /// a soft shadow for depth.
    /// Adjusts the color's saturation/brightness multiplicatively (HSB). Used to
    /// derive a deeper, more vibrant version of a pastel space color.
    func adjusted(saturation sFactor: CGFloat, brightness bFactor: CGFloat) -> Color {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h),
                     saturation: Double(min(1, max(0, s * sFactor))),
                     brightness: Double(min(1, max(0, b * bFactor))),
                     opacity: Double(a))
    }

    func elevatedSelectionFill(scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark:
            // Lift the dark space tone toward a raised dark-card surface —
            // a little lighter than the background, not stark white.
            return mixed(with: Color(white: 0.95), by: 0.26)
        default:
            // Near-white wash that keeps a faint space tint (~20%).
            return mixed(with: .white, by: 0.80)
        }
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
