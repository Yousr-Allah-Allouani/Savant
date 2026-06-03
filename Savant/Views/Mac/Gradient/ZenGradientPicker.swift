import AppKit
import SwiftUI

#if os(macOS)

/// Theme popover body. Matches the Zen layout: scheme toggle on top,
/// HS pad, ± stop count, horizontal preset strip, then a brightness
/// (wavy) slider + circular grain dial. Saturation is wheel-driven and
/// vivid; brightness is the slider; the scheme toggle authors light vs
/// dark appearance.
struct ZenGradientPicker: View {
    @Binding var config: ZenGradientConfig

    @Environment(\.colorScheme) private var osColorScheme
    @State private var presetPage: Int = 0
    private let presetsPerPage = 9

    private var isDark: Bool {
        config.resolvedDark(osIsDark: osColorScheme == .dark)
    }

    /// Force the whole popover into the previewed appearance so the
    /// backdrop, pad material, and swatches all reflect light vs dark
    /// (matching Zen's behavior). `.system` leaves the OS value alone.
    private var forcedScheme: ColorScheme? {
        switch config.previewScheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        content
            .environment(\.colorScheme, forcedScheme ?? osColorScheme)
    }

    private var content: some View {
        VStack(spacing: 16) {
            schemeToggle

            ZenColorPad(config: $config)
                .frame(width: 280, height: 280)

            stopCountRow

            presetStrip

            HStack(spacing: 14) {
                BrightnessSlider(
                    value: Binding(get: { config.intensity },
                                   set: { config.intensity = $0 }),
                    range: SafeColor.intensityRange
                )
                .frame(maxWidth: .infinity)

                ZenGrainDial(value: Binding(
                    get: { config.grain },
                    set: { config.grain = $0 }
                ))
            }
        }
        .padding(20)
        .frame(width: 360)
        // Tint the whole popover (content AND the arrow/beak) to the active
        // scheme so the picker previews how the space will feel and the beak
        // matches the surface rather than the system material.
        .presentationBackground { previewBackdrop }
    }

