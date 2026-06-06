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

/// Renders a space's icon, which may be an emoji glyph OR an SF Symbol name —
/// macOS-created spaces store symbol names (e.g. "lightbulb.fill") in the same
/// `emoji` field. Mirrors the macOS `MacSpaceIcon` detection so both platforms
/// render the same identity. Without this, iOS shows the literal string.
struct SpaceGlyph: View {
    let value: String
    var size: CGFloat
    var fallback: String = "✦"

    /// SF Symbol names are ASCII with dots/underscores; emoji has non-ASCII scalars.
    static func isSFSymbolName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        if s.unicodeScalars.contains(where: { !$0.isASCII }) { return false }
        return s.contains(".") || s.allSatisfy { $0.isLetter || $0 == "." }
    }

    var body: some View {
        if value.isEmpty {
            Text(fallback).font(.system(size: size))
        } else if Self.isSFSymbolName(value) {
            Image(systemName: value).font(.system(size: size * 0.86))
        } else {
            Text(value).font(.system(size: size))
        }
    }
}

/// One consistent header for every home tier (Anchors / Kept / Stream): a quiet
/// uppercase label, an optional count, an optional drag hint, and an optional
/// trailing control. Keeps the three sections visually identical instead of
/// each rolling its own.
struct SectionLabel<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(.savantInk)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .contentTransition(.numericText())
            }
            if let hint {
                Text("· \(hint)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(title: String, count: Int? = nil, hint: String? = nil) {
        self.init(title: title, count: count, hint: hint) { EmptyView() }
    }
}
