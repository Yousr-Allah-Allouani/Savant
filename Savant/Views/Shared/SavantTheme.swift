import SwiftUI

/// Savant's visual identity tokens (Figma skeleton, 2026-06): soft milk-white
/// surfaces floating on the space accent color, rounded-sans type, film grain.
/// Shared by the iOS and macOS targets so both shells speak the same language.
enum SavantTheme {
    // MARK: Radii

    /// Essentials tiles.
    static let cardRadius: CGFloat = 24
    /// Full-width note/folder rows.
    static let rowRadius: CGFloat = 22
    /// Small chips (space rail active chip, count badges).
    static let chipRadius: CGFloat = 11

    // MARK: Spacing

    static let pageMargin: CGFloat = 20
    /// Vertical air around tier dividers.
    static let tierSpacing: CGFloat = 18
    /// Gap between rows inside a tier.
    static let rowSpacing: CGFloat = 10

    // MARK: Surfaces

    /// Primary card surface — essentials tiles, kept rows, the `…` circle.
    static func cardSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.88)
    }

    /// Quieter surface — stream rows sit closer to the accent color.
    static func softSurface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.52)
    }

    /// Thin tier divider on the accent color.
    static func hairline(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.18 : 0.13)
    }

    /// Soft ambient drop shadow under cards.
    static let cardShadow = Color.black.opacity(0.07)
}

/// Soft milk-white card treatment: fill + continuous corners + ambient shadow.
struct SavantCardSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var radius: CGFloat
    /// `true` = quieter stream-row surface; `false` = primary card surface.
    var soft: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(soft
                          ? SavantTheme.softSurface(colorScheme)
                          : SavantTheme.cardSurface(colorScheme))
            )
            .shadow(color: soft ? .clear : SavantTheme.cardShadow, radius: 9, y: 4)
    }
}

extension View {
    func savantCard(radius: CGFloat = SavantTheme.rowRadius, soft: Bool = false) -> some View {
        modifier(SavantCardSurface(radius: radius, soft: soft))
    }
}
