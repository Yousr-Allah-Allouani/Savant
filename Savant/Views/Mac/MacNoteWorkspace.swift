import AppKit
import SwiftData
import SwiftUI

#if os(macOS)
struct MacNoteWorkspace: View {
    let space: Space
    let note: Note?
    let createNote: () -> Void

    var body: some View {
        ZStack {
            if let note {
                MacNoteEditor(space: space, note: note)
                    .id(note.id)
            } else {
                MacEmptyNotePane(space: space, createNote: createNote)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .padding(6)
    }
}

private struct MacNoteEditor: View {
    @Environment(\.modelContext) private var modelContext
    @FocusState private var focusedField: Field?
    @AppStorage("mac.note.bodyFont") private var bodyFontRawValue = MacNoteBodyFont.system.rawValue
    @State private var titleText: NSAttributedString
    @State private var bodyText: NSAttributedString
    @State private var autosaveTask: Task<Void, Never>?
    @State private var activeEditor: Field = .body
    @State private var titleEditingRequest: RichTextEditRequest?
    @State private var bodyEditingRequest: RichTextEditRequest?
    @State private var isShowingNoteInfo = false
    @State private var isShowingFormattingBar = false

    let space: Space
    let note: Note

    private enum Field: Hashable {
        case title
        case body
    }

    init(space: Space, note: Note) {
        self.space = space
        self.note = note
        _titleText = State(initialValue: MacRichTextArchive.loadTitle(note: note))
        _bodyText = State(initialValue: MacRichTextArchive.load(note: note))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            noteHeader

            bodyEditor

            if isShowingFormattingBar {
                HStack {
                    Spacer(minLength: 0)
                    bottomFormattingBar
                    Spacer(minLength: 0)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 42)
        .padding(.top, 26)
        .padding(.bottom, 30)
        .animation(.easeOut(duration: 0.16), value: isShowingFormattingBar)
        .onAppear(perform: focusBlankNote)
        .onDisappear {
            autosaveTask?.cancel()
            let pendingTitle = NSAttributedString(attributedString: titleText)
            let pendingBody = NSAttributedString(attributedString: bodyText)
            Task { @MainActor [note, modelContext] in
                await Task.yield()
                Self.saveIfNeeded(
                    note: note,
                    modelContext: modelContext,
                    title: pendingTitle,
                    body: pendingBody
                )
            }
        }
    }

    private var noteHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            titleEditor
                .layoutPriority(1)

            headerActionPill
        }
    }

    private var titleEditor: some View {
        ZStack(alignment: .topLeading) {
            MacRichTitleEditor(
                text: $titleText,
                defaultFont: MacRichTitleEditor.defaultFont,
                editingRequest: titleEditingRequest,
                isFocused: focusedField == .title,
                onSubmit: focusBody,
                onFocusChange: updateTitleFocus,
                onTextChange: scheduleAutosave
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .accessibilityLabel("Title")
            .accessibilityIdentifier("mac-note-title-editor")

            if titleText.string.isEmpty {
                Text("Untitled")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.secondary.opacity(0.62))
                    .allowsHitTesting(false)
            }
        }
    }

    private var headerActionPill: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    isShowingFormattingBar.toggle()
                }
            } label: {
                HStack(spacing: 0) {
                    Text("B")
                        .fontWeight(.bold)
                    Text("I")
                        .italic()
                        .padding(.horizontal, 1)
                    Text("U")
                        .underline()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isShowingFormattingBar ? .primary : .secondary)
                .frame(width: 42, height: 24)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(isShowingFormattingBar ? "Hide formatting" : "Show formatting")
            .accessibilityLabel("Show formatting")

            Button {
                isShowingNoteInfo.toggle()
            } label: {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Note info")
            .accessibilityLabel("Note info")
            .popover(isPresented: $isShowingNoteInfo, arrowEdge: .top) {
                MacNoteInfoPopover(note: note, stats: noteStats)
            }

            Menu {
                fontMenuItems

                Divider()

                Button(isShowingFormattingBar ? "Hide formatting" : "Show formatting") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isShowingFormattingBar.toggle()
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var bottomFormattingBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Body") { issue(.heading(level: 0)) }
                Button("Heading 1") { issue(.heading(level: 1)) }
                Button("Heading 2") { issue(.heading(level: 2)) }
                Button("Heading 3") { issue(.heading(level: 3)) }
            } label: {
                formatBarMenuLabel(title: "H")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Heading")

            formatBarButton(systemImage: "checkmark.square", help: "Checklist", command: .checklist)

            toolbarDivider

            Menu {
                Button("Bulleted list") { issue(.bullets) }
                Button("Separator") { issue(.separator) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 15, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("List")

            toolbarDivider

            formatBarButton(systemImage: "bold", help: "Bold", command: .fontTrait(.boldFontMask))
            formatBarButton(systemImage: "italic", help: "Italic", command: .fontTrait(.italicFontMask))
            formatBarButton(systemImage: "underline", help: "Underline", command: .underline)
            formatBarButton(systemImage: "highlighter", help: "Highlight", command: .highlight)
            formatBarButton(systemImage: "link", help: "Link from clipboard", command: .link)

            Menu {
                fontMenuItems
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Editor font")

            toolbarDivider

            Menu {
                Button("Insert separator") { issue(.separator) }
                Button("Hide formatting") {
                    withAnimation(.easeOut(duration: 0.16)) {
                        isShowingFormattingBar = false
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
        }
    }

    private var bodyEditor: some View {
        ZStack(alignment: .topLeading) {
            MacRichTextEditor(
                text: $bodyText,
                defaultFont: bodyFont.font,
                editingRequest: bodyEditingRequest,
                isFocused: focusedField == .body,
                onFocusChange: updateBodyFocus,
                onTextChange: scheduleAutosave
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Body")
                .accessibilityIdentifier("mac-note-body-editor")

            if bodyText.string.isEmpty {
                Text("Start writing...")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.82))
                    .padding(.top, MacRichTextEditor.textInset.height)
                    .padding(.leading, MacRichTextEditor.textInset.width)
                    .allowsHitTesting(false)
            }
        }
        .layoutPriority(1)
    }

    private var bodyFont: MacNoteBodyFont {
        MacNoteBodyFont(rawValue: bodyFontRawValue) ?? .system
    }

    private var noteStats: MacNoteStats {
        MacNoteStats(text: bodyText.string)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.55))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var fontMenuItems: some View {
        ForEach(MacNoteBodyFont.allCases) { font in
            Button {
                selectFont(font)
            } label: {
                HStack {
                    Text(font.label)

                    if bodyFont == font {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private func selectFont(_ font: MacNoteBodyFont) {
        if activeEditor == .body {
            bodyFontRawValue = font.rawValue
        }

        issue(.font(font))
    }

    private func formatBarMenuLabel(title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 18, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(.secondary)
        .frame(width: 38, height: 28)
    }

    private func formatBarButton(systemImage: String, help: String, command: RichTextEditCommand) -> some View {
        Button {
            issue(command)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func issue(_ command: RichTextEditCommand) {
        if activeEditor == .title {
            guard command.appliesToTitle else { return }
            titleEditingRequest = RichTextEditRequest(command: command)
        } else {
            bodyEditingRequest = RichTextEditRequest(command: command)
        }
    }

    private func focusBlankNote() {
        guard bodyText.string.isEmpty, note.title == "Untitled" else { return }
        DispatchQueue.main.async {
            focusedField = .body
        }
    }

    private func focusBody() {
        focusedField = .body
        activeEditor = .body
    }

    private func updateTitleFocus(_ isFocused: Bool) {
        if isFocused {
            focusedField = .title
            activeEditor = .title
        } else if focusedField == .title {
            focusedField = nil
        }
    }

    private func updateBodyFocus(_ isFocused: Bool) {
        if isFocused {
            focusedField = .body
            activeEditor = .body
        } else if focusedField == .body {
            focusedField = nil
        }
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        let pendingTitle = NSAttributedString(attributedString: titleText)
        let pendingBody = NSAttributedString(attributedString: bodyText)
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            saveIfNeeded(title: pendingTitle, body: pendingBody)
        }
    }

    private func saveIfNeeded(title nextTitle: NSAttributedString, body nextBody: NSAttributedString) {
        Self.saveIfNeeded(note: note, modelContext: modelContext, title: nextTitle, body: nextBody)
    }

    private static func saveIfNeeded(
        note: Note,
        modelContext: ModelContext,
        title nextTitle: NSAttributedString,
        body nextBody: NSAttributedString
    ) {
        let plainBody = nextBody.string
        let rtfData = MacRichTextArchive.data(for: nextBody)
        let plainTitle = nextTitle.string
        let normalizedTitle = plainTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedTitle = normalizedTitle.isEmpty ? NoteService.title(from: plainBody) : normalizedTitle
        let titleRTFData = normalizedTitle.isEmpty ? nil : MacRichTextArchive.data(for: nextTitle)
        guard note.title != savedTitle
                || note.bodyMarkdown != plainBody
                || note.titleRichTextRTF != titleRTFData
                || note.bodyRichTextRTF != rtfData else { return }

        do {
            try NoteService(context: modelContext).saveRichText(
                note: note,
                title: plainTitle,
                titleRTFData: titleRTFData,
                body: plainBody,
                rtfData: rtfData
            )
        } catch {
            assertionFailure("Unable to save macOS note: \(error)")
        }
    }
}

private struct MacRichTitleEditor: NSViewRepresentable {
    static let defaultFont = NSFont.systemFont(ofSize: 26, weight: .bold)

    @Binding var text: NSAttributedString
    let defaultFont: NSFont
    let editingRequest: RichTextEditRequest?
    let isFocused: Bool
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void
    let onTextChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            defaultFont: defaultFont,
            onSubmit: onSubmit,
            onFocusChange: onFocusChange,
            onTextChange: onTextChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(text)
        configure(textView: textView, in: scrollView)
        context.coordinator.restorePreferredTypingAttributes(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        context.coordinator.setDefaultFont(defaultFont)
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onTextChange = onTextChange
        configure(textView: textView, in: scrollView)

        if !textView.attributedString().isEqual(to: text) {
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(text)
            textView.selectedRanges = selectedRanges
        }

        context.coordinator.restorePreferredTypingAttributes(in: textView)

        if let editingRequest, context.coordinator.shouldHandle(editingRequest) {
            DispatchQueue.main.async {
                context.coordinator.apply(editingRequest, to: textView, defaultFont: defaultFont)
            }
        }

        guard isFocused, textView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func configure(textView: NSTextView, in scrollView: NSScrollView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineBreakMode = .byTruncatingTail

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.lineBreakMode = .byTruncatingTail
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.94)
        textView.defaultParagraphStyle = paragraphStyle
        if textView.string.isEmpty {
            textView.font = defaultFont
        }

        var typingAttributes = textView.typingAttributes
        typingAttributes[.font] = typingAttributes[.font] as? NSFont ?? defaultFont
        typingAttributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.94)
        typingAttributes[.paragraphStyle] = paragraphStyle
        textView.typingAttributes = typingAttributes
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<NSAttributedString>
        private var defaultFont: NSFont
        private var preferredTypingFont: NSFont?
        var onSubmit: () -> Void
        var onFocusChange: (Bool) -> Void
        var onTextChange: () -> Void
        private var handledRequestID: UUID?

        init(
            text: Binding<NSAttributedString>,
            defaultFont: NSFont,
            onSubmit: @escaping () -> Void,
            onFocusChange: @escaping (Bool) -> Void,
            onTextChange: @escaping () -> Void
        ) {
            self.text = text
            self.defaultFont = defaultFont
            self.onSubmit = onSubmit
            self.onFocusChange = onFocusChange
            self.onTextChange = onTextChange
        }

        func setDefaultFont(_ font: NSFont) {
            defaultFont = font
            preferredTypingFont = preferredTypingFont ?? font
        }

        func shouldHandle(_ request: RichTextEditRequest) -> Bool {
            guard handledRequestID != request.id else { return false }
            handledRequestID = request.id
            return true
        }

        func apply(_ request: RichTextEditRequest, to textView: NSTextView, defaultFont: NSFont) {
            let originalSelection = textView.selectedRange()
            let titleRange = NSRange(location: 0, length: (textView.string as NSString).length)
            if originalSelection.length == 0, titleRange.length > 0 {
                textView.setSelectedRange(titleRange)
            }

            request.command.apply(to: textView, defaultFont: defaultFont)
            updatePreferredTypingFontIfNeeded(for: request.command, in: textView)

            if originalSelection.length == 0 {
                let finalLength = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: finalLength, length: 0))
            }

            restorePreferredTypingAttributes(in: textView)
            sync(textView)
            textView.window?.makeFirstResponder(textView)
            onFocusChange(true)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange(true)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            sync(textView)
            restorePreferredTypingAttributes(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            restorePreferredTypingAttributes(in: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange(false)
        }

        func restorePreferredTypingAttributes(in textView: NSTextView) {
            let preferredFont = preferredTypingFont ?? defaultFont
            var attributes = textView.typingAttributes
            let currentFont = attributes[.font] as? NSFont
                ?? fontNearSelection(in: textView)
                ?? defaultFont
            attributes[.font] = MacRichTextFontTools.font(for: currentFont, withFamilyFrom: preferredFont)
            attributes[.foregroundColor] = attributes[.foregroundColor] as? NSColor
                ?? NSColor.labelColor.withAlphaComponent(0.94)
            textView.typingAttributes = attributes
        }

        private func updatePreferredTypingFontIfNeeded(for command: RichTextEditCommand, in textView: NSTextView) {
            guard command.pinsTypingFont else { return }
            let selection = textView.selectedRange()
            if selection.length == 0, let typingFont = textView.typingAttributes[.font] as? NSFont {
                preferredTypingFont = typingFont
                return
            }

            preferredTypingFont = fontNearSelection(in: textView)
                ?? textView.typingAttributes[.font] as? NSFont
                ?? preferredTypingFont
                ?? defaultFont
        }

        private func fontNearSelection(in textView: NSTextView) -> NSFont? {
            guard let storage = textView.textStorage else { return nil }
            let length = (textView.string as NSString).length
            guard length > 0 else { return nil }

            let selection = textView.selectedRange()
            let location: Int
            if selection.length > 0 {
                location = min(selection.location, length - 1)
            } else {
                location = min(max(selection.location - 1, 0), length - 1)
            }

            return storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        }

        private func sync(_ textView: NSTextView) {
            let nextText = NSAttributedString(attributedString: textView.attributedString())
            guard !text.wrappedValue.isEqual(to: nextText) else { return }
            text.wrappedValue = nextText
            onTextChange()
        }
    }
}

private struct MacRichTextEditor: NSViewRepresentable {
    static let textInset = CGSize(width: 0, height: 8)

    @Binding var text: NSAttributedString
    let defaultFont: NSFont
    let editingRequest: RichTextEditRequest?
    let isFocused: Bool
    let onFocusChange: (Bool) -> Void
    let onTextChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            defaultFont: defaultFont,
            onFocusChange: onFocusChange,
            onTextChange: onTextChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(text)
        configure(textView: textView, in: scrollView)
        context.coordinator.restorePreferredTypingAttributes(in: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        context.coordinator.text = $text
        context.coordinator.setDefaultFont(defaultFont)
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onTextChange = onTextChange
        configure(textView: textView, in: scrollView)

        if !textView.attributedString().isEqual(to: text) {
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.setAttributedString(text)
            textView.selectedRanges = selectedRanges
        }

        context.coordinator.restorePreferredTypingAttributes(in: textView)

        if let editingRequest, context.coordinator.shouldHandle(editingRequest) {
            DispatchQueue.main.async {
                context.coordinator.apply(editingRequest, to: textView, defaultFont: defaultFont)
            }
        }

        guard isFocused, textView.window?.firstResponder !== textView else { return }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
    }

    private func configure(textView: NSTextView, in scrollView: NSScrollView) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScroller?.isHidden = true
        scrollView.horizontalScroller?.isHidden = true

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: Self.textInset.width, height: Self.textInset.height)
        textView.textContainer?.lineFragmentPadding = 0
        if textView.string.isEmpty {
            textView.font = defaultFont
        }
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.94)
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes[.font] = textView.typingAttributes[.font] as? NSFont ?? defaultFont
        textView.typingAttributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(0.94)
        textView.typingAttributes[.paragraphStyle] = paragraphStyle
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<NSAttributedString>
        private var defaultFont: NSFont
        private var preferredTypingFont: NSFont
        var onFocusChange: (Bool) -> Void
        var onTextChange: () -> Void
        private var handledRequestID: UUID?

        init(
            text: Binding<NSAttributedString>,
            defaultFont: NSFont,
            onFocusChange: @escaping (Bool) -> Void,
            onTextChange: @escaping () -> Void
        ) {
            self.text = text
            self.defaultFont = defaultFont
            self.preferredTypingFont = defaultFont
            self.onFocusChange = onFocusChange
            self.onTextChange = onTextChange
        }

        func setDefaultFont(_ font: NSFont) {
            defaultFont = font
            preferredTypingFont = font
        }

        func shouldHandle(_ request: RichTextEditRequest) -> Bool {
            guard handledRequestID != request.id else { return false }
            handledRequestID = request.id
            return true
        }

        func apply(_ request: RichTextEditRequest, to textView: NSTextView, defaultFont: NSFont) {
            request.command.apply(to: textView, defaultFont: defaultFont)
            updatePreferredTypingFontIfNeeded(for: request.command, in: textView)
            restorePreferredTypingAttributes(in: textView)
            sync(textView)
            textView.window?.makeFirstResponder(textView)
            onFocusChange(true)
        }

        func textDidBeginEditing(_ notification: Notification) {
            onFocusChange(true)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            sync(textView)
            restorePreferredTypingAttributes(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            restorePreferredTypingAttributes(in: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            onFocusChange(false)
        }

        func restorePreferredTypingAttributes(in textView: NSTextView) {
            var attributes = textView.typingAttributes
            let currentFont = attributes[.font] as? NSFont
                ?? fontNearSelection(in: textView)
                ?? defaultFont
            attributes[.font] = MacRichTextFontTools.font(for: currentFont, withFamilyFrom: preferredTypingFont)
            attributes[.foregroundColor] = attributes[.foregroundColor] as? NSColor
                ?? NSColor.labelColor.withAlphaComponent(0.94)
            textView.typingAttributes = attributes
        }

        private func updatePreferredTypingFontIfNeeded(for command: RichTextEditCommand, in textView: NSTextView) {
            guard command.pinsTypingFont else { return }
            let selection = textView.selectedRange()
            if selection.length == 0, let typingFont = textView.typingAttributes[.font] as? NSFont {
                preferredTypingFont = typingFont
                return
            }

            preferredTypingFont = fontNearSelection(in: textView)
                ?? textView.typingAttributes[.font] as? NSFont
                ?? preferredTypingFont
        }

        private func fontNearSelection(in textView: NSTextView) -> NSFont? {
            guard let storage = textView.textStorage else { return nil }
            let length = (textView.string as NSString).length
            guard length > 0 else { return nil }

            let selection = textView.selectedRange()
            let location: Int
            if selection.length > 0 {
                location = min(selection.location, length - 1)
            } else {
                location = min(max(selection.location - 1, 0), length - 1)
            }

            return storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
        }

        private func sync(_ textView: NSTextView) {
            let nextText = NSAttributedString(attributedString: textView.attributedString())
            guard !text.wrappedValue.isEqual(to: nextText) else { return }
            text.wrappedValue = nextText
            onTextChange()
        }
    }
}

private struct RichTextEditRequest: Equatable {
    let id = UUID()
    let command: RichTextEditCommand
}

private enum MacRichTextFontTools {
    static func font(for current: NSFont, withFamilyFrom replacement: NSFont) -> NSFont {
        let sizeMatchedFont = sizedFont(replacement, size: current.pointSize)
        let traits = NSFontManager.shared.traits(of: current)
        var result = sizeMatchedFont

        if traits.contains(.boldFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }

        if traits.contains(.italicFontMask) {
            result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask)
        }

        return result
    }

    private static func sizedFont(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

private enum RichTextEditCommand: Equatable {
    case fontTrait(NSFontTraitMask)
    case font(MacNoteBodyFont)
    case heading(level: Int)
    case bullets
    case checklist
    case underline
    case highlight
    case link
    case separator

    var appliesToTitle: Bool {
        switch self {
        case .fontTrait, .font, .underline, .highlight, .link:
            return true
        case .heading, .bullets, .checklist, .separator:
            return false
        }
    }

    var pinsTypingFont: Bool {
        if case .font = self {
            return true
        }

        return false
    }

    func apply(to textView: NSTextView, defaultFont: NSFont) {
        switch self {
        case let .fontTrait(trait):
            toggleFontTrait(trait, in: textView, defaultFont: defaultFont)
        case let .font(font):
            applyFont(font.font, to: textView, defaultFont: defaultFont)
        case let .heading(level):
            applyHeading(level: level, to: textView, defaultFont: defaultFont)
        case .bullets:
            insertLinePrefix("\u{2022} ", in: textView, defaultFont: defaultFont)
        case .checklist:
            insertLinePrefix("\u{2610} ", in: textView, defaultFont: defaultFont)
        case .underline:
            toggleUnderline(in: textView, defaultFont: defaultFont)
        case .highlight:
            toggleHighlight(in: textView, defaultFont: defaultFont)
        case .link:
            applyLink(in: textView, defaultFont: defaultFont)
        case .separator:
            insertSeparator(in: textView, defaultFont: defaultFont)
        }
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask, in textView: NSTextView, defaultFont: NSFont) {
        let selection = textView.selectedRange()

        guard selection.length > 0, let storage = textView.textStorage else {
            var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
            let font = attributes[.font] as? NSFont ?? defaultFont
            attributes[.font] = toggledFont(font, trait: trait)
            textView.typingAttributes = attributes
            return
        }

        let firstFont = storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont ?? defaultFont
        let shouldAddTrait = !hasTrait(trait, in: firstFont)

        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            let font = value as? NSFont ?? defaultFont
            storage.addAttribute(
                .font,
                value: converted(font, trait: trait, shouldAdd: shouldAddTrait),
                range: range
            )
        }
    }

    private func applyFont(_ targetFont: NSFont, to textView: NSTextView, defaultFont: NSFont) {
        let selection = textView.selectedRange()

        guard selection.length > 0, let storage = textView.textStorage else {
            var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
            let currentFont = attributes[.font] as? NSFont ?? defaultFont
            attributes[.font] = font(for: currentFont, withFamilyFrom: targetFont)
            textView.typingAttributes = attributes
            return
        }

        storage.enumerateAttribute(.font, in: selection) { value, range, _ in
            let currentFont = value as? NSFont ?? defaultFont
            storage.addAttribute(.font, value: font(for: currentFont, withFamilyFrom: targetFont), range: range)
        }
    }

    private func applyHeading(level: Int, to textView: NSTextView, defaultFont: NSFont) {
        let selection = textView.selectedRange()
        let size = headingSize(level: level)
        let targetRange = paragraphRange(in: textView, selection: selection)

        guard targetRange.length > 0, let storage = textView.textStorage else {
            var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
            let currentFont = attributes[.font] as? NSFont ?? defaultFont
            attributes[.font] = headingFont(from: currentFont, size: size, level: level)
            textView.typingAttributes = attributes
            return
        }

        storage.enumerateAttribute(.font, in: targetRange) { value, range, _ in
            let currentFont = value as? NSFont ?? defaultFont
            storage.addAttribute(.font, value: headingFont(from: currentFont, size: size, level: level), range: range)
        }
    }

    private func toggleUnderline(in textView: NSTextView, defaultFont: NSFont) {
        let selection = textView.selectedRange()

        guard selection.length > 0, let storage = textView.textStorage else {
            var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
            let currentValue = attributes[.underlineStyle] as? Int
            if currentValue == NSUnderlineStyle.single.rawValue {
                attributes.removeValue(forKey: .underlineStyle)
            } else {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            textView.typingAttributes = attributes
            return
        }

        let currentValue = storage.attribute(.underlineStyle, at: selection.location, effectiveRange: nil) as? Int
        if currentValue == NSUnderlineStyle.single.rawValue {
            storage.removeAttribute(.underlineStyle, range: selection)
        } else {
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: selection)
        }
    }

    private func toggleHighlight(in textView: NSTextView, defaultFont: NSFont) {
        let selection = textView.selectedRange()
        let highlight = NSColor.systemYellow.withAlphaComponent(0.35)

        guard selection.length > 0, let storage = textView.textStorage else {
            var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
            if attributes[.backgroundColor] != nil {
                attributes.removeValue(forKey: .backgroundColor)
            } else {
                attributes[.backgroundColor] = highlight
            }
            textView.typingAttributes = attributes
            return
        }

        if storage.attribute(.backgroundColor, at: selection.location, effectiveRange: nil) != nil {
            storage.removeAttribute(.backgroundColor, range: selection)
        } else {
            storage.addAttribute(.backgroundColor, value: highlight, range: selection)
        }
    }

    private func applyLink(in textView: NSTextView, defaultFont: NSFont) {
        guard let storage = textView.textStorage else { return }

        let selection = textView.selectedRange()
        let url = pasteboardURL() ?? URL(string: "https://")!
        var linkAttributes = insertionAttributes(in: textView, defaultFont: defaultFont)
        linkAttributes[.link] = url
        linkAttributes[.foregroundColor] = NSColor.linkColor
        linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue

        if selection.length > 0 {
            storage.addAttributes(linkAttributes, range: selection)
            return
        }

        let insertedText = url.absoluteString
        storage.replaceCharacters(
            in: selection,
            with: NSAttributedString(string: insertedText, attributes: linkAttributes)
        )
        textView.setSelectedRange(NSRange(location: selection.location + (insertedText as NSString).length, length: 0))
    }

    private func pasteboardURL() -> URL? {
        guard let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else {
            return nil
        }

        return url
    }

    private func insertLinePrefix(_ marker: String, in textView: NSTextView, defaultFont: NSFont) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let targetRange = paragraphRange(in: textView, selection: selection)
        let markerLength = (marker as NSString).length

        if source.length == 0 || targetRange.length == 0 {
            storage.replaceCharacters(
                in: selection,
                with: NSAttributedString(string: marker, attributes: insertionAttributes(in: textView, defaultFont: defaultFont))
            )
            textView.setSelectedRange(NSRange(location: selection.location + markerLength, length: 0))
            return
        }

        var lineStarts: [Int] = []
        var lineLocation = targetRange.location
        let targetEnd = NSMaxRange(targetRange)

        while lineLocation < targetEnd {
            let lineRange = source.lineRange(for: NSRange(location: lineLocation, length: 0))
            let lineText = source.substring(with: lineRange)
            if !lineText.hasPrefix(marker) {
                lineStarts.append(lineRange.location)
            }

            let nextLine = NSMaxRange(lineRange)
            guard nextLine > lineLocation else { break }
            lineLocation = nextLine
        }

        for location in lineStarts.reversed() {
            storage.replaceCharacters(
                in: NSRange(location: location, length: 0),
                with: NSAttributedString(string: marker, attributes: insertionAttributes(in: textView, defaultFont: defaultFont))
            )
        }

        let insertedBeforeSelection = lineStarts.filter { $0 <= selection.location }.count
        textView.setSelectedRange(
            NSRange(
                location: selection.location + insertedBeforeSelection * markerLength,
                length: selection.length == 0 ? 0 : selection.length + lineStarts.count * markerLength
            )
        )
    }

    private func insertSeparator(in textView: NSTextView, defaultFont: NSFont) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let beforeSelection = (textView.string as NSString).substring(to: selection.location)
        let prefix = beforeSelection.isEmpty || beforeSelection.hasSuffix("\n") ? "" : "\n"
        let rule = String(repeating: "\u{2500}", count: 36)
        let insertion = prefix + rule + "\n"
        var attributes = insertionAttributes(in: textView, defaultFont: defaultFont)
        attributes[.foregroundColor] = NSColor.secondaryLabelColor

        storage.replaceCharacters(
            in: selection,
            with: NSAttributedString(string: insertion, attributes: attributes)
        )
        textView.setSelectedRange(NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    private func paragraphRange(in textView: NSTextView, selection: NSRange) -> NSRange {
        (textView.string as NSString).paragraphRange(for: selection)
    }

    private func insertionAttributes(in textView: NSTextView, defaultFont: NSFont) -> [NSAttributedString.Key: Any] {
        var attributes = textView.typingAttributes
        attributes[.font] = attributes[.font] as? NSFont ?? defaultFont
        attributes[.foregroundColor] = attributes[.foregroundColor] as? NSColor ?? NSColor.labelColor
        return attributes
    }

    private func toggledFont(_ font: NSFont, trait: NSFontTraitMask) -> NSFont {
        converted(font, trait: trait, shouldAdd: !hasTrait(trait, in: font))
    }

    private func converted(_ font: NSFont, trait: NSFontTraitMask, shouldAdd: Bool) -> NSFont {
        if shouldAdd {
            return NSFontManager.shared.convert(font, toHaveTrait: trait)
        }

        return NSFontManager.shared.convert(font, toNotHaveTrait: trait)
    }

    private func hasTrait(_ trait: NSFontTraitMask, in font: NSFont) -> Bool {
        NSFontManager.shared.traits(of: font).contains(trait)
    }

    private func font(for current: NSFont, withFamilyFrom replacement: NSFont) -> NSFont {
        MacRichTextFontTools.font(for: current, withFamilyFrom: replacement)
    }

    private func headingFont(from font: NSFont, size: CGFloat, level: Int) -> NSFont {
        var result = sizedFont(font, size: size)

        if level > 0 {
            result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask)
        }

        return result
    }

    private func sizedFont(_ font: NSFont, size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    private func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1:
            return 24
        case 2:
            return 20
        case 3:
            return 17
        default:
            return 15
        }
    }
}

private enum MacRichTextArchive {
    static func loadTitle(note: Note) -> NSAttributedString {
        if let data = note.titleRichTextRTF,
           let richText = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return richText
        }

        guard note.title != "Untitled" else {
            return NSAttributedString()
        }

        return NSAttributedString(
            string: note.title,
            attributes: [
                .font: MacRichTitleEditor.defaultFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.94)
            ]
        )
    }

    static func load(note: Note) -> NSAttributedString {
        if let data = note.bodyRichTextRTF,
           let richText = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return richText
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        return importPlainBody(note.bodyMarkdown, paragraphStyle: paragraphStyle)
    }

    static func data(for text: NSAttributedString) -> Data? {
        try? text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func importPlainBody(_ text: String, paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            append(line: line, to: result, paragraphStyle: paragraphStyle)

            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes(paragraphStyle: paragraphStyle)))
            }
        }

        return result
    }

    private static func append(
        line: String,
        to result: NSMutableAttributedString,
        paragraphStyle: NSParagraphStyle
    ) {
        if line.trimmingCharacters(in: .whitespaces) == "---" {
            var ruleAttributes = attributes(paragraphStyle: paragraphStyle)
            ruleAttributes[.foregroundColor] = NSColor.secondaryLabelColor
            result.append(
                NSAttributedString(
                    string: String(repeating: "\u{2500}", count: 36),
                    attributes: ruleAttributes
                )
            )
            return
        }

        let importedLine = importedLine(from: line)
        result.append(
            inlineStyledText(
                importedLine.text,
                font: importedLine.font,
                paragraphStyle: paragraphStyle
            )
        )
    }

    private static func importedLine(from line: String) -> (text: String, font: NSFont) {
        if let match = line.range(of: #"^\s{0,3}(#{1,3})\s+"#, options: .regularExpression) {
            let marker = String(line[match])
            let level = marker.filter { $0 == "#" }.count
            return (
                String(line[match.upperBound...]),
                headingFont(level: level)
            )
        }

        if line.hasPrefix("- ") {
            return ("\u{2022} " + line.dropFirst(2), MacNoteBodyFont.system.font)
        }

        return (line, MacNoteBodyFont.system.font)
    }

    private static func inlineStyledText(
        _ text: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var buffer = ""
        var cursor = text.startIndex

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            result.append(
                NSAttributedString(
                    string: buffer,
                    attributes: attributes(font: font, paragraphStyle: paragraphStyle)
                )
            )
            buffer = ""
        }

        while cursor < text.endIndex {
            if text[cursor...].hasPrefix("**") {
                let contentStart = text.index(cursor, offsetBy: 2)
                if let closeRange = text[contentStart...].range(of: "**") {
                    flushBuffer()
                    result.append(
                        NSAttributedString(
                            string: String(text[contentStart..<closeRange.lowerBound]),
                            attributes: attributes(
                                font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                                paragraphStyle: paragraphStyle
                            )
                        )
                    )
                    cursor = closeRange.upperBound
                    continue
                }
            }

            let character = text[cursor]
            if character == "*" || character == "_" {
                let contentStart = text.index(after: cursor)
                if let closeIndex = text[contentStart...].firstIndex(of: character) {
                    flushBuffer()
                    result.append(
                        NSAttributedString(
                            string: String(text[contentStart..<closeIndex]),
                            attributes: attributes(
                                font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                                paragraphStyle: paragraphStyle
                            )
                        )
                    )
                    cursor = text.index(after: closeIndex)
                    continue
                }
            }

            buffer.append(character)
            cursor = text.index(after: cursor)
        }

        flushBuffer()
        return result
    }

    private static func attributes(
        font: NSFont = MacNoteBodyFont.system.font,
        paragraphStyle: NSParagraphStyle
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
    }

    private static func headingFont(level: Int) -> NSFont {
        let size: CGFloat

        switch level {
        case 1:
            size = 24
        case 2:
            size = 20
        default:
            size = 17
        }

        return NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: size, weight: .regular),
            toHaveTrait: .boldFontMask
        )
    }
}

