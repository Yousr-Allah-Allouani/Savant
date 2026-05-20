import SwiftData
import SwiftUI

struct FavoritesTileRow: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let notes: [Note]
    let allNotes: [Note]
    let spaces: [Space]
    let currentSpace: Space

    @State private var isTargeted = false

    var body: some View {
        let dragActive = interaction.isDragging
        let isEmpty = notes.isEmpty

        if isEmpty && !dragActive {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Favorites")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.savantSubtleInk)
                        .textCase(.uppercase)
                    if dragActive {
                        Text("• drop to favorite")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                    Spacer()
                }

                if isEmpty && dragActive {
                    DropZonePlaceholder(tier: .favorite, isTargeted: isTargeted)
                        .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                            handleDrop(items)
                        } isTargeted: { isTargeted = $0 }
                } else {
                    tilesGroup
                        .dropZoneAura(active: dragActive, targeted: isTargeted, cornerRadius: 20)
                        .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                            handleDrop(items)
                        } isTargeted: { isTargeted = $0 }
                }
            }
            .animation(.easeOut(duration: 0.18), value: dragActive)
        }
    }

    @ViewBuilder private var tilesGroup: some View {
        if notes.count == 1, let note = notes.first {
            FavoriteTile(note: note, style: .large, spaces: spaces, currentSpace: currentSpace)
        } else if notes.count == 2 {
            HStack(spacing: 10) {
                ForEach(notes) { note in
                    FavoriteTile(note: note, style: .medium, spaces: spaces, currentSpace: currentSpace)
                }
            }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(notes) { note in
                        FavoriteTile(note: note, style: .compact, spaces: spaces, currentSpace: currentSpace)
                            .frame(width: 150)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func handleDrop(_ items: [DraggedItemTransfer]) -> Bool {
        guard let first = items.first, first.kind == .note else { return false }
        guard let note = allNotes.first(where: { $0.id == first.id }) else { return false }
        let service = NoteService(context: modelContext)
        do {
            try service.promote(note, to: .favorite, currentSpace: currentSpace)
            return true
        } catch {
            assertionFailure("Favorite drop failed: \(error)")
            return false
        }
    }
}

private enum FavoriteTileStyle {
    case large
    case medium
    case compact
}

private struct FavoriteTile: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let note: Note
    let style: FavoriteTileStyle
    let spaces: [Space]
    let currentSpace: Space

    var body: some View {
        tileContent
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: style == .large ? 130 : 112, alignment: .topLeading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
            .onTapGesture(count: 2) { appState.presentEdit(note) }
            .onTapGesture { appState.presentRead(note) }
            .draggable(DraggedItemTransfer.note(note.id)) {
                NoteDragPreview(note: note)
                    .dragLifecycleHook(interaction)
            }
            .contextMenu {
                Button("Edit", systemImage: "pencil") { appState.presentEdit(note) }
                Button("Unfavorite", systemImage: "star.slash") {
                    update { try $0.promote(note, to: .pinned, currentSpace: currentSpace) }
                }
                Menu("Move to space", systemImage: "arrow.left.arrow.right") {
                    ForEach(spaces) { space in
                        Button("\(space.emoji) \(space.name)") {
                            update { try $0.move(note, to: space) }
                        }
                    }
                }
                Button("Archive", systemImage: "archivebox") {
                    update { try $0.archive(note) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    update { try $0.delete(note) }
                }
            }
    }

    @ViewBuilder private var tileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.caption)
                Text(note.title)
                    .font(.system(style == .large ? .title3 : .body, design: .rounded).weight(.semibold))
                    .lineLimit(style == .large ? 2 : 1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
            }
            if style != .compact {
                Text(note.bodyMarkdown.isEmpty ? "No body yet" : note.bodyMarkdown)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .large ? 4 : 2)
            }
        }
    }

    private func update(_ work: (NoteService) throws -> Void) {
        do {
            try work(NoteService(context: modelContext))
        } catch {
            assertionFailure("Tile action failed: \(error)")
        }
    }
}
