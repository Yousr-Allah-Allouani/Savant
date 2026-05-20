import SwiftUI

struct NoteDragPreview: View {
    let note: Note

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.primary.opacity(0.72))
                .frame(width: 6, height: 6)
            Text(note.title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.savantInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
    }
}

struct FolderDragPreview: View {
    let folder: Folder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.primary.opacity(0.72))
            Text(folder.name)
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(.savantInk)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
    }
}
