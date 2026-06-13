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

// `GrainOverlay` and `GrainTexture` moved to `Views/Shared/GrainOverlay.swift`
// (shared with the iOS space backdrop).

#endif
