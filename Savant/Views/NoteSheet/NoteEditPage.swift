import SwiftData
import SwiftUI

struct NoteEditPage: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @FocusState private var focusedField: Field?

    let note: Note

    @State private var title: String
    @State private var bodyText: String
    @State private var showsMarkdownSource = false

    enum Field: Hashable {
        case title
        case body
    }

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title == "Untitled" ? "" : note.title)
        _bodyText = State(initialValue: note.bodyMarkdown)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        TextField("Title", text: $title, axis: .vertical)
                            .focused($focusedField, equals: .title)
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .lineLimit(1...3)

                        TextEditor(text: $bodyText)
                            .focused($focusedField, equals: .body)
                            .font(.system(.body, design: .default))
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 360)
                            .accessibilityLabel("Body")
                            .accessibilityIdentifier("note-body-editor")
                            .overlay(alignment: .topLeading) {
                                if bodyText.isEmpty {
                                    Text("Body")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    .padding(22)
                }

                KeyboardToolbarView(
                    isKeyboardActive: focusedField != nil,
                    insertMarkdown: insertMarkdown,
                    dismissKeyboard: { focusedField = nil }
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .background(.background)
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done", systemImage: "chevron.left") {
                        saveAndClose()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(showsMarkdownSource ? "Hide markdown source" : "Show markdown source", systemImage: "text.alignleft") {
                            showsMarkdownSource.toggle()
                        }
                        Button("Keep", systemImage: "pin.fill") {
                            saveThen { try NoteService(context: modelContext).promote(note, to: .pinned, currentSpace: note.space) }
                        }
                        Button("Anchor", systemImage: "star.fill") {
                            saveThen { try NoteService(context: modelContext).promote(note, to: .favorite, currentSpace: note.space) }
                        }
                        Button("Archive", systemImage: "archivebox") {
                            saveThen { try NoteService(context: modelContext).archive(note) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            try? NoteService(context: modelContext).delete(note)
                            appState.closeFullScreen()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .onAppear {
                focusedField = bodyText.isEmpty ? .body : nil
            }
        }
    }

    private func insertMarkdown(_ token: KeyboardToolbarToken) {
        focusedField = .body
        switch token {
        case .bold:
            bodyText.append(bodyText.isEmpty ? "**bold**" : " **bold**")
        case .italic:
            bodyText.append(bodyText.isEmpty ? "_italic_" : " _italic_")
        case .heading:
            bodyText.append(bodyText.isEmpty ? "# " : "\n# ")
        case .list:
            bodyText.append(bodyText.isEmpty ? "- " : "\n- ")
        case .link:
            bodyText.append(bodyText.isEmpty ? "[title](https://)" : " [title](https://)")
        case .attachment:
            bodyText.append(bodyText.isEmpty ? "![attachment]()" : "\n![attachment]()")
        }
    }

    private func saveAndClose() {
        saveThen {
            appState.closeFullScreen()
        }
    }

    private func saveThen(_ next: () throws -> Void) {
        do {
            try NoteService(context: modelContext).save(note: note, title: title, body: bodyText)
            try next()
        } catch {
            assertionFailure("Unable to save note: \(error)")
        }
    }
}

enum KeyboardToolbarToken: CaseIterable, Identifiable {
    case bold
    case italic
    case heading
    case list
    case link
    case attachment

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .heading: "textformat.size"
        case .list: "list.bullet"
        case .link: "link"
        case .attachment: "paperclip"
        }
    }
}

struct KeyboardToolbarView: View {
    let isKeyboardActive: Bool
    let insertMarkdown: (KeyboardToolbarToken) -> Void
    let dismissKeyboard: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            GeometryReader { proxy in
                ExpandableGlassMenu(
                    alignment: .center,
                    progress: isKeyboardActive ? 1 : 0,
                    labelSize: CGSize(width: 220, height: proxy.size.height),
                    cornerRadius: 23
                ) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 26) {
                            ForEach(KeyboardToolbarToken.allCases) { token in
                                Button {
                                    insertMarkdown(token)
                                } label: {
                                    Image(systemName: token.systemImage)
                                        .font(.title3)
                                        .frame(width: 30, height: 38)
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                dismissKeyboard()
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.title3)
                                    .frame(width: 30, height: 38)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                        .frame(height: proxy.size.height)
                    }
                    .scrollIndicators(.hidden)
                } label: {
                    HStack(spacing: 22) {
                        Image(systemName: "bold")
                        Image(systemName: "italic")
                        Image(systemName: "link")
                    }
                    .font(.title3)
                }
            }
            .frame(height: 46)
        }
        .animation(.interactiveSpring(response: 0.5, dampingFraction: 0.68), value: isKeyboardActive)
    }
}
