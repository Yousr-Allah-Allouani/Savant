import SwiftData
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
/// Live, reference-typed selection state for the ⌘T palette. The palette's
/// key monitor captures this object (not a value-type `MacRootView` snapshot,
/// whose `@State` reads back as stale), so ↑/↓ always move against the current,
/// post-filter results. `count` is kept in sync from the root each render.
final class CommandPaletteNav: ObservableObject {
    /// Process-wide single instance. `WindowGroup` can spin up more than one
    /// `MacRootView` (window restoration / a second window), each with its own
    /// `@StateObject`; that produced TWO selection states — the keys moved one,
    /// the palette you saw observed the other, so the highlight never moved.
    /// Sharing one nav guarantees the visible palette and the keyed palette are
    /// the same selection.
    static let shared = CommandPaletteNav()

    @Published var selectedIndex = 0
    var count = 0

    func move(_ delta: Int) {
        guard count > 0 else { return }
        let nextIndex = min(max(selectedIndex + delta, 0), count - 1)
        guard selectedIndex != nextIndex else { return }
        selectedIndex = nextIndex
    }

    func set(_ index: Int) {
        let nextIndex = count > 0 ? min(max(index, 0), count - 1) : 0
        guard selectedIndex != nextIndex else { return }
        selectedIndex = nextIndex
    }
}

/// Release-time "landing" of a dragged tab into a freshly-formed split pane.
private struct SplitLanding: Equatable {
    let id: UUID      // dragged note (for the flying card's content)
    let from: CGRect  // ghost's release frame (window coords)
    let to: CGRect    // target pane frame it scales up to fill (window coords)
}

