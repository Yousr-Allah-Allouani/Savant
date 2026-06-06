import SwiftData
import SwiftUI

struct SearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \Space.sortIndex) private var spaces: [Space]

    let initialSpace: Space?

    @State private var query = ""
    @State private var scope: SearchScope = .thisSpace

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section("Recent") {
                        Text("Start typing to search titles, markdown, and archived notes.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Results") {
                    ForEach(results) { note in
                        Button {
                            dismiss()
                            appState.presentRead(note)
                        } label: {
                            SearchResultRow(note: note, space: space(for: note))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Find notes")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Scope", selection: $scope) {
                        ForEach(SearchScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                scope = initialSpace == nil ? .allSpaces : .thisSpace
            }
        }
    }

    private var results: [Note] {
        notes.filter { note in
            SearchService.matches(note, query: query) && matchesScope(note)
        }
    }

    private func matchesScope(_ note: Note) -> Bool {
        switch scope {
        case .thisSpace:
            guard let initialSpace else { return note.tier != .archived }
            return note.space?.id == initialSpace.id && note.tier != .archived
        case .allSpaces:
            return note.tier != .archived
        case .archive:
            return note.tier == .archived
        }
    }

    private func space(for note: Note) -> Space? {
        guard let id = note.space?.id else { return nil }
        return spaces.first { $0.id == id }
    }
}

private struct SearchResultRow: View {
    let note: Note
    let space: Space?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(note.title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let space {
                    Text("\(space.emoji) \(space.name)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: space.colorHex).opacity(0.35), in: .capsule)
                } else if note.tier == .favorite {
                    Text("Anchor")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.yellow.opacity(0.2), in: .capsule)
                }
            }
            Text(note.bodyMarkdown)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }
}