private enum MacNoteBodyFont: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case mono

    var id: Self { self }

    var label: String {
        switch self {
        case .system:
            return "System"
        case .rounded:
            return "Rounded"
        case .serif:
            return "Serif"
        case .mono:
            return "Mono"
        }
    }

    var font: NSFont {
        switch self {
        case .system:
            return .systemFont(ofSize: 15, weight: .regular)
        case .rounded:
            return designedFont(.rounded)
        case .serif:
            return designedFont(.serif)
        case .mono:
            return .monospacedSystemFont(ofSize: 15, weight: .regular)
        }
    }

    private func designedFont(_ design: NSFontDescriptor.SystemDesign) -> NSFont {
        let fallback = NSFont.systemFont(ofSize: 15, weight: .regular)
        guard let descriptor = fallback.fontDescriptor.withDesign(design),
              let font = NSFont(descriptor: descriptor, size: 15) else {
            return fallback
        }

        return font
    }
}

private struct MacNoteStats {
    private static let wordsPerMinute = 220

    let wordCount: Int
    let characterCount: Int

    init(text: String) {
        wordCount = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .count
        characterCount = text.count
    }

    var readingTimeLabel: String {
        guard wordCount > 0 else { return "0 min" }
        guard wordCount >= Self.wordsPerMinute else { return "< 1 min" }
        let minutes = Int(ceil(Double(wordCount) / Double(Self.wordsPerMinute)))
        return "\(minutes) min"
    }
}

