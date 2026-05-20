import SwiftData
import SwiftUI

struct SpaceSwitcherSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Space.sortIndex) private var spaces: [Space]

    var body: some View {
        NavigationStack {
            spaceList
            .listStyle(.plain)
            .navigationTitle("Spaces")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New space", systemImage: "plus") {
                        appState.presentedSheet = .newSpace
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                GlassCapsuleButton {
                    appState.presentedSheet = .newSpace
                } content: {
                    Label("New space", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
        }
    }

    private var spaceList: some View {
        List {
            ForEach(spaces) { space in
                SpaceSwitcherRow(
                    space: space,
                    isActive: appState.selectedSpaceID == space.id,
                    select: {
                        appState.selectedSpaceID = space.id
                        dismiss()
                    },
                    delete: {
                        delete(space)
                    }
                )
            }
            .onMove(perform: move)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var reordered = spaces
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, space) in reordered.enumerated() {
            space.sortIndex = index
        }
        try? modelContext.save()
    }

    private func delete(_ space: Space) {
        modelContext.delete(space)
        try? modelContext.save()
        if appState.selectedSpaceID == space.id {
            appState.selectedSpaceID = spaces.first(where: { $0.id != space.id })?.id
        }
    }
}

private struct SpaceSwitcherRow: View {
    let space: Space
    let isActive: Bool
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                Text(space.emoji)
                VStack(alignment: .leading, spacing: 3) {
                    Text(space.name)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text(space.profile?.summary ?? "No profile")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isActive {
                    Text("active")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(rowBackground)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isActive ? Color.primary.opacity(0.08) : Color.clear)
    }
}
