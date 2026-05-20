import SwiftData
import SwiftUI

struct MultiSelectActionBar: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InteractionMode.self) private var interaction

    let space: Space
    let spaces: [Space]
    let allNotes: [Note]

    var body: some View {
        let selected = selectedNotes
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ActionButton(systemName: "star.fill", label: "Favorite") {
                    bulk { try $0.promote($1, to: .favorite, currentSpace: space) }
                }
                ActionButton(systemName: "pin.fill", label: "Pin") {
                    bulk { try $0.promote($1, to: .pinned, currentSpace: space) }
                }
                Menu {
                    ForEach(spaces.filter { $0.id != space.id }) { target in
                        Button("\(target.emoji) \(target.name)") {
                            bulk { try $0.move($1, to: target) }
                        }
                    }
                } label: {
                    actionLabel(systemName: "arrow.left.arrow.right", label: "Move")
                }
                ActionButton(systemName: "archivebox", label: "Archive") {
                    bulk { try $0.archive($1) }
                }
                ActionButton(systemName: "trash", label: "Delete", role: .destructive) {
                    bulk { try $0.delete($1) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .overlay(alignment: .top) {
                Text(selected.isEmpty ? "Select notes" : "\(selected.count) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: .capsule)
                    .offset(y: -16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .opacity(selected.isEmpty ? 0.7 : 1)
        .animation(.easeOut(duration: 0.15), value: selected.count)
    }

    private var selectedNotes: [Note] {
        let ids = interaction.editingSelection
        return allNotes.filter { ids.contains($0.id) }
    }

    private func bulk(_ work: (NoteService, Note) throws -> Void) {
        let service = NoteService(context: modelContext)
        for note in selectedNotes {
            do { try work(service, note) } catch {
                assertionFailure("Bulk action failed: \(error)")
            }
        }
        interaction.clearSelection()
    }

    @ViewBuilder
    private func actionLabel(systemName: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
            Text(label)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
    }

    private struct ActionButton: View {
        let systemName: String
        let label: String
        var role: ButtonRole? = nil
        let action: () -> Void

        var body: some View {
            Button(role: role, action: action) {
                VStack(spacing: 4) {
                    Image(systemName: systemName)
                        .font(.system(size: 18, weight: .semibold))
                    Text(label)
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(role == .destructive ? Color.red : .primary)
            }
            .buttonStyle(.plain)
        }
    }
}
