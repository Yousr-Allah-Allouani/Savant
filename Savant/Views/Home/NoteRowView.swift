import SwiftData
import SwiftUI

struct NoteRowView: View {
    @Environment(AppState.self) private var appState
    @Environment(InteractionMode.self) private var interaction

    let note: Note
    let currentSpace: Space
    /// `true` = kept row (primary white surface, title + 1-line preview);
    /// `false` = stream row (quieter surface, title only).
    let showsPreview: Bool
    /// Where this row lives — the drag engine resolves the tier's published
    /// context from these at lift time.
    let tier: NoteTier
    var parentFolderID: UUID? = nil

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

            NoteRowCard(note: note, showsPreview: showsPreview)
                .contentShape(.rect(cornerRadius: SavantTheme.rowRadius))
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
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: SavantTheme.rowRadius, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
            }
        }
        .dragRow(
            id: note.id,
            payload: .note(note.id),
            tier: tier,
            parentFolderID: parentFolderID,
            spaceID: currentSpace.id,
            ghost: { .note(note) },
            isEnabled: !editing
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: editing)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }
}

/// The bare row card — shared between the in-list row and the drag ghost so
/// the lifted ghost is pixel-identical to the row it replaces.
struct NoteRowCard: View {
    let note: Note
    let showsPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(.system(size: 17, design: .rounded))
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
                Spacer(minLength: 0)
            }

            if showsPreview, !note.bodyMarkdown.isEmpty {
                Text(note.bodyMarkdown)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, showsPreview ? 13 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: showsPreview ? 62 : 48)
        .savantCard(radius: SavantTheme.rowRadius, soft: !showsPreview)
    }
}
