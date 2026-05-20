import SwiftData
import SwiftUI

struct ArchiveBrowserView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Space.sortIndex) private var spaces: [Space]

    @State private var selectedSpaceID: UUID?
    @State private var query = ""

    var body: some View {
        List {
            Section {
                Picker("Space", selection: $selectedSpaceID) {
                    Text("All").tag(Optional<UUID>.none)
                    ForEach(spaces) { space in
                        Text("\(space.emoji) \(space.name)").tag(Optional(space.id))
                    }
                }
            }

            ForEach(results) { note in
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.title)
                        .font(.headline)
                    Text(note.bodyMarkdown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Restore", systemImage: "arrow.uturn.backward") {
                        restore(note)
                    }
                    .buttonStyle(.glass)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("Archive")
        .searchable(text: $query)
    }

    private var results: [Note] {
        notes.filter { note in
            note.tier == .archived &&
            (selectedSpaceID == nil || note.space?.id == selectedSpaceID) &&
            SearchService.matches(note, query: query)
        }
    }

    private func restore(_ note: Note) {
        let fallback = note.space ?? spaces.first
        guard let fallback else { return }
        try? NoteService(context: modelContext).restore(note, to: fallback)
    }
}
