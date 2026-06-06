import SwiftData
import SwiftUI

struct TidyBannerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let run: TidyRun

    var body: some View {
        // A transient notification, not content — so it reads as a slim, quiet
        // single-line pill rather than a heavy card competing with the notes.
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.savantInk)

            Text(summaryLine)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.savantInk)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 6)

            Button("Review") {
                appState.presentedSheet = .tidyReview(run)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.savantInk)
            .buttonStyle(.plain)

            Button {
                run.bannerDismissed = true
                try? modelContext.save()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.savantSubtleInk)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var summaryLine: String {
        guard run.notesArchived > 0 || run.foldersCreated > 0 else {
            return "Tidied — no moves needed"
        }
        var parts = ["Tidied \(run.notesProcessed) \(pluralize(run.notesProcessed, "note"))"]
        if run.foldersCreated > 0 {
            parts.append("\(run.foldersCreated) \(pluralize(run.foldersCreated, "folder"))")
        }
        if run.notesArchived > 0 {
            parts.append("\(run.notesArchived) archived")
        }
        return parts.joined(separator: " · ")
    }

    private func pluralize(_ count: Int, _ word: String) -> String {
        count == 1 ? word : word + "s"
    }
}
