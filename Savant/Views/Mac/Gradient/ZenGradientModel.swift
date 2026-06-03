import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)

// MARK: - Color stop

/// The single user-controlled point on the wheel. Hue = angle around
/// center, saturation = normalized distance from center (clamped to the
/// SafeColor range). Lightness is global on the config so every derived
/// color stays in the safe band regardless of how the satellites spread.
struct ZenColorStop: Equatable, Codable {
    var hue: Double          // 0…360
    var saturation: Double   // clamped to SafeColor.minSaturation…maxSaturation
}

// MARK: - Scheme

/// Which appearance the picker is previewing / editing. `system` follows
/// the OS. Mirrors Zen's scheme buttons (auto / light / dark).
enum ZenColorScheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .system: return "sparkles"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}

// MARK: - Config

/// Per-Space color identity. The `primary` stop is the user-draggable
/// hue + saturation; satellites spread symmetrically by `ZenSpread`.
/// Brightness is authored *per scheme* — `lightLightness` for light
/// mode, `darkLightness` for dark — so the scheme toggle genuinely
/// designs both appearances (matching Zen/Arc). `previewScheme` is the
/// scheme currently shown in the picker; it persists so a Space can
/// remember "I prefer dark," but rendering still respects the OS when
/// it's `.system`.
struct ZenGradientConfig: Equatable, Codable {
    var primary: ZenColorStop
    var stopCount: Int          // 1, 2, or 3
    /// How strongly the picked color tints the window vs. the neutral
    /// scheme base. Ported from Zen's `currentOpacity` — the single
    /// most important value for getting good dark mode. Range ~0.2…0.9.
    var intensity: Double
    var grain: Int              // 0…15
    var previewScheme: ZenColorScheme

    static let maxStopCount: Int = 3
    static let minStopCount: Int = 1

    static let defaultConfig: ZenGradientConfig = ZenGradientConfig(
        primary: ZenColorStop(hue: 218, saturation: 82),
        stopCount: 1,
        intensity: 0.55,
        grain: 0,
        previewScheme: .system
    )

    static func encode(_ c: ZenGradientConfig) -> Data? { try? JSONEncoder().encode(c) }
    static func decode(_ d: Data) -> ZenGradientConfig? { try? JSONDecoder().decode(ZenGradientConfig.self, from: d) }

    func resolvedDark(osIsDark: Bool) -> Bool {
        switch previewScheme {
        case .system: return osIsDark
        case .light: return false
        case .dark: return true
        }
    }

    /// Hue/saturation of every stop (primary + satellites). Used for
    /// positioning dots on the pad and for resolving colors.
    var colorStops: [(h: Double, s: Double)] {
        let h = SafeColor.clampHue(primary.hue)
        let s = SafeColor.clampSaturation(primary.saturation)
        let count = max(ZenGradientConfig.minStopCount, min(ZenGradientConfig.maxStopCount, stopCount))
        if count == 1 { return [(h, s)] }
        let spread = ZenSpread.satelliteAngleDegrees(forSaturation: s)
        let rightHue = (h + spread).truncatingRemainder(dividingBy: 360)
        let leftHue  = (h - spread + 360).truncatingRemainder(dividingBy: 360)
        if count == 2 { return [(h, s), (rightHue, s)] }
        return [(leftHue, s), (h, s), (rightHue, s)]
    }

    /// Resolved SwiftUI colors for the renderer at the given scheme.
    func resolvedColors(forDark dark: Bool) -> [Color] {
        colorStops.map { ZenBlend.resolved(hue: $0.h, saturation: $0.s, intensity: intensity, dark: dark) }
    }

    var lightHex: String {
        ZenBlend.hex(hue: SafeColor.clampHue(primary.hue),
                     saturation: SafeColor.clampSaturation(primary.saturation),
                     intensity: intensity, dark: false)
    }

    var darkHex: String {
        ZenBlend.hex(hue: SafeColor.clampHue(primary.hue),
                     saturation: SafeColor.clampSaturation(primary.saturation),
                     intensity: intensity, dark: true)
    }
}

// MARK: - Zen-style blend

/// Faithful port of Zen's *macOS* color resolution
/// (ZenGradientGenerator.mjs `#getSingleRGBColor` + `blendWithWhiteOverlay`).
///
/// On macOS `canBeTransparent` is true, so Zen does NOT blend the color
/// toward a dark base — that path is Windows-only. Instead it:
///   1. lifts the pure color toward white by ~29% (`blendWithWhiteOverlay`),
///      which keeps the hue vivid and prevents muddiness, then
///   2. renders it **translucent** at `opacity` over the window. The
///      light or dark window showing through is what makes the same
///      color read as a soft pastel (light) or a deep tint (dark) —
///      no pigment is mixed toward black, so colors never go muddy.
///
/// We bake that composite into an opaque color here (over a near-white
/// or near-black backdrop) so callers can use it as a normal fill.
enum ZenBlend {
    /// Lightness the *pure* picked color is rendered at. 56 ≈ the most
    /// chromatic point in HSL.
    static let baseLightness: Double = 56

