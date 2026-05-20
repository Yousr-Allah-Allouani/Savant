import SwiftData
import SwiftUI

struct SpaceView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var interaction = InteractionMode()

    let space: Space
    let spaces: [Space]
    let notes: [Note]
    let folders: [Folder]
    let latestTidyRun: TidyRun?
    let selectedIndex: Int
    let selectSpaceAtIndex: (Int) -> Void
    let tidyNow: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        SpaceHeaderView(
                            space: space,
                            spaces: spaces,
                            selectedIndex: selectedIndex,
                            selectSpaceAtIndex: selectSpaceAtIndex,
                            tidyNow: tidyNow
                        )
                        .padding(.top, 18)

                        if let latestTidyRun, !interaction.isEditing {
                            TidyBannerView(run: latestTidyRun)
                                .padding(.top, 2)
                        }

                        contentSections
                            .padding(.bottom, 160)

                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 20)
                }
                .scrollIndicators(.hidden)
                .refreshable { tidyNow() }
                .onChange(of: randomNotes.map(\.id)) { _, _ in
                    scrollToBottom(proxy)
                }

                if interaction.isEditing(spaceID: space.id) {
                    MultiSelectActionBar(space: space, spaces: spaces, allNotes: notes)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(interaction)
            .onChange(of: space.id) { _, _ in
                if interaction.isEditing { interaction.exitEditMode() }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: interaction.isEditing)
        }
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            FavoritesTileRow(
                notes: favoriteNotes,
                allNotes: notes,
                spaces: spaces,
                currentSpace: space
            )

            if shouldShowPinnedDivider, !interaction.isDragging {
                SectionDivider()
            }

            PinnedSection(
                folders: pinnedFolders,
                notes: pinnedNotes,
                allNotes: notes,
                allFolders: folders,
                spaces: spaces,
                currentSpace: space
            )

            if shouldShowRandomDivider, !interaction.isDragging {
                SectionDivider()
            }

            RandomSection(
                folders: randomFolders,
                notes: randomNotes,
                allNotes: notes,
                allFolders: folders,
                spaces: spaces,
                currentSpace: space,
                tidyNow: tidyNow
            )
        }
    }

    private var shouldShowPinnedDivider: Bool {
        !favoriteNotes.isEmpty && (!pinnedNotes.isEmpty || !pinnedFolders.isEmpty || !randomNotes.isEmpty || !randomFolders.isEmpty)
    }

    private var shouldShowRandomDivider: Bool {
        (!pinnedNotes.isEmpty || !pinnedFolders.isEmpty) && (!randomNotes.isEmpty || !randomFolders.isEmpty)
    }

    private var favoriteNotes: [Note] {
        notes
            .filter { $0.tier == .favorite }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var pinnedNotes: [Note] {
        notes
            .filter { $0.tier == .pinned && $0.folder == nil && $0.space?.id == space.id }
            .sorted(by: noteSort)
    }

    private var randomNotes: [Note] {
        notes
            .filter { $0.tier == .random && $0.folder == nil && $0.space?.id == space.id }
            .sorted(by: noteSort)
    }

    private var pinnedFolders: [Folder] {
        folders
            .filter { $0.tier == .pinned && $0.parent == nil && $0.space?.id == space.id }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private var randomFolders: [Folder] {
        folders
            .filter { $0.tier == .random && $0.parent == nil && $0.space?.id == space.id }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private var bottomID: String { "space-bottom-\(space.id.uuidString)" }

    private func noteSort(_ lhs: Note, _ rhs: Note) -> Bool {
        switch (lhs.manualSortIndex, rhs.manualSortIndex) {
        case let (l?, r?): l < r
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.createdAt < rhs.createdAt
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !randomNotes.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}