struct MacRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Space.sortIndex) private var spaces: [Space]
    @Query(sort: \Note.createdAt) private var notes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var selectedSpaceID: UUID?
    @State private var selectedNoteIDsBySpace: [UUID: UUID] = [:]
    /// Space the user has asked to delete; drives the destructive
    /// confirmation dialog. Deleting a space cascade-deletes its notes and
    /// folders, so it always routes through a confirm step.
    @State private var spacePendingDeletion: Space?
    @State private var showManageSpaces = false
    /// Editor splits are transient tab pairs. The pair containing the selected
    /// note renders in the editor; unrelated pairs remain combined in the
    /// sidebar while another note or pair is focused.
    @State private var editorSplits: [EditorSplit] = []
    /// "Add to Split View" pending state: the primary is chosen and the editor
    /// shows a placeholder pane until you pick a note from the sidebar or
    /// create one.
    @State private var pendingSplitPrimaryID: UUID?
    /// Blank secondary created from the placeholder button but not yet fully
    /// published into the sidebar query. Prevents repeat presses from creating
    /// multiple notes during that short handoff.
    @State private var pendingSplitCreatedSecondaryID: UUID?
    /// Which side the pending placeholder pane sits on — honors the drop side
    /// when entered via drag (left drop → placeholder on the left).
    @State private var pendingSplitSecondaryLeading = false
    /// Drives the release "landing" of a dragged tab into the new split pane:
    /// a card flies from the ghost's drop point and scales up to fill the void
    /// (then fades as the real pane resolves), so the drop feels continuous
    /// instead of the ghost just blinking out.
    @State private var splitLanding: SplitLanding?
    @State private var splitLandingActive = false   // drives from→to flight + grow
    @State private var splitLandingRevealed = false  // end crossfade: card→note
    /// The note-drag session, owned here so the editor pane can observe the
    /// in-progress drag (drag-onto-editor split) while the sidebar drives it.
    @State private var dragSession = CrossTierDragSession()
    /// Live quarter-edge drop side while dragging a note over the editor.
    @State private var editorDropSide: SplitDropSide?
    /// Editor pane frame in the window coordinate space (for drop hit-testing).
    @State private var editorFrame: CGRect = .zero
    @State private var sidebarWidth: CGFloat = 300
    @State private var lastExpandedSidebarWidth: CGFloat = 300
    /// Fractional page index for the space pager, animated. Lives in its own
    /// @Observable model (NOT @State) so per-frame swipe updates invalidate
    /// only the views that read it in their own body — the backdrop and the
    /// sidebar's column-offset modifier — instead of re-evaluating the whole
    /// window tree (sidebar columns + editor) on every swipe frame.
    @State private var pager = SpacePagerModel()
    @State private var swipeSettleGeneration = 0
    @State private var spaceAnimationGeneration = 0
    @State private var swipeStartPageOffset: CGFloat?
    @State private var isSpaceSettling = false
    /// Live preview of the in-creation Space's gradient. While set, the
    /// window background renders this gradient (matching Zen's gradient
    /// generator behavior: the entire chrome updates as you drag dots).
    @State private var previewGradient: ZenGradientConfig?
    @State private var isCommandPalettePresented = false
    @ObservedObject private var paletteNav = CommandPaletteNav.shared
    @State private var sidebarSearchResetToken = 0
    @StateObject private var swipeMonitor = SpaceSwipeDirectionMonitor()
    @StateObject private var hoverManager = MacHoverSidebarManager()
    @Environment(\.colorScheme) private var colorScheme

    private var selectedSpace: Space? {
        if let selectedSpaceID, let match = spaces.first(where: { $0.id == selectedSpaceID }) {
            return match
        }
        return spaces.first
    }

    private var selectedNote: Note? {
        guard let selectedSpace, let noteID = selectedNoteID(for: selectedSpace) else { return nil }
        return notes.first { $0.id == noteID }
    }

    private func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    // Body broken into pieces — the full chain blew the type-checker budget.

    @ViewBuilder
    private var rootContent: some View {
        MacSpaceBackdrop(
            spaces: spaces,
            pager: pager,
            previewGradient: previewGradient
        )

        HStack(spacing: 0) {
            notesSidebar(width: sidebarWidth)
                .frame(width: sidebarWidth)
                .opacity(sidebarWidth == 0 ? 0 : 1)
                // The floating drag ghost lives in the sidebar's overlay but
                // can extend over the editor pane (drag-onto-editor split).
                // Lift it above the editor's z-layer so it renders ON TOP of
                // the note + its borders, not under.
                .zIndex(2)

            MacSidebarResizer(
                width: $sidebarWidth,
                lastExpandedWidth: $lastExpandedSidebarWidth
            )

            editorPane
        }

        // Always-mounted ⌘S / ⌘T shortcuts from anywhere.
        Button(action: toggleSidebar) { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)

        Button(action: toggleCommandPalette) { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("t", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)

        // ⌘N / ⇧⌘N — the shortcuts the command palette advertises on its
        // New Note / New Space rows. Wired here so they actually fire.
        Button(action: createNote) { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)

        Button(action: createSpace) { Color.clear }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .focusable(false)
    }

    @ViewBuilder
    private var commandPaletteOverlay: some View {
        if isCommandPalettePresented {
            MacCommandPalette(
                nav: paletteNav,
                resultsProvider: commandPaletteResults(for:),
                activeSpaceColor: displaySpaceColor,
                execute: executeCommandPaletteResult,
                dismiss: closeCommandPalette
            )
            .zIndex(20)
        }
    }

    @ViewBuilder
    private var manageSpacesOverlay: some View {
        if showManageSpaces {
            MacManageSpacesView(
                spaces: spaces,
                activeSpaceID: selectedSpaceID,
                notesProvider: { space in
                    notes
                        .filter { $0.space?.id == space.id && ($0.tier == .pinned || $0.tier == .random) }
                        .sorted {
                            ($0.manualSortIndex ?? Int.max) != ($1.manualSortIndex ?? Int.max)
                                ? ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max)
                                : $0.createdAt < $1.createdAt
                        }
                },
                onClose: { withAnimation(.smooth(duration: 0.2)) { showManageSpaces = false } },
                onOpenSpace: { space in
                    selectedSpaceID = space.id
                    withAnimation(.smooth(duration: 0.2)) { showManageSpaces = false }
                },
                requestDeleteSpace: { spacePendingDeletion = $0 }
            )
            .transition(.opacity)
            .zIndex(25)
        }
    }

    @ViewBuilder
    private var hoverSidebarOverlay: some View {
        // Hover-reveal sidebar: when collapsed, hovering the left edge slides a
        // floating preview of the sidebar over the editor.
        if sidebarWidth == 0, hoverManager.isVisible {
            notesSidebar(width: lastExpandedSidebarWidth)
                .frame(width: lastExpandedSidebarWidth)
                .frame(maxHeight: .infinity)
                .background {
                    ZStack {
                        displaySpaceColor.opacity(colorScheme == .dark ? 0.85 : 0.78)
                        Rectangle().fill(.thickMaterial)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.primary.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 18, x: 6, y: 0)
                .padding(.leading, 7)
                .padding(.vertical, 7)
                .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    /// The sidebar with all its bindings/closures, factored out so the body
    /// stays type-checkable (the two call sites differ only by `width`).
    private func notesSidebar(width: CGFloat) -> MacNotesSidebar {
        MacNotesSidebar(
            spaces: spaces,
            notes: notes,
            folders: folders,
            selectedSpaceID: $selectedSpaceID,
            selectedNoteIDsBySpace: $selectedNoteIDsBySpace,
            pager: pager,
            previewGradient: $previewGradient,
            searchResetToken: sidebarSearchResetToken,
            width: width,
            selectNote: selectNote,
            createNote: createNote,
            openCommandPalette: openCommandPalette,
            isCommandPaletteActive: isCommandPalettePresented,
            createSpace: createSpace,
            toggleSidebar: toggleSidebar,
            requestDeleteSpace: { spacePendingDeletion = $0 },
            openManageSpaces: { withAnimation(.smooth(duration: 0.2)) { showManageSpaces = true } },
            openInSplit: openInSplit,
            addToSplit: { addToSplit($0) },
            onSplitDrop: createSplitFromDrag,
            activeSplits: editorSplits,
            pendingSplitPrimaryID: pendingSplitPrimaryID,
            dissolveSplit: { dissolveSplit(containing: $0, hostedTier: $1, hostedSpace: $2) },
            cancelPendingSplit: cancelPendingSplit,
            session: dragSession
        )
    }

    @ViewBuilder
    private var editorPane: some View {
        if let selectedSpace {
            editorContent(selectedSpace)
                // Frame in window coords so the drag engine can hit-test the
                // cursor against the editor.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("window")) } action: { editorFrame = $0 }
        } else {
            Color.clear
        }
    }

    /// The editor: creation mode, or ONE `MacSplitEditorView` for every other
    /// state (single note / drag preview / pending pick / formed split). Using
    /// one view with a stable primary `.id` is what makes single → preview →
    /// split → single all resize smoothly, with no view swap to flicker the
    /// open note on release.
    @ViewBuilder
    private func editorContent(_ space: Space) -> some View {
        if previewGradient != nil {
            CreationModeEmptyPane()
                .padding(6)
                .transition(.opacity)
        } else if let primary = splitPrimaryNote {
            MacSplitEditorView(
                space: space,
                primary: primary,
                secondary: splitSecondaryNote,
                secondPane: splitSecondPaneKind,
                secondaryLeading: splitSecondaryLeading,
                ratio: splitRatioBinding,
                secondPaneOpacity: secondPaneRevealOpacity,
                createNote: createNote,
                onCancelPending: cancelPendingSplit
            )
            // Stable across single→preview→split (same note) → no flicker.
            .id(primary.id)
        } else {
            MacNoteWorkspace(space: space, note: nil, createNote: { createNote(in: space) })
                .id(space.id)
        }
    }

    // MARK: Editor split resolution (single source of truth for the pane)

    /// The note shown in the primary pane (the open note in every state).
    private var splitPrimaryNote: Note? {
        if let focusedEditorSplit { return note(focusedEditorSplit.primaryID) }
        if let pid = pendingSplitPrimaryID { return note(pid) }
        return selectedNote
    }
    private var splitSecondaryNote: Note? {
        focusedEditorSplit.flatMap { note($0.secondaryID) }
    }
    /// What the empty second pane shows when there's no real secondary yet.
    private var splitSecondPaneKind: MacSplitEditorView.SecondPane {
        if isShowingSplit {
            // A newly-created secondary can take a runloop to reach `notes`
            // after the split IDs are recorded. Keep the placeholder mounted
            // during that handoff instead of briefly collapsing to one pane.
            return splitSecondaryNote == nil && pendingSplitPrimaryID != nil ? .pick : .none
        }
        if pendingSplitPrimaryID != nil { return .pick }
        // Drag-over-editor preview (single note open).
        if editorDropSide != nil { return .drop }
        return .none
    }
    private var splitSecondaryLeading: Bool {
        if let focusedEditorSplit { return focusedEditorSplit.secondaryLeading }
        if pendingSplitPrimaryID != nil { return pendingSplitSecondaryLeading }
        return editorDropSide?.secondaryLeading ?? false
    }
    private var splitRatioBinding: Binding<CGFloat> {
        Binding(
            get: { focusedEditorSplit?.ratio ?? 0.5 },
            set: { ratio in
                guard let index = focusedEditorSplitIndex else { return }
                editorSplits[index].ratio = ratio
            }
        )
    }

    /// Open `secondary` beside the currently-open note (the primary). Per the
    /// design rule, the primary is always the note that was already open.
    private func openInSplit(_ secondary: Note) {
        guard let space = selectedSpace,
              let primaryID = selectedNoteID(for: space),
              primaryID != secondary.id else { return }
        withAnimation(.smooth(duration: 0.2)) {
            storeSplit(EditorSplit(primaryID: primaryID, secondaryID: secondary.id,
                                   axis: .horizontal, secondaryLeading: false))
        }
    }

    /// "Add to Split View" on the open tab: enter pending mode. The editor
    /// shows the primary + a placeholder pane; pick a sidebar note (→
    /// `selectNote`) or hit New Note to fill the second pane.
    private func addToSplit(_ primary: Note, secondaryLeading: Bool = false) {
        guard let space = selectedSpace else { return }
        selectedNoteIDsBySpace[space.id] = primary.id
        pendingSplitSecondaryLeading = secondaryLeading
        withAnimation(.smooth(duration: 0.2)) {
            removeSplits(containingAnyOf: [primary.id])
            pendingSplitPrimaryID = primary.id
            pendingSplitCreatedSecondaryID = nil
        }
    }

    /// Fill the pending split's second pane with `secondaryID` and form it.
    private func completePendingSplit(with secondaryID: UUID) {
        guard let pid = pendingSplitPrimaryID, let space = selectedSpace, pid != secondaryID else { return }
        selectedNoteIDsBySpace[space.id] = pid
        withAnimation(.smooth(duration: 0.2)) {
            storeSplit(EditorSplit(primaryID: pid, secondaryID: secondaryID,
                                   axis: .horizontal, secondaryLeading: pendingSplitSecondaryLeading))
        }
        finishPendingSplitTransitionIfReady()
    }

    /// Keep the pending combined pill mounted until SwiftData has published a
    /// newly-created secondary into `notes`. Without this handoff the pending
    /// pill disappears before the sidebar can resolve the real split pair.
    private func finishPendingSplitTransitionIfReady() {
        guard let primaryID = pendingSplitPrimaryID,
              let secondaryID = split(containing: primaryID)?.secondaryID,
              notes.contains(where: { $0.id == secondaryID }) else { return }
        withAnimation(.smooth(duration: 0.2)) {
            pendingSplitPrimaryID = nil
            pendingSplitCreatedSecondaryID = nil
        }
    }

    /// New Note button in the placeholder → create + fill the second pane.
    private func createSecondaryForPendingSplit() {
        guard pendingSplitCreatedSecondaryID == nil,
              let space = selectedSpace,
              let secondary = try? NoteService(context: modelContext).createBlankNote(in: space) else { return }
        // Defer the layout swap one runloop. Running it synchronously inside
        // the tap handler caused an EXC_BAD_ACCESS on `Note.id` from
        // `splitPair` — the sidebar re-renders mid-context-save and reads a
        // Note in a transient state. Capturing the id (a value type) before
        // the async hop keeps the reference safe.
        let secondaryID = secondary.id
        pendingSplitCreatedSecondaryID = secondaryID
        DispatchQueue.main.async {
            completePendingSplit(with: secondaryID)
        }
    }

    private func cancelPendingSplit() {
        withAnimation(.smooth(duration: 0.2)) {
            if let createdID = pendingSplitCreatedSecondaryID {
                removeSplits(containingAnyOf: [createdID])
            }
            pendingSplitPrimaryID = nil
            pendingSplitCreatedSecondaryID = nil
        }
    }

    /// Zen's `_calculateDropSide`: while a single note is dragged over the
    /// editor, the side is whichever edge the cursor is within a quarter of;
    /// the middle half = no split. Stored on the session so the sidebar's
    /// `commitDrag` makes a split (instead of a reorder) on release.
    private func updateEditorDropSide() {
        // Only the plain single-note editor is a split target. (Don't re-split
        // an existing split / pending add / creation mode mid-drag.)
        // NB: pending pick-mode is NOT excluded — dragging a note onto the
        // editor while picking should FILL the placeholder (otherwise pending
        // is a dead-end that silently blocks all drag-to-split).
        let inEditor: Bool = {
            guard dragSession.isActive, !dragSession.isMulti,
                  let x = dragSession.cursorX, let y = dragSession.cursorY,
                  editorFrame.width > 0
            else { return false }
            return editorFrame.contains(CGPoint(x: x, y: y))
        }()
        // Update the "cursor over editor" flag separately — it drives the big
        // floating-tile ghost even in the middle (no-split) zone.
        if dragSession.cursorOverEditor != inEditor { dragSession.cursorOverEditor = inEditor }

        guard inEditor, !isShowingSplit, previewGradient == nil,
              let x = dragSession.cursorX else {
            setEditorDropSide(nil); return
        }
        // Small middle dead-zone (~12% of the width centered). Anything past a
        // gentle skew off-center engages — feels responsive, while still giving
        // a real "drop on top" zone.
        let lx = x - editorFrame.minX
        let w = editorFrame.width
        let half = w / 2
        let dead = w * 0.06   // 6% each side of center → 12% dead-zone
        let proposed: SplitDropSide? = lx < half - dead ? .left
            : (lx > half + dead ? .right : nil)
        // Lock-once-engaged: don't flip directly L↔R. Switching sides REQUIRES
        // passing through the middle (which disengages first), so the void
        // doesn't appear to slide from one side to the other.
        let current = editorDropSide
        if proposed == nil { setEditorDropSide(nil); return }       // disengage in middle
        if current == nil { setEditorDropSide(proposed); return }   // engage from middle
        if current == proposed { return }                            // no-op
        // current != proposed (other outer-third): keep current, ignore flip.
    }

    private func setEditorDropSide(_ side: SplitDropSide?) {
        dragSession.editorDropSide = side
        guard editorDropSide != side else { return }
        // A tick when the split engages or flips side — matches the per-row
        // haptics the drag already emits.
        #if canImport(AppKit)
        if side != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        #endif
        withAnimation(.smooth(duration: 0.18)) { editorDropSide = side }
    }

    /// Release over the editor: split the open note (primary) with the dragged
    /// note (secondary) on the chosen side. The dragged note never became the
    /// open note (drag ≠ open), so the primary is the previously-open note.
    private func createSplitFromDrag(_ dragged: Note, side: SplitDropSide) {
        guard let space = selectedSpace,
              let primaryID = selectedNoteID(for: space) else { return }
        editorDropSide = nil
        // Already picking (pending) → this drop FILLS the placeholder.
        if let pid = pendingSplitPrimaryID {
            guard dragged.id != pid else { return }
            let fillSide: SplitDropSide = pendingSplitSecondaryLeading ? .left : .right
            beginSplitLanding(noteID: dragged.id, side: fillSide)
            completePendingSplit(with: dragged.id)
            return
        }
        // Dragged the open note onto itself → enter pick-mode. NO landing card
        // here: the dragged tile is the open note (already in the editor — it
        // isn't going anywhere), so flying a white card and fading it out just
        // reads as a stray white container. The placeholder pane fades in via
        // the editor's transition instead.
        if primaryID == dragged.id {
            addToSplit(dragged, secondaryLeading: side.secondaryLeading)
            return
        }
        // Real split: fly the dragged card from its release point into the new
        // pane's void. Captured BEFORE wipe() resets the session.
        beginSplitLanding(noteID: dragged.id, side: side)
        // A snappy spring so the secondary note pops in to fill the void.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            storeSplit(EditorSplit(primaryID: primaryID, secondaryID: dragged.id,
                                   axis: side.axis, secondaryLeading: side.secondaryLeading))
        }
        selectedNoteIDsBySpace[space.id] = primaryID
    }

    /// Set up + run the flying-card landing for a drop on `side`. The card
    /// starts at the floating ghost's frame (so the handoff is seamless) and
    /// springs to the pane's half of the editor while fading out.
    private func beginSplitLanding(noteID: UUID, side: SplitDropSide) {
        guard editorFrame.width > 0 else { return }
        let center = CGPoint(
            x: dragSession.sourceRowCenter.x + dragSession.translation.width,
            y: dragSession.sourceRowCenter.y + dragSession.translation.height
        )
        // Matches `MacSidebarFloatingGhost.editorTileGhost` (150×200).
        let from = CGRect(x: center.x - 75, y: center.y - 100, width: 150, height: 200)
        let half = editorFrame.width / 2
        let pane: CGRect = side == .left
            ? CGRect(x: editorFrame.minX, y: editorFrame.minY, width: half, height: editorFrame.height)
            : CGRect(x: editorFrame.minX + half, y: editorFrame.minY, width: half, height: editorFrame.height)
        // Match the secondary pane's visible card (side half, MacNoteWorkspace's
        // 6pt inset) so the card lands exactly where the note will be.
        let to = pane.insetBy(dx: 6, dy: 6)

        splitLanding = SplitLanding(id: noteID, from: from, to: to)
        splitLandingActive = false
        splitLandingRevealed = false
        // Phase 1: the OPAQUE card flies + grows from `from` to the pane frame
        // (the real note pane is held hidden via `secondPaneRevealOpacity`).
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                splitLandingActive = true
            }
        }
        // Phase 2: once it has filled the slot, crossfade card → note in place
        // (card fades out, the note fades in at the exact same frame).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard splitLanding?.id == noteID else { return }
            withAnimation(.easeInOut(duration: 0.10)) { splitLandingRevealed = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            if splitLanding?.id == noteID {
                splitLanding = nil
                splitLandingRevealed = false
            }
        }
    }

    /// The real second pane is held invisible until the flying card has filled
    /// its slot, then they crossfade — so the note doesn't pre-fill behind the
    /// travelling card ("vanish then fill"); the card becomes the note.
    private var secondPaneRevealOpacity: Double {
        guard splitLanding != nil else { return 1 }
        return splitLandingRevealed ? 1 : 0
    }

    @ViewBuilder
    private var splitLandingOverlay: some View {
        if let landing = splitLanding {
            let rect = splitLandingActive ? landing.to : landing.from
            splitLandingCard(landing.id)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .opacity(splitLandingRevealed ? 0 : 1)
                .allowsHitTesting(false)
        }
    }

    /// The flying card — mirrors `editorTileGhost` so the handoff from the
    /// drag ghost is seamless.
    @ViewBuilder
    private func splitLandingCard(_ id: UUID) -> some View {
        VStack(spacing: 14) {
            if let n = note(id) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Text(String(n.title.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "N"))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                Text(n.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary.opacity(0.85))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
    }

    /// Separate one combined tab without changing focus. When the sidebar
    /// supplies its hosted section, both notes become adjacent rows there.
    private func dissolveSplit(
        containing noteID: UUID,
        hostedTier: NoteTier? = nil,
        hostedSpace: Space? = nil
    ) {
        guard let split = split(containing: noteID) else { return }
        if let hostedTier, let hostedSpace {
            placeSeparatedNotes(split, in: hostedTier, space: hostedSpace)
        }
        withAnimation(.smooth(duration: 0.2)) {
            removeSplits(containingAnyOf: [split.primaryID, split.secondaryID])
        }
    }

    private func dissolveFocusedSplit() {
        guard let split = focusedEditorSplit else { return }
        if let hosted = splitHostingLocation(for: split) {
            dissolveSplit(containing: split.primaryID, hostedTier: hosted.tier, hostedSpace: hosted.space)
        } else {
            dissolveSplit(containing: split.primaryID)
        }
    }

    private func splitHostingLocation(for split: EditorSplit) -> (tier: NoteTier, space: Space)? {
        let candidates = [note(split.primaryID), note(split.secondaryID)].compactMap { $0 }
        guard let hostedNote = candidates.first(where: {
            ($0.tier == .pinned || $0.tier == .random)
                && $0.folder == nil && $0.space != nil
        }), let space = hostedNote.space else { return nil }
        return (hostedNote.tier, space)
    }

    private func placeSeparatedNotes(_ split: EditorSplit, in tier: NoteTier, space: Space) {
        guard let primary = note(split.primaryID), let secondary = note(split.secondaryID) else { return }
        let pairIDs = Set([primary.id, secondary.id])
        let hostedNotes = notes
            .filter {
                $0.tier == tier && $0.space?.id == space.id
                    && $0.folder == nil && !pairIDs.contains($0.id)
            }
            .sorted(by: sidebarNoteSort)
        let anchorIndex = min(
            notes
                .filter { $0.tier == tier && $0.space?.id == space.id && $0.folder == nil }
                .sorted(by: sidebarNoteSort)
                .firstIndex(where: { $0.id == primary.id || $0.id == secondary.id })
                ?? hostedNotes.count,
            hostedNotes.count
        )

        primary.tier = tier
        primary.space = space
        primary.folder = nil
        secondary.tier = tier
        secondary.space = space
        secondary.folder = nil

        var reordered = hostedNotes
        reordered.insert(contentsOf: [primary, secondary], at: anchorIndex)
        for (index, note) in reordered.enumerated() {
            note.manualSortIndex = index
        }
        try? modelContext.save()
    }

    private func sidebarNoteSort(_ lhs: Note, _ rhs: Note) -> Bool {
        switch (lhs.manualSortIndex, rhs.manualSortIndex) {
        case let (.some(left), .some(right)):
            return left == right ? lhs.createdAt < rhs.createdAt : left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.createdAt < rhs.createdAt
        }
    }

    /// Notes may belong to at most one pair. Replacing a focused pair removes
    /// only conflicting pairs; unrelated combined tabs remain in the sidebar.
    private func storeSplit(_ split: EditorSplit) {
        removeSplits(containingAnyOf: [split.primaryID, split.secondaryID])
        editorSplits.append(split)
    }

    private func removeSplits(containingAnyOf noteIDs: Set<UUID>) {
        editorSplits.removeAll {
            noteIDs.contains($0.primaryID) || noteIDs.contains($0.secondaryID)
        }
    }

    private func split(containing noteID: UUID) -> EditorSplit? {
        editorSplits.first {
            $0.primaryID == noteID || $0.secondaryID == noteID
        }
    }

    private func pruneMissingEditorSplits() {
        let noteIDs = Set(notes.map(\.id))
        editorSplits.removeAll {
            !noteIDs.contains($0.primaryID) || !noteIDs.contains($0.secondaryID)
        }
    }

    private func color(for space: Space?) -> Color {
        guard let space else { return Color(hex: "#C8D5C0") }
        return Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    /// Active-space tint for the palette + hover-sidebar overlays. Deliberately
    /// NOT driven by the fractional pager offset: reading `pager.pageOffset`
    /// here would re-register the whole root body on every swipe frame —
    /// exactly the per-frame invalidation the pager model exists to avoid.
    /// The continuously-interpolated tint lives in `MacSpaceBackdrop`, which
    /// reads the pager in its own (cheap) body.
    private var displaySpaceColor: Color {
        color(for: selectedSpace)
    }

    /// The visual stack + overlays + base window modifiers. Split out so the
    /// long trailing chain of `.onChange`/`.task`/dialogs in `body` resolves
    /// from a concrete type (the full chain blew the type-checker budget).
    private var shell: some View {
        ZStack { rootContent }
            .overlay { commandPaletteOverlay }
            .overlay { manageSpacesOverlay }
            .overlay(alignment: .topLeading) { hoverSidebarOverlay }
            // fullSizeContentView: content extends under the traffic lights.
            .ignoresSafeArea()
            // Full-window overlay (after ignoresSafeArea so its local origin ==
            // window origin) for the flying split-landing card.
            .overlay { splitLandingOverlay }
            // The note drag's cursor lives in the sidebar's "notes-column"
            // space (origin == window origin), so the editor can hit-test it.
            .coordinateSpace(name: "window")
    }

    var body: some View {
        shell
        // Re-evaluate the editor drop side as the drag moves. The observation
        // lives in a zero-size leaf view: putting `.onChange(of:
        // dragSession.translation)` directly here read `translation` during
        // THIS body's evaluation, re-running the entire window tree (sidebar
        // columns + editor) on every drag frame.
        .background {
            DragFrameWatcher(session: dragSession) { updateEditorDropSide() }
        }
        .confirmationDialog(
            "Delete space?",
            isPresented: Binding(
                get: { spacePendingDeletion != nil },
                set: { if !$0 { spacePendingDeletion = nil } }
            ),
            presenting: spacePendingDeletion
        ) { space in
            Button("Delete \u{201C}\(space.name)\u{201D}", role: .destructive) {
                deleteSpace(space)
                spacePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { spacePendingDeletion = nil }
        } message: { space in
            let count = noteCount(in: space)
            Text(count > 0
                 ? "\u{201C}\(space.name)\u{201D} and its \(count) note\(count == 1 ? "" : "s") will be permanently deleted."
                 : "\u{201C}\(space.name)\u{201D} will be permanently deleted.")
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(MacWindowConfigurator())
        .task {
            // Continuous space-switch swipe: the sidebar column tracks
            // fingers in real time. Pausing mid-swipe holds position;
            // swiping back cancels. Commit on release if past threshold
            // (~32% of sidebar width) or if the final velocity is high
            // enough — otherwise spring back to the current space.
            swipeMonitor.canBegin = {
                !isSpaceSettling
            }
            swipeMonitor.onBegin = {
                beginSpaceSwipe()
            }
            swipeMonitor.onProgress = { totalDx in
                applySwipeProgress(totalDx)
            }
            swipeMonitor.onEnd = { totalDx, velocity in
                finishSwipe(totalDx: totalDx, velocity: velocity)
            }
            swipeMonitor.onCancel = {
                snapBackToActiveSpace()
            }
            swipeMonitor.install()
            hoverManager.sidebarIsCollapsed = (sidebarWidth == 0)
            hoverManager.savedWidth = lastExpandedSidebarWidth
            hoverManager.install()
        }
        .onChange(of: sidebarWidth) { _, new in
            hoverManager.sidebarIsCollapsed = (new == 0)
            hoverManager.savedWidth = lastExpandedSidebarWidth
        }
        // Disable the global swipe-to-switch-space monitor whenever the gradient
        // preview OR the Manage Spaces board is open. The board is a full-window
        // overlay with its own horizontal ScrollView; the monitor must stand
        // down so swiping just scrolls the columns instead of switching (and
        // retinting) the underlying space. Combined into one onChange to keep
        // the body's type-checking cost down.
        .onChange(of: (previewGradient != nil) || showManageSpaces) { _, disabled in
            swipeMonitor.isGloballyDisabled = disabled
        }
        .onChange(of: selectedSpaceID) { _, newID in
            // NB: a FORMED split is NOT cleared here — switching spaces (incl.
            // the edge auto-switch while dragging the split pill across spaces)
            // must keep it. But a PENDING pick-mode is space-scoped (its
            // placeholder pane belongs to the space you left), so cancel it —
            // otherwise it lingers invisibly and blocks all new splits.
            if pendingSplitPrimaryID != nil {
                pendingSplitPrimaryID = nil
                pendingSplitCreatedSecondaryID = nil
            }
            guard let id = newID, let idx = spaces.firstIndex(where: { $0.id == id }) else { return }
            let targetOffset = CGFloat(idx)
            guard abs(pager.pageOffset - targetOffset) > 0.001 else { return }
            animateSpacePageOffset(to: targetOffset, velocityPages: 0)
        }
        .onChange(of: spaces.map(\.id)) { _, _ in
            if let id = selectedSpaceID, let idx = spaces.firstIndex(where: { $0.id == id }) {
                pager.pageOffset = CGFloat(idx)
            }
        }
        .task {
            try? SampleDataSeeder.ensureInitialSpaces(in: modelContext)
            selectDefaultsIfNeeded()
        }
        .onChange(of: spaces.map(\.id)) { _, _ in
            selectDefaultsIfNeeded()
        }
        .onChange(of: notes.map(\.id)) { _, _ in
            pruneMissingEditorSplits()
            finishPendingSplitTransitionIfReady()
            selectDefaultsIfNeeded()
        }
        .animation(.snappy(duration: 0.16), value: isCommandPalettePresented)
    }

    private func selectedNoteID(for space: Space) -> UUID? {
        if let id = selectedNoteIDsBySpace[space.id], notes.contains(where: { $0.id == id }) {
            return id
        }
        return defaultNoteID(for: space)
    }

    private func selectDefaultsIfNeeded() {
        if selectedSpaceID == nil || !spaces.contains(where: { $0.id == selectedSpaceID }) {
            selectedSpaceID = spaces.first?.id
        }

        for space in spaces where selectedNoteIDsBySpace[space.id] == nil {
            selectedNoteIDsBySpace[space.id] = defaultNoteID(for: space)
        }
    }

    // MARK: - Continuous swipe handling

    private func beginSpaceSwipe() {
        swipeSettleGeneration &+= 1
        spaceAnimationGeneration &+= 1
        isSpaceSettling = false
        swipeStartPageOffset = clampedPageOffset(pager.pageOffset)
    }

    /// Per-event update from the swipe monitor. Translates accumulated
    /// horizontal point delta into a fractional `pager.pageOffset` so the
    /// per-space column tracks fingers in real time. A single swipe can
    /// only ever reveal the immediately-adjacent space.
    private func applySwipeProgress(_ totalDx: CGFloat) {
        guard !spaces.isEmpty, effectiveSwipePageWidth > 0 else { return }
        let baseOffset = currentSwipeBaseOffset()
        let baseIdx = nearestSpaceIndex(to: baseOffset)
        // dx > 0 (fingers right) → reveal previous space → offset shrinks.
        let pageDelta = -totalDx / effectiveSwipePageWidth
        // Keep a small visible remainder for the release settle. A fast
        // trackpad flick can deliver a full page of delta before `.ended`;
        // allowing that through would leave the animation with no distance.
        let trackedPageDelta = min(max(pageDelta, -0.82), 0.82)
        let neighborLowerIdx = CGFloat(max(0, baseIdx - 1))
        let neighborUpperIdx = CGFloat(min(spaces.count - 1, baseIdx + 1))
        let raw = baseOffset + trackedPageDelta
        let clamped = min(max(raw, neighborLowerIdx), neighborUpperIdx)
        if abs(pager.pageOffset - clamped) > 0.001 {
            setSpacePageOffset(clamped)
        }
    }

    /// Gesture release. Commits to the adjacent space if past the
    /// 32% drag threshold OR if the final velocity is high (flick).
    /// Otherwise springs back to the current space.
    private func finishSwipe(totalDx: CGFloat, velocity: CGFloat) {
        guard !spaces.isEmpty, effectiveSwipePageWidth > 0 else {
            snapBackToActiveSpace()
            return
        }
        let baseOffset = currentSwipeBaseOffset()
        let baseIdx = nearestSpaceIndex(to: baseOffset)
        let pageDelta = -totalDx / effectiveSwipePageWidth
        let velocityPage = -velocity / effectiveSwipePageWidth
        let commitThreshold: CGFloat = 0.32
        let projected = baseOffset + pageDelta + velocityPage * 4
        let projectedDeltaFromBase = projected - CGFloat(baseIdx)

        let direction: Int
        if projectedDeltaFromBase >= commitThreshold {
            direction = 1
        } else if projectedDeltaFromBase <= -commitThreshold {
            direction = -1
        } else {
            direction = 0
        }

        let targetIdx = max(0, min(spaces.count - 1, baseIdx + direction))
        settleSwipe(to: targetIdx, velocityPages: velocityPage)
    }

    private func settleSwipe(to targetIdx: Int, velocityPages: CGFloat) {
        let targetOffset = CGFloat(targetIdx)
        let targetID = spaces[targetIdx].id
        let generation = swipeSettleGeneration
        swipeStartPageOffset = nil

        animateSpacePageOffset(to: targetOffset, velocityPages: velocityPages) {
            guard swipeSettleGeneration == generation else { return }
            guard selectedSpaceID != targetID else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                selectedSpaceID = targetID
            }
        }
    }

    private func snapBackToActiveSpace(velocityPages: CGFloat = 0) {
        guard let activeID = selectedSpaceID,
              let activeIdx = spaces.firstIndex(where: { $0.id == activeID }) else { return }
        animateSpacePageOffset(to: CGFloat(activeIdx), velocityPages: velocityPages)
    }

    private func animateSpacePageOffset(
        to targetOffset: CGFloat,
        velocityPages: CGFloat,
        completion: (() -> Void)? = nil
    ) {
        let startOffset = clampedPageOffset(pager.pageOffset)
        let distance = abs(targetOffset - startOffset)
        guard distance > 0.001 else {
            setSpacePageOffset(targetOffset)
            completion?()
            return
        }

        spaceAnimationGeneration &+= 1
        let animationGeneration = spaceAnimationGeneration
        let duration = spaceSettleDuration(distancePages: distance, velocityPages: velocityPages)
        isSpaceSettling = true

        withAnimation(spaceSettleAnimation(duration: duration), completionCriteria: .logicallyComplete) {
            pager.pageOffset = targetOffset
        } completion: {
            guard spaceAnimationGeneration == animationGeneration else { return }
            setSpacePageOffset(targetOffset)
            isSpaceSettling = false
            completion?()
        }
        // Watchdog: .logicallyComplete on @Observable can still miss in edge cases.
        // Force-clear after the animation window elapses.
        let gen = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25) { [self] in
            guard spaceAnimationGeneration == gen, isSpaceSettling else { return }
            setSpacePageOffset(targetOffset)
            isSpaceSettling = false
            completion?()
        }
    }

    private var effectiveSwipePageWidth: CGFloat {
        sidebarWidth > 0 ? sidebarWidth : lastExpandedSidebarWidth
    }

    private func spaceSettleDuration(distancePages: CGFloat, velocityPages: CGFloat) -> TimeInterval {
        let base = 0.16 + Double(distancePages) * 0.18
        let velocityBoost = min(0.075, Double(abs(velocityPages)) * 0.018)
        return min(0.34, max(0.16, base - velocityBoost))
    }

    private func spaceSettleAnimation(duration: TimeInterval) -> Animation {
        .smooth(duration: duration)
    }

    private func setSpacePageOffset(_ offset: CGFloat) {
        let next = clampedPageOffset(offset)
        guard abs(pager.pageOffset - next) > 0.0005 else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            pager.pageOffset = next
        }
    }

    private func currentSwipeBaseOffset() -> CGFloat {
        if let swipeStartPageOffset { return swipeStartPageOffset }
        guard let activeID = selectedSpaceID,
              let activeIdx = spaces.firstIndex(where: { $0.id == activeID }) else { return 0 }
        return CGFloat(activeIdx)
    }

    private func clampedPageOffset(_ offset: CGFloat) -> CGFloat {
        guard !spaces.isEmpty else { return 0 }
        return min(max(0, offset), CGFloat(spaces.count - 1))
    }

    private func nearestSpaceIndex(to offset: CGFloat) -> Int {
        guard !spaces.isEmpty else { return 0 }
        return min(max(0, Int(clampedPageOffset(offset).rounded())), spaces.count - 1)
    }

    private func selectNextSpace() {
        guard let current = selectedSpace,
              let idx = spaces.firstIndex(where: { $0.id == current.id }),
              idx + 1 < spaces.count else { return }
        withAnimation(.smooth(duration: 0.22)) {
            selectedSpaceID = spaces[idx + 1].id
        }
    }

    private func selectPreviousSpace() {
        guard let current = selectedSpace,
              let idx = spaces.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        withAnimation(.smooth(duration: 0.22)) {
            selectedSpaceID = spaces[idx - 1].id
        }
    }

    private func selectNote(_ note: Note, in space: Space) {
        // Picking a note while a split is pending fills its second pane.
        if let pid = pendingSplitPrimaryID, note.id != pid {
            completePendingSplit(with: note.id)
            return
        }
        if selectedSpaceID != space.id {
            selectedSpaceID = space.id
        }
        if selectedNoteIDsBySpace[space.id] != note.id {
            selectedNoteIDsBySpace[space.id] = note.id
        }
        // Note: does NOT clear the split. The split is a persistent combined
        // tab; opening another note just shows that note (the editor renders
        // the split only while a split note is the selected one — see
        // `isSplitFocused`). Close the split via the pill's ×.
    }

    /// The selected note chooses which persisted pair renders in the editor.
    /// Other pairs stay combined in the sidebar until explicitly separated.
    private var focusedEditorSplitIndex: Int? {
        guard let space = selectedSpace,
              let selectedID = selectedNoteID(for: space) else { return nil }
        return editorSplits.firstIndex {
            $0.primaryID == selectedID || $0.secondaryID == selectedID
        }
    }

    private var focusedEditorSplit: EditorSplit? {
        focusedEditorSplitIndex.map { editorSplits[$0] }
    }

    private var isShowingSplit: Bool { focusedEditorSplit != nil }

    private func createNote() {
        guard let selectedSpace else { return }
        createNote(in: selectedSpace)
    }

    private func createNote(in space: Space) {
        // While a split is pending, "New Note" (sidebar row, ⌘N, or the pane's
        // button) fills the empty pane instead of opening a standalone note.
        if pendingSplitPrimaryID != nil {
            createSecondaryForPendingSplit()
            return
        }
        do {
            let note = try NoteService(context: modelContext).createBlankNote(in: space)
            selectedSpaceID = space.id
            selectedNoteIDsBySpace[space.id] = note.id
        } catch {
            assertionFailure("Unable to create macOS note: \(error)")
        }
    }

    private func createNote(title: String, in space: Space) {
        do {
            let note = try NoteService(context: modelContext).createNote(title: title, in: space)
            selectedSpaceID = space.id
            selectedNoteIDsBySpace[space.id] = note.id
        } catch {
            assertionFailure("Unable to create macOS note: \(error)")
        }
    }

    private func createSpace() {
        let palette = [
            ("#C8D5C0", "#2A3328"),
            ("#BFD6E8", "#1F3445"),
            ("#E9C8B8", "#4A2C22"),
            ("#D6CAE8", "#322743"),
            ("#F0D88A", "#4A3B17")
        ]
        let colors = palette[spaces.count % palette.count]
        let space = SpaceFactory.makeCustomSpace(
            name: "Space \(spaces.count + 1)",
            emoji: "✦",
            colorHex: colors.0,
            darkColorHex: colors.1,
            sortIndex: spaces.count,
            profile: ProfileExpanderService.fallback(description: "General notes and ideas.")
        )
        modelContext.insert(space)
        do {
            try modelContext.save()
            withAnimation(.smooth(duration: 0.24)) {
                selectedSpaceID = space.id
            }
        } catch {
            assertionFailure("Unable to create macOS space: \(error)")
        }
    }

    /// Notes that belong to a space (its Pinned + Random tiers). Favorites
    /// are global (`space == nil`), so they're excluded from the count.
    private func noteCount(in space: Space) -> Int {
        notes.filter { $0.space?.id == space.id }.count
    }

    /// Permanently delete a space and everything scoped to it. Guards against
    /// removing the final space, reselects a neighbor when the active space
    /// goes away, and re-packs `sortIndex` so ordering stays contiguous.
    private func deleteSpace(_ space: Space) {
        guard spaces.count > 1 else { return }
        let ordered = spaces.sorted { $0.sortIndex < $1.sortIndex }

        if selectedSpaceID == space.id,
           let idx = ordered.firstIndex(where: { $0.id == space.id }) {
            let neighbor = (idx > 0 ? ordered[idx - 1] : nil)
                ?? (idx + 1 < ordered.count ? ordered[idx + 1] : nil)
            selectedSpaceID = neighbor?.id
        }
        selectedNoteIDsBySpace[space.id] = nil

        modelContext.delete(space)

        // Re-pack survivors to 0..n-1 so the swipe page math and any future
        // Cmd-1..9 shortcuts stay aligned with visible order.
        for (i, s) in ordered.filter({ $0.id != space.id }).enumerated() {
            s.sortIndex = i
        }

        do {
            try modelContext.save()
        } catch {
            assertionFailure("Unable to delete macOS space: \(error)")
        }
    }

    private func toggleSidebar() {
        withAnimation(.smooth(duration: 0.2)) {
            if sidebarWidth == 0 {
                sidebarWidth = lastExpandedSidebarWidth
            } else {
                lastExpandedSidebarWidth = sidebarWidth
                sidebarWidth = 0
            }
        }
    }

    private func defaultNoteID(for space: Space) -> UUID? {
        notesFor(space: space, tier: .random).last?.id
            ?? notesFor(space: space, tier: .pinned).first?.id
            ?? favoriteNotes.first?.id
    }

    private var favoriteNotes: [Note] {
        notes
            .filter { $0.tier == .favorite }
            .sorted(by: noteSort)
    }

    private func notesFor(space: Space, tier: NoteTier) -> [Note] {
        notes
            .filter { $0.tier == tier && $0.space?.id == space.id && $0.folder == nil }
            .sorted(by: noteSort)
    }

    private func noteSort(_ lhs: Note, _ rhs: Note) -> Bool {
        switch (lhs.manualSortIndex, rhs.manualSortIndex) {
        case let (.some(left), .some(right)):
            return left == right ? lhs.createdAt < rhs.createdAt : left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.createdAt < rhs.createdAt
        }
    }
}

