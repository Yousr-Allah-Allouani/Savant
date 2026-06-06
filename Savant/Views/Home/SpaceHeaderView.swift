import SwiftUI

struct SpaceHeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction

    let space: Space
    let spaces: [Space]
    let selectedIndex: Int
    let selectSpaceAtIndex: (Int) -> Void
    /// Editorial metadata line under the title (e.g. "12 notes").
    var subtitle: String? = nil
    let tidyNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpaceSymbolRail(spaces: spaces, selectedIndex: selectedIndex, select: selectSpaceAtIndex)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Button {
                    appState.presentedSheet = .switcher
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        SpaceGlyph(value: space.emoji, size: 26)
                        Text(space.name)
                            .font(.system(size: 34, weight: .semibold, design: .serif))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.savantSubtleInk)
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
                    .foregroundStyle(.savantInk)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("edit-done")
                } else {
                    headerActions
                }
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(.subheadline, design: .serif))
                    .italic()
                    .foregroundStyle(.savantSubtleInk)
            }

            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(height: 1)
                .padding(.top, 4)
        }
    }

    // Plain, un-boxed icon actions — editorial chrome recedes; the serif
    // identity + content carry the page. (No glass circles.)
    private var headerActions: some View {
        HStack(spacing: 16) {
            Button {
                appState.presentedSheet = .search(space)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .accessibilityIdentifier("space-search")

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
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 30, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .tint(.primary)
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("more-actions")
        }
        .foregroundStyle(.savantInk)
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
                    SpaceGlyph(value: space.emoji, size: 18)
                        .grayscale(active ? 0 : 1)
                        .opacity(active ? 1 : 0.4)
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
