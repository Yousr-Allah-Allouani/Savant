import AppKit
import CoreGraphics
import SwiftUI

#if os(macOS)

/// Renders a `ZenGradientConfig` as a single-color tint + grain overlay.
/// Grain is a one-off CGImage generated at startup (cached) and tiled —
/// gives the appearance of real film grain without recomputing per draw.
struct ZenGradientBackground: View {
    let config: ZenGradientConfig
    /// Optional explicit scheme override (used by the picker preview).
    /// When nil, follows the OS appearance via the environment.
    var forceDark: Bool? = nil

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        forceDark ?? config.resolvedDark(osIsDark: colorScheme == .dark)
    }

    var body: some View {
        ZStack {
            base
            if config.grain > 0 {
                GrainOverlay(intensity: Double(config.grain) / 15.0)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var base: some View {
        let dark = isDark
        let colors = config.resolvedColors(forDark: dark)
        switch colors.count {
        case 0:
            Color.gray
        case 1:
            // Plain: subtle top-down wash. A faint white/black overlay
            // gives depth without changing the resolved tint.
            ZStack {
                colors[0]
                LinearGradient(
                    colors: [Color.white.opacity(dark ? 0.0 : 0.06), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
        case 2:
            // Clean diagonal sweep between both colors — full opacity
            // at each endpoint so both colors are clearly visible.
            // (Previous fade-to-transparent overlay made gradients
            // read as washed-out monochrome.)
            LinearGradient(
                colors: [colors[0], colors[1]],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            // 3 stops: diagonal linear gradient with each color
            // anchoring a third of the canvas. Same logic for 4+ stops
            // with proportional spacing.
            LinearGradient(
                gradient: Gradient(stops: colors.enumerated().map { i, c in
                    Gradient.Stop(
                        color: c,
                        location: CGFloat(i) / CGFloat(colors.count - 1)
                    )
                }),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

/// Tiled film-grain overlay (Arc-style): a FINE, crisp, per-pixel speckle.
///
/// Two things make it read like Arc rather than chunky TV static:
///   • It's rendered at the NATIVE pixel scale (`scale: displayScale`) so one
///     noise texel maps to exactly one device pixel. At `scale: 1` each texel
///     covered a 2×2 device-pixel block on Retina → coarse/soft.
///   • The texture is lightly chromatic (shared luminance + small independent
///     per-channel chroma), so specks pick up faint color like real film grain.
struct GrainOverlay: View {
    let intensity: Double  // 0…1

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        if let cgImage = GrainTexture.shared.cgImage {
            // scale = displayScale → 1 texel == 1 device pixel == finest grain.
            Image(cgImage, scale: max(1, displayScale), label: Text(""))
                .resizable(resizingMode: .tile)
                .blendMode(.softLight)
                .opacity(0.16 + intensity * 0.62)
        }
    }
}

/// Cached fine-grain film texture: independent per-pixel Gaussian noise (sharp,
/// high-frequency — like Arc's grain, NOT clumped). Lightly chromatic so specks
/// carry subtle color. Generated once, tiled. Also re-used by `ZenGrainDial`.
final class GrainTexture {
    static let shared = GrainTexture()

    let cgImage: CGImage?

    private init() {
        cgImage = Self.generate(size: 512)
    }

    private static func generate(size: Int) -> CGImage? {
        let count = size * size
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var data = [UInt8](repeating: 0, count: count * bytesPerPixel)
        var seed: UInt64 = 0xA1B2C3D4E5F60718

        // Mostly luminance grain with a small independent per-channel chroma
        // component — gives the faint colored specks Arc has without turning
        // the whole field rainbow.
        let lumAmp = 40.0
        let chromaAmp = 15.0

        for i in 0..<count {
            let lum = gaussian(&seed) * lumAmp
            let r = 128 + lum + gaussian(&seed) * chromaAmp
            let g = 128 + lum + gaussian(&seed) * chromaAmp
            let b = 128 + lum + gaussian(&seed) * chromaAmp
            let o = i * bytesPerPixel
            data[o]     = UInt8(max(0, min(255, Int(r))))
            data[o + 1] = UInt8(max(0, min(255, Int(g))))
            data[o + 2] = UInt8(max(0, min(255, Int(b))))
            data[o + 3] = 255
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// One N(0,1) sample via Box–Muller (cosine branch).
    private static func gaussian(_ seed: inout UInt64) -> Double {
        let u1 = Double(next(&seed) & 0xFFFF) / Double(0xFFFF)
        let u2 = Double(next(&seed) & 0xFFFF) / Double(0xFFFF)
        return sqrt(-2.0 * log(max(u1, 1e-6))) * cos(2 * .pi * u2)
    }

    private static func next(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

#endif