    @ViewBuilder
    private var previewBackdrop: some View {
        // A faint wash of the resolved color at the previewed scheme, so
        // the popover reads light or dark with the space tint behind it.
        let colors = config.resolvedColors(forDark: isDark)
        ZStack {
            (isDark ? Color.black : Color.white).opacity(isDark ? 0.22 : 0.10)
            if let first = colors.first {
                first.opacity(0.5)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Scheme toggle

    private var schemeToggle: some View {
        HStack(spacing: 6) {
            ForEach(ZenColorScheme.allCases) { scheme in
                Button {
                    config.previewScheme = scheme
                } label: {
                    Image(systemName: scheme.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(config.previewScheme == scheme
                                         ? Color.primary
                                         : Color.primary.opacity(0.5))
                        .frame(width: 34, height: 28)
                        .background(
                            config.previewScheme == scheme
                                ? Color.primary.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(scheme.rawValue.capitalized)
            }
        }
    }

    // MARK: - Stop count

    private var stopCountRow: some View {
        HStack(spacing: 22) {
            stopButton(symbol: "minus",
                       enabled: config.stopCount > ZenGradientConfig.minStopCount) {
                config.stopCount = max(ZenGradientConfig.minStopCount, config.stopCount - 1)
            }
            Text("\(config.stopCount)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary.opacity(0.65))
                .frame(width: 18)
            stopButton(symbol: "plus",
                       enabled: config.stopCount < ZenGradientConfig.maxStopCount) {
                config.stopCount = min(ZenGradientConfig.maxStopCount, config.stopCount + 1)
            }
        }
    }

    @ViewBuilder
    private func stopButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(enabled ? Color.primary.opacity(0.7) : Color.primary.opacity(0.25))
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Preset strip

    private var presetStrip: some View {
        let pages = pagedPresets
        let page = pages[safe: presetPage] ?? []
        return HStack(spacing: 8) {
            chevron(symbol: "chevron.left", enabled: presetPage > 0) {
                presetPage = max(0, presetPage - 1)
            }
            HStack(spacing: 8) {
                ForEach(page) { preset in
                    PresetSwatch(
                        preset: preset,
                        isSelected: matchesPreset(preset),
                        isDark: isDark,
                        onTap: { apply(preset) }
                    )
                }
                ForEach(0..<max(0, presetsPerPage - page.count), id: \.self) { _ in
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            chevron(symbol: "chevron.right", enabled: presetPage < pages.count - 1) {
                presetPage = min(pages.count - 1, presetPage + 1)
            }
        }
        .padding(.vertical, 2)
    }

    private var pagedPresets: [[ZenColorPreset]] {
        let all = ZenPresetLibrary.presets
        var result: [[ZenColorPreset]] = []
        var i = 0
        while i < all.count {
            let end = min(i + presetsPerPage, all.count)
            result.append(Array(all[i..<end]))
            i = end
        }
        return result.isEmpty ? [[]] : result
    }

    @ViewBuilder
    private func chevron(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        ChevronButton(symbol: symbol, enabled: enabled, action: action)
    }

    private func matchesPreset(_ preset: ZenColorPreset) -> Bool {
        abs(config.primary.hue - preset.hue) < 2
            && abs(config.primary.saturation - preset.saturation) < 2
            && config.stopCount == preset.stopCount
    }

    private func apply(_ preset: ZenColorPreset) {
        config.primary = ZenColorStop(hue: preset.hue, saturation: preset.saturation)
        config.intensity = preset.intensity
        config.stopCount = preset.stopCount
    }
}

// MARK: - Chevron paging button

private struct ChevronButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(enabled ? (isHovering ? 0.85 : 0.55) : 0.18))
                .frame(width: 20, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(enabled && isHovering ? 0.10 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHoverTracked { hovering in
            // Only react when the control is actually usable, and reset the
            // cursor cleanly when it becomes disabled mid-hover.
            isHovering = hovering && enabled
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - Preset swatch

private struct PresetSwatch: View {
    let preset: ZenColorPreset
    let isSelected: Bool
    let isDark: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle().fill(swatchFill)
                Circle().strokeBorder(
                    .primary.opacity(isSelected ? 0.9 : (hovering ? 0.32 : 0.12)),
                    lineWidth: isSelected ? 2 : 1
                )
            }
            .frame(width: 22, height: 22)
            .scaleEffect(isSelected ? 1.0 : (hovering ? 0.97 : 0.92))
            .help(preset.name)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.14), value: isSelected)
        .animation(.smooth(duration: 0.10), value: hovering)
    }

    private func resolved(_ hue: Double) -> Color {
        ZenBlend.resolved(hue: hue, saturation: preset.saturation,
                          intensity: preset.intensity, dark: isDark)
    }

    private var swatchFill: AnyShapeStyle {
        if preset.stopCount > 1 {
            let spread = ZenSpread.satelliteAngleDegrees(forSaturation: preset.saturation)
            let primary = resolved(preset.hue)
            let right = resolved(preset.hue + spread)
            let left = resolved(preset.hue - spread)
            let colors: [Color] = preset.stopCount == 2
                ? [primary, right, primary]
                : [left, primary, right, left]
            return AnyShapeStyle(AngularGradient(
                gradient: Gradient(colors: colors),
                center: .center,
                angle: .degrees(-90)
            ))
        }
        return AnyShapeStyle(resolved(preset.hue))
    }
}

// MARK: - Brightness slider (wavy)

private struct BrightnessSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 38
            let span = range.upperBound - range.lowerBound
            let percent = max(0, min(1, (value - range.lowerBound) / span))

            ZStack(alignment: .leading) {
                WavePath()
                    .stroke(.primary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: 14, height: trackHeight)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
                    .overlay(Capsule().strokeBorder(.black.opacity(0.10), lineWidth: 0.5))
                    .offset(x: percent * (geo.size.width - 14))
            }
            .frame(height: trackHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let p = max(0, min(1, drag.location.x / geo.size.width))
                        value = range.lowerBound + p * span
                    }
            )
        }
        .frame(height: 38)
    }
}

private struct WavePath: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let midY = rect.midY
        let waves = 5
        let waveWidth = rect.width / CGFloat(waves * 2)
        let amplitude: CGFloat = 8
        p.move(to: CGPoint(x: rect.minX, y: midY))
        var x = rect.minX
        var up = true
        for _ in 0..<(waves * 2) {
            let nextX = x + waveWidth
            let controlY = up ? midY - amplitude * 2 : midY + amplitude * 2
            p.addQuadCurve(to: CGPoint(x: nextX, y: midY),
                           control: CGPoint(x: x + waveWidth / 2, y: controlY))
            x = nextX
            up.toggle()
        }
        return p
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#endif
