import SwiftData
import SwiftUI

struct TidyBannerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let run: TidyRun

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title3)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidied \(run.notesProcessed) notes")
                    .font(.system(.headline, design: .rounded))
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review") {
                appState.presentedSheet = .tidyReview(run)
            }
            .buttonStyle(.glass)
            Button {
                run.bannerDismissed = true
                try? modelContext.save()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var summary: String {
        if run.notesArchived == 0 && run.foldersCreated == 0 {
            return "No moves needed"
        }
        return "\(run.notesArchived) archived · \(run.notesProcessed - run.notesArchived) reviewed · \(run.foldersCreated) folders"
    }
}