private struct MacNoteInfoPopover: View {
    let note: Note
    let stats: MacNoteStats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note info")
                .font(.system(size: 13, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                MacNoteInfoRow(label: "Words", value: stats.wordCount.formatted())
                MacNoteInfoRow(label: "Characters", value: stats.characterCount.formatted())
                MacNoteInfoRow(label: "Reading time", value: stats.readingTimeLabel)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Created \(note.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Edited \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 228, alignment: .leading)
    }
}

private struct MacNoteInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
                .gridColumnAlignment(.trailing)
        }
        .font(.system(size: 12))
    }
}

private struct MacEmptyNotePane: View {
    let space: Space
    let createNote: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            MacSpaceIcon.view(space.emoji, size: 54)
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

// MARK: - Split editor (two notes, resizable divider)

/// Transient editor split state. `secondaryLeading` + `axis` come from the
/// drop side (left/top → secondary leads; right/bottom → trails). The primary
/// is always the note that was already open (see the drag-never-opens rule).
struct EditorSplit: Equatable {
    var primaryID: UUID
    var secondaryID: UUID
    var axis: Axis
    var secondaryLeading: Bool
    var ratio: CGFloat = 0.5
}

/// Renders two `MacNoteWorkspace` panes with a draggable divider. Each pane has
/// a close button that collapses the split, keeping the *other* note open.
struct MacSplitEditorView: View {
    /// What the *second* pane shows when there's no real `secondary` note yet.
    enum SecondPane: Equatable {
        case none   // single note — no second pane at all
        case drop   // drag-over-editor preview void
        case pick   // "Add to Split View" pick-mode placeholder
    }

