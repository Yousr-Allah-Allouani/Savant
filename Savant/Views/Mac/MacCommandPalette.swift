import AppKit
import SwiftUI

#if os(macOS)
struct MacCommandPalette: View {
    /// Selection lives here as an observed object so the palette re-renders the
    /// instant the index changes — relying on the parent (MacRootView) to
    /// re-render and re-pass an `Int` did NOT refresh the highlight.
    @ObservedObject var nav: CommandPaletteNav
    let resultsProvider: (String) -> [MacCommandPaletteResult]
    let activeSpaceColor: Color
    let execute: (MacCommandPaletteResult) -> Void
    let dismiss: () -> Void

    private var selectedIndex: Int { nav.selectedIndex }

    @Environment(\.colorScheme) private var colorScheme
    /// Only auto-scroll for arrow-key navigation. Hover-driven selection must
    /// NOT scroll, or scrolling moves rows under the cursor → hover-select →
    /// scrollTo → re-scroll → chaotic flicker.
    @State private var navByKeyboard = false
    @State private var lastMouseLocation: CGPoint?
    @State private var query = ""

    private var results: [MacCommandPaletteResult] {
        resultsProvider(query)
    }

    var body: some View {
        return ZStack(alignment: .top) {
            // No screen dimming (Arc-style) — just an invisible catcher so a
            // click anywhere outside the panel still dismisses it.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)

            VStack(spacing: 0) {
                inputRow

                Divider()
                    .opacity(0.45)

                if !results.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Plain VStack (not Lazy): the few palette rows are
                            // always realized, so each re-evaluates `isSelected`
                            // on every render. LazyVStack can keep a cached row
                            // and skip the selection update.
                            VStack(spacing: 5) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                    MacCommandPaletteRow(
                                        result: result,
                                        isSelected: index == selectedIndex,
                                        activeSpaceColor: activeSpaceColor
                                    )
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        execute(result)
                                    }
                                    .onContinuousHover(coordinateSpace: .global) { phase in
                                        if case let .active(location) = phase {
                                            selectFromMouseMove(index: index, location: location)
                                        }
                                    }
                                }
                            }
                            .padding(14)
                        }
                        .scrollIndicators(.hidden)
                        .frame(maxHeight: resultsHeight)
                        // Keep the highlighted row in view when navigating
                        // with arrow keys past the visible window.
                        .onChange(of: selectedIndex) { _, newIndex in
                            guard navByKeyboard else { return }
                            navByKeyboard = false
                            withAnimation(.easeOut(duration: 0.14)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 650)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.98 : 1.0))
                    // Two-layer shadow: a tight contact shadow plus a wide soft
                    // cast so the panel reads as floating now that there's no
                    // dimmed backdrop behind it (Arc-style).
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.55 : 0.22), radius: 40, x: 0, y: 26)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.30 : 0.12), radius: 8, x: 0, y: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10), lineWidth: 1)
            }
            .padding(.top, 170)
            .transition(.scale(scale: 0.985).combined(with: .opacity))

            Button(action: dismiss) { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .focusable(false)
        }
        .background {
            PaletteKeyboardMonitorView(
                onMove: moveSelection,
                onSubmit: submitSelection,
                onCancel: dismiss
            )
        }
        .onChange(of: results.count) { _, count in
            nav.count = count
            if selectedIndex >= count {
                nav.set(max(0, count - 1))
            }
        }
        .onAppear {
            nav.count = results.count
            nav.set(0)
        }
    }

    private func moveSelection(_ delta: Int) {
        navByKeyboard = true
        nav.move(delta)
    }

    private func submitSelection() {
        if let result = results[safe: selectedIndex] {
            execute(result)
        }
    }

    private func updateQuery(_ newQuery: String) {
        guard query != newQuery else { return }
        query = newQuery
        nav.count = resultsProvider(newQuery).count
        nav.set(0)
    }

    private func selectFromMouseMove(index: Int, location: CGPoint) {
        if let lastMouseLocation,
           hypot(lastMouseLocation.x - location.x, lastMouseLocation.y - location.y) < 0.5 {
            return
        }
        lastMouseLocation = location
        nav.set(index)
    }

    private var resultsHeight: CGFloat {
        let rowHeights = results.reduce(CGFloat(0)) { total, result in
            total + (result.subtitle == nil ? 48 : 54)
        }
        let spacing = CGFloat(max(0, results.count - 1)) * 5
        return min(456, rowHeights + spacing + 28)
    }

    private var inputRow: some View {
        HStack(spacing: 14) {
            Image(systemName: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "plus" : "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)

            // Custom AppKit field: its delegate forwards ↑/↓ (moveUp:/moveDown:)
            // straight to selection, so the field never swallows the arrows to
            // move its insertion point (which broke navigation once you typed).
            CommandPaletteField(
                text: query,
                placeholder: "Title a new note or run a command...",
                onChange: updateQuery,
                onMove: moveSelection,
                onSubmit: submitSelection,
                onCancel: dismiss
            )
            .frame(height: 26)
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.025 : 0.01))
    }

}

