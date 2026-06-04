import SwiftUI

// MARK: - Palette

/// Resolves a Space into an ordered palette of mesh colors for the current
/// scheme. Prefers the shared `ZenGradientConfig` (so iOS matches macOS),
/// and falls back to deriving related tones from the flat `colorHex` pair
/// for spaces that predate the gradient model.
enum SpaceMeshPalette {
    /// Three horizontal "anchor" colors (left → mid → right) that the mesh
    /// builds its 3×3 grid from. Always returns exactly three.
    static func anchors(for space: Space, dark: Bool) -> [Color] {
        if let config = space.gradientConfig {
            return expand(config.resolvedColors(forDark: dark))
        }
        let base = Color(hex: dark ? space.darkColorHex : space.colorHex)
        return derive(from: base)
    }

    /// Pad/blend a 1–3 color set into exactly three horizontal anchors.
    private static func expand(_ colors: [Color]) -> [Color] {
        switch colors.count {
        case 0:  return derive(from: Color(hex: "#7AA2F7"))
        case 1:  return derive(from: colors[0])
        case 2:  return [colors[0], colors[0].mixed(with: colors[1], by: 0.5), colors[1]]
        default: return Array(colors.prefix(3))
        }
    }

    /// Build three related anchors from a single seed color: a hue-shifted,
    /// slightly desaturated companion on each side keeps the world cohesive
    /// but never flat-monochrome.
    private static func derive(from seed: Color) -> [Color] {
        [
            seed.hueShifted(by: -22).adjusted(saturation: 0.92, brightness: 1.04),
            seed,
            seed.hueShifted(by: 22).adjusted(saturation: 1.04, brightness: 0.96)
        ]
    }
}

// MARK: - Animated mesh background

/// The immersive, luminous backdrop for a space. A 3×3 `MeshGradient` whose
/// interior + edge-mid control points drift on slow, out-of-phase sines so the
/// world feels alive without distracting. Corner points stay pinned to the
/// bounds so coverage is always full. A soft top glow adds depth.
struct SpaceMeshBackground: View {
    let space: Space
    /// When false (off-screen / reduce-motion), the mesh is rendered static.
    var animated: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let anchors = SpaceMeshPalette.anchors(for: space, dark: dark)
        let colors = Self.grid(from: anchors, dark: dark)

        ZStack {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: t),
                                 colors: colors,
                                 smoothsColors: true)
                }
            } else {
                MeshGradient(width: 3, height: 3,
                             points: Self.points(at: 0),
                             colors: colors,
                             smoothsColors: true)
            }

            // Luminous crown — a faint light bloom at the top that makes the
            // header content sit in light and gives the world a "sky".
            // softLight (both schemes) lifts the top gently without clipping
            // pale pastels to flat white.
            LinearGradient(
                colors: [Color.white.opacity(dark ? 0.12 : 0.32), .clear],
                startPoint: .top, endPoint: .center
            )
            .blendMode(.softLight)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    /// Expand three horizontal anchors into nine grid colors with a vertical
    /// lighting gradient: luminous at the top, grounded at the bottom.
    private static func grid(from anchors: [Color], dark: Bool) -> [Color] {
        // Row brightness multipliers (top → bottom).
        let rows: [CGFloat] = dark ? [1.22, 1.0, 0.84] : [1.14, 1.0, 0.86]
        let rowSat: [CGFloat] = dark ? [0.94, 1.0, 1.08] : [0.96, 1.0, 1.06]
        var out: [Color] = []
        for r in 0..<3 {
            for c in 0..<3 {
                out.append(anchors[c].adjusted(saturation: rowSat[r], brightness: rows[r]))
            }
        }
        return out
    }

    /// Nine control points. Corners pinned to the bounds (full coverage);
    /// edge-mid points slide along their edge; the center roams. Each axis
    /// uses a distinct slow frequency + phase so the drift never repeats
    /// obviously.
    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        func osc(_ period: Double, _ phase: Double, _ amp: Double) -> Float {
            Float(sin(t * (2 * .pi / period) + phase) * amp)
        }
        let topMidX:    Float = 0.5 + osc(13, 0.0, 0.10)
        let bottomMidX: Float = 0.5 + osc(17, 1.7, 0.10)
        let leftMidY:   Float = 0.5 + osc(15, 0.6, 0.10)
        let rightMidY:  Float = 0.5 + osc(19, 2.3, 0.10)
        let centerX:    Float = 0.5 + osc(21, 0.9, 0.07)
        let centerY:    Float = 0.5 + osc(23, 2.0, 0.07)

        return [
            SIMD2(0, 0), SIMD2(topMidX, 0),       SIMD2(1, 0),
            SIMD2(0, leftMidY), SIMD2(centerX, centerY), SIMD2(1, rightMidY),
            SIMD2(0, 1), SIMD2(bottomMidX, 1),    SIMD2(1, 1)
        ]
    }
}

// MARK: - Readable ink

extension Space {
    /// Near-black or white, whichever reads better over this space's mesh in
    /// the given scheme. Use for header titles / icons that sit on the world.
    func meshInk(dark: Bool) -> Color {
        let anchors = SpaceMeshPalette.anchors(for: self, dark: dark)
        // Average the mid anchor against the top-row brightening the header sits on.
        let mid = anchors[1].adjusted(brightness: dark ? 1.1 : 1.08)
        return mid.selectionInk
    }
}
