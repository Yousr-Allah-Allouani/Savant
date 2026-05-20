import AppKit
import RichEditorSwiftUI
import SwiftData
import SwiftUI

#if os(macOS)
struct MacNoteWorkspace: View {
    @Environment(\.colorScheme) private var colorScheme
    let space: Space
    let note: Note?
    let createNote: () -> Void

    var body: some View {
        ZStack {
            if let note {
                MacNoteEditor(space: space, note: note)
                    .id(note.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.992)))
            } else {
                MacEmptyNotePane(space: space, createNote: createNote)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.82))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.10), radius: 14, x: 0, y: 4)
        // Tight Nook-style inset; tinted window background frames the editor
        // and the rounded corners "insert" into that frame.
        .padding(6)
    }
}

private struct MacNoteEditor: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var editorState: RichEditorState
    @State private var title: String

    let space: Space
    let note: Note

    init(space: Space, note: Note) {
        self.space = space
        self.note = note
        _title = State(initialValue: note.title == "Untitled" ? "" : note.title)
        _editorState = ObservedObject(wrappedValue: RichEditorState(input: note.bodyMarkdown))
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Untitled", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .bold))
                .onSubmit(save)
                .padding(.horizontal, 4)

            RichTextEditor(
                context: _editorState,
                viewConfiguration: { component in
                    component.textContentInset = CGSize(width: 4, height: 8)
                    if let textView = component as? NSTextView {
                        textView.backgroundColor = .clear
                        textView.drawsBackground = false
                        // Hide the NSScrollView's right-edge scroller (the
                        // faint vertical bar visible against the editor).
                        if let scrollView = textView.enclosingScrollView {
                            scrollView.hasVerticalScroller = false
                            scrollView.hasHorizontalScroller = false
                            scrollView.scrollerStyle = .overlay
                            scrollView.autohidesScrollers = true
                            scrollView.verticalScroller?.isHidden = true
                        }
                    }
                }
            )
            .richTextEditorConfig(.standard)
        }
        .padding(.horizontal, 38)
        .padding(.top, 24)
        .padding(.bottom, 26)
        .onDisappear(perform: save)
        .onChange(of: note.id) { _, _ in save() }
    }

    private func save() {
        let body = editorState.attributedString.string
        do {
            try NoteService(context: modelContext).save(note: note, title: title, body: body)
        } catch {
            assertionFailure("Unable to save macOS note: \(error)")
        }
    }
}

private struct MacEmptyNotePane: View {
    let space: Space
    let createNote: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(space.emoji.isEmpty ? "✦" : space.emoji)
                .font(.system(size: 54))
                .frame(width: 92, height: 92)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 6) {
                Text(space.name)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("No note selected")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            Button("New note", systemImage: "square.and.pencil", action: createNote)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
