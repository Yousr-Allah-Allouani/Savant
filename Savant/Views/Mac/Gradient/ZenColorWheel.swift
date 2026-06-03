import AppKit
import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)

/// Square HS pad with the React-component UX: one primary draggable
/// swatch in the middle of the pad, and up to two ghost satellite
/// swatches that follow the primary via `ZenSpread`. Angle = hue,
/// distance from center = saturation; lightness is shared across all
/// stops (no user-facing slider).
struct ZenColorPad: View {
    @Binding var config: ZenGradientConfig

    @Environment(\.colorScheme) private var colorScheme

    private let primarySize: CGFloat = 42
    private let satelliteSize: CGFloat = 26

    @State private var dragging = false

    private var isDark: Bool {
        config.resolvedDark(osIsDark: colorScheme == .dark)
    }

    /// Resolved (scheme-blended) color for a stop, so swatches match
    /// exactly how the space will render.
    private func resolved(hue: Double, saturation: Double) -> Color {
        ZenBlend.resolved(hue: hue, saturation: saturation,
                          intensity: config.intensity, dark: isDark)
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let center = CGPoint(x: radius, y: radius)

            ZStack {
                surface(size: size)
                dotGrid(size: size)

                ForEach(satellites(radius: radius, center: center)) { spec in
                    satelliteSwatch(color: spec.color)
                        .position(spec.position)
                        .allowsHitTesting(false)
                }

                primarySwatch
                    .position(primaryPosition(radius: radius, center: center))
                    .gesture(dragGesture(radius: radius, center: center))
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Backdrop

    private func surface(size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .clear],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .offset(y: 0.5)
                    .blendMode(.overlay)
            }
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: size, height: size)
    }

    private func dotGrid(size: CGFloat) -> some View {
        Canvas { ctx, canvasSize in
            let spacing: CGFloat = 12
            let color: Color = colorScheme == .dark
                ? .white.opacity(0.10) : .black.opacity(0.07)
            var x = spacing
            while x < canvasSize.width - 2 {
                var y = spacing
                while y < canvasSize.height - 2 {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)),
                             with: .color(color))
                    y += spacing
                }
                x += spacing
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .allowsHitTesting(false)
    }

    // MARK: - Swatches

    private var primarySwatch: some View {
        let fill = resolved(hue: config.primary.hue, saturation: config.primary.saturation)
        return ZStack {
            Circle()
                .fill(fill)
            Circle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 2.5)
            Circle()
                .stroke(.black.opacity(0.18), lineWidth: 0.5)
                .padding(2)
        }
        .frame(width: primarySize, height: primarySize)
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
        .scaleEffect(dragging ? 1.06 : 1.0)
        .animation(.smooth(duration: 0.12), value: dragging)
    }

    @ViewBuilder
    private func satelliteSwatch(color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2)
            )
            .frame(width: satelliteSize, height: satelliteSize)
            .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            .opacity(0.92)
    }

    // MARK: - Geometry

    private func primaryPosition(radius: CGFloat, center: CGPoint) -> CGPoint {
        let normalized = normalizedRadius(for: config.primary.saturation)
        let theta = config.primary.hue * .pi / 180
        return CGPoint(
            x: center.x + Foundation.cos(theta) * radius * normalized,
            y: center.y + Foundation.sin(theta) * radius * normalized
        )
    }

    private struct SatelliteSpec: Identifiable { let id: Int; let position: CGPoint; let color: Color }

    /// Satellites derive purely from the primary + spread, so they
    /// follow along as you drag the primary. Two when stopCount == 3,
    /// one when 2, zero when 1.
    private func satellites(radius: CGFloat, center: CGPoint) -> [SatelliteSpec] {
        guard config.stopCount > 1 else { return [] }
        let stops = config.colorStops
        var out: [SatelliteSpec] = []
        for (i, stop) in stops.enumerated() {
            let isPrimary = (config.stopCount == 2 && i == 0)
                || (config.stopCount == 3 && i == 1)
            if isPrimary { continue }
            let theta = stop.h * .pi / 180
            let normalized = normalizedRadius(for: stop.s)
            let pos = CGPoint(
                x: center.x + Foundation.cos(theta) * radius * normalized,
                y: center.y + Foundation.sin(theta) * radius * normalized
            )
            out.append(SatelliteSpec(
                id: i,
                position: pos,
                color: resolved(hue: stop.h, saturation: stop.s)
            ))
        }
        return out
    }

    private func normalizedRadius(for saturation: Double) -> CGFloat {
        let span = SafeColor.maxSaturation - SafeColor.minSaturation
        let raw = (saturation - SafeColor.minSaturation) / span
        return CGFloat(max(0, min(1, raw)))
    }

    // MARK: - Drag

    private func dragGesture(radius: CGFloat, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                dragging = true
                updatePrimary(to: value.location, radius: radius, center: center)
            }
            .onEnded { _ in
                dragging = false
            }
    }

    private func updatePrimary(to location: CGPoint, radius: CGFloat, center: CGPoint) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        let ratio = max(0, min(1, dist / radius))
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        let satSpan = SafeColor.maxSaturation - SafeColor.minSaturation
        config.primary.hue = angle
        config.primary.saturation = SafeColor.minSaturation + Double(ratio) * satSpan
    }
}

#endif