    @Environment(\.colorScheme) private var colorScheme
    let space: Space
    let primary: Note
    /// The real second note, or nil while previewing / picking.
    let secondary: Note?
    /// What the empty second pane shows when `secondary == nil`.
    var secondPane: SecondPane = .none
    let secondaryLeading: Bool
    @Binding var ratio: CGFloat
    /// Held at 0 while a flying landing card fills the slot, then →1 to crossfade
    /// the real pane in (so the note doesn't pre-fill behind the moving card).
    var secondPaneOpacity: Double = 1
    let createNote: () -> Void
    var onCancelPending: (() -> Void)? = nil

    @State private var dragRatio: CGFloat?
    private let dividerThickness: CGFloat = 8
    private let minFraction: CGFloat = 0.22

    private var hasSecond: Bool { secondary != nil || secondPane != .none }
    private var isRealSplit: Bool { secondary != nil }

    // Continuity is everything here: the PRIMARY workspace is ONE view that
    // only ever moves (`.offset`) and resizes — never reordered into a
    // different HStack slot — so going single → preview → split (and back)
    // resizes it smoothly without recreating it (which is what flickered the
    // open note on release). The second pane appears/fades beside it.
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dT: CGFloat = isRealSplit ? dividerThickness : 0
            let total = max(1, w - dT)
            let pr: CGFloat = hasSecond
                ? min(max(minFraction, dragRatio ?? ratio), 1 - minFraction)
                : 1.0
            let primaryW = total * pr
            let secondW = total - primaryW

