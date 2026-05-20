import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

struct InputBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    let currentSpace: Space?
    let keyboardDismissRequest: Int
    @Binding var isInputFocused: Bool

    @State private var draft = ""
    @State private var pendingAttachments: [AttachmentDraft] = []
    @State private var statusMessage: String?
    @State private var isPhotoPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isFocused = false
    @State private var inputHeight: CGFloat = 34

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Menu {
                        Button("Photo", systemImage: "photo") {
                            isPhotoPickerPresented = true
                        }
                        Button("File", systemImage: "doc") {
                            isFileImporterPresented = true
                        }
                        Button("Paste link", systemImage: "link") {
                            pasteLink()
                        }
                        Button("Voice memo", systemImage: "waveform") {
                            focusForDictation()
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30, height: 34)
                    }
                    .buttonStyle(.plain)

                    inputContent

                    Button(action: trailingAction) {
                        Image(systemName: canSend ? "arrow.up" : "mic.fill")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(canSend ? .white : .primary)
                            .background {
                                if canSend {
                                    Circle()
                                        .fill(.primary.opacity(0.78))
                                }
                            }
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(canSend ? "Send note" : "Dictate")
                    .accessibilityIdentifier("quick-add-action")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    createBlankAndEdit()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("New full note")
            }
        }
        .overlay(alignment: .topLeading) {
            focusStateProbe
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $selectedPhotoItem, matching: .images)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false,
            onCompletion: importFile
        )
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                await loadPhoto(from: newItem)
            }
        }
        .onAppear {
            isInputFocused = isFocused
        }
        .onDisappear {
            isInputFocused = false
        }
        .onChange(of: isFocused) { _, newValue in
            isInputFocused = newValue
        }
        .onChange(of: isInputFocused) { _, newValue in
            if !newValue, isFocused {
                isFocused = false
            }
        }
        .onChange(of: keyboardDismissRequest) { _, _ in
            isFocused = false
            isInputFocused = false
            dismissKeyboard()
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingAttachments)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: statusMessage)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: canSend)
    }

    private var inputContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            attachmentChips

            ZStack(alignment: .leading) {
                QuickAddTextEditor(
                    text: $draft,
                    isFocused: $isFocused,
                    measuredHeight: $inputHeight,
                    minHeight: inputMinHeight,
                    maxHeight: 112,
                    onSwipeDown: dismissInput
                )
                .frame(maxWidth: .infinity)
                .frame(height: inputHeight)
                .accessibilityIdentifier("quick-add-field")

                if draft.isEmpty {
                    Text("Empty your mind…")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(height: inputHeight, alignment: .center)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: inputMinHeight, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 34, alignment: hasInputAdornment ? .bottomLeading : .leading)
    }

    @ViewBuilder private var focusStateProbe: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Quick add focus state")
                .accessibilityIdentifier(isFocused ? "quick-add-focused" : "quick-add-unfocused")
        }
    }

    @ViewBuilder private var attachmentChips: some View {
        if !pendingAttachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                        HStack(spacing: 5) {
                            Image(systemName: icon(for: attachment.kind))
                                .font(.caption.weight(.semibold))
                            Text(attachment.displayTitle)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Button {
                                pendingAttachments.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.08), in: .capsule)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 28)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraft.isEmpty || !pendingAttachments.isEmpty
    }

    private var hasInputAdornment: Bool {
        statusMessage != nil || !pendingAttachments.isEmpty
    }

    private var inputMinHeight: CGFloat {
        hasInputAdornment ? 22 : 34
    }

    private func trailingAction() {
        if canSend {
            sendDraft()
        } else {
            focusForDictation()
        }
    }

    private func sendDraft() {
        guard let currentSpace else {
            showStatus("Choose a space first")
            return
        }
        do {
            _ = try NoteService(context: modelContext).createQuickNote(
                text: trimmedDraft,
                in: currentSpace,
                attachments: pendingAttachments
            )
            draft = ""
            pendingAttachments = []
            showStatus("Saved to Random")
        } catch {
            showStatus("Couldn’t save note")
        }
    }

    private func createBlankAndEdit() {
        guard let currentSpace else {
            showStatus("Choose a space first")
            return
        }
        do {
            let note = try NoteService(context: modelContext).createBlankNote(in: currentSpace)
            appState.presentEdit(note)
        } catch {
            showStatus("Couldn’t create note")
        }
    }

    private func focusForDictation() {
        isFocused = true
        showStatus("Ready for dictation")
    }

    private func dismissInput() {
        isFocused = false
        isInputFocused = false
        dismissKeyboard()
    }

    private func pasteLink() {
        guard let string = UIPasteboard.general.string,
              let url = URL(string: string),
              url.scheme?.hasPrefix("http") == true
        else {
            showStatus("No link on clipboard")
            return
        }

        pendingAttachments.append(
            AttachmentDraft(
                kind: .link,
                displayTitle: url.host(percentEncoded: false) ?? url.absoluteString,
                url: url,
                linkSiteName: url.absoluteString
            )
        )
        showStatus("Link attached")
    }

    private func loadPhoto(from item: PhotosPickerItem?) async {
        guard let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                showStatus("Couldn’t read photo")
                return
            }
            await MainActor.run {
                pendingAttachments.append(
                    AttachmentDraft(
                        kind: .image,
                        displayTitle: "Photo",
                        imageData: data
                    )
                )
                selectedPhotoItem = nil
                showStatus("Photo attached")
            }
        } catch {
            showStatus("Couldn’t attach photo")
        }
    }

    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            pendingAttachments.append(
                AttachmentDraft(
                    kind: .file,
                    displayTitle: url.lastPathComponent,
                    url: url
                )
            )
            showStatus("File attached")
        case .failure:
            showStatus("Couldn’t attach file")
        }
    }

    private func icon(for kind: AttachmentKind) -> String {
        switch kind {
        case .link: "link"
        case .image: "photo"
        case .file: "doc"
        case .voice: "waveform"
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            await MainActor.run {
                if statusMessage == message {
                    statusMessage = nil
                }
            }
        }
    }
}