    /// The window material Zen composites over. macOS values from
    /// `getToolbarModifiedBaseRaw`.
    static let lightBackdrop: (Double, Double, Double) = (240.0/255, 240.0/255, 244.0/255)
    static let darkBackdrop:  (Double, Double, Double) = (23.0/255,  23.0/255,  26.0/255)

    static let minOpacity: Double = 0.1
    static let whiteOverlayOpacity: Double = 0.18

    static func resolvedRGB(hue: Double, saturation: Double, intensity: Double, dark: Bool)
        -> (Double, Double, Double)
    {
        let pure = HSL.rgb(h: hue, s: saturation, l: baseLightness)
        let alpha = max(0, min(1, intensity))

        // 1. White overlay — Zen's blendWithWhiteOverlay. Lightens the
        //    color so it stays vivid rather than going muddy.
        let blendedAlpha = min(1, alpha + minOpacity + whiteOverlayOpacity * (1 - (alpha + minOpacity)))
        func liftToWhite(_ c: Double) -> Double { c * blendedAlpha + 1.0 * (1 - blendedAlpha) }
        let lr = liftToWhite(pure.0), lg = liftToWhite(pure.1), lb = liftToWhite(pure.2)

        // 2. Composite the lifted color at `alpha` over the scheme
        //    backdrop (the translucency-over-window step).
        let bg = dark ? darkBackdrop : lightBackdrop
        let r = lr * alpha + bg.0 * (1 - alpha)
        let g = lg * alpha + bg.1 * (1 - alpha)
        let b = lb * alpha + bg.2 * (1 - alpha)
        return (r, g, b)
    }

    static func resolved(hue: Double, saturation: Double, intensity: Double, dark: Bool) -> Color {
        let (r, g, b) = resolvedRGB(hue: hue, saturation: saturation, intensity: intensity, dark: dark)
        return Color(red: r, green: g, blue: b)
    }