private extension MacRootView {
    func commandPaletteResults(for query: String) -> [MacCommandPaletteResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty query → a compact default menu (create, the current note's top
        // actions, split, new space).
        if trimmed.isEmpty {
            var defaults: [MacCommandPaletteResult] = [blankNoteCommand]
            if let split = splitCommand { defaults.append(split) }
            defaults.append(contentsOf: currentNoteActions.prefix(2))
            defaults.append(newSpaceCommand)
            return Array(defaults.prefix(6))
        }

        // Non-empty → score every command + matching note + a create option,
        // then rank by relevance. (No more all-or-nothing "command-like" gate.)
        let q = trimmed.lowercased()
        var scored: [(score: Int, order: Int, result: MacCommandPaletteResult)] = []
        var order = 0
        func add(_ s: Int, _ r: MacCommandPaletteResult) { scored.append((s, order, r)); order += 1 }

        for cmd in allCommands {
            if let s = commandScore(q, cmd) { add(s, cmd) }
        }
        for note in matchingNotes(q) {
            add(noteScore(q, note), noteResult(note))
        }
        add(createScore, createResult(trimmed))

        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .map(\.result)
            .prefix(9)
            .reduce(into: []) { $0.append($1) }
    }

    /// Every action available in the current context (scored against the query).
    private var allCommands: [MacCommandPaletteResult] {
        var cmds: [MacCommandPaletteResult] = [blankNoteCommand]
        cmds.append(contentsOf: currentNoteActions)
        if let split = splitCommand { cmds.append(split) }
        cmds.append(contentsOf: [newSpaceCommand, nextSpaceCommand, previousSpaceCommand, toggleSidebarCommand])
        return cmds
    }

    private var blankNoteCommand: MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "create:blank",
            title: "New Note",
            subtitle: selectedSpace.map { "Create in \($0.name)" },
            systemImage: "square.and.pencil",
            kind: .createNote(title: ""),
            shortcut: "⌘N"
        )
    }

    /// Zen-style split commands: "Add to Split View" (an empty second pane) when
    /// a single note is open, or "Separate Notes" when a pair is active.
    private var splitCommand: MacCommandPaletteResult? {
        if isShowingSplit {
            return MacCommandPaletteResult(
                id: "close-split",
                title: "Separate Notes",
                subtitle: "Return to two individual tabs",
                systemImage: "rectangle.split.2x1.slash",
                kind: .closeSplit
            )
        }
        if selectedNote != nil, pendingSplitPrimaryID == nil {
            return MacCommandPaletteResult(
                id: "add-to-split",
                title: "Add to Split View",
                subtitle: "Open a second note beside this one",
                systemImage: "rectangle.split.2x1",
                kind: .addToSplitCurrent
            )
        }
        return nil
    }

    private var newSpaceCommand: MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "new-space", title: "New Space",
            subtitle: "Create a new colored workspace",
            systemImage: "plus.square.on.square", kind: .newSpace, shortcut: "⇧⌘N"
        )
    }
    private var nextSpaceCommand: MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "next-space", title: "Next Space", subtitle: "Move to the next space",
            systemImage: "arrow.right", kind: .nextSpace
        )
    }
    private var previousSpaceCommand: MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "previous-space", title: "Previous Space", subtitle: "Move to the previous space",
            systemImage: "arrow.left", kind: .previousSpace
        )
    }
    private var toggleSidebarCommand: MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "toggle-sidebar",
            title: sidebarWidth == 0 ? "Show Sidebar" : "Hide Sidebar",
            subtitle: "Toggle the sidebar",
            systemImage: "sidebar.left", kind: .toggleSidebar, shortcut: "⌘S"
        )
    }

    // MARK: Palette scoring

    /// Create always appears, but ranks BELOW any genuine keyword match
    /// (exact/prefix/word-prefix/substring) so typing "pin"/"split"/etc. floats
    /// that command to the very top. Only beats subsequence/fuzzy noise (230).
    private var createScore: Int { 300 }

    private func createResult(_ title: String) -> MacCommandPaletteResult {
        MacCommandPaletteResult(
            id: "create:\(title)",
            title: "Create \"\(title)\"",
            subtitle: selectedSpace.map { "New note in \($0.name)" },
            systemImage: "square.and.pencil",
            kind: .createNote(title: title),
            isPrimaryCreate: true
        )
    }

    /// Best fuzzy score of the query over a command's title + aliases.
    private func commandScore(_ q: String, _ cmd: MacCommandPaletteResult) -> Int? {
        var best: Int?
        for text in [cmd.title] + commandAliases(for: cmd.kind) {
            if let s = fuzzyScore(q, text) { best = max(best ?? 0, s) }
        }
        return best
    }

    private func noteScore(_ q: String, _ note: Note) -> Int {
        var best = 0
        if let s = fuzzyScore(q, note.title) { best = max(best, s) }
        if let name = note.space?.name, let s = fuzzyScore(q, name) { best = max(best, s - 120) }
        if note.bodyMarkdown.lowercased().contains(q) { best = max(best, 360) }
        return best
    }

    private func matchingNotes(_ q: String) -> [Note] {
        notes
            .filter { $0.tier != .archived && noteScore(q, $0) > 0 }
            .sorted {
                let a = noteScore(q, $0), b = noteScore(q, $1)
                return a == b ? $0.updatedAt > $1.updatedAt : a > b
            }
            .prefix(6)
            .map { $0 }
    }

    /// Ranked substring/prefix/subsequence match. `query` is pre-lowercased.
    private func fuzzyScore(_ query: String, _ text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let t = text.lowercased()
        if t == query { return 1000 }
        if t.hasPrefix(query) { return 820 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 720 }
        if t.contains(query) { return 520 }
        // subsequence (every query char appears in order)
        var qi = query.startIndex
        for ch in t where qi < query.endIndex && ch == query[qi] {
            qi = query.index(after: qi)
        }
        return qi == query.endIndex ? 230 : nil
    }

    private var currentNoteActions: [MacCommandPaletteResult] {
        guard let selectedNote else { return [] }
        var actions: [MacCommandPaletteResult] = []
        if selectedNote.tier != .pinned {
            actions.append(
                MacCommandPaletteResult(
                    id: "pin-current",
                    title: "Pin Current Note",
                    subtitle: selectedSpace.map { "Pin to \($0.name)" },
                    systemImage: "pin.fill",
                    kind: .pinCurrent
                )
            )
        }
        if selectedNote.tier != .favorite {
            actions.append(
                MacCommandPaletteResult(
                    id: "favorite-current",
                    title: "Make Current Note Essential",
                    subtitle: "Move to Favorites",
                    systemImage: "star.fill",
                    kind: .favoriteCurrent
                )
            )
        }
        if selectedNote.tier != .random {
            actions.append(
                MacCommandPaletteResult(
                    id: "move-current-to-notes",
                    title: "Move Current Note to Notes",
                    subtitle: "Return to regular notes",
                    systemImage: "tray.fill",
                    kind: .moveCurrentToNotes
                )
            )
        }
        actions.append(
            MacCommandPaletteResult(
                id: "duplicate-current",
                title: "Duplicate Current Note",
                subtitle: selectedNote.title,
                systemImage: "plus.square.on.square",
                kind: .duplicateCurrent
            )
        )
        return actions
    }

    private func noteResult(_ note: Note) -> MacCommandPaletteResult {
        let spaceLabel = note.tier == .favorite
            ? "Favorites"
            : note.space.map { "\($0.emoji) \($0.name)" } ?? "No space"
        return MacCommandPaletteResult(
            id: "note:\(note.id.uuidString)",
            title: note.title,
            subtitle: spaceLabel,
            systemImage: iconName(for: note),
            kind: .openNote(note.id)
        )
    }

    private func toggleCommandPalette() {
        if isCommandPalettePresented {
            closeCommandPalette()
        } else {
            openCommandPalette()
        }
    }

    private func openCommandPalette() {
        paletteNav.count = commandPaletteResults(for: "").count
        paletteNav.selectedIndex = 0
        sidebarSearchResetToken &+= 1
        withAnimation(.snappy(duration: 0.16)) {
            isCommandPalettePresented = true
        }
    }

    private func closeCommandPalette() {
        withAnimation(.easeOut(duration: 0.12)) {
            isCommandPalettePresented = false
        }
    }

    private func executeCommandPaletteResult(_ result: MacCommandPaletteResult) {
        closeCommandPalette()
        switch result.kind {
        case let .createNote(title):
            guard let selectedSpace else { return }
            createNote(title: title, in: selectedSpace)
        case let .openNote(noteID):
            guard let note = notes.first(where: { $0.id == noteID }) else { return }
            let targetSpace = note.space ?? selectedSpace
            guard let targetSpace else { return }
            selectNote(note, in: targetSpace)
        case let .openNoteInSplit(noteID):
            guard let note = notes.first(where: { $0.id == noteID }) else { return }
            openInSplit(note)
        case .pinCurrent:
            promoteSelectedNote(to: .pinned)
        case .favoriteCurrent:
            promoteSelectedNote(to: .favorite)
        case .moveCurrentToNotes:
            promoteSelectedNote(to: .random)
        case .duplicateCurrent:
            duplicateSelectedNote()
        case .addToSplitCurrent:
            guard let selectedNote else { return }
            addToSplit(selectedNote)
        case .closeSplit:
            dissolveFocusedSplit()
        case .newSpace:
            createSpace()
        case .nextSpace:
            selectNextSpace()
        case .previousSpace:
            selectPreviousSpace()
        case .toggleSidebar:
            toggleSidebar()
        }
    }

    private func promoteSelectedNote(to tier: NoteTier) {
        guard let selectedNote else { return }
        try? NoteService(context: modelContext).promote(selectedNote, to: tier, currentSpace: selectedSpace)
    }

    private func duplicateSelectedNote() {
        guard let selectedNote,
              let copy = try? NoteService(context: modelContext).duplicate(selectedNote) else { return }
        let targetSpace = copy.space ?? selectedSpace
        if let targetSpace {
            selectNote(copy, in: targetSpace)
        }
    }

    private func commandAliases(for kind: MacCommandPaletteResult.Kind) -> [String] {
        switch kind {
        case .createNote:
            return ["new note", "create note", "note", "add note"]
        case .openNote:
            return ["open", "switch"]
        case .openNoteInSplit:
            return ["split", "open in split"]
        case .addToSplitCurrent:
            return ["split", "split view", "split screen", "side by side", "add to split"]
        case .closeSplit:
            return ["separate", "separate notes", "unsplit", "close split", "split", "merge", "single"]
        case .pinCurrent:
            return ["pin", "pinned"]
        case .favoriteCurrent:
            return ["favorite", "favourite", "essential", "star"]
        case .moveCurrentToNotes:
            return ["random", "notes", "unpin", "move"]
        case .duplicateCurrent:
            return ["duplicate", "copy"]
        case .newSpace:
            return ["new space", "space", "workspace"]
        case .nextSpace:
            return ["next", "next space"]
        case .previousSpace:
            return ["previous", "prev", "previous space"]
        case .toggleSidebar:
            return ["sidebar", "hide sidebar", "show sidebar"]
        }
    }

    private func iconName(for note: Note) -> String {
        switch note.tier {
        case .favorite:
            return "star.fill"
        case .pinned:
            return "pin.fill"
        case .random:
            return "doc.text"
        case .archived:
            return "archivebox.fill"
        }
    }
}

