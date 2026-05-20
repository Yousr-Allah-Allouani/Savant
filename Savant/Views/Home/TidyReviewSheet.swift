import SwiftData
import SwiftUI

struct TidyReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query private var notes: [Note]

    let run: TidyRun

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tidied \(run.notesProcessed) notes")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                        Text(summary)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                if let actions = run.actions, !actions.isEmpty {
                    Section("Changes") {
                        ForEach(actions) { action in
                            TidyActionRow(action: action, note: note(for: action)) {
                                undo(action)
                            }
                        }
                    }
                } else {
                    Section("Changes") {
                        ContentUnavailableView(
                            "No changes needed",
                            systemImage: "checkmark.circle",
                            description: Text(run.notesProcessed == 0 ? "There were no Random notes ready to tidy." : "Everything already looked organized.")
                        )
                    }
                }
            }
            .navigationTitle("Tidy review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        run.bannerDismissed = true
                        try? modelContext.save()
                        dismiss()
                    }
                }
            }
        }
    }

    private func note(for action: TidyAction) -> Note? {
        notes.first { $0.id == action.noteId }
    }

    private func undo(_ action: TidyAction) {
        try? TidyService(context: modelContext).undo(action, notes: notes)
    }

    private var summary: String {
        if run.notesArchived == 0 && run.foldersCreated == 0 {
            return run.notesProcessed == 0 ? "Nothing to tidy yet" : "No moves needed"
        }
        return "\(run.notesArchived) archived · \(run.foldersCreated) folders created"
    }
}

private struct TidyActionRow: View {
    let action: TidyAction
    let note: Note?
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(note?.title ?? "Missing note")
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action.undone ? "Undone" : "Undo", action: undo)
                .disabled(action.undone)
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch action.actionKind {
        case .archived: "archivebox"
        case .foldered: "folder"
        case .leftAlone: "checkmark"
        }
    }

    private var detail: String {
        switch action.actionKind {
        case .archived:
            "Archived"
        case .foldered:
            "Moved into \(action.folderName ?? "a folder")"
        case .leftAlone:
            "Left alone"
        }
    }
}
