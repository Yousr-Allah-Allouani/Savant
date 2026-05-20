import SwiftUI

struct DropZonePlaceholder: View {
    let tier: NoteTier
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(
                .primary.opacity(isTargeted ? 0.55 : 0.28),
                style: StrokeStyle(lineWidth: isTargeted ? 1.5 : 1, dash: [5, 4])
            )
            .frame(maxWidth: .infinity)
            .frame(height: tier == .favorite ? 96 : 64)
            .overlay {
                Label(label, systemImage: symbol)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(isTargeted ? .primary : .secondary)
                    .textCase(.uppercase)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.primary.opacity(isTargeted ? 0.10 : 0.04))
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .animation(.easeOut(duration: 0.18), value: isTargeted)
    }

    private var label: String {
        switch tier {
        case .favorite: "Drop to favorite"
        case .pinned: "Drop to pin"
        case .random: "Drop here"
        case .archived: "Archive"
        }
    }

    private var symbol: String {
        switch tier {
        case .favorite: "star.fill"
        case .pinned: "pin.fill"
        case .random: "tray"
        case .archived: "archivebox"
        }
    }
}

struct DropZoneAura: ViewModifier {
    let isActive: Bool
    let isTargeted: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(isTargeted ? 0.10 : 0))
                    .animation(.easeOut(duration: 0.15), value: isTargeted)
            )
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            .primary.opacity(isTargeted ? 0.55 : 0.22),
                            lineWidth: isTargeted ? 1.6 : 1
                        )
                        .animation(.easeOut(duration: 0.18), value: isTargeted)
                }
            }
    }
}

extension View {
    func dropZoneAura(active: Bool, targeted: Bool, cornerRadius: CGFloat = 16) -> some View {
        modifier(DropZoneAura(isActive: active, isTargeted: targeted, cornerRadius: cornerRadius))
    }
}