            // Plain HStack layout — natural SwiftUI flow, hit-testing 100%
            // predictable (no `.offset`/`.position` quirks where the visual
            // and hit-test areas diverge). Pane order swaps with
            // `secondaryLeading`; `.id(primary.id)` keeps the primary's editor
            // state through that swap.
            HStack(spacing: 0) {
                if secondaryLeading && hasSecond {
                    secondPaneContent
                        .frame(width: max(1, secondW), height: h)
                        .opacity(secondPaneOpacity)
                    if isRealSplit {
                        divider(total: total)
                            .frame(width: dividerThickness, height: h)
                    }
                }

                MacNoteWorkspace(space: space, note: primary, createNote: createNote)
                    .id(primary.id)
                    .frame(width: max(1, primaryW), height: h)
                    .clipped()

                if !secondaryLeading && hasSecond {
                    if isRealSplit {
                        divider(total: total)
                            .frame(width: dividerThickness, height: h)
                    }
                    secondPaneContent
                        .frame(width: max(1, secondW), height: h)
                        .opacity(secondPaneOpacity)
                }
            }
            .animation(.spring(response: 0.16, dampingFraction: 0.86), value: hasSecond)
            .animation(.spring(response: 0.16, dampingFraction: 0.86), value: secondaryLeading)
        }
    }

    @ViewBuilder
    private var secondPaneContent: some View {
        if let secondary {
            MacNoteWorkspace(space: space, note: secondary, createNote: createNote)
                .id(secondary.id)
                .clipped()
                // Fades in under the flying landing card (which carries the
                // motion) so the drop reads as one continuous gesture.
                .transition(.opacity)
        } else if secondPane == .pick {
            placeholderPane.transition(.opacity)
        } else {
            dropVoidPane.transition(.opacity)
        }
    }

    /// The bordered void shown while a tab is dragged over the editor.
    private var dropVoidPane: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 2)
            }
            .padding(8)
    }

    /// Empty pane shown while "Add to Split View" is pending — pick a note from
    /// the sidebar, or create one here.
    private var placeholderPane: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.and.hand.point.up.left")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Pick a note from the sidebar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
            Text("or")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            NewNoteButton(onTap: createNote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.primary.opacity(colorScheme == .dark ? 0.04 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            // Same grey-transparent hover treatment as the "New Note" button.
            SoftHoverIconButton(systemName: "xmark", diameter: 22, iconSize: 10) {
                onCancelPending?()
            }
            .padding(10)
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(dragRatio != nil ? 0.22 : 0.10))
            .overlay {
                Capsule()
                    .fill(.primary.opacity(0.3))
                    .frame(width: 3, height: 28)
            }
            .contentShape(Rectangle().inset(by: -6))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                // `.global`: local coords move with the resizing panes and
                // create a feedback loop that reads as lag/jitter.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        // Divider drag changes the PRIMARY's fraction; invert
                        // when the primary is on the right (secondary leading).
                        let sign: CGFloat = secondaryLeading ? -1 : 1
                        dragRatio = min(max(minFraction,
                            ratio + sign * v.translation.width / max(1, total)),
                            1 - minFraction)
                    }
                    .onEnded { _ in
                        if let dr = dragRatio { ratio = dr }
                        dragRatio = nil
                    }
            )
    }
}

/// "New Note" action for the pick-mode placeholder. The visual treatment
/// stays in SwiftUI, but the action fires from AppKit on mouse-down so a pane
/// update cannot discard an in-flight SwiftUI tap before mouse-up.
private struct NewNoteButton: View {
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    private let width: CGFloat = 104
    private let height: CGFloat = 32

    var body: some View {
        ZStack {
            Capsule()
                .fill(.primary.opacity(
                    isHovered ? (colorScheme == .dark ? 0.20 : 0.16) : 0.08
                ))

            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                Text("New Note")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(.primary.opacity(isHovered ? 1.0 : 0.82))
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        // Scale the VISUALS only. The hit/hover tracking view lives in the
        // overlay below, OUTSIDE this scaleEffect, so its tracking area never
        // moves under the cursor — otherwise scaling up on hover shifts the
        // edge past the pointer, firing exit→enter→exit in a flicker loop.
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .frame(width: width, height: height)
        .overlay {
            // Only hit-tested child; explicit size matches the pill bounds so
            // the representable adopts the full frame, not the label fragment.
            MouseDownTrackingView(action: onTap) { hovering in
                guard isHovered != hovering else { return }
                isHovered = hovering
            }
            .frame(width: width, height: height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Note")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}
#endif