private struct MacSidebarResizer: View {
    @Binding var width: CGFloat
    @Binding var lastExpandedWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    @State private var isResizing = false
    @State private var isHovering = false
    @State private var startingWidth: CGFloat = 0
    @State private var startingMouseX: CGFloat = 0
    @State private var hoverTask: Task<Void, Never>?

    // Lifted directly from Nook's SidebarResizeView. Minimum/maximum match
    // our existing constraints. ⌘S is the only way to fully collapse the
    // sidebar; the drag never auto-dismisses.
    private let minimumWidth: CGFloat = 200
    private let maximumWidth: CGFloat = 440

    var body: some View {
        ZStack {
            // Hover/active indicator: 4pt pill at the seam.
            if isHovering || isResizing {
                RoundedRectangle(cornerRadius: 100)
                    .fill(colorScheme == .dark ? .white.opacity(0.45) : .black.opacity(0.45))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .offset(x: -3)
                    .padding(.vertical, 30)
                    .animation(.easeOut(duration: 0.10), value: isResizing)
                    .animation(.easeOut(duration: 0.10), value: isHovering)
            }

            // Hit area — 12pt wide, offset to straddle the seam.
            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
                .padding(.vertical, 30)
                .offset(x: -5)
                .contentShape(.rect)
                .onHover { hovering in
                    guard width > 0 else { return }
                    hoverTask?.cancel()
                    if hovering && !isResizing {
                        hoverTask = Task {
                            try? await Task.sleep(for: .seconds(0.1))
                            guard !Task.isCancelled else { return }
                            await MainActor.run {
                                if !isHovering { isHovering = true }
                                NSCursor.resizeLeftRight.set()
                            }
                        }
                    } else {
                        if isHovering { isHovering = false }
                        if !isResizing { NSCursor.arrow.set() }
                    }
                }
                .gesture(
                    // Critical: .global coordinate space. Local coordinates
                    // shift as the sidebar resizes, which causes feedback
                    // jitter. Absolute mouse X in screen space is stable.
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            guard width > 0 else { return }
                            if !isResizing {
                                startingWidth = width
                                startingMouseX = value.startLocation.x
                                isResizing = true
                                NSCursor.resizeLeftRight.set()
                            }
                            let delta = value.location.x - startingMouseX
                            let proposed = startingWidth + delta
                            width = min(max(proposed, minimumWidth), maximumWidth)
                        }
                        .onEnded { _ in
                            isResizing = false
                            lastExpandedWidth = width
                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }
                )
        }
        .frame(width: width == 0 ? 0 : 3)
        .allowsHitTesting(width > 0)
    }
}

