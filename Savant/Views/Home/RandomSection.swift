import SwiftData
import SwiftUI

struct RandomSection: View {
    @Environment(InteractionMode.self) private var interaction
    @Environment(\.modelContext) private var modelContext

    let folders: [Folder]
    let notes: [Note]
    let allNotes: [Note]
    let allFolders: [Folder]
    let spaces: [Space]
    let currentSpace: Space
    let tidyNow: () -> Void

    @State private var expandedFolderIDs: Set<UUID> = []
    @State private var isTargeted = false

    var body: some View {
        let dragActive = interaction.isDragging
        let isEmpty = folders.isEmpty && notes.isEmpty

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Random")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.savantSubtleInk)
                    .textCase(.uppercase)
                if dragActive {
                    Text("• drop to demote")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                if !notes.isEmpty && !dragActive {
                    Button(action: tidyNow) {
                        Label("Tidy", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                }
            }

            if isEmpty && !dragActive {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.message.fill")
                        .font(.system(size: 28))
                    Text("Nothing here yet. Capture below ↓")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
                .multilineTextAlignment(.center)
            } else if isEmpty && dragActive {
                DropZonePlaceholder(tier: .random, isTargeted: isTargeted)
                    .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                        handleDrop(items)
                    } isTargeted: { isTargeted = $0 }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(folders) { folder in
                        FolderRowView(
                            folder: folder,
                            notes: notesIn(folder),
                            spaces: spaces,
                            currentSpace: currentSpace,
                            isExpanded: expandedFolderIDs.contains(folder.id),
                            toggleExpanded: { toggle(folder.id) }
                        )
                    }
                    ForEach(notes) { note in
                        NoteRowView(
                            note: note,
                            spaces: spaces,
                            currentSpace: currentSpace,
                            showsPreview: false
                        )
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dropZoneAura(active: dragActive, targeted: isTargeted, cornerRadius: 16)
                .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                    handleDrop(items)
                } isTargeted: { isTargeted = $0 }
            }
        }
        .animation(.easeOut(duration: 0.18), value: dragActive)
    }

    private func notesIn(_ folder: Folder) -> [Note] {
        allNotes
            .filter { $0.folder?.id == folder.id && $0.tier == .random }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func toggle(_ id: UUID) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            if expandedFolderIDs.contains(id) {
                expandedFolderIDs.remove(id)
            } else {
                expandedFolderIDs.insert(id)
            }
        }
    }

    private func handleDrop(_ items: [DraggedItemTransfer]) -> Bool {
        guard let first = items.first else { return false }
        let noteService = NoteService(context: modelContext)
        let folderService = FolderService(context: modelContext)
        do {
            switch first.kind {
            case .note:
                guard let note = allNotes.first(where: { $0.id == first.id }) else { return false }
                try noteService.promote(note, to: .random, currentSpace: currentSpace)
                return true
            case .folder:
                guard let folder = allFolders.first(where: { $0.id == first.id }), folder.tier != .random else { return false }
                try folderService.changeTier(folder, to: .random)
                return true
            }
        } catch {
            assertionFailure("Random drop failed: \(error)")
            return false
        }
    }
}
