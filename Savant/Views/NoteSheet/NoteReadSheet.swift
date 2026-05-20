import SwiftUI
import UIKit

struct NoteReadSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let note: Note

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(note.title)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if note.bodyMarkdown.isEmpty {
                        Text("No body yet.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(LocalizedStringKey(note.bodyMarkdown))
                            .font(.system(.body, design: .default))
                            .lineSpacing(6)
                    }

                    ForEach(note.attachments ?? []) { attachment in
                        AttachmentCard(attachment: attachment)
                    }

                    Text("created \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 20)
                }
                .padding(24)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "pencil") {
                        appState.presentEdit(note)
                    }
                    .buttonStyle(.glassProminent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct AttachmentCard: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.kind == .image,
           let data = attachment.imageData,
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 42, height: 42)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var icon: String {
        switch attachment.kind {
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .voice: "waveform"
        }
    }

    private var title: String {
        attachment.linkTitle ?? attachment.url?.absoluteString ?? attachment.kind.rawValue.capitalized
    }

    private var subtitle: String? {
        attachment.linkSiteName ?? attachment.voiceTranscript
    }
}
