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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpaceSymbolRail(spaces: spaces, selectedIndex: selectedIndex, select: selectSpaceAtIndex)
                .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: 12) {
                Button {
                    appState.presentedSheet = .switcher
                } label: {
                    Text(space.name)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.savantInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(.plain)
                .disabled(interaction.isEditing)
                .opacity(interaction.isEditing ? 0.6 : 1)

                Spacer(minLength: 8)

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