/// Inert pane shown in the editor area while space creation is open.
/// Matches `MacNoteWorkspace`'s outer styling (rounded card on the
/// active-space tint) but holds no content and consumes hit-tests so
/// the user can't accidentally interact with a stale note.
private struct CreationModeEmptyPane: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)
                .opacity(colorScheme == .dark ? 0.55 : 0.82))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.10), radius: 14, x: 0, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Consume taps + scrolls so the user can't fiddle with
            // anything in this pane while the sidebar form is up.
            .contentShape(Rectangle())
            .onTapGesture { /* swallow */ }
            .allowsHitTesting(true)
    }
}

/// Full-window backdrop behind the sidebar + editor. Composes three
/// layers: the flat space-tint crossfade (for preset/legacy spaces), the
/// saved-gradient crossfade (for gradient-config spaces), and the live
/// preview gradient during space creation. Extracted from MacRootView's
/// body so the type-checker isn't asked to chew the whole scene at once.
/// Fractional space-pager offset (1.4 = 40% of the way from space[1] to
/// space[2]). An @Observable model rather than root @State so that per-frame
/// swipe updates invalidate only the leaf views that read it in their own
/// body (the backdrop + the sidebar's column-offset modifier) — never the
/// whole window tree.
@Observable
@MainActor
final class SpacePagerModel {
    var pageOffset: CGFloat = 0
}

