import SwiftData
import SwiftUI

struct NoteRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let note: Note
    let spaces: [Space]
    let currentSpace: Space
    let showsPreview: Bool

    var body: some View {
        let editing = interaction.isEditing(spaceID: currentSpace.id)
        let isSelected = interaction.editingSelection.contains(note.id)

        HStack(alignment: .center, spacing: 10) {
            if editing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .transition(.scale.combined(with: .opacity))
            }

            rowContent
                .contentShape(.rect)
                .onTapGesture(count: 2) {
                    if !editing { appState.presentEdit(note) }
                }
                .onTapGesture {
                    if editing {
                        interaction.toggleSelection(note.id)
                    } else {
                        appState.presentRead(note)
                    }
                }
        }
        .padding(.horizontal, editing ? 6 : 0)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .draggable(DraggedItemTransfer.note(note.id)) {
            NoteDragPreview(note: note)
                .dragLifecycleHook(interaction)
        }
        .contextMenu {
            if !editing { noteActions }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: editing)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(.primary.opacity(0.72))
                .frame(width: 6, height: 6)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(note.title)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.savantInk)
                        .lineLimit(1)
                    if let moveSuggestionTitle = note.moveSuggestionTitle {
                        Text("→ \(moveSuggestionTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.08), in: .capsule)
                    }
                }

                if showsPreview {
                    Text(note.bodyMarkdown)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var noteActions: some View {
        Button("Edit", systemImage: "pencil") {
            appState.presentEdit(note)
        }
        Button("Pin", systemImage: "pin.fill") {
            update { try $0.promote(note, to: .pinned, currentSpace: currentSpace) }
        }
        Button("Favorite", systemImage: "star.fill") {
            update { try $0.promote(note, to: .favorite, currentSpace: currentSpace) }
        }
        Menu("Move to space", systemImage: "arrow.left.arrow.right") {
            ForEach(spaces) { space in
                Button("\(space.emoji) \(space.name)") {
                    update { try $0.move(note, to: space) }
                }
            }
        }
        Button("Duplicate", systemImage: "doc.on.doc") {
            update { _ = try $0.duplicate(note) }
        }
        Button("Archive", systemImage: "archivebox") {
            update { try $0.archive(note) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) {
            update { try $0.delete(note) }
        }
    }

    private func update(_ work: (NoteService) throws -> Void) {
        do {
            try work(NoteService(context: modelContext))
        } catch {
            assertionFailure("Note action failed: \(error)")
        }
    }
}
