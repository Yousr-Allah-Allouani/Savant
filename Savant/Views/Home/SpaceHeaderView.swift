import SwiftUI

struct SpaceHeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction

    let space: Space
    let spaces: [Space]
    let selectedIndex: Int
    let selectSpaceAtIndex: (Int) -> Void
    let tidyNow: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            CapsulePageDots(count: spaces.count, selectedIndex: selectedIndex, select: selectSpaceAtIndex)
                .frame(maxWidth: .infinity)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    appState.presentedSheet = .switcher
                } label: {
                    HStack(spacing: 8) {
                        Text(space.emoji)
                        Text(space.name)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.savantInk)
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
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityIdentifier("edit-done")
                } else {
                    headerActions
                }
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            GlassCircleButton(
                systemName: "magnifyingglass",
                accessibilityLabel: "Search",
                accessibilityIdentifier: "space-search"
            ) {
                appState.presentedSheet = .search(space)
            }

            Menu {
                Button("Edit notes", systemImage: "checkmark.circle") {
                    interaction.enterEditMode(spaceID: space.id)
                }
                Button("Tidy now", systemImage: "sparkles", action: tidyNow)
                Button("New space", systemImage: "plus") {
                    appState.presentedSheet = .newSpace
                }
                Button("Settings", systemImage: "gearshape") {
                    appState.presentedSheet = .settings
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("more-actions")
        }
    }
}