/// Zero-size leaf that re-evaluates on every drag frame and forwards the
/// tick. Isolates per-frame `session.translation` observation from whatever
/// view owns the handler (their bodies stay un-invalidated).
struct DragFrameWatcher: View {
    let session: CrossTierDragSession
    let onFrame: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: session.translation) { _, _ in onFrame() }
    }
}

private struct MacSpaceBackdrop: View {
    let spaces: [Space]
    let pager: SpacePagerModel
    let previewGradient: ZenGradientConfig?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            MacSpaceBackground(tint: displaySpaceColor)
            gradientLayer
            if let preview = previewGradient {
                ZenGradientBackground(config: preview)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    private func color(for space: Space?) -> Color {
        guard let space else { return Color(hex: "#C8D5C0") }
        return Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private var displaySpaceColor: Color {
        guard !spaces.isEmpty else { return color(for: nil) }
        let clamped = max(0, min(CGFloat(spaces.count - 1), pager.pageOffset))
        let floorIdx = Int(clamped.rounded(.down))
        let ceilIdx = min(floorIdx + 1, spaces.count - 1)
        let t = clamped - CGFloat(floorIdx)
        return color(for: spaces[floorIdx]).mixed(with: color(for: spaces[ceilIdx]), by: t)
    }

    @ViewBuilder
    private var gradientLayer: some View {
        if !spaces.isEmpty {
            let clamped = max(0, min(CGFloat(spaces.count - 1), pager.pageOffset))
            let floorIdx = Int(clamped.rounded(.down))
            let ceilIdx = min(floorIdx + 1, spaces.count - 1)
            let t = Double(clamped - CGFloat(floorIdx))
            ZStack {
                if let g = spaces[floorIdx].gradientConfig {
                    ZenGradientBackground(config: g).opacity(1 - t)
                }
                if floorIdx != ceilIdx, let g = spaces[ceilIdx].gradientConfig {
                    ZenGradientBackground(config: g).opacity(t)
                }
            }
        }
    }
}

private struct MacSpaceBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color

    var body: some View {
        // Full-window space tint. Sidebar sits transparent over this; editor
        // pane's rounded corners reveal it on all four sides for the "inserted"
        // effect. Tint is driven by `displaySpaceColor` so it interpolates
        // continuously during a swipe.
        tint
            .opacity(colorScheme == .dark ? 0.62 : 0.78)
            .overlay {
                LinearGradient(
                    colors: [
                        tint.opacity(colorScheme == .dark ? 0.18 : 0.10),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
    }
}

// MARK: - Hover sidebar overlay manager

/// Direct port of Nook's `HoverSidebarManager`. Tracks the mouse via local +
/// global event monitors and flips `isVisible` when the cursor enters the
/// left-edge trigger zone (only when the real sidebar is collapsed). Once
/// open, a wider "keep-open" zone keeps it visible until the cursor leaves.
@MainActor
final class MacHoverSidebarManager: ObservableObject {
    @Published var isVisible: Bool = false

    // External state, written by MacRootView.
    var sidebarIsCollapsed: Bool = false
    var savedWidth: CGFloat = 300

    let triggerWidth: CGFloat = 6
    let overshootSlack: CGFloat = 12
    let keepOpenHysteresis: CGFloat = 52
    let verticalSlack: CGFloat = 24

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var handleScheduled = false

    func install() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] event in
            self?.schedule()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            self?.schedule()
        }
    }

    deinit {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }

    nonisolated private func schedule() {
        Task { @MainActor [weak self] in self?.scheduleHandle() }
    }

    private func scheduleHandle() {
        guard !handleScheduled else { return }
        handleScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            handleScheduled = false
            handle()
        }
    }