#if canImport(UIKit)
private struct QuickAddTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat

    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSwipeDown: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = QuickAddUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = Self.font
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .label
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.keyboardDismissMode = .interactive
        textView.accessibilityIdentifier = "quick-add-field"
        // Don't let intrinsic single-line width push the surrounding HStack outward —
        // let SwiftUI's frame dictate width so the text wraps and grows vertically instead.
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.delegate = context.coordinator
        textView.addGestureRecognizer(pan)

        let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSwipe))
        swipe.direction = .down
        swipe.cancelsTouchesInView = false
        swipe.delaysTouchesBegan = false
        swipe.delaysTouchesEnded = false
        swipe.delegate = context.coordinator
        textView.addGestureRecognizer(swipe)
        textView.onSwipeDown = {
            context.coordinator.parent.onSwipeDown()
        }

        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        (textView as? QuickAddUITextView)?.onSwipeDown = {
            context.coordinator.parent.onSwipeDown()
        }

        if textView.text != text {
            textView.text = text
        }

        if isFocused, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }

        context.coordinator.updateHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static var font: UIFont {
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        let roundedDescriptor = descriptor.withDesign(.rounded) ?? descriptor
        return UIFont(descriptor: roundedDescriptor, size: 0)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: QuickAddTextEditor

        init(parent: QuickAddTextEditor) {
            self.parent = parent
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard parent.isFocused, recognizer.state == .changed || recognizer.state == .ended else { return }

            let translation = recognizer.translation(in: recognizer.view)
            guard translation.y > 18, abs(translation.y) > abs(translation.x) else { return }

            parent.onSwipeDown()
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }

        @objc func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
            guard parent.isFocused, recognizer.state == .ended else { return }
            parent.onSwipeDown()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            parent.isFocused
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func updateHeight(for textView: UITextView) {
            guard textView.bounds.width > 0 else { return }

            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let targetHeight = textView.sizeThatFits(fittingSize).height
            let clampedHeight = min(max(targetHeight, parent.minHeight), parent.maxHeight)
            textView.isScrollEnabled = targetHeight > parent.maxHeight

            guard abs(parent.measuredHeight - clampedHeight) > 0.5 else { return }

            DispatchQueue.main.async { [weak self] in
                self?.parent.measuredHeight = clampedHeight
            }
        }
    }
}

private final class QuickAddUITextView: UITextView {
    var onSwipeDown: (() -> Void)?

    private var touchStart: CGPoint?
    private var didTriggerSwipeDown = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStart = touches.first?.location(in: self)
        didTriggerSwipeDown = false
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !didTriggerSwipeDown,
           isFirstResponder,
           let start = touchStart,
           let current = touches.first?.location(in: self) {
            let translation = CGPoint(x: current.x - start.x, y: current.y - start.y)
            if translation.y > 18, abs(translation.y) > abs(translation.x) {
                didTriggerSwipeDown = true
                onSwipeDown?()
            }
        }

        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStart = nil
        didTriggerSwipeDown = false
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchStart = nil
        didTriggerSwipeDown = false
        super.touchesCancelled(touches, with: event)
    }
}

extension QuickAddTextEditor.Coordinator: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        parent.text = textView.text
        updateHeight(for: textView)
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if !parent.isFocused {
            parent.isFocused = true
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if parent.isFocused {
            parent.isFocused = false
        }
    }
}
#endif
