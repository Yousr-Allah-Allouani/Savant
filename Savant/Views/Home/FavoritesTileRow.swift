import SwiftData
import SwiftUI

/// Anchors — the global top tier. Editorial direction: a clean starred list on
/// the open color, not glass tiles. (Kept the filename/type so call sites and
/// the project file don't churn.)
struct FavoritesTileRow: View {
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
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Anchors", count: notes.count,
                             hint: dragActive ? "drop to anchor" : nil)

                if isEmpty && dragActive {
                    DropZonePlaceholder(tier: .favorite, isTargeted: isTargeted)
                        .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                            handleDrop(items)
                        } isTargeted: { isTargeted = $0 }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notes) { note in
                            AnchorRow(note: note, spaces: spaces, currentSpace: currentSpace)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dropZoneAura(active: dragActive, targeted: isTargeted, cornerRadius: 14)
                    .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                        handleDrop(items)
                    } isTargeted: { isTargeted = $0 }
                }
            }
            .animation(.easeOut(duration: 0.18), value: dragActive)
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
            assertionFailure("Anchor drop failed: \(error)")
            return false
        }
    }
}

/// A single Anchor as an editorial list row: a small star mark + the title on
/// the open color. Mirrors the Kept/Stream row rhythm so the whole page reads
/// as one typographic list, distinguished only by the star.
private struct AnchorRow: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let note: Note
    let spaces: [Space]
    let currentSpace: Space

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(.savantSubtleInk)
            Text(note.title)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.savantInk)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture(count: 2) { appState.presentEdit(note) }
        .onTapGesture { appState.presentRead(note) }
        .draggable(DraggedItemTransfer.note(note.id)) {
            NoteDragPreview(note: note)
                .dragLifecycleHook(interaction)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { appState.presentEdit(note) }
            Button("Remove from Anchors", systemImage: "star.slash") {
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

    private func update(_ work: (NoteService) throws -> Void) {
        do {
            try work(NoteService(context: modelContext))
        } catch {
            assertionFailure("Anchor action failed: \(error)")
        }
    }
}