    private func handle() {
        guard sidebarIsCollapsed else {
            if isVisible { withAnimation(.easeInOut(duration: 0.15)) { isVisible = false } }
            return
        }
        guard let window = NSApp.keyWindow else {
            if isVisible { withAnimation(.easeInOut(duration: 0.15)) { isVisible = false } }
            return
        }

        let mouse = NSEvent.mouseLocation // screen coords
        let frame = window.frame

        let verticalOK = mouse.y >= frame.minY - verticalSlack && mouse.y <= frame.maxY + verticalSlack
        guard verticalOK else {
            if isVisible { withAnimation(.easeInOut(duration: 0.15)) { isVisible = false } }
            return
        }

        let overlayWidth = savedWidth
        // Edge zone (with overshoot to handle cursor slightly off-window).
        let inTriggerZone = mouse.x >= frame.minX - overshootSlack
            && mouse.x <= frame.minX + triggerWidth
        // Keep-open zone: stay visible while cursor remains anywhere over or
        // just past the floating overlay.
        let inKeepOpenZone = mouse.x >= frame.minX
            && mouse.x <= frame.minX + overlayWidth + keepOpenHysteresis

        let shouldShow = inTriggerZone || (isVisible && inKeepOpenZone)
        if shouldShow != isVisible {
            withAnimation(.easeInOut(duration: 0.15)) { isVisible = shouldShow }
        }
    }
}

