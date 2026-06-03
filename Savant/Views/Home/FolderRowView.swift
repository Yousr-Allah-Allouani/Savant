import SwiftData
import SwiftUI

struct FolderRowView: View {
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let folder: Folder
    let notes: [Note]
    let spaces: [Space]
    let currentSpace: Space
    let isExpanded: Bool
    let toggleExpanded: () -> Void

    @State private var isTargeted = false

    var body: some View {
        let dragActive = interaction.isDragging

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .frame(width: 12)
                Image(systemName: "folder.fill")
                    .foregroundStyle(.primary.opacity(0.72))
                Text(folder.name)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.savantInk)
                Spacer()
                Text("\(notes.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(.rect)
            .onTapGesture { toggleExpanded() }
            .dropZoneAura(active: dragActive, targeted: isTargeted, cornerRadius: 12)
            .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                handleDrop(items)
            } isTargeted: { isTargeted = $0 }
            .draggable(DraggedItemTransfer.folder(folder.id)) {
                FolderDragPreview(folder: folder)
                    .dragLifecycleHook(interaction)
            }
            .contextMenu {
                Button("Rename", systemImage: "pencil") { }
                Button(isExpanded ? "Collapse" : "Expand", systemImage: isExpanded ? "chevron.up" : "chevron.down") {
                    toggleExpanded()
                }
                Button("Delete folder", systemImage: "trash", role: .destructive) {
                    do {
                        try FolderService(context: modelContext).delete(folder)
                    } catch {
                        assertionFailure("Folder delete failed: \(error)")
                    }
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(notes) { note in
                        NoteRowView(note: note, spaces: spaces, currentSpace: currentSpace, showsPreview: folder.tier == .pinned)
                            .padding(.leading, 30)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isExpanded)
    }

    private func handleDrop(_ items: [DraggedItemTransfer]) -> Bool {
        guard let first = items.first, first.kind == .note else { return false }
        let folderService = FolderService(context: modelContext)
        do {
            let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == first.id })
            if let note = try modelContext.fetch(descriptor).first {
                try folderService.moveNote(note, into: folder)
                return true
            }
        } catch {
            assertionFailure("Folder drop failed: \(error)")
        }
        return false
    }
}

// `FolderService` lives in `Services/FolderService.swift` so it compiles into
// both the iOS and macOS targets.
