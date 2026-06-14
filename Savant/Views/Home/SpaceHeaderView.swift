import SwiftUI

struct SpaceHeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.colorScheme) private var colorScheme

    let space: Space
    let spaces: [Space]
    let selectedIndex: Int
    let selectSpaceAtIndex: (Int) -> Void
    let tidyNow: () -> Void
    /// Live fractional page index — drives the continuous title transition.
    let pageOffset: SpacePageOffsetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpaceSymbolRail(spaces: spaces, selectedIndex: selectedIndex, select: selectSpaceAtIndex)
                .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: 12) {
                // Full-bleed to the screen edge; the page margin lives as the
                // title's rest inset, so it clips at the bezel as it slides off.
                SpaceTitleStrip(
                    spaces: spaces,
                    pageOffset: pageOffset,
                    dimmed: interaction.isEditing,
                    restInset: SavantTheme.pageMargin,
                    onTap: { appState.presentedSheet = .switcher }
                )

                Group {
                    if interaction.isEditing(spaceID: space.id) {
                        Button("Done") {
                            interaction.exitEditMode()
                        }
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.savantInk)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("edit-done")
                    } else {
                        menuCircle
                    }
                }
                .padding(.trailing, SavantTheme.pageMargin)
            }
        }
    }

    /// The single `…` circle absorbs search, edit, tidy, new-space and settings
    /// — the header carries only the strip, the title, and this one control.
    private var menuCircle: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") {
                appState.presentedSheet = .search(space)
            }
            Button("Edit notes", systemImage: "checkmark.circle") {
                interaction.enterEditMode(spaceID: space.id)
            }
            Button("Tidy now", systemImage: "sparkles", action: tidyNow)
            Divider()
            Button("New space", systemImage: "plus") {
                appState.presentedSheet = .newSpace
            }
            Button("Settings", systemImage: "gearshape") {
                appState.presentedSheet = .settings
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.savantSubtleInk)
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(SavantTheme.cardSurface(colorScheme))
                )
                .shadow(color: SavantTheme.cardShadow, radius: 9, y: 4)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("more-actions")
    }
}

/// The space title as a continuous, swipe-driven transition (Phase B): the two
/// nearest spaces' names slide and cross-fade in lockstep with the page offset,
/// so the title changes at the same rhythm as the color blend and the incoming
/// rows. Outgoing slides off and fades before it reaches the bezel; a brief
/// title-less header sits at the crossover; the incoming fades in while sliding
/// from just right-of-rest into the resting slot. A leaf — only this view reads
/// `pageOffset`, so the per-swipe-frame work doesn't invalidate the header.
private struct SpaceTitleStrip: View {
    let spaces: [Space]
    let pageOffset: SpacePageOffsetModel
    let dimmed: Bool
    /// The title's resting inset from the strip's leading edge. The strip itself
    /// spans to the SCREEN edge, so the title clips at the real bezel (not at the
    /// page margin) as it slides off — while still resting at the margin.
    let restInset: CGFloat
    let onTap: () -> Void

    /// Horizontal travel per unit page-distance; fade half-width in page units.
    /// A title is fully gone by ±fadeWidth, so the title-less gap spans
    /// `2·(0.5 − fadeWidth)` of the swipe — near 0.5 it shrinks to a tiny
    /// snapshot as the two titles hand off almost exactly at the midpoint.
    private let travel: CGFloat = 170
    private let fadeWidth: CGFloat = 0.50

    var body: some View {
        let offset = pageOffset.value
        ZStack(alignment: .leading) {
            ForEach(visibleIndices(offset), id: \.self) { idx in
                let d = CGFloat(idx) - offset
                Text(spaces[idx].name)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.savantInk)
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: restInset + d * travel)
                    .opacity(Double(max(0, 1 - abs(d) / fadeWidth)) * (dimmed ? 0.6 : 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
        .allowsHitTesting(!dimmed)
    }

    /// Only the spaces within fade range of the current offset need rendering.
    private func visibleIndices(_ offset: CGFloat) -> [Int] {
        let lo = max(0, Int((offset - 1).rounded(.down)))
        let hi = min(spaces.count - 1, Int((offset + 1).rounded(.up)))
        guard lo <= hi else { return [] }
        return Array(lo...hi)
    }
}

/// Top space strip: every space's symbol in a centered row. The current space
/// is full-color ink; the rest recede (desaturated + dimmed). Tapping a symbol
/// switches spaces. Frames are reported per space so a dragged note can be
/// dropped on a symbol to move it there (P4).
private struct SpaceSymbolRail: View {
    let spaces: [Space]
    let selectedIndex: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                let active = index == selectedIndex
                Button {
                    if !active { select(index) }
                } label: {
                    SpaceGlyph(value: space.emoji, size: 17)
                        .grayscale(active ? 0 : 1)
                        .opacity(active ? 1 : 0.35)
                        .scaleEffect(active ? 1 : 0.88)
                        .frame(width: 34, height: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(space.name)\(active ? ", current space" : "")")
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex)
    }
}
