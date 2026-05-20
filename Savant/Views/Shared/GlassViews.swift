import SwiftUI

struct GlassCapsuleButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct GlassCircleButton: View {
    let systemName: String
    var accessibilityLabel: String?
    var accessibilityIdentifier: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
        }
        .frame(width: 48, height: 48)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(accessibilityLabel ?? systemName.accessibilitySymbolLabel)
        .accessibilityIdentifier(accessibilityIdentifier ?? systemName)
    }
}

struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.15))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}

struct CapsulePageDots: View {
    let count: Int
    let selectedIndex: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    select(index)
                } label: {
                    Capsule()
                        .fill(.primary.opacity(index == selectedIndex ? 0.8 : 0.28))
                        .frame(width: index == selectedIndex ? 18 : 6, height: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Space \(index + 1)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: selectedIndex)
    }
}

extension String {
    var accessibilitySymbolLabel: String {
        replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