struct MacCommandPaletteResult: Identifiable {
    enum Kind: Equatable {
        case createNote(title: String)
        case openNote(UUID)
        case openNoteInSplit(UUID)
        case pinCurrent
        case favoriteCurrent
        case moveCurrentToNotes
        case duplicateCurrent
        case addToSplitCurrent
        case closeSplit
        case newSpace
        case nextSpace
        case previousSpace
        case toggleSidebar
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind
    var shortcut: String?
    var isPrimaryCreate: Bool = false
}

private struct MacCommandPaletteRow: View {
    let result: MacCommandPaletteResult
    let isSelected: Bool
    let activeSpaceColor: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: result.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? ink.opacity(0.9) : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                if let subtitle = result.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? ink.opacity(0.7) : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            if let shortcut = result.shortcut {
                // A real, working keyboard shortcut — show it as a chip always.
                Text(shortcut)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? ink.opacity(0.9) : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? ink.opacity(0.14) : Color.primary.opacity(0.06))
                    )
            } else if isSelected {
                // No dedicated shortcut: the ↵ affordance shows ONLY on the
                // highlighted row to mean "Return runs this" (Arc-style). It
                // was previously drawn on every row, reading as a fake shortcut.
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(ink.opacity(0.65))
            }
        }
        .foregroundStyle(isSelected ? ink : Color.primary.opacity(0.92))
        .padding(.horizontal, 12)
        .frame(height: result.subtitle == nil ? 48 : 54)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? selectionFill : Color.clear)
        }
    }

    /// Selection pill = the SAME elevated, space-tinted fill the sidebar uses
    /// for a selected note row (`elevatedSelectionFill`), so the palette's
    /// highlight matches the sidebar selection exactly instead of the raw,
    /// over-saturated space color it used before. Readability comes from the
    /// adaptive `ink`.
    private var selectionFill: Color {
        activeSpaceColor.elevatedSelectionFill(scheme: colorScheme)
    }

    /// Readable text/glyph color chosen from the fill's luminance — fixes the
    /// old hardcoded white that vanished on pale themes.
    private var ink: Color { selectionFill.selectionInk }
}

/// Palette-scoped keyboard handling. This keeps ↑/↓/Return/Escape reliable even
/// when AppKit chooses a different first responder or skips the text field's
/// command delegate in a particular layout/focus state.
private struct PaletteKeyboardMonitorView: NSViewRepresentable {
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PaletteKeyboardMonitorNSView()
        view.onMove = onMove
        view.onSubmit = onSubmit
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? PaletteKeyboardMonitorNSView else { return }
        view.onMove = onMove
        view.onSubmit = onSubmit
        view.onCancel = onCancel
    }
}

private final class PaletteKeyboardMonitorNSView: NSView {
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 126:
                self.onMove?(-1)
                return nil
            case 125:
                self.onMove?(1)
                return nil
            case 36, 76:
                self.onSubmit?()
                return nil
            case 53:
                self.onCancel?()
                return nil
            default:
                return event
            }
        }
    }

    private func stopMonitoring() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    deinit {
        stopMonitoring()
    }
}

/// AppKit-backed single-line field for the palette. Its delegate intercepts the
/// arrow / return / escape command selectors and routes them to closures, so:
/// - ↑/↓ drive list selection and NEVER move the field's insertion point (the
///   SwiftUI `TextField` swallowed them once it had text, breaking nav);
/// - Return runs the highlighted result, Escape dismisses.
/// The coordinator's `parent` is refreshed every `updateNSView`, so the closures
/// (and the live state they read) are always current.
private struct CommandPaletteField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let onChange: (String) -> Void
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 19, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        // Take focus once attached so typing starts immediately.
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteField
        init(_ parent: CommandPaletteField) { self.parent = parent }

        @objc func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        @objc func control(_ control: NSControl, textView: NSTextView,
                           doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMove(-1); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMove(1); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default:
                return false
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
