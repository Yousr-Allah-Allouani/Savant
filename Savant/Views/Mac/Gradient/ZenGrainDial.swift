import AppKit
import SwiftUI

#if os(macOS)

/// Faithful native port of Zen's `PanelUI-zen-gradient-generator-texture-wrapper`
/// (zen-gradient-generator.css:364-433). A circular dial: 16 dots
/// arranged around a central preview circle showing the grain pattern
/// at the current intensity, with a small rotating handle indicating
/// the active step. Drag around the dial to set value 0…15.
struct ZenGrainDial: View {
    @Binding var value: Int

    @Environment(\.displayScale) private var displayScale
    @State private var lastTick: Int = -1

    private let stepCount = 16
    private let frame: CGFloat = 96

    var body: some View {
        ZStack {
            // 16 tick dots arranged around the perimeter. Inactive dots
            // are 40% opacity, active (≤ value) full.
            ForEach(0..<stepCount, id: \.self) { i in
                Circle()
                    .fill(.primary.opacity(i < value ? 0.62 : 0.22))
                    .frame(width: 4, height: 4)
                    .offset(y: -(frame / 2 - 8))
                    .rotationEffect(angleForStep(i))
            }

            // Central preview disc: shows the grain texture at the
            // current intensity, with the same dashed-circle stroke
            // Zen has via `&::after`.
            previewDisc

            // Rotating indicator handle.
            handle
        }
        .frame(width: frame, height: frame)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    let centerPt = CGPoint(x: frame / 2, y: frame / 2)
                    let dx = drag.location.x - centerPt.x
                    let dy = drag.location.y - centerPt.y
                    // SwiftUI atan2: 0 rad = right (3 o'clock). Shift
                    // by π/2 so step 0 sits at the top (12 o'clock).
                    var theta = atan2(dy, dx) + .pi / 2
                    if theta < 0 { theta += 2 * .pi }
                    let normalized = theta / (2 * .pi)
                    let stepped = Int((normalized * Double(stepCount)).rounded()) % stepCount
                    if stepped != value {
                        value = stepped
                        if stepped != lastTick {
                            lastTick = stepped
                            NSHapticFeedbackManager.defaultPerformer
                                .perform(.alignment, performanceTime: .now)
                        }
                    }
                }
        )
    }

    // MARK: - Pieces

    private var previewDisc: some View {
        let diameter = frame * 0.60
        return ZStack {
            Circle()
                .fill(.primary.opacity(0.04))
            // Actual grain at the current intensity. Borrows the same
            // tiled CGImage the window background uses, so the dial is
            // a true WYSIWYG preview.
            if value > 0, let cgImage = GrainTexture.shared.cgImage {
                // Match GrainOverlay exactly (native scale + same opacity curve)
                // so the dial is a true WYSIWYG preview of the window grain.
                Image(cgImage, scale: max(1, displayScale), label: Text(""))
                    .resizable(resizingMode: .tile)
                    .blendMode(.softLight)
                    .opacity(0.16 + (Double(value) / 15.0) * 0.62)
                    .clipShape(Circle())
            }
            Circle()
                .strokeBorder(
                    .primary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2.5])
                )
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    private var handle: some View {
        // 6×12 rounded bar that rotates around the dial. Matches Zen's
        // `#PanelUI-zen-gradient-generator-texture-handler` styling.
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(.primary.opacity(0.85))
            .frame(width: 6, height: 12)
            .offset(y: -(frame / 2 - 8))
            .rotationEffect(angleForStep(value))
            .animation(.snappy(duration: 0.12), value: value)
            .allowsHitTesting(false)
    }

    private func angleForStep(_ step: Int) -> Angle {
        .degrees(Double(step) / Double(stepCount) * 360)
    }
}

#endif
