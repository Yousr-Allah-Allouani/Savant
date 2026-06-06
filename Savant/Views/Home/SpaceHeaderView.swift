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
            SpaceSymbolRail(spaces: spaces, selectedIndex: selectedIndex, select: selectSpaceAtIndex)
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

/// macOS-style space rail: every space's symbol laid out in a row. The current
/// space sits full-color in a soft frosted chip (which glides between symbols on
/// switch); the rest are desaturated + dimmed. Tapping a symbol switches spaces.
/// Replaces the old anonymous page dots — you can see *which* worlds exist and
/// where you are at a glance, and jump straight to any of them.
private struct SpaceSymbolRail: View {
    let spaces: [Space]
    let selectedIndex: Int
    let select: (Int) -> Void

    @Namespace private var chip

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                let active = index == selectedIndex
                Button {
                    if !active { select(index) }
                } label: {
                    Text(space.emoji)
                        .font(.system(size: 18))
                        .grayscale(active ? 0 : 1)
                        .opacity(active ? 1 : 0.45)
                        .scaleEffect(active ? 1 : 0.86)
                        .frame(width: 36, height: 34)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .matchedGeometryEffect(id: "active-space-chip", in: chip)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(space.name)\(active ? ", current space" : "")")
            }
        }
        .padding(3)
        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex)
    }
}