    static func hex(hue: Double, saturation: Double, intensity: Double, dark: Bool) -> String {
        let (r, g, b) = resolvedRGB(hue: hue, saturation: saturation, intensity: intensity, dark: dark)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Spread

/// Computes the satellite angle (in degrees) symmetrically around the
/// primary. Ported from `clementjanssens/color-picker`:
///
///     spread = (minSpread + (maxSpread - minSpread) * (r/R)^3) * spreadFactor
///
/// At the rim (high saturation) satellites are spread wide; near the
/// center (low saturation) they cluster around the primary. We map
/// saturation directly to `r/R`. The cubic curve keeps the center
/// gentle and the rim dramatic — same feel as the reference.
enum ZenSpread {
    /// Spread between primary and each satellite. We deliberately go
    /// wider than the React reference's 0.4 factor — the original
    /// produced spreads of ~24° at the rim that read as a single
    /// near-monochrome wash on the rendered window. Bumping to 0.75
    /// gives ~45° at the rim and ~90° at the center, so two-color and
    /// three-color presets actually look like gradients instead of
    /// subtle tints of one color.
    static let rimSpread: Double = .pi / 1.5
    static let centerSpread: Double = .pi / 3
    static let spreadFactor: Double = 0.75

    static func satelliteAngleDegrees(forSaturation saturation: Double) -> Double {
        // Map saturation [minSaturation, maxSaturation] to [0, 1] for r/R.
        let satSpan = SafeColor.maxSaturation - SafeColor.minSaturation
        let normalized = max(0, min(1,
            (saturation - SafeColor.minSaturation) / satSpan
        ))
        let cubic = pow(normalized, 3)
        let rad = (rimSpread + (centerSpread - rimSpread) * cubic) * spreadFactor
        return rad * 180 / .pi
    }
}

// MARK: - Presets

struct ZenColorPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let hue: Double
    let saturation: Double
    let intensity: Double
    /// Default stop count when this preset is applied. Lets us ship
    /// cuicui's gradient presets (sunset, peach blossom, …) as proper
    /// multi-stop presets while keeping single-color presets at 1.
    let stopCount: Int

    init(id: String, name: String, hue: Double, saturation: Double,
         intensity: Double = 0.55, stopCount: Int = 1) {
        self.id = id
        self.name = name
        self.hue = hue
        self.saturation = saturation
        self.intensity = intensity
        self.stopCount = stopCount
    }
}

/// Combined palette: cuicui-inspired multi-stop spreads + Cift's
/// single-color hand-picked tones. All clamped into the SafeColor
/// range so contrast remains legible.
enum ZenPresetLibrary {
    /// Presets are a 1:1 port of the cuicui repo's
    /// `arc-color-picker.tsx` COLORS array (lines 11-22) plus a few
    /// extra blues + Cift-derived tones for variety. Every entry is
    /// passed through the SafeColor clamp so it stays legible.
    ///
    /// Cuicui mapping (preset id → cuicui CSS):
    ///   sunrise  ← `linear-gradient(45deg, #f6d365, #fda085)`
    ///   sunset   ← `linear-gradient(45deg, #ff9a9e, #fad0c4)`
    ///   blossom  ← `linear-gradient(45deg, #ff9a9e, #fad0c4, #ffd1ff)`
    ///   mint_sky ← `linear-gradient(45deg, #84fab0, #8fd3f4)`
    ///   mint     ← `#79E7D0`
    ///   sky      ← `#7AA2F7`
    ///   stone    ← `#6B6E8D`
    static let presets: [ZenColorPreset] = [
        // Cuicui-derived gradient seeds
        ZenColorPreset(id: "sunrise",   name: "Sunrise",    hue: 38,  saturation: 92, intensity: 0.6, stopCount: 2),
        ZenColorPreset(id: "sunset",    name: "Sunset",     hue: 358, saturation: 90, intensity: 0.58, stopCount: 2),
        ZenColorPreset(id: "blossom",   name: "Blossom",    hue: 330, saturation: 85, intensity: 0.5, stopCount: 3),
        ZenColorPreset(id: "mint_sky",  name: "Mint Sky",   hue: 160, saturation: 85, intensity: 0.55, stopCount: 2),
        // Cuicui-derived single tones
        ZenColorPreset(id: "mint",      name: "Mint",       hue: 168, saturation: 90, intensity: 0.55),
        ZenColorPreset(id: "sky",       name: "Sky",        hue: 218, saturation: 95, intensity: 0.55),
        ZenColorPreset(id: "indigo",    name: "Indigo",     hue: 233, saturation: 80, intensity: 0.6),
        ZenColorPreset(id: "ocean",     name: "Ocean",      hue: 200, saturation: 88, intensity: 0.55),
        ZenColorPreset(id: "stone",     name: "Stone",      hue: 232, saturation: 28, intensity: 0.45),
        // Cift-derived single tones
        ZenColorPreset(id: "soft_green",  name: "Sage",       hue: 149, saturation: 68, intensity: 0.5),
        ZenColorPreset(id: "soft_yellow", name: "Warm Tan",   hue: 40,  saturation: 85, intensity: 0.55),
        ZenColorPreset(id: "soft_pink",   name: "Petal",      hue: 340, saturation: 80, intensity: 0.5),
        ZenColorPreset(id: "green",       name: "Moss",       hue: 135, saturation: 60, intensity: 0.5),
        ZenColorPreset(id: "purple",      name: "Lavender",   hue: 270, saturation: 70, intensity: 0.55),
        ZenColorPreset(id: "orange",      name: "Terracotta", hue: 18,  saturation: 85, intensity: 0.55),
        ZenColorPreset(id: "red",         name: "Rust",       hue: 5,   saturation: 80, intensity: 0.55)
    ]
}

// MARK: - Safe range

enum SafeColor {
    static let minSaturation: Double = 12
    /// Full vibrancy is fine now — the Zen-style blend toward a neutral
    /// base (see `ZenBlend`) keeps even a 100%-saturation pick legible.
    static let maxSaturation: Double = 100

    /// Intensity slider range. Below ~0.25 the tint is barely there;
    /// above ~0.9 dark mode starts to get harsh.
    static let intensityRange: ClosedRange<Double> = 0.25...0.9

    static func clampHue(_ hue: Double) -> Double {
        ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    }

    static func clampSaturation(_ s: Double) -> Double {
        max(minSaturation, min(maxSaturation, s))
    }
}

// MARK: - HSL math

enum HSL {
    static func color(h: Double, s: Double, l: Double) -> Color {
        let (r, g, b) = rgb(h: h, s: s, l: l)
        return Color(red: r, green: g, blue: b)
    }

    static func rgb(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hN = ((h.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360) / 360
        let sN = max(0, min(1, s / 100))
        let lN = max(0, min(1, l / 100))
        if sN == 0 { return (lN, lN, lN) }
        let q = lN < 0.5 ? lN * (1 + sN) : lN + sN - lN * sN
        let p = 2 * lN - q
        return (
            hueToRGB(p: p, q: q, t: hN + 1.0 / 3.0),
            hueToRGB(p: p, q: q, t: hN),
            hueToRGB(p: p, q: q, t: hN - 1.0 / 3.0)
        )
    }

    private static func hueToRGB(p: Double, q: Double, t: Double) -> Double {
        var t = t
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2.0 { return q }
        if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
        return p
    }

    static func hex(h: Double, s: Double, l: Double) -> String {
        let (r, g, b) = rgb(h: h, s: s, l: l)
        let R = Int((r * 255).rounded())
        let G = Int((g * 255).rounded())
        let B = Int((b * 255).rounded())
        return String(format: "#%02X%02X%02X", R, G, B)
    }
}

// MARK: - Space integration

extension Space {
    var gradientConfig: ZenGradientConfig? {
        guard let data = gradientConfigJSON else { return nil }
        return ZenGradientConfig.decode(data)
    }
}

#endif