// MARK: - Swipe direction monitor

/// Continuous trackpad swipe tracker for space switching. Reports
/// signed `accumulated` deltas in real time as the user drags two
/// fingers horizontally; on gesture-end, the caller decides whether
/// to commit to the adjacent space or snap back. Direction convention:
/// negative dx (fingers moving right) reveals the previous space;
/// positive dx (fingers moving left) reveals the next space — matches
/// macOS natural-scroll page conventions.
@MainActor
final class SpaceSwipeDirectionMonitor: ObservableObject {
    /// Lets the owner reject a new horizontal gesture while a previous
    /// space settle is still in flight.
    var canBegin: () -> Bool = { true }
    /// Called when a new scroll gesture locks horizontally.
    var onBegin: () -> Void = { }
    /// Called with coalesced visual progress while a horizontal gesture is active.
    /// `accumulated` is the signed total horizontal delta in points.
    var onProgress: (CGFloat) -> Void = { _ in }
    /// Called when the user lifts their fingers. Receives the final
    /// accumulated delta in points and a smoothed per-event velocity
    /// (points per event), for boosting commits on flicks.
    var onEnd: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// Called if a gesture starts but is recognized as vertical-only.
    /// Caller may use this to reset any pending visual state.
    var onCancel: () -> Void = { }

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var lastVelocityDx: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var deliveredProgress: CGFloat = 0
    private var progressDeliveryTask: Task<Void, Never>?
    private var isActive = false
    private var verticallyLocked = false
    private var blockedUntilEnd = false
    private var suppressMomentumUntil = Date.distantPast

    /// When true, the monitor short-circuits entirely (used while the
    /// space-creation form is open — switching out of the in-creation
    /// state would be confusing).
    var isGloballyDisabled: Bool = false

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Trackpad only — ignore traditional mouse wheels.
        guard event.hasPreciseScrollingDeltas else { return event }

        if isGloballyDisabled { return event }

        // Momentum (inertia) events fire AFTER the user releases. The
        // space-switch intent is captured at `.ended`; after handling a
        // horizontal swipe, briefly consume momentum so a fast flick cannot
        // leak inertial horizontal scroll into nested sidebar scroll views.
        if event.momentumPhase != [] {
            return Date() < suppressMomentumUntil ? nil : event
        }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // New gesture: reset all tracking state.
        if event.phase == .began {
            accumulated = 0
            lastVelocityDx = 0
            resetProgressDelivery()
            isActive = false
            verticallyLocked = false
            blockedUntilEnd = false
        }

        // Gesture end / cancel — commit progress, then reset.
        if event.phase == .ended || event.phase == .cancelled {
            let wasBlocked = blockedUntilEnd
            let wasActive = isActive
            if wasActive {
                flushProgress()
                suppressMomentumUntil = Date().addingTimeInterval(0.35)
                onEnd(accumulated, lastVelocityDx)
            }
            accumulated = 0
            lastVelocityDx = 0
            resetProgressDelivery()
            isActive = false
            verticallyLocked = false
            blockedUntilEnd = false
            // Consume the .ended event ourselves when we handled the
            // gesture, otherwise pass it through so vertical lists
            // close out their own scroll cleanly.
            return (wasActive || wasBlocked) ? nil : event
        }

        if blockedUntilEnd { return nil }

        // Direction lock — the first frame with significant motion
        // decides whether this is a horizontal page-swipe (we handle it)
        // or a vertical scroll (we pass it through to the list).
        if !isActive && !verticallyLocked {
            if abs(dy) > abs(dx) * 1.2 && abs(dy) > 1 {
                verticallyLocked = true
                return event
            }
            if abs(dx) > 1 {
                guard canBegin() else {
                    blockedUntilEnd = true
                    suppressMomentumUntil = Date().addingTimeInterval(0.35)
                    return nil
                }
                onBegin()
                isActive = true
            } else {
                // Tiny motion — wait for the gesture to declare itself.
                return event
            }
        }

        if verticallyLocked { return event }

        if isActive {
            accumulated += dx
            updateVelocity(with: dx)
            scheduleProgress(accumulated)
            return nil
        }
        return event
    }

    private func updateVelocity(with dx: CGFloat) {
        if lastVelocityDx == 0 {
            lastVelocityDx = dx
        } else {
            lastVelocityDx = lastVelocityDx * 0.72 + dx * 0.28
        }
    }

    private func scheduleProgress(_ value: CGFloat) {
        targetProgress = value
        guard progressDeliveryTask == nil else { return }

        progressDeliveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                guard !Task.isCancelled else { break }
                guard let self, self.isActive else { break }

                let delta = self.targetProgress - self.deliveredProgress
                let next: CGFloat
                if abs(delta) < 0.15 {
                    next = self.targetProgress
                } else {
                    next = self.deliveredProgress + delta * 0.78
                }

                if abs(next - self.deliveredProgress) > 0.01 {
                    self.deliveredProgress = next
                    self.onProgress(next)
                }

                if abs(self.targetProgress - self.deliveredProgress) < 0.15 {
                    self.deliveredProgress = self.targetProgress
                    self.onProgress(self.targetProgress)
                    break
                }
            }
            self?.progressDeliveryTask = nil
        }
    }

    private func flushProgress() {
        progressDeliveryTask?.cancel()
        progressDeliveryTask = nil
        targetProgress = accumulated
        deliveredProgress = accumulated
        onProgress(accumulated)
    }

    private func resetProgressDelivery() {
        progressDeliveryTask?.cancel()
        progressDeliveryTask = nil
        targetProgress = 0
        deliveredProgress = 0
    }
}

#endif
