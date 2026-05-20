import SwiftUI

struct ExpandableGlassMenu<Content: View, Label: View>: View, Animatable {
    let alignment: Alignment
    var progress: CGFloat
    let labelSize: CGSize
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content
    @ViewBuilder let label: Label

    @State private var contentSize: CGSize = .zero

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GlassEffectContainer {
            let widthDiff = contentSize.width - labelSize.width
            let heightDiff = contentSize.height - labelSize.height
            let resolvedWidth = labelSize.width + widthDiff * contentOpacity
            let resolvedHeight = labelSize.height + heightDiff * contentOpacity

            ZStack(alignment: alignment) {
                content
                    .compositingGroup()
                    .scaleEffect(contentScale)
                    .blur(radius: 12 * blurProgress)
                    .opacity(contentOpacity)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        if abs(size.width - contentSize.width) > 1 || abs(size.height - contentSize.height) > 1 {
                            contentSize = size
                        }
                    }
                    .fixedSize()
                    .frame(width: resolvedWidth, height: resolvedHeight)

                label
                    .compositingGroup()
                    .blur(radius: 12 * blurProgress)
                    .opacity(1 - labelOpacity)
                    .frame(width: labelSize.width, height: labelSize.height)
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        }
        .scaleEffect(
            x: 1 - (blurProgress * 0.22),
            y: 1 + (blurProgress * 0.22),
            anchor: scaleAnchor
        )
        .offset(y: offset * blurProgress)
    }

    private var labelOpacity: CGFloat {
        min(progress / 0.35, 1)
    }

    private var contentOpacity: CGFloat {
        max(progress - 0.35, 0) / 0.65
    }

    private var contentScale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        let minAspectScale = min(labelSize.width / contentSize.width, labelSize.height / contentSize.height)
        return minAspectScale + (1 - minAspectScale) * progress
    }

    private var blurProgress: CGFloat {
        progress > 0.5 ? (1 - progress) / 0.5 : progress / 0.5
    }

    private var offset: CGFloat {
        switch alignment {
        case .bottom, .bottomLeading, .bottomTrailing: -40
        case .top, .topLeading, .topTrailing: 40
        default: 0
        }
    }

    private var scaleAnchor: UnitPoint {
        switch alignment {
        case .bottomLeading: .bottomLeading
        case .bottom: .bottom
        case .bottomTrailing: .bottomTrailing
        case .topLeading: .topLeading
        case .top: .top
        case .topTrailing: .topTrailing
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}
