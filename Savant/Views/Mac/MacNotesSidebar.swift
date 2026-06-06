import SwiftData
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)

/// Per-space multi-selection set for batch operations (⌘-click to toggle,
/// ⇧-click to range-select). Distinct from the single "open" note that fills
/// the editor (`selectedNoteIDsBySpace`): this drives the batch context menu
/// and shared row highlight. When empty, the open note carries the highlight.
@Observable
@MainActor
final class NoteSelectionModel {
    private(set) var selected: Set<UUID> = []
    /// Anchor for ⇧-range selection — the last row the user ⌘/plain-clicked.
    @ObservationIgnored private var anchorID: UUID?
    /// The active space's currently-open note (shown in the editor). Kept in
    /// sync by the sidebar. The open note is treated as implicitly selected, so
    /// the first ⌘/⇧-click seeds it into the set rather than replacing it.
    @ObservationIgnored var openNoteID: UUID?

    var count: Int { selected.count }
    var isActive: Bool { !selected.isEmpty }
    func contains(_ id: UUID) -> Bool { selected.contains(id) }

    func clear() {
        guard !selected.isEmpty else { return }
        selected = []
        anchorID = nil
    }

    /// Before the first modified click grows a selection, fold in the open note
    /// so it stays selected alongside the newly-clicked one.
    private func seedFromOpenNoteIfEmpty() {
        guard selected.isEmpty, let open = openNoteID else { return }
        selected.insert(open)
        if anchorID == nil { anchorID = open }
    }

    /// ⌘-click: toggle one row's membership, leaving the rest of the set intact.
    func toggle(_ id: UUID) {
        seedFromOpenNoteIfEmpty()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        anchorID = id
    }

    /// ⇧-click: select the contiguous run between the anchor and `id` within
    /// `ordered` (the tier's displayed order). Falls back to a single select if
    /// the anchor isn't resolvable (e.g. anchor lives in another tier).
    func selectRange(to id: UUID, in ordered: [UUID]) {
        seedFromOpenNoteIfEmpty()
        guard let anchor = anchorID ?? selected.first,
              let a = ordered.firstIndex(of: anchor),
              let b = ordered.firstIndex(of: id) else {
            selected = [id]
            anchorID = id
            return
        }
        selected = Set(ordered[min(a, b)...max(a, b)])
        // Keep the original anchor so successive ⇧-clicks pivot from it.
        anchorID = anchor
    }

    /// Note the anchor on a plain open so a subsequent ⇧-click ranges from here.
    func setAnchor(_ id: UUID) { anchorID = id }
}

/// Batch operations available from the multi-select context menu.
enum NoteBatchAction {
    case pin, makeEssential, moveToNotes, duplicate, archive, delete, openSplit, group
}

/// Which edge of the editor a note is being dragged toward → the split layout.
enum SplitDropSide {
    case left, right, top, bottom
    var axis: Axis { (self == .left || self == .right) ? .horizontal : .vertical }
    /// True when the dragged (secondary) note lands before the primary.
    var secondaryLeading: Bool { self == .left || self == .top }
}

/// One value that captures everything affecting the vertical layout of
/// the Essentials area at the top of the sidebar. Used as the `value:`
/// for the spring that drives banner expansion, banner collapse, and
/// grid appear/disappear transitions so they share one continuous curve.
private struct EssentialsLayoutKey: Hashable {
    let showsBanner: Bool
    let hasEssentials: Bool
    let count: Int
}

struct MacNotesSidebar: View {
    let spaces: [Space]
    let notes: [Note]
    let folders: [Folder]
    @Binding var selectedSpaceID: UUID?
    @Binding var selectedNoteIDsBySpace: [UUID: UUID]
    let spacePageOffset: CGFloat // fractional page index, animated by the parent
    /// While creation mode is up, the form's gradient drives the
    /// window+sidebar background. MacRootView owns the storage so the
    /// entire window updates in real time.
    @Binding var previewGradient: ZenGradientConfig?
    let searchResetToken: Int
    let width: CGFloat
    let selectNote: (Note, Space) -> Void
    let createNote: () -> Void
    /// Open the ⌘T command palette (the sidebar's New Note row routes here:
    /// type a title + Enter to create, or run any command).
    let openCommandPalette: () -> Void
    /// True while the ⌘T palette is open — the New Note row then shows the
    /// selected-bar treatment (Arc highlights the "New Tab" button while its
    /// command bar is up).
    let isCommandPaletteActive: Bool
    let createSpace: () -> Void
    let toggleSidebar: () -> Void
    /// Ask the root to delete a space (routes through its confirm dialog).
    let requestDeleteSpace: (Space) -> Void
    /// Open the full-window Manage Spaces board.
    let openManageSpaces: () -> Void
    /// Open a note beside the current one (editor split).
    let openInSplit: (Note) -> Void
    /// Add an empty note beside the open one (the open tab's "Add to Split").
    let addToSplit: (Note) -> Void
    /// Release a dragged note over the editor → split the open note with it.
    let onSplitDrop: (Note, SplitDropSide) -> Void
    /// Persisted transient split pairs. The selected pair renders in the
    /// editor; every pair remains combined in the sidebar until separated.
    let activeSplits: [EditorSplit]
    /// The open note awaiting its split partner (pick-mode) — its sidebar pill
    /// renders a combined tab with an empty second slot.
    var pendingSplitPrimaryID: UUID?
    /// Dissolve the split, keeping BOTH notes as individual tabs.
    let dissolveSplit: (UUID, NoteTier, Space) -> Void
    /// Cancel a pending add-to-split.
    var cancelPendingSplit: () -> Void = { }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @State private var searchText: String = ""
    // Hoisted to MacRootView so the editor pane can observe the in-progress
    // drag (for the drag-onto-editor split).
    let session: CrossTierDragSession
    /// Multi-select set for batch actions (⌘/⇧-click). See NoteSelectionModel.
    @State private var selection = NoteSelectionModel()
    /// Notes queued for a batch delete; drives the destructive confirm dialog.
    @State private var pendingBatchDelete: [Note] = []
    /// Edge auto-switch: while dragging a note near the sidebar's left/right
    /// edge, switch to the adjacent space after a short hold so the note can be
    /// dropped there.
    @State private var edgeSwitchTimer: Timer?
    @State private var edgeSwitchTargetID: UUID?   // chip-drop target (one-shot)
    @State private var edgeSwitchDir: Int = 0      // edge direction (repeating)
    /// The folder currently showing its inline-rename text field (nil = none).
    /// Set when a folder is created or "Rename" is chosen; threaded down to
    /// `MacFolderRow`.
    @State private var renamingFolderID: UUID?
    // The docked sidebar is followed by the 3pt resizer and the workspace
    // card's 6pt inset. Let pages travel through that gutter while swiping so
    // they disappear exactly under the visible note-page edge.
    private let pageClipTrailingBleed: CGFloat = 9
    // Zen-style "Create Space" mode. While active, the upper sidebar
    // content fades to 0 and the inline form takes over; the bottom rail
    // stays put with its `+` morphed to an `X`. Mirrors
    // ZenSpaceCreation.mjs's lifecycle: animate-out siblings, mount form,
    // animate-in form (staggered), then reverse on cancel/create.
    @State private var isCreatingSpace: Bool = false
    @State private var cancelCreationTick: Int = 0

    private var selectedSpace: Space? {
        if let selectedSpaceID, let match = spaces.first(where: { $0.id == selectedSpaceID }) {
            return match
        }
        return spaces.first
    }

    /// Create a top-level folder in the active space and drop straight into
    /// inline rename. New user folders default to the Pinned tier (SPEC §20.7
    /// — Random folders are tidy-only).
    private func createFolder() {
        guard let space = selectedSpace else { return }
        if let folder = try? FolderService(context: modelContext).create(in: space, tier: .pinned, parent: nil) {
            renamingFolderID = folder.id
        }
    }

    private var spaceColor: Color {
        guard let s = selectedSpace else { return .accentColor }
        return Color.spaceColor(lightHex: s.colorHex, darkHex: s.darkColorHex, scheme: colorScheme)
    }

    /// The active space's currently-open (editor) note. Fed into the selection
    /// model so a multi-select started from a single open note keeps it.
    private var activeOpenNoteID: UUID? {
        selectedSpace.flatMap { selectedNoteIDsBySpace[$0.id] }
    }

    /// Note id to render as *selected* in the list. While the ⌘T palette is
    /// open the New Note row becomes the active selection, so the normal
    /// open-note highlight is suppressed (Arc deselects the current tab while
    /// its command bar is up). Per-space so each column resolves its own.
    private func displayedSelectedNoteID(for space: Space?) -> UUID? {
        guard !isCommandPaletteActive else { return nil }
        return space.flatMap { selectedNoteIDsBySpace[$0.id] }
    }

    /// Plain click on a row: open it in the editor and drop any multi-select.
    private func openNote(_ note: Note, in space: Space) {
        selection.clear()
        selection.setAnchor(note.id)
        selectNote(note, space)
    }

    /// Run a batch action over the current multi-selection. Destructive
    /// deletes route through a confirm dialog; everything else applies and
    /// then clears the set. Order is preserved by applying in displayed order.
    private func performBatch(_ action: NoteBatchAction) {
        let targets = notes.filter { selection.contains($0.id) }
            .sorted(by: noteSort)
        guard !targets.isEmpty, let space = selectedSpace else { return }

        if action == .delete {
            pendingBatchDelete = targets
            return
        }

        if action == .openSplit {
            // Split the two selected notes: focus the first, add the second.
            guard targets.count == 2 else { return }
            selectNote(targets[0], space)
            openInSplit(targets[1])
            selection.clear()
            return
        }

        if action == .group {
            createFolder(from: targets, in: space)
            return
        }

        let service = NoteService(context: modelContext)
        for note in targets {
            switch action {
            case .pin: try? service.promote(note, to: .pinned, currentSpace: space)
            case .makeEssential: try? service.promote(note, to: .favorite, currentSpace: space)
            case .moveToNotes: try? service.promote(note, to: .random, currentSpace: space)
            case .archive: try? service.archive(note)
            case .duplicate: _ = try? service.duplicate(note)
            case .delete, .openSplit, .group: break
            }
        }
        selection.clear()
    }

    /// Create a new folder from a multi-selection: the selected notes reflow
    /// into a fresh folder (placed roughly where the selection was), which opens
    /// in inline-rename. Notes from other tiers are pulled into the folder's tier.
    private func createFolder(from targets: [Note], in space: Space) {
        guard !targets.isEmpty else { return }
        func rank(_ t: NoteTier) -> Int {
            switch t { case .pinned: return 0; case .random: return 1; case .favorite: return 2; case .archived: return 3 }
        }
        let ordered = targets.sorted { a, b in
            let ra = rank(a.tier), rb = rank(b.tier)
            return ra == rb ? noteSort(a, b) : ra < rb
        }
        let anchor = ordered[0]
        // If the selection lives INSIDE a folder, create the new folder at the
        // same indentation (nested under that parent) — unless that would exceed
        // the max nesting depth, in which case fall back one level up.
        let parentFolder = anchor.folder
        let nestParent: Folder? = {
            guard let pf = parentFolder else { return nil }
            return (pf.depth + 1 <= Folder.maxDepth) ? pf : pf.parent
        }()
        let folderTier: NoteTier = nestParent?.tier
            ?? ((anchor.tier == .pinned || anchor.tier == .random) ? anchor.tier : .pinned)
        let svc = FolderService(context: modelContext)

        let newFolder: Folder? = withAnimation(.smooth(duration: 0.24)) {
            guard let folder = try? svc.create(in: space, tier: folderTier, parent: nestParent) else { return nil }
            // Take the anchor's slot within its container so the folder forms in place.
            if anchor.folder?.id == nestParent?.id, let idx = anchor.manualSortIndex {
                folder.sortIndex = idx
            }
            for (i, note) in ordered.enumerated() {
                try? svc.moveNote(note, into: folder)
                note.manualSortIndex = i
            }
            try? svc.normalizeTierOrder(tier: folderTier, in: space)
            return folder
        }
        guard let folder = newFolder else { return }
        selection.clear()
        renamingFolderID = folder.id
    }

    private func commitBatchDelete() {
        let service = NoteService(context: modelContext)
        for note in pendingBatchDelete { try? service.delete(note) }
        pendingBatchDelete = []
        selection.clear()
    }

    /// Show the promo banner only when (a) a non-favorite is being dragged,
    /// (b) there are no Essentials yet, AND (c) the cursor has crossed
    /// above the active column's space-name label.
    private var shouldShowAddToEssentialsBanner: Bool {
        session.showsAddToEssentialsBanner
    }

    /// Cross-space — favorites are global. Lives at sidebar level so its
    /// view doesn't slide with per-space swipes (Zen does the same with
    /// `#zen-essentials`).
    private var favoriteNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return notes
            .filter { $0.tier == .favorite }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.bodyMarkdown.lowercased().contains(q) }
            .sorted {
                switch ($0.manualSortIndex, $1.manualSortIndex) {
                case let (.some(l), .some(r)): return l == r ? $0.createdAt < $1.createdAt : l < r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return $0.createdAt < $1.createdAt
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                normalSidebarContent
                    .opacity(isCreatingSpace ? 0 : 1)
                    .allowsHitTesting(!isCreatingSpace)
                    .animation(.easeInOut(duration: 0.18), value: isCreatingSpace)

                if isCreatingSpace {
                    let activeSpaceID = selectedSpace?.id
                    MacCreateSpaceForm(
                        suggestedSortIndex: spaces.count,
                        cancelToken: cancelCreationTick,
                        previewGradient: $previewGradient,
                        onCreate: { space in
                            isCreatingSpace = false
                            previewGradient = nil
                            withAnimation(.smooth(duration: 0.22)) {
                                selectedSpaceID = space.id
                            }
                        },
                        onCancel: {
                            isCreatingSpace = false
                            previewGradient = nil
                            if selectedSpaceID == nil { selectedSpaceID = activeSpaceID }
                        }
                    )
                    .id("create-space-form")
                }
            }
            .frame(maxHeight: .infinity)

            MacSpaceStrip(
                spaces: spaces,
                selectedSpaceID: selectedSpace?.id,
                isCreatingSpace: isCreatingSpace,
                canDeleteSpaces: spaces.count > 1,
                selectSpace: selectSpace,
                requestDeleteSpace: requestDeleteSpace,
                onCreateSpace: { isCreatingSpace = true },
                onCreateFolder: { createFolder() },
                onCreateNote: createNote,
                onCancelCreation: { cancelCreationTick &+= 1 },
                session: session
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        // Smooth (critically damped) curve for the Essentials-section
        // grow/shrink. Avoids the slight overshoot a regular spring has,
        // which can read as a faint "ghost" / "shadow" of the tile around
        // its disappearing slot.
        .animation(.smooth(duration: 0.22),
                   value: EssentialsLayoutKey(
                       showsBanner: shouldShowAddToEssentialsBanner,
                       hasEssentials: !favoriteNotes.isEmpty,
                       count: favoriteNotes.count
                   ))
        .frame(width: width)
        // Intentionally NO tinted background here. MacSpaceBackground +
        // spaceGradientLayer in MacRootView paint the space color across
        // the full window edge-to-edge; the docked sidebar must be a
        // transparent region over that one layer so it reads as part of
        // the same colored frame as the strip around the workspace pane.
        // Painting another tint+material on top of it produced two
        // slightly different shades of the same color and a visible
        // seam between the sidebar and the surrounding frame.
        // Floating ghost lives at sidebar level so its `.position(...)` uses
        // the same "notes-column" coords that `tierFrames` / `cursorY` /
        // `sourceRowCenter` are written in. Anchoring it to the sidebar
        // also means it doesn't get clipped by the HStack's `.clipped()`.
        .overlay(alignment: .topLeading) {
            if let id = session.draggedNoteID,
               let note = notes.first(where: { $0.id == id }) {
                MacSidebarFloatingGhost(
                    note: note,
                    activeSpace: selectedSpace,
                    session: session,
                    width: width,
                    sourceAlreadyInFavorites: favoriteNotes.contains { $0.id == id },
                    isSelected: displayedSelectedNoteID(for: selectedSpace) == id,
                    draggedNotes: session.draggedNoteIDs.compactMap { did in notes.first { $0.id == did } },
                    splitPair: {
                        // Dragging EITHER split member (pill row, plain row, or
                        // essential tile) → the ghost is the combined pill.
                        guard let split = activeSplits.first(where: {
                            id == $0.primaryID || id == $0.secondaryID
                        }),
                              let pn = notes.first(where: { $0.id == split.primaryID }),
                              let sn = notes.first(where: { $0.id == split.secondaryID }) else { return nil }
                        return (pn, sn)
                    }(),
                    pendingPrimary: (id == pendingSplitPrimaryID)
                        ? notes.first(where: { $0.id == id }) : nil
                )
            } else if let fid = session.draggedFolderID,
                      let folder = folders.first(where: { $0.id == fid }) {
                MacSidebarFolderGhost(folder: folder, session: session, activeSpace: selectedSpace)
            }
        }
        // Shared coord space across the anchored Essentials and the per-
        // space columns, so tier frames + cursor Y are measured in one
        // consistent frame of reference.
        .coordinateSpace(name: "notes-column")
        .onAppear {
            syncEssentialsDropZoneVisibility()
            selection.openNoteID = activeOpenNoteID
        }
        .onChange(of: activeOpenNoteID) { _, newValue in
            selection.openNoteID = newValue
        }
        .onChange(of: favoriteNotes.count) { _, _ in
            syncEssentialsDropZoneVisibility()
        }
        .onChange(of: shouldShowAddToEssentialsBanner) { _, _ in
            syncEssentialsDropZoneVisibility()
        }
        .onChange(of: searchResetToken) { _, _ in
            searchText = ""
        }
        // Drives edge auto-switch + drop-on-chip: translation updates every
        // drag frame, so we re-evaluate the cursor's drag targets here.
        .onChange(of: session.translation) { _, _ in
            handleDragOverTargets()
        }
        .confirmationDialog(
            "Delete \(pendingBatchDelete.count) notes?",
            isPresented: Binding(
                get: { !pendingBatchDelete.isEmpty },
                set: { if !$0 { pendingBatchDelete = [] } }
            )
        ) {
            Button("Delete \(pendingBatchDelete.count) Notes", role: .destructive) {
                commitBatchDelete()
            }
            Button("Cancel", role: .cancel) { pendingBatchDelete = [] }
        } message: {
            Text("These notes will be permanently deleted.")
        }
    }

    private func syncEssentialsDropZoneVisibility() {
        session.syncFavoriteDropZone(favoriteCount: favoriteNotes.count)
    }

    @ViewBuilder
    private var normalSidebarContent: some View {
        VStack(spacing: 0) {
            MacSidebarCommandField(
                searchText: $searchText,
                createNote: createNote,
                toggleSidebar: toggleSidebar
            )
            .padding(.top, 10)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            // Anchored Essentials grid — rendered once at sidebar level so
            // it doesn't move during a per-space swipe. Cross-space.
            if !favoriteNotes.isEmpty, let activeSpace = selectedSpace {
                MacEssentialsRow(
                    notes: favoriteNotes,
                    space: activeSpace,
                    allNotes: notes,
                    selectedNoteID: displayedSelectedNoteID(for: selectedSpace),
                    selectNote: { note in
                        if let sp = selectedSpace { openNote(note, in: sp) }
                    },
                    session: session,
                    splitMemberIDs: {
                        var ids = Set(activeSplits.flatMap { [$0.primaryID, $0.secondaryID] })
                        if let pid = pendingSplitPrimaryID { ids.insert(pid) }
                        return ids
                    }(),
                    activeSplits: activeSplits,
                    dissolveSplit: dissolveSplit,
                    onSplitDrop: onSplitDrop,
                    selection: selection,
                    performBatch: performBatch,
                    openInSplit: openInSplit,
                    addToSplit: addToSplit
                )
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    session.essentialsSectionHeight = newHeight
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .opacity
                ))
            } else if shouldShowAddToEssentialsBanner {
                // No favorites yet — render the Zen-style "Add to Essentials"
                // promo banner during a non-favorite drag. Pushes the
                // sidebar down via the .animation(value:) below.
                addToEssentialsBanner
                    // Asymmetric like the real Essentials row above: slide+fade
                    // in, but fade out IN PLACE on dismiss. A symmetric move-out
                    // made the banner slide up while the section collapsed
                    // underneath it — two fighting motions that read as janky.
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Horizontal track of all space columns, offset by the animated
            // page index. Per Zen: only Pinned + Notes (per-space content)
            // slides with the workspace.
            HStack(spacing: 0) {
                ForEach(spaces) { space in
                    MacSpaceNotesColumn(
                        space: space,
                        notes: notes,
                        folders: folders,
                        selectedNoteID: displayedSelectedNoteID(for: space),
                        searchText: searchText,
                        selectNote: { openNote($0, in: space) },
                        createNote: createNote,
                        openCommandPalette: openCommandPalette,
                        isCommandPaletteActive: isCommandPaletteActive,
                        session: session,
                        selection: selection,
                        performBatch: performBatch,
                        renamingFolderID: $renamingFolderID,
                        isActiveSpace: space.id == selectedSpaceID,
                        columnWidth: width,
                        canDeleteSpace: spaces.count > 1,
                        requestDeleteSpace: requestDeleteSpace,
                        openManageSpaces: openManageSpaces,
                        openInSplit: openInSplit,
                        addToSplit: addToSplit,
                        onSplitDrop: onSplitDrop,
                        activeSplits: activeSplits,
                        pendingSplitPrimaryID: pendingSplitPrimaryID,
                        dissolveSplit: dissolveSplit,
                        cancelPendingSplit: cancelPendingSplit
                    )
                    .frame(width: width)
                }
            }
            .offset(x: pixelAlignedColumnOffset)
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            .clipShape(MacSpacePageClipShape(trailingBleed: spacePageClipTrailingBleed))
        }
    }

    private var pixelAlignedColumnOffset: CGFloat {
        let rawOffset = -spacePageOffset * width
        guard displayScale > 0 else { return rawOffset }
        return (rawOffset * displayScale).rounded() / displayScale
    }

    private var spacePageClipTrailingBleed: CGFloat {
        isSpaceSwipeVisuallyActive ? pageClipTrailingBleed : 0
    }

    private var isSpaceSwipeVisuallyActive: Bool {
        let distanceFromSettledPage = abs(spacePageOffset - spacePageOffset.rounded()) * width
        let pixelThreshold = displayScale > 0 ? 0.5 / displayScale : 0.25
        return distanceFromSettledPage > pixelThreshold
    }

    @ViewBuilder
    private var addToEssentialsBanner: some View {
        let isTargeted = session.currentTier == .favorite
        VStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
            Text("Add to Essentials")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
            Text("Keep your favorite notes just a click away")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(spaceColor.opacity(isTargeted ? 0.32 : 0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    spaceColor.opacity(isTargeted ? 0.95 : 0.55),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [5, 4])
                )
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            session.tierFrames[.favorite] = newFrame
            session.updateTarget(rowHeight: CrossTierDragSession.noteRowHeight)
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    private func selectSpace(_ space: Space) {
        guard selectedSpaceID != space.id else { return }
        withAnimation(.smooth(duration: 0.18)) {
            selectedSpaceID = space.id
        }
    }

    // MARK: - Drag-over space switching (edges + bottom chips)

    /// While a single note is dragged, switch to another space after a short
    /// hold when the cursor is over a bottom space chip, or near the sidebar's
    /// left/right edge — so the note can be dropped there (the session
    /// re-targets the new active column; release commits a cross-space move).
    /// Mirrors Zen's `#shouldSwitchSpace` + `handle_spaceIconDragOver`.
    private func handleDragOverTargets() {
        // Notes (single + multi) and folders can all switch spaces by edge/chip.
        guard session.isActive, let x = session.cursorX else {
            cancelEdgeSwitch(); return
        }

        // 1. A bottom space chip under the cursor → quick (0.2s), one-shot jump.
        if let y = session.cursorY,
           let hit = session.spaceChipFrames.first(where: { $0.value.contains(CGPoint(x: x, y: y)) }),
           hit.key != selectedSpaceID {
            if edgeSwitchTargetID != hit.key {
                cancelEdgeSwitch()
                edgeSwitchTargetID = hit.key
                let id = hit.key
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    guard session.isActive else { return }
                    switchSpace(toID: id)
                    cancelEdgeSwitch()
                }
                RunLoop.main.add(timer, forMode: .common)
                edgeSwitchTimer = timer
            }
            return
        }

        // 2. Near the left/right edge → deliberate 1s hold, then REPEAT every
        //    1s so holding keeps advancing through spaces (no re-arm needed).
        //    Longer than the chip path so brushing the edge doesn't switch.
        let padding: CGFloat = 26
        // Right-edge switch only within the sidebar; past its right edge the
        // cursor is over the editor (drag-onto-editor split owns that zone).
        let dir = x <= padding ? -1 : (x >= width - padding && x < width ? 1 : 0)
        guard dir != 0 else { cancelEdgeSwitch(); return }
        if edgeSwitchDir != dir || edgeSwitchTargetID != nil {
            cancelEdgeSwitch()
            edgeSwitchDir = dir
            let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
                guard session.isActive else { return }
                switchSpace(by: dir)
            }
            RunLoop.main.add(timer, forMode: .common)
            edgeSwitchTimer = timer
        }
    }

    private func cancelEdgeSwitch() {
        edgeSwitchTimer?.invalidate()
        edgeSwitchTimer = nil
        edgeSwitchTargetID = nil
        edgeSwitchDir = 0
    }

    private func switchSpace(toID id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        withAnimation(.smooth(duration: 0.22)) { selectedSpaceID = id }
    }

    /// Advance one space in `dir` from the current (no wrap). Used by the
    /// repeating edge timer so a held edge keeps stepping through spaces.
    private func switchSpace(by dir: Int) {
        guard let cur = selectedSpaceID, let idx = spaces.firstIndex(where: { $0.id == cur }) else { return }
        let next = idx + dir
        guard next >= 0, next < spaces.count else { return }
        withAnimation(.smooth(duration: 0.22)) { selectedSpaceID = spaces[next].id }
    }
}

private struct MacSpacePageClipShape: Shape {
    let trailingBleed: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width + trailingBleed,
            height: rect.height
        ))
    }
}

/// Floating ghost for a dragged folder header — a collapsed folder pill that
/// tracks the cursor via the shared `sourceRowCenter` + `translation`.
private struct MacSidebarFolderGhost: View {
    @Environment(\.colorScheme) private var colorScheme
    let folder: Folder
    let session: CrossTierDragSession
    let activeSpace: Space?

    private var tint: Color {
        guard let s = activeSpace else { return .accentColor }
        return Color.spaceColor(lightHex: s.colorHex, darkHex: s.darkColorHex, scheme: colorScheme)
    }
    private var rowWidth: CGFloat {
        session.tierFrames[session.sourceTier ?? .random]?.width
            ?? session.tierFrames[.random]?.width
            ?? session.tierFrames[.pinned]?.width
            ?? 220
    }
    private var count: Int { (folder.notes?.count ?? 0) + (folder.children?.count ?? 0) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(folder.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .frame(width: max(0, rowWidth - CGFloat(session.draggedRowDepth) * 14), height: 32)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.6 : 0.85),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(session.isSettling ? 0 : 0.18),
                radius: session.isSettling ? 0 : 8, x: 0, y: session.isSettling ? 0 : 4)
        .frame(width: rowWidth, alignment: .trailing)
        .animation(.smooth(duration: 0.16), value: session.draggedRowDepth)
        .position(
            x: session.sourceRowCenter.x + session.translation.width,
            y: session.sourceRowCenter.y + session.translation.height
        )
        .allowsHitTesting(false)
    }
}

private struct MacSidebarFloatingGhost: View {
    @Environment(\.colorScheme) private var colorScheme

    let note: Note
    let activeSpace: Space?
    let session: CrossTierDragSession
    let width: CGFloat
    let sourceAlreadyInFavorites: Bool
    /// Whether the dragged note is the active space's selected note. When true
    /// the ghost wears the same elevated pill + bold ink as the resting row,
    /// so dragging keeps the highlight and the release handoff is seamless
    /// (no plain-ghost → styled-row pop).
    let isSelected: Bool
    /// The full dragged group, in order. For a multi-drag the ghost renders
    /// these as a contiguous stack of real rows (the grabbed row under the
    /// cursor); for a single drag it's just `[note]`.
    var draggedNotes: [Note] = []
    /// Set when dragging EITHER member of a split (pill, row, or essential
    /// tile) — the ghost renders the combined tab in (primary, secondary)
    /// order regardless of which one was grabbed.
    var splitPair: (Note, Note)? = nil
    /// Set when dragging the pending pick-mode pill (primary + empty slot).
    var pendingPrimary: Note? = nil

    private var spaceColor: Color? {
        guard let s = activeSpace else { return nil }
        return Color.spaceColor(lightHex: s.colorHex, darkHex: s.darkColorHex, scheme: colorScheme)
    }
    private var selectionFill: Color {
        (spaceColor ?? .accentColor).elevatedSelectionFill(scheme: colorScheme)
    }
    private var selectionInk: Color { selectionFill.selectionInk }

    private var asTile: Bool {
        if let frozen = session.frozenAsTile { return frozen }
        return (session.currentTier ?? session.sourceTier) == .favorite
    }

    private var rowWidth: CGFloat {
        session.tierFrames[session.sourceTier ?? .random]?.width
            ?? session.tierFrames[.random]?.width
            ?? session.tierFrames[.pinned]?.width
            ?? max(160, width - 20)
    }

    /// Dragged over the editor → the ghost becomes a big page-tile preview
    /// (like Zen), echoing the note that's about to drop into the split.
    private var overEditor: Bool {
        // Cursor inside the editor pane (engaged or middle no-split zone) →
        // big tile floats over the note, like Arc.
        session.cursorOverEditor && splitPair == nil && pendingPrimary == nil && !session.isMulti
    }

    var body: some View {
        Group {
            if overEditor {
                editorTileGhost
            } else if let pair = splitPair {
                // A split dragged FROM Essentials morphs with the drop target:
                // the combined tile while over the grid, the row pill once it
                // crosses into a list tier (mirrors a single tile's morph).
                if asTile && session.sourceTier == .favorite {
                    splitTileGhost(primary: pair.0, secondary: pair.1)
                } else {
                    MacSplitTabRow(primary: pair.0, secondary: pair.1,
                                   showsSeparateIndicator: true,
                                   isFocused: true, tint: spaceColor ?? .accentColor)
                        .frame(width: rowWidth)
                }
            } else if let pending = pendingPrimary {
                // Dragging the pending pick-mode pill: ghost mirrors the combined
                // primary + "choose a note" placeholder (matches the resting tab).
                MacSplitTabRow(primary: pending, secondary: nil,
                               isFocused: true, tint: spaceColor ?? .accentColor)
                    .frame(width: rowWidth)
            } else if session.isMulti {
                // Morphs with the drop target: a stack of tiles over Essentials,
                // a stack of rows over the list — so the group visibly becomes
                // tiles/tabs as it crosses the boundary.
                if asTile { multiTileStack } else { multiRowStack }
            } else if asTile {
                tileGhost
            } else if activeSpace != nil {
                rowGhost
            }
        }
        .position(x: ghostX, y: ghostCenterY)
        .animation(.smooth(duration: 0.16), value: overEditor)
        // Stronger lift while "picked up" (radius 8), easing down to the
        // resting pill's shadow during the release glide so the handoff to the
        // real row has no shadow step. `isSettling` flips inside the commit's
        // withAnimation, so this interpolates over the same 0.18s.
        .shadow(color: settleShadowColor, radius: settleShadowRadius, x: 0, y: settleShadowY)
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.12), value: asTile)
    }

    /// Shadow that matches the resting row once settled: the selected pill's
    /// rest shadow, or nothing for a non-selected row (which has none at rest).
    private var settleShadowColor: Color {
        if session.isSettling {
            return isSelected ? .black.opacity(colorScheme == .dark ? 0.45 : 0.14) : .clear
        }
        return .black.opacity(isSelected ? 0.22 : 0.18)
    }
    private var settleShadowRadius: CGFloat {
        session.isSettling ? (isSelected ? 4 : 0) : 8
    }
    private var settleShadowY: CGFloat {
        session.isSettling ? (isSelected ? 1.5 : 0) : 4
    }

    private var tileGhost: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacNoteMiniIcon(note: note, size: 24, ink: isSelected ? selectionInk : nil)
            Text(note.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isSelected ? selectionInk : Color.primary.opacity(0.82))
        }
        .frame(width: ghostTileWidth, alignment: .topLeading)
        .frame(minHeight: 66, alignment: .topLeading)
        .padding(8)
        .background(
            isSelected ? selectionFill : Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05) : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 0.5 : 1
                )
        }
    }

    /// Combined-tile ghost for a split dragged over Essentials — two note
    /// cards side by side in one tray, matching the resting Essentials split
    /// tile so the pickup→drop handoff has no shape pop.
    private func splitTileGhost(primary: Note, secondary: Note) -> some View {
        let tileWidth = session.draggedTileWidth
            ?? session.tierFrames[.favorite]?.width ?? rowWidth
        return HStack(spacing: 4) {
            splitTileGhostHalf(primary)
            splitTileGhostHalf(secondary)
        }
        .padding(3)
        .frame(width: max(120, tileWidth), height: CrossTierDragSession.favoriteCellHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selectionFill)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(selectionInk.opacity(0.4))
                .padding(7)
        }
    }

    private func splitTileGhostHalf(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacNoteMiniIcon(note: note, size: 24, ink: selectionInk)
            Text(note.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(selectionInk)
        }
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.92))
        )
    }

    /// Big floating page-tile shown while dragging over the editor.
    private var editorTileGhost: some View {
        VStack(spacing: 14) {
            MacNoteMiniIcon(note: note, size: 30, ink: nil)
            Text(note.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.primary.opacity(0.85))
        }
        .padding(20)
        .frame(width: 150, height: 200)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                // Translucent so the note + borders read through it (Arc-style).
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.86))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), lineWidth: 1)
        }
    }

    private var rowGhost: some View {
        // Inset + narrow to match a folder member's tab; right-aligned within
        // the full tier width so the pill sits exactly where the real member
        // row renders (which is left-inset, trailing edge unchanged). Animates
        // as the previewed depth changes while dragging in/out of folders.
        let inset = CGFloat(session.draggedRowDepth) * 14
        return HStack(spacing: 9) {
            Text(note.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? selectionInk : Color.primary.opacity(0.86))

            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(width: max(0, rowWidth - inset), height: 32)
        .background(
            isSelected
            ? selectionFill
            : Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.78),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .frame(width: rowWidth, alignment: .trailing)
        .animation(.smooth(duration: 0.16), value: session.draggedRowDepth)
    }

    /// Multi-drag ghost: the dragged group rendered as a contiguous stack of
    /// real selected rows (same 35pt pitch as the list), so it reads as the
    /// rows "reuniting" and moving together rather than a single proxy.
    private var multiRowStack: some View {
        // Inset the whole stack to the resolved depth so the selection visibly
        // indents/outdents as you steer it in/out of folders.
        let inset = CGFloat(session.draggedRowDepth) * 14
        return VStack(spacing: 3) {
            ForEach(draggedNotes, id: \.id) { n in
                selectedGhostRow(for: n)
            }
        }
        .frame(width: max(0, rowWidth - inset))
        .frame(width: rowWidth, alignment: .trailing)
        .animation(.smooth(duration: 0.16), value: session.draggedRowDepth)
    }

    private func selectedGhostRow(for note: Note) -> some View {
        HStack(spacing: 9) {
            Text(note.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(selectionInk)
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .background(selectionFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    /// Center-Y for the floating ghost. Single drag: the row tracks the cursor.
    /// Multi drag: the stack is offset so the grabbed (primary) group row sits
    /// at the cursor anchor, with the rest stacked above/below in order.
    private var ghostCenterY: CGFloat {
        let anchorY = session.sourceRowCenter.y + session.translation.height
        guard session.isMulti else { return anchorY }
        // Tiles cluster HORIZONTALLY (a strip), so no vertical stacking offset —
        // they stay on one row at the cursor instead of forming a tall column.
        if asTile { return anchorY }
        // Rows stack vertically; offset so the grabbed row sits at the cursor.
        let pitch = CrossTierDragSession.noteRowHeight
        let content = CrossTierDragSession.noteRowContentHeight
        let k = session.primaryGroupIndex
        let totalHeight = CGFloat(session.draggedCount) * pitch - 3
        return anchorY - (CGFloat(k) * pitch + content / 2) + totalHeight / 2
    }

    /// Horizontal strip of tiles — matches how they sit in the grid (vs a tall
    /// vertical column, which felt wrong for same-row selections).
    private var multiTileStack: some View {
        HStack(spacing: 7) {
            ForEach(draggedNotes, id: \.id) { n in selectedGhostTile(for: n) }
        }
    }

    private func selectedGhostTile(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacNoteMiniIcon(note: note, size: 24, ink: selectionInk)
            Text(note.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(selectionInk)
        }
        .frame(width: ghostTileWidth, alignment: .topLeading)
        .frame(minHeight: 66, alignment: .topLeading)
        .padding(8)
        .background(selectionFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var ghostTileWidth: CGFloat {
        // Locked at release so the @Query-driven count refresh can't
        // resize the tile mid-snap.
        if let frozen = session.frozenTileWidth { return frozen }
        // Match the exact resting tile width measured at pickup (the unified
        // flow's cell width may differ from a count-based estimate when split
        // tiles are present). `-16` for the tile's internal h-padding.
        if let w = session.draggedTileWidth { return w - 16 }
        let gridWidth = session.tierFrames[.favorite]?.width ?? 0
        guard gridWidth > 0 else { return 88 }
        let stored = session.noteCountsByTier[.favorite] ?? 0
        let displayCount: Int
        if session.sourceTier == .favorite || sourceAlreadyInFavorites {
            displayCount = max(stored, 1)
        } else {
            displayCount = stored + 1
        }
        return CrossTierDragSession.favoriteCellWidth(gridWidth: gridWidth, count: displayCount) - 16
    }

    private var ghostX: CGFloat {
        // Anchor to the grab point (fixed at drag start) + cursor delta, NOT
        // the active column's live frame. Tying it to the column center made
        // the ghost jump off-screen and back during a space-switch (the new
        // column's frame is mid-transition), and reading the grab anchor keeps
        // the ghost glued to the pointer where you grabbed it.
        session.sourceRowCenter.x + session.translation.width
    }
}


// MARK: - Command field

private struct MacSidebarCommandField: View {
    @Binding var searchText: String
    let createNote: () -> Void
    let toggleSidebar: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: traffic lights (hosted), toggle button, overflow menu —
            // all on the same row, same vertical level. Lifted straight from
            // Nook's SidebarWindowControlsView (spacing 8, height 28).
            HStack(spacing: 8) {
                EmbeddedTrafficLights()

                Button("Toggle Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .buttonStyle(NavButtonStyle())
                    .foregroundStyle(.primary)
                    .help("Hide sidebar (⌘S)")

                Spacer(minLength: 0)

                Menu {
                    Button("New Note", action: createNote)
                        .keyboardShortcut("n", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                        .imageScale(.large)
                }
                .menuStyle(.button)
                .buttonStyle(NavButtonStyle())
                .foregroundStyle(.primary)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(height: 28)

            // Row 2: full-width URL-style search pill.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.55))

                TextField("Search or create note", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($isFocused)
                    .onSubmit {
                        if !searchText.isEmpty {
                            createNote()
                            searchText = ""
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            // Flat Zen-style URL pill: just a soft tinted fill, no stroke.
            .background(.primary.opacity(isFocused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}

// MARK: - Bottom space strip (mirrors Nook SidebarBottomBar + SpacesList)

private struct MacSpaceStrip: View {
    let spaces: [Space]
    let selectedSpaceID: UUID?
    let isCreatingSpace: Bool
    /// False when only one space remains — deleting the last space is blocked,
    /// so the chip hides its Delete action.
    let canDeleteSpaces: Bool
    let selectSpace: (Space) -> Void
    let requestDeleteSpace: (Space) -> Void
    let onCreateSpace: () -> Void
    let onCreateFolder: () -> Void
    let onCreateNote: () -> Void
    let onCancelCreation: () -> Void
    /// Drag session — chips report their frames into it so a dragged note can
    /// hit-test a chip and switch to that space.
    let session: CrossTierDragSession

    @State private var availableWidth: CGFloat = 0
    @State private var menuOpen: Bool = false
    @Environment(\.modelContext) private var modelContext

    // Horizontal drag-to-reorder state. Same model as the note reorder:
    // the base order (`spaces`) is fixed during the drag; the dragged chip
    // follows the finger (`dragTranslation`) while siblings shift by one
    // chip-pitch to open its target slot. Chip centers are measured (the
    // strip uses flexible spacers, so pitch isn't constant) and snapshotted
    // at drag start into `baseCenters`.
    @State private var draggingID: UUID?
    @State private var dragSourceIndex: Int = 0
    @State private var dragCurrentIndex: Int = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var chipCenterX: [UUID: CGFloat] = [:]
    @State private var baseCenters: [CGFloat] = []

    private var layoutMode: SpaceStripMode {
        let total = spaces.count + (isCreatingSpace ? 1 : 0)
        return SpaceStripMode.determine(count: total, width: availableWidth)
    }

    /// Average distance between adjacent chip centers (snapshotted at drag
    /// start). Used to shift siblings by exactly one chip when reordering —
    /// the strip's flexible spacers mean this isn't a fixed constant.
    private var reorderPitch: CGFloat {
        guard baseCenters.count > 1 else { return 36 }
        let span = (baseCenters.max() ?? 0) - (baseCenters.min() ?? 0)
        return span / CGFloat(baseCenters.count - 1)
    }

    /// Dragged chip follows the finger; siblings between the source and target
    /// slots shift one pitch to open the landing gap (horizontal analogue of
    /// the note-row offset).
    private func chipOffset(index: Int, id: UUID) -> CGFloat {
        guard draggingID != nil else { return 0 }
        if id == draggingID { return dragTranslation }
        let s = dragSourceIndex, c = dragCurrentIndex
        if c > s, index > s, index <= c { return -reorderPitch }
        if c < s, index >= c, index < s { return reorderPitch }
        return 0
    }

    private func reorderGesture(space: Space, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("space-strip"))
            .onChanged { value in
                guard !isCreatingSpace, spaces.count > 1 else { return }
                if draggingID == nil {
                    draggingID = space.id
                    dragSourceIndex = index
                    dragCurrentIndex = index
                    baseCenters = spaces.map { chipCenterX[$0.id] ?? 0 }
                }
                dragTranslation = value.translation.width
                let sourceCenter = baseCenters.indices.contains(dragSourceIndex) ? baseCenters[dragSourceIndex] : 0
                let projected = sourceCenter + dragTranslation
                var target = 0
                for (i, center) in baseCenters.enumerated() where i != dragSourceIndex {
                    if center < projected { target += 1 }
                }
                let clamped = min(max(0, target), spaces.count - 1)
                if clamped != dragCurrentIndex {
                    withAnimation(.smooth(duration: 0.18)) { dragCurrentIndex = clamped }
                }
            }
            .onEnded { _ in commitReorder() }
    }

    private func commitReorder() {
        if draggingID != nil, spaces.indices.contains(dragSourceIndex) {
            var ids = spaces.map(\.id)
            let moved = ids.remove(at: dragSourceIndex)
            ids.insert(moved, at: min(dragCurrentIndex, ids.count))
            for (i, sid) in ids.enumerated() {
                spaces.first(where: { $0.id == sid })?.sortIndex = i
            }
            try? modelContext.save()
        }
        draggingID = nil
        dragTranslation = 0
        baseCenters = []
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    MacSpaceChip(
                        space: space,
                        isSelected: selectedSpaceID == space.id,
                        compact: layoutMode == .compact,
                        canDelete: canDeleteSpaces,
                        action: { selectSpace(space) },
                        requestDelete: { requestDeleteSpace(space) }
                    )
                    .opacity(draggingID == space.id ? 0.85 : 1)
                    .offset(x: chipOffset(index: index, id: space.id))
                    .zIndex(draggingID == space.id ? 1 : 0)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.frame(in: .named("space-strip")).midX
                    } action: { chipCenterX[space.id] = $0 }
                    // Also report the chip frame in the sidebar's coordinate
                    // space so a dragged note can hit-test it for drop-to-switch.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("notes-column"))
                    } action: { session.spaceChipFrames[space.id] = $0 }
                    .simultaneousGesture(reorderGesture(space: space, index: index))
                    if index < spaces.count - 1 || isCreatingSpace {
                        Spacer().frame(minWidth: 1, maxWidth: 8).layoutPriority(-1)
                    }
                }
                if isCreatingSpace {
                    // Placeholder dot for the space being created; Zen
                    // shows this in screenshot 4 — a 4th dot for the
                    // unnamed in-creation workspace.
                    MacSpaceCreationDot()
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .coordinateSpace(name: "space-strip")
            .frame(maxWidth: .infinity)
            .clipped() // safety net: never bleed past the allotted width
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { availableWidth = $0 }
            .animation(.smooth(duration: 0.2), value: isCreatingSpace)

            Button {
                if isCreatingSpace {
                    onCancelCreation()
                } else {
                    menuOpen.toggle()
                }
            } label: {
                ZStack {
                    Image(systemName: "plus")
                        .opacity(isCreatingSpace ? 0 : 1)
                        .rotationEffect(.degrees(isCreatingSpace ? 45 : 0))
                    Image(systemName: "xmark")
                        .opacity(isCreatingSpace ? 1 : 0)
                        .rotationEffect(.degrees(isCreatingSpace ? 0 : -45))
                }
                .font(.system(size: 13, weight: .semibold))
                .animation(.smooth(duration: 0.18), value: isCreatingSpace)
            }
            .buttonStyle(NavButtonStyle())
            .foregroundStyle(.primary)
            .layoutPriority(1) // never gets squeezed out
            .help(isCreatingSpace ? "Cancel" : "New…")
            .popover(isPresented: $menuOpen, arrowEdge: .top) {
                MacSidebarNewElementMenu(
                    onCreateSpace: {
                        menuOpen = false
                        onCreateSpace()
                    },
                    onCreateFolder: {
                        menuOpen = false
                        onCreateFolder()
                    },
                    onNewSplit: { menuOpen = false },
                    onNewTab: {
                        menuOpen = false
                        onCreateNote()
                    }
                )
            }
        }
    }
}

private struct MacSpaceCreationDot: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .strokeBorder(.primary.opacity(colorScheme == .dark ? 0.45 : 0.35),
                          style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            .frame(width: 8, height: 8)
            .frame(width: 32, height: 32) // match SpaceChipButtonStyle slot
    }
}

private enum SpaceStripMode {
    case normal, compact

    static func determine(count: Int, width: CGFloat) -> SpaceStripMode {
        guard count > 0 else { return .normal }
        let buttonSize: CGFloat = 32
        let minSpacing: CGFloat = 4
        let normalMinWidth = CGFloat(count) * buttonSize + CGFloat(max(0, count - 1)) * minSpacing
        return width >= normalMinWidth ? .normal : .compact
    }
}

private struct MacSpaceChip: View {
    let space: Space
    let isSelected: Bool
    let compact: Bool
    let canDelete: Bool
    let action: () -> Void
    let requestDelete: () -> Void

    private let dotSize: CGFloat = 6

    var body: some View {
        Button(action: action) {
            spaceIcon
                .opacity(isSelected ? 1.0 : 0.7)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpaceChipButtonStyle())
        .foregroundStyle(.primary)
        .layoutPriority(isSelected ? 2 : 0) // active chip never shrinks below 32
        .help(space.name)
        .contextMenu {
            if canDelete {
                Button("Delete Space", systemImage: "trash", role: .destructive) {
                    requestDelete()
                }
            }
        }
    }

    @ViewBuilder
    private var spaceIcon: some View {
        if compact && !isSelected {
            Circle()
                .fill(.primary.opacity(0.45))
                .frame(width: dotSize, height: dotSize)
        } else {
            MacSpaceIcon.view(space.emoji, size: 15)
        }
    }
}

/// Port of Nook's `SpaceListItemButtonStyle`. Key detail: `frame(maxWidth: size)`
/// instead of `frame(width: size)` lets the chip shrink when the row is tight,
/// preventing overflow into the editor area.
private struct SpaceChipButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private let size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            configuration.label
                .foregroundStyle(.primary)
        }
        .frame(height: size)
        .frame(maxWidth: size)
        .opacity(isEnabled ? 1.0 : 0.3)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isHovering || isPressed { return colorScheme == .dark ? 0.20 : 0.10 }
        return 0
    }
}

/// Lifted straight from Nook (`NavButtonStyle`): 32pt square, 8pt radius,
/// hover/press tint, smooth scale.
struct NavButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering: Bool = false

    private let size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
                .frame(width: size, height: size)

            configuration.label
                .foregroundStyle(.primary)
        }
        .opacity(isEnabled ? 1.0 : 0.3)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isHovering || isPressed { return colorScheme == .dark ? 0.20 : 0.10 }
        return 0
    }
}

// MARK: - Notes column (sections only)

private struct MacSidebarSplitPair {
    let primary: Note
    let secondary: Note
    let anchorID: UUID
}

private struct MacSpaceNotesColumn: View {
    let space: Space
    let notes: [Note]
    let folders: [Folder]
    let selectedNoteID: UUID?
    let searchText: String
    let selectNote: (Note) -> Void
    let createNote: () -> Void
    /// Open the ⌘T palette — the New Note row fires this instead of creating
    /// directly, so you can title-then-create or run a command.
    let openCommandPalette: () -> Void
    /// Palette open → New Note row wears the selected-bar look.
    let isCommandPaletteActive: Bool
    let session: CrossTierDragSession
    let selection: NoteSelectionModel
    let performBatch: (NoteBatchAction) -> Void
    @Binding var renamingFolderID: UUID?
    let isActiveSpace: Bool
    let columnWidth: CGFloat
    let canDeleteSpace: Bool
    let requestDeleteSpace: (Space) -> Void
    let openManageSpaces: () -> Void
    let openInSplit: (Note) -> Void
    let addToSplit: (Note) -> Void
    let onSplitDrop: (Note, SplitDropSide) -> Void
    let activeSplits: [EditorSplit]
    var pendingSplitPrimaryID: UUID?
    let dissolveSplit: (UUID, NoteTier, Space) -> Void
    var cancelPendingSplit: () -> Void = { }
    private let contentLeadingInset: CGFloat = 10
    private let contentTrailingInset: CGFloat = 10

    @Environment(\.modelContext) private var modelContext
    // Space-edit state, owned here so BOTH the header's ⋯ menu and the
    // empty-sidebar right-click drive the same pickers / inline rename.
    @State private var iconPickerOpen = false
    @State private var themeOpen = false
    @State private var isRenamingSpace = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacSpaceHeaderView(
                space: space,
                isRenaming: $isRenamingSpace,
                draftName: $draftName,
                onCommitRename: commitRename,
                isDropTarget: spaceIsDropTarget,
                menuItems: { spaceMenuItems() }
            )
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 4)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named("notes-column")).maxY
            } action: { newValue in
                if isActiveSpace { session.setSpaceNameMaxY(newValue) }
            }
            .popover(isPresented: $iconPickerOpen, arrowEdge: .trailing) {
                MacIconPicker(selection: iconBinding) { iconPickerOpen = false }
            }
            .onChange(of: iconPickerOpen) { _, open in if !open { save() } }
            .popover(isPresented: $themeOpen, arrowEdge: .trailing) {
                ZenGradientPicker(config: gradientBinding)
            }
            .onChange(of: themeOpen) { _, open in if !open { save() } }

            scrollContent
        }
        // Right-clicking the empty sidebar area shows the active space's menu
        // (Arc behaviour). Rows/folders/header carry their own context menus,
        // which take precedence where they're hit.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .contextMenu { spaceMenuItems() }
    }

    @ViewBuilder
    private func spaceMenuItems() -> some View {
        Button { iconPickerOpen = true } label: { Label("Change Space Icon…", systemImage: "face.smiling") }
        Button { startRename() } label: { Label("Rename Space…", systemImage: "pencil") }
        Button { themeOpen = true } label: { Label("Edit Theme Color…", systemImage: "paintpalette") }
        Button { createFolderHere() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
        Divider()
        Button { openManageSpaces() } label: { Label("Manage Spaces…", systemImage: "square.grid.2x2") }
        if canDeleteSpace {
            Divider()
            Button(role: .destructive) { requestDeleteSpace(space) } label: { Label("Delete Space", systemImage: "trash") }
        }
    }

    private var iconBinding: Binding<String> {
        Binding(get: { space.emoji }, set: { space.emoji = $0 })
    }

    private var gradientBinding: Binding<ZenGradientConfig> {
        Binding(
            get: {
                if let data = space.gradientConfigJSON, let config = ZenGradientConfig.decode(data) {
                    return config
                }
                return .defaultConfig
            },
            set: { newValue in
                space.gradientConfigJSON = ZenGradientConfig.encode(newValue)
                space.colorHex = newValue.lightHex
                space.darkColorHex = newValue.darkHex
            }
        )
    }

    private func startRename() {
        draftName = space.name
        isRenamingSpace = true
    }

    private func commitRename() {
        guard isRenamingSpace else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { space.name = trimmed }
        save()
        isRenamingSpace = false
    }

    private func createFolderHere() {
        if let folder = try? FolderService(context: modelContext).create(in: space, tier: .pinned, parent: nil) {
            renamingFolderID = folder.id
        }
    }

    private func save() {
        do { try modelContext.save() } catch {
            assertionFailure("Failed to save space edit: \(error)")
        }
    }

    private var scrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            // Wrap the LazyVStack in a non-Lazy container so the
            // `.animation(_:value:)` modifier sits on a view that is NOT
            // the immediate scroll-content. Putting it directly on the
            // LazyVStack made SwiftUI capture the ScrollView's
            // overscroll-bounce as an "animatable layout change" — the
            // spring damping then conflicted with the native bounce-back
            // and items would stay displaced instead of snapping back.
            VStack(spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    MacSidebarGroup(
                        space: space,
                        allNotes: notes,
                        notes: pinnedNotes,
                        folders: pinnedFolders,
                        selectedNoteID: selectedNoteID,
                        selectNote: selectNote,
                        tier: .pinned,
                        session: session,
                        selection: selection,
                        performBatch: performBatch,
                        openInSplit: openInSplit,
                        addToSplit: addToSplit,
                        onSplitDrop: onSplitDrop,
                        splitPairs: splitPairs,
                        pendingSplitPrimaryID: pendingSplitPrimaryID,
                        dissolveSplit: dissolveSplit,
                        cancelPendingSplit: cancelPendingSplit,
                        renamingFolderID: $renamingFolderID,
                        isActiveSpace: isActiveSpace,
                        columnWidth: contentWidth
                    )

                    // Hairline separator between the Pinned area and the loose
                    // Notes section. Always visible, regardless of whether either
                    // tier has items — keeps the layout anchored.
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)

                    NewNoteRow(action: openCommandPalette,
                               isActive: isCommandPaletteActive,
                               space: space)
                        .padding(.horizontal, 0)
                        .padding(.top, 2)
                        .padding(.bottom, 4)

                    MacSidebarGroup(
                        space: space,
                        allNotes: notes,
                        notes: randomNotes,
                        folders: randomFolders,
                        selectedNoteID: selectedNoteID,
                        selectNote: selectNote,
                        tier: .random,
                        session: session,
                        selection: selection,
                        performBatch: performBatch,
                        openInSplit: openInSplit,
                        addToSplit: addToSplit,
                        onSplitDrop: onSplitDrop,
                        splitPairs: splitPairs,
                        pendingSplitPrimaryID: pendingSplitPrimaryID,
                        dissolveSplit: dissolveSplit,
                        cancelPendingSplit: cancelPendingSplit,
                        renamingFolderID: $renamingFolderID,
                        isActiveSpace: isActiveSpace,
                        columnWidth: contentWidth
                    )
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.leading, contentLeadingInset)
                .padding(.top, 2)
                .padding(.bottom, 12)
            }
            // Animates the separator's vertical position (and every
            // sibling's) so when a tier grows or shrinks during a drag the
            // separator slides smoothly instead of teleporting. Gated on
            // `isActive`: `.animation(value:)` is transaction-independent, so
            // without the gate it re-fires when the session clears on release
            // and animates the whole column's reflow — the residual movement
            // of the other rows after a drop. Nil while inactive → instant.
                .animation(session.isActive ? .smooth(duration: 0.16) : nil,
                       value: columnLayoutKey)
        }
        // Only bounce when content actually overflows. Without this,
        // pulling on a short list (typical sidebar state) overscrolls
        // and SwiftUI's animation transactions on the content captured
        // the bounce, leaving rows visibly displaced.
        .scrollBounceBehavior(.basedOnSize)
    }

    private var contentWidth: CGFloat {
        max(0, columnWidth - contentLeadingInset - contentTrailingInset)
    }

    /// A within-tier tab drag (note or folder) is resolving to the TOP LEVEL
    /// (depth 0, no folder) → highlight the space name as the drop target,
    /// mirroring how a folder lights up when you nest.
    private var spaceIsDropTarget: Bool {
        isActiveSpace
            && session.isActive
            && session.nestTargetFolderID == nil
            && session.draggedRowDepth == 0
            && session.currentTier == session.sourceTier
            && (session.sourceTier == .pinned || session.sourceTier == .random)
    }

    /// Only changes during drag/cross-tier transitions, NOT on commit. The
    /// counts are deliberately excluded so the @Query refresh that lands a
    /// reorder doesn't trigger the column's layout spring (which would
    /// otherwise animate the source row's slot move).
    private var columnLayoutKey: String {
        let dragID = session.draggedNoteID?.uuidString ?? ""
        let srcTier = session.sourceTier?.rawValue ?? ""
        let curTier = session.currentTier?.rawValue ?? ""
        return "\(dragID)|\(srcTier)|\(curTier)"
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ note: Note) -> Bool {
        guard !query.isEmpty else { return true }
        return note.title.lowercased().contains(query)
            || note.bodyMarkdown.lowercased().contains(query)
    }

    private var pinnedNotes: [Note] { notesFor(tier: .pinned) }
    private var randomNotes: [Note] { notesFor(tier: .random) }
    private var pinnedFolders: [Folder] { foldersFor(tier: .pinned) }
    private var randomFolders: [Folder] { foldersFor(tier: .random) }

    /// Every split whose notes belong to this column. The row whose slot
    /// renders a pair is normally the primary, falling back to the secondary
    /// when the primary has no visible list row.
    /// A split with at least one Essential (favorite) member is hosted as a
    /// combined tile in the Essentials section, so it does NOT render a pill in
    /// this column and both its members are pulled from the row list. Only
    /// splits with no Essential member keep their combined pill here.
    private func isEssentialsHosted(_ split: EditorSplit) -> Bool {
        let p = notes.first { $0.id == split.primaryID }
        let s = notes.first { $0.id == split.secondaryID }
        return p?.tier == .favorite || s?.tier == .favorite
    }

    private var splitPairs: [MacSidebarSplitPair] {
        activeSplits.compactMap { split in
            guard !isEssentialsHosted(split) else { return nil }
            guard let primary = notes.first(where: { $0.id == split.primaryID }),
                  let secondary = notes.first(where: { $0.id == split.secondaryID }),
                  // Favorites are global (`space == nil`) — they belong to
                  // every column. Scope only by each non-favorite member.
                  (primary.tier == .favorite || primary.space?.id == space.id),
                  (secondary.tier == .favorite || secondary.space?.id == space.id)
            else { return nil }
            let primaryIsRowTile = (primary.tier == .pinned || primary.tier == .random)
                && primary.space?.id == space.id
                && primary.folder == nil
            return MacSidebarSplitPair(
                primary: primary,
                secondary: secondary,
                anchorID: primaryIsRowTile ? primary.id : secondary.id
            )
        }
    }
    private var hiddenSplitIDs: Set<UUID> {
        // Non-Essentials splits: hide the non-anchor member (the pill stands in).
        var ids = Set(splitPairs.map { pair in
            pair.anchorID == pair.primary.id ? pair.secondary.id : pair.primary.id
        })
        // Essentials-hosted splits: hide BOTH members — they live only in the
        // Essentials combined tile now.
        for split in activeSplits where isEssentialsHosted(split) {
            ids.insert(split.primaryID)
            ids.insert(split.secondaryID)
        }
        return ids
    }

    private func notesFor(tier: NoteTier) -> [Note] {
        notes
            .filter { $0.tier == tier && $0.space?.id == space.id && $0.folder == nil
                && !hiddenSplitIDs.contains($0.id) && matches($0) }
            .sorted(by: noteSort)
    }

    private func foldersFor(tier: NoteTier) -> [Folder] {
        folders
            .filter { $0.tier == tier && $0.space?.id == space.id && $0.parent == nil }
            .sorted { $0.sortIndex == $1.sortIndex ? $0.createdAt < $1.createdAt : $0.sortIndex < $1.sortIndex }
    }
}

/// Combined sidebar tab for an active split: one pill holding both notes as
/// sub-tabs and one explicit action that separates them back into rows.
private struct MacSplitTabRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let primary: Note
    /// Nil while "Add to Split View" is pending — the second slot shows an
    /// empty "choose a note" placeholder until one is picked/created.
    let secondary: Note?
    /// Tapping the pill focuses the split (shows it in the editor). Ghost
    /// instances pass nil.
    var onSelect: (() -> Void)? = nil
    /// Dissolve the split (separate into two individual tabs).
    var onSeparate: (() -> Void)? = nil
    /// Floating drag pills keep the formed split silhouette without exposing
    /// an active separation action while they are in flight.
    var showsSeparateIndicator = false
    /// Whether the split is the focused (shown) editor content.
    var isFocused: Bool = false
    /// Pending mode: the × on the empty slot cancels the add-to-split.
    var onCancelPending: (() -> Void)? = nil
    /// Space color — when focused the pill wears the same elevated tinted fill
    /// + shadow as a selected note pill.
    var tint: Color = .accentColor

    private var elevatedFill: Color { tint.elevatedSelectionFill(scheme: colorScheme) }
    private var subTabInk: Color { elevatedFill.selectionInk }

    var body: some View {
        HStack(spacing: 4) {
            subTab(primary, isFocused: isFocused)
            if let secondary {
                subTab(secondary, isFocused: isFocused)
                if onSeparate != nil || showsSeparateIndicator {
                    separateControl
                }
            } else {
                pendingSubTab
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                // OPAQUE elevated fill when focused so it casts a real shadow
                // (a translucent fill's shadow is nearly invisible) and matches
                // a selected note pill.
                .fill(isFocused ? elevatedFill
                                : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                // Tinted hairline frames the focused split so its colored tray
                // reads as selected against the (also-tinted) sidebar.
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isFocused ? tint.opacity(colorScheme == .dark ? 0.45 : 0.40) : .clear,
                                      lineWidth: 1)
                }
                .shadow(
                    color: isFocused ? Color.black.opacity(colorScheme == .dark ? 0.45 : 0.16) : .clear,
                    radius: isFocused ? 5 : 0, x: 0, y: isFocused ? 2 : 0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .contextMenu {
            if secondary != nil, let onSeparate {
                Button("Separate Notes", systemImage: "rectangle.split.2x1.slash") { onSeparate() }
            }
        }
    }

    /// The empty second slot shown while waiting for a note to be picked.
    private var pendingSubTab: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.4))
            Text("Choose a note")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let onCancelPending {
                Button { onCancelPending() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.primary.opacity(0.5))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cancel split")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.22),
                              style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
    }

    private func subTab(_ note: Note, isFocused: Bool) -> some View {
        HStack(spacing: 7) {
            MacNoteMiniIcon(note: note, size: 16, ink: isFocused ? subTabInk : nil)
            Text(note.title)
                // Focused: bright opaque card + bold readable ink (matches a
                // selected note pill). Unfocused: flat, recessed, dimmed — so
                // the two states no longer read as near-identical white cards.
                .font(.system(size: 12, weight: isFocused ? .semibold : .medium))
                .foregroundStyle(isFocused ? subTabInk : Color.primary.opacity(0.55))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 7)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused
                      ? Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.92)
                      : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        )
    }

    @ViewBuilder
    private var separateControl: some View {
        if let onSeparate {
            SoftHoverChipButton(help: "Separate notes", action: onSeparate) { hovering in
                Image(systemName: "rectangle.split.2x1.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(hovering ? 0.9 : 0.58))
                    .frame(width: 24, height: 30)
            }
            .accessibilityLabel("Separate notes")
        } else {
            separateIcon
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var separateIcon: some View {
        Image(systemName: "rectangle.split.2x1.slash")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.58))
            .frame(width: 24, height: 30)
            .contentShape(Rectangle())
    }
}

private struct MacSidebarSectionLabel: View {
    let title: String
    let count: Int
    var isExpanded: Bool?
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            if let isExpanded, let toggle {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }
}

private struct NewNoteRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void
    /// While the ⌘T palette is open this row reads as the active selection
    /// (like Arc highlighting "New Tab" when its command bar is up).
    var isActive: Bool = false
    /// Used to tint the active-state bar to match the space's selected-row tone.
    var space: Space? = nil
    @State private var isHovering = false

    private var activeFill: Color {
        let base = space.map {
            Color.spaceColor(lightHex: $0.colorHex, darkHex: $0.darkColorHex, scheme: colorScheme)
        } ?? .accentColor
        return base.elevatedSelectionFill(scheme: colorScheme)
    }
    private var activeInk: Color { activeFill.selectionInk }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .foregroundStyle(isActive ? activeInk.opacity(0.9) : .primary.opacity(0.78))

            Text("New Note")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? activeInk : .primary.opacity(0.82))

            Spacer(minLength: 0)
        }
        // Match MacNoteRow's selected pill EXACTLY: same leading/trailing
        // insets, height, corner radius (9), hairline stroke and shadow — so
        // the active New Note bar is indistinguishable from a selected note.
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isActive
                      ? activeFill
                      : .primary.opacity(isHovering ? (colorScheme == .dark ? 0.10 : 0.07) : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isActive ? Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05) : .clear,
                            lineWidth: 0.5
                        )
                }
                .shadow(
                    color: isActive ? Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14) : .clear,
                    radius: isActive ? 4 : 0, x: 0, y: isActive ? 1.5 : 0
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
        .animation(.easeOut(duration: 0.12), value: isActive)
        .animation(.easeOut(duration: 0.08), value: isHovering)
    }
}

/// Per-subview column span for `EssentialsFlowLayout` (single tile = 1,
/// combined split tile = 2).
private struct EssentialsSpanKey: LayoutValueKey {
    static let defaultValue: Int = 1
}

/// Greedy wrapping grid where each child occupies `EssentialsSpanKey` columns.
/// Delegates the geometry to `CrossTierDragSession.essentialsLayout` so the
/// rendered tiles match the drag hit-test exactly.
private struct EssentialsFlowLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let spans = subviews.map { $0[EssentialsSpanKey.self] }
        let (_, h) = CrossTierDragSession.essentialsLayout(spans: spans, gridWidth: width)
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let spans = subviews.map { $0[EssentialsSpanKey.self] }
        let (rects, _) = CrossTierDragSession.essentialsLayout(spans: spans, gridWidth: bounds.width)
        for (i, sv) in subviews.enumerated() where i < rects.count {
            let r = rects[i]
            sv.place(
                at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY),
                proposal: ProposedViewSize(width: r.width, height: r.height)
            )
        }
    }
}

private struct MacEssentialsRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let notes: [Note]
    let space: Space
    let allNotes: [Note]
    let selectedNoteID: UUID?
    let selectNote: (Note) -> Void
    let session: CrossTierDragSession
    /// Notes currently in a split — used for the pending pick-mode dim.
    var splitMemberIDs: Set<UUID> = []
    /// Active editor splits. Any split with an Essential member renders here as
    /// a combined tile (and is pulled from the normal row sections).
    var activeSplits: [EditorSplit] = []
    /// Separate a split back into individual notes.
    var dissolveSplit: (UUID, NoteTier, Space) -> Void = { _, _, _ in }
    /// Release a dragged tile over the editor → split the open note with it.
    var onSplitDrop: (Note, SplitDropSide) -> Void = { _, _ in }
    /// Shared multi-select set (⌘/⇧-click) + batch action, mirroring the rows.
    let selection: NoteSelectionModel
    var performBatch: (NoteBatchAction) -> Void = { _ in }
    var openInSplit: (Note) -> Void = { _ in }
    var addToSplit: (Note) -> Void = { _ in }

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private struct EssentialsSplit: Identifiable {
        let primary: Note
        let secondary: Note
        var id: UUID { primary.id }
    }

    /// Splits that have at least one Essential member → rendered as a combined
    /// tile at the top of the Essentials section.
    private var essentialsSplits: [EssentialsSplit] {
        activeSplits.compactMap { split in
            guard let primary = allNotes.first(where: { $0.id == split.primaryID }),
                  let secondary = allNotes.first(where: { $0.id == split.secondaryID }),
                  primary.tier == .favorite || secondary.tier == .favorite
            else { return nil }
            return EssentialsSplit(primary: primary, secondary: secondary)
        }
    }

    /// Favorite members shown inside a combined split tile → excluded from the
    /// single-tile grid so they aren't duplicated.
    private var splitFavoriteIDs: Set<UUID> {
        var ids = Set<UUID>()
        for s in essentialsSplits {
            if s.primary.tier == .favorite { ids.insert(s.primary.id) }
            if s.secondary.tier == .favorite { ids.insert(s.secondary.id) }
        }
        return ids
    }

    /// ⌘ toggles membership, ⇧ selects a range over the favorites order, plain
    /// opens the note. Reads live modifier flags (composes with the tap).
    private func handleTileClick(_ note: Note) {
        #if canImport(AppKit)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) { selection.toggle(note.id); return }
        if flags.contains(.shift) { selection.selectRange(to: note.id, in: notes.map(\.id)); return }
        #endif
        selectNote(note)
    }

    @ViewBuilder
    private func tileMenu(_ note: Note) -> some View {
        if selection.count > 1, selection.contains(note.id) {
            let n = selection.count
            if n == 2 {
                Button("Open in Split View", systemImage: "rectangle.split.2x1") { performBatch(.openSplit) }
                Divider()
            }
            Button("Pin \(n) Notes", systemImage: "pin.fill") { performBatch(.pin) }
            Button("Move \(n) to Notes", systemImage: "tray") { performBatch(.moveToNotes) }
            Divider()
            Button("Duplicate \(n) Notes", systemImage: "plus.square.on.square") { performBatch(.duplicate) }
            Button("Archive \(n) Notes", systemImage: "archivebox") { performBatch(.archive) }
            Button("Delete \(n) Notes", systemImage: "trash", role: .destructive) { performBatch(.delete) }
        } else {
            Button("Open", systemImage: "doc.text") { selectNote(note) }
            if selectedNoteID == note.id {
                Button("Add to Split View", systemImage: "rectangle.split.2x1") { addToSplit(note) }
            } else {
                Button("Open in Split View", systemImage: "rectangle.split.2x1") { openInSplit(note) }
            }
            Divider()
            Button("Pin", systemImage: "pin.fill") { try? NoteService(context: modelContext).promote(note, to: .pinned, currentSpace: space) }
            Button("Move to Notes", systemImage: "tray") { try? NoteService(context: modelContext).promote(note, to: .random, currentSpace: space) }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") { _ = try? NoteService(context: modelContext).duplicate(note) }
            Button("Archive", systemImage: "archivebox") { try? NoteService(context: modelContext).archive(note) }
            Button("Delete", systemImage: "trash", role: .destructive) { try? NoteService(context: modelContext).delete(note) }
        }
    }

    private var isCrossTierTarget: Bool {
        session.isActive
            && session.sourceTier != .favorite
            && session.currentTier == .favorite
    }

    private let rowHeight = CrossTierDragSession.noteRowHeight

    /// Measured frame (in `"notes-column"` coords) of every rendered Essentials
    /// entry (single tile, combined split tile, or the live drag gap), keyed by
    /// entry id, so a drag can anchor its ghost / settle target to real geometry.
    @State private var entryFrames: [UUID: CGRect] = [:]
    /// Stable id for the single live drag-gap placeholder so SwiftUI animates
    /// it rather than rebuilding it as it moves between slots.
    @State private var essentialsGapID = UUID()

    /// Full favorites list in stored order (includes split members). The whole
    /// unified grid — singles AND split tiles — is indexed in THIS note space,
    /// so the existing reorder / promote / demote commits stay unchanged.
    private var favoritesByOrder: [Note] {
        Array(notes.sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            .prefix(8))
    }

    /// Single-tile favorites (full favorites minus split-hosted members). Kept
    /// for the section-collapse check.
    private var visibleFavorites: [Note] {
        notes.filter { !splitFavoriteIDs.contains($0.id) }
    }

    /// Favorite note id → the combined split tile that hosts it.
    private var splitByFavoriteMember: [UUID: EssentialsSplit] {
        var m: [UUID: EssentialsSplit] = [:]
        for s in essentialsSplits {
            if s.primary.tier == .favorite { m[s.primary.id] = s }
            if s.secondary.tier == .favorite { m[s.secondary.id] = s }
        }
        return m
    }

    private enum EssentialsEntryKind {
        case single(Note)
        case split(EssentialsSplit)
        case gap
    }
    private struct EssentialsEntry: Identifiable {
        let id: UUID
        let kind: EssentialsEntryKind
        let span: Int       // columns occupied: single 1, split 2
        let noteCount: Int  // favorite notes represented (for index mapping)
        var isGap: Bool { if case .gap = kind { return true }; return false }
    }

    /// Unified ordered grid entries (no drag applied): walk favorites in order,
    /// emitting a 2-wide split tile once per split and a 1-wide single tile
    /// otherwise.
    private var restingEntries: [EssentialsEntry] {
        let splitMap = splitByFavoriteMember
        var out: [EssentialsEntry] = []
        var seen = Set<UUID>()
        for fav in favoritesByOrder {
            if let s = splitMap[fav.id] {
                if seen.contains(s.id) { continue }
                seen.insert(s.id)
                let favCount = (s.primary.tier == .favorite ? 1 : 0)
                    + (s.secondary.tier == .favorite ? 1 : 0)
                out.append(EssentialsEntry(id: s.id, kind: .split(s), span: 2, noteCount: max(1, favCount)))
            } else {
                out.append(EssentialsEntry(id: fav.id, kind: .single(fav), span: 1, noteCount: 1))
            }
        }
        return out
    }

    /// Favorite note ids currently being dragged out of the grid (only when the
    /// drag originated in Essentials — a promote from a list tier excludes none).
    private var draggedFavoriteIDs: Set<UUID> {
        guard session.isActive, session.sourceTier == .favorite else { return [] }
        return Set(session.draggedNoteIDs)
    }

    /// Resting entries with the dragged entry lifted out (it becomes the
    /// floating ghost). This is the layout the hit-test measures against.
    private var restingEntriesExDragged: [EssentialsEntry] {
        let dragged = draggedFavoriteIDs
        guard !dragged.isEmpty else { return restingEntries }
        return restingEntries.filter { entry in
            switch entry.kind {
            case .single(let n): return !dragged.contains(n.id)
            case .split(let s): return !(dragged.contains(s.primary.id) || dragged.contains(s.secondary.id))
            case .gap: return true
            }
        }
    }

    private var favoriteEntryTuples: [(span: Int, noteCount: Int)] {
        restingEntriesExDragged.map { ($0.span, $0.noteCount) }
    }

    /// Change token so we only re-publish the layout to the session when the
    /// resting entry set actually changes.
    private var favoriteLayoutKey: String {
        restingEntriesExDragged
            .map { "\($0.id)-\($0.span)-\($0.noteCount)" }
            .joined(separator: ",")
    }

    /// First entry index whose accumulated `noteCount` reaches `ni`.
    private func entryInsertionIndex(forNoteIndex ni: Int, in entries: [EssentialsEntry]) -> Int {
        var acc = 0
        for (i, e) in entries.enumerated() {
            if acc >= ni { return i }
            acc += e.noteCount
        }
        return entries.count
    }

    /// Is this entry the one currently being dragged within Essentials? (It
    /// stays rendered — invisibly — so the gesture-owning view is never removed
    /// from the hierarchy mid-drag, which would freeze the drag.)
    private func isDraggedEntry(_ entry: EssentialsEntry) -> Bool {
        let dragged = draggedFavoriteIDs
        guard !dragged.isEmpty else { return false }
        switch entry.kind {
        case .single(let n): return dragged.contains(n.id)
        case .split(let s): return dragged.contains(s.primary.id) || dragged.contains(s.secondary.id)
        case .gap: return false
        }
    }

    /// Live drag display order. Within-Essentials: the dragged entry is LIFTED
    /// to the drop slot but kept in the list (rendered at opacity 0 — it is its
    /// own placeholder). Promote from a list tier: the source isn't a favorite
    /// yet, so a separate `.gap` reserves the landing slot.
    private var displayedEntries: [EssentialsEntry] {
        let entries = restingEntries
        guard session.isActive, session.currentTier == .favorite else { return entries }
        if draggedFavoriteIDs.isEmpty {
            var result = entries
            let span = max(1, session.draggedCount)
            let ei = entryInsertionIndex(forNoteIndex: session.currentIndex, in: result)
            let gap = EssentialsEntry(id: essentialsGapID, kind: .gap, span: span, noteCount: span)
            result.insert(gap, at: min(max(0, ei), result.count))
            return result
        }
        let moving = entries.filter { isDraggedEntry($0) }
        var rest = entries.filter { !isDraggedEntry($0) }
        let ei = entryInsertionIndex(forNoteIndex: session.currentIndex, in: rest)
        rest.insert(contentsOf: moving, at: min(max(0, ei), rest.count))
        return rest
    }

    /// Full-favorites note index of a given note (drag source index).
    private func favoritesNoteIndex(_ id: UUID) -> Int {
        favoritesByOrder.firstIndex { $0.id == id } ?? 0
    }

    /// Analytic rect (in `"notes-column"` coords) of a resting entry, computed
    /// from the SAME flow math the renderer uses — reliable at pickup (no
    /// dependency on when `onGeometryChange` last fired). Used to anchor the
    /// drag ghost's center + width to the exact resting tile.
    private func restingEntryRect(_ id: UUID) -> CGRect? {
        guard let frame = session.tierFrames[.favorite], frame.width > 0 else { return nil }
        let entries = restingEntries
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let (rects, _) = CrossTierDragSession.essentialsLayout(
            spans: entries.map { $0.span }, gridWidth: frame.width)
        guard idx < rects.count else { return nil }
        return rects[idx].offsetBy(dx: frame.minX, dy: frame.minY)
    }

    var body: some View {
        EssentialsFlowLayout {
            ForEach(displayedEntries) { entry in
                entryContent(entry)
                    .opacity(isDraggedEntry(entry) ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("notes-column"))
                    } action: { newFrame in
                        entryFrames[entry.id] = newFrame
                    }
                    // `.layoutValue` must be the OUTERMOST modifier so the
                    // EssentialsFlowLayout actually reads each entry's span
                    // (otherwise every tile defaults to 1 column).
                    .layoutValue(key: EssentialsSpanKey.self, value: entry.span)
            }
        }
        // Reflow the gap/tiles as the drop slot or resting set changes.
        .animation(.smooth(duration: 0.18),
                   value: "\(session.currentIndex)|\(restingEntriesExDragged.count)")
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(spaceColor.opacity(isCrossTierTarget ? 0.65 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.15), value: isCrossTierTarget)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            session.tierFrames[.favorite] = newFrame
        }
        .onAppear {
            session.noteCountsByTier[.favorite] = notes.count
            session.favoriteEntryLayout = favoriteEntryTuples
            releaseColumnFreezeIfSettled(count: notes.count)
        }
        .onChange(of: notes.count) { _, newValue in
            session.noteCountsByTier[.favorite] = newValue
            releaseColumnFreezeIfSettled(count: newValue)
        }
        .onChange(of: favoriteLayoutKey) { _, _ in
            session.favoriteEntryLayout = favoriteEntryTuples
        }
    }

    @ViewBuilder
    private func entryContent(_ entry: EssentialsEntry) -> some View {
        switch entry.kind {
        case .single(let note): singleTileView(note)
        case .split(let split): essentialsSplitTile(split)
        case .gap: Color.clear
        }
    }

    /// One single-note Essentials tile (icon + title), with tap / drag /
    /// context-menu. Width is driven by the flow layout (1 column).
    private func singleTileView(_ note: Note) -> some View {
        let isSelected = (selection.isActive ? selection.contains(note.id) : selectedNoteID == note.id)
            && !splitMemberIDs.contains(note.id)
        let inSplit = splitMemberIDs.contains(note.id)
        let tileFill = spaceColor.elevatedSelectionFill(scheme: colorScheme)
        let tileInk = tileFill.selectionInk
        return VStack(alignment: .leading, spacing: 8) {
            MacNoteMiniIcon(note: note, size: 24, ink: isSelected ? tileInk : nil)
            Text(note.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isSelected ? tileInk : Color.primary.opacity(0.82))
        }
        .frame(maxWidth: .infinity, minHeight: 66, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? tileFill : Color.primary.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isSelected
                            ? Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05)
                            : Color.primary.opacity(0.06),
                            lineWidth: isSelected ? 0.5 : 1
                        )
                }
                .shadow(
                    color: isSelected ? Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14) : .clear,
                    radius: isSelected ? 4 : 0, x: 0, y: isSelected ? 1.5 : 0
                )
        }
        .overlay(alignment: .topTrailing) {
            if inSplit {
                Image(systemName: "rectangle.split.2x1.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .padding(5)
            }
        }
        .opacity(inSplit ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { handleTileClick(note) }
        .gesture(tileDragGesture(for: note))
        .contextMenu { tileMenu(note) }
    }

    /// A split rendered to match the Essentials grid: two note-cards (icon +
    /// title, like the square tiles) side by side inside one faint grouping
    /// container, with a split badge and a Separate action. Width is driven by
    /// the flow layout (2 columns).
    private func essentialsSplitTile(_ split: EssentialsSplit) -> some View {
        let isFocused = selectedNoteID == split.primary.id
            || selectedNoteID == split.secondary.id
        let elevated = spaceColor.elevatedSelectionFill(scheme: colorScheme)
        let ink = elevated.selectionInk
        return HStack(spacing: 4) {
            essentialsSplitHalf(split.primary, isFocused: isFocused, ink: ink)
            essentialsSplitHalf(split.secondary, isFocused: isFocused, ink: ink)
        }
        .padding(3)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isFocused ? elevated
                                : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isFocused ? spaceColor.opacity(colorScheme == .dark ? 0.45 : 0.40) : .clear,
                                      lineWidth: 1)
                }
                .shadow(
                    color: isFocused ? Color.black.opacity(colorScheme == .dark ? 0.45 : 0.16) : .clear,
                    radius: isFocused ? 5 : 0, x: 0, y: isFocused ? 2 : 0
                )
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "rectangle.split.2x1.fill")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle((isFocused ? ink : .primary).opacity(0.4))
                .padding(7)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectNote(split.primary) }
        .gesture(splitTileDragGesture(for: split))
        .contextMenu {
            Button("Separate Notes", systemImage: "rectangle.split.2x1.slash") {
                dissolveSplit(split.primary.id, .favorite, space)
            }
        }
    }

    /// Drag the whole combined tile: both notes move together and the split is
    /// preserved. Over Essentials the ghost is the combined tile (and the grid
    /// reflows a 2-wide gap); over a list tier it morphs to the row split pill
    /// and, on release, lands there as a pinned/notes split (never dissolves).
    private func splitTileDragGesture(for split: EssentialsSplit) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedNoteID == nil {
                    session.dragGeneration &+= 1
                    let startIndex = favoritesNoteIndex(split.primary.id)
                    session.draggedNoteID = split.primary.id
                    session.draggedNoteIDs = [split.primary.id]
                    session.sourceTier = .favorite
                    session.sourceSpaceID = space.id
                    session.sourceIndex = startIndex
                    session.currentTier = .favorite
                    session.currentIndex = startIndex
                    let rect = restingEntryRect(split.id) ?? entryFrames[split.id]
                    session.sourceRowCenter = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
                        ?? value.startLocation
                    session.draggedTileWidth = rect?.width
                    session.noteCountsByTier[.favorite] = notes.count
                    session.favoriteEntryLayout = favoriteEntryTuples
                }
                session.updateDrag(location: value.location, translation: value.translation, rowHeight: rowHeight)
            }
            .onEnded { _ in
                let stuckID = session.draggedNoteID
                let gen = session.dragGeneration
                commitTileDrag()
                session.scheduleWatchdog(for: stuckID, generation: gen)
            }
    }

    private func essentialsSplitHalf(_ note: Note, isFocused: Bool,
                                     ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacNoteMiniIcon(note: note, size: 24, ink: isFocused ? ink : nil)
            Text(note.title)
                .font(.system(size: 11, weight: isFocused ? .semibold : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(isFocused ? ink : Color.primary.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(
            // Focused halves are bright opaque cards on the tinted tray;
            // unfocused halves recede to a flat dim fill so selection is
            // unmistakable rather than near-white-on-near-white.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFocused
                      ? Color(nsColor: .windowBackgroundColor)
                          .opacity(colorScheme == .dark ? 0.5 : 0.92)
                      : Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
        )
    }

    /// Clears the column-count freeze once the live count produces the
    /// same column layout — i.e. @Query has caught up to the post-commit
    /// favorites count. Checked from both onAppear (covers promoting into
    /// a previously-empty Essentials, where this row mounts fresh) and
    /// onChange. No visible resize since the layout already matches.
    private func releaseColumnFreezeIfSettled(count: Int) {
        guard let frozen = session.frozenFavoriteColumnCount,
              CrossTierDragSession.favoriteColumnCount(for: max(count, 1)) == frozen else { return }
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { session.frozenFavoriteColumnCount = nil }
    }

    /// Single-tile drag in the unified Essentials grid: the tile follows the
    /// cursor while the grid reflows a 1-wide gap. On release it reorders
    /// within Essentials or demotes to another tier.
    private func tileDragGesture(for note: Note) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedNoteID == nil {
                    session.dragGeneration &+= 1
                    let startIndex = favoritesNoteIndex(note.id)
                    session.draggedNoteID = note.id
                    // Multi-tile drag: the whole selection moves together (e.g.
                    // demote a batch of essentials to Notes). Else a single tile.
                    if selection.contains(note.id), selection.count > 1 {
                        session.draggedNoteIDs = allNotes
                            .filter { selection.contains($0.id) }
                            .sorted(by: noteSort)
                            .map(\.id)
                    } else {
                        session.draggedNoteIDs = [note.id]
                    }
                    session.sourceTier = .favorite
                    session.sourceSpaceID = space.id
                    session.sourceIndex = startIndex
                    session.currentTier = .favorite
                    session.currentIndex = startIndex
                    let rect = restingEntryRect(note.id) ?? entryFrames[note.id]
                    session.sourceRowCenter = rect.map { CGPoint(x: $0.midX, y: $0.midY) }
                        ?? value.startLocation
                    session.draggedTileWidth = rect?.width
                    session.noteCountsByTier[.favorite] = notes.count
                    session.favoriteEntryLayout = favoriteEntryTuples
                }
                // 2D translation — both axes so the ghost can move freely
                // through the grid while reshuffling other tiles.
                session.updateDrag(location: value.location, translation: value.translation, rowHeight: rowHeight)
            }
            .onEnded { _ in
                let stuckID = session.draggedNoteID
                let gen = session.dragGeneration
                commitTileDrag()
                session.scheduleWatchdog(for: stuckID, generation: gen)
            }
    }

    /// Center of where the dragged tile will land, in `"notes-column"` coords.
    /// Within-Essentials the dragged entry itself is the placeholder (id ==
    /// `draggedNoteID`); a promote uses the separate gap placeholder.
    private func essentialsDropCenter() -> CGPoint? {
        let id = draggedFavoriteIDs.isEmpty
            ? essentialsGapID
            : (session.draggedNoteID ?? essentialsGapID)
        guard let r = entryFrames[id], r.width > 0 else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func commitTileDrag() {
        // Multi-tile drag → demote the whole selection to the target list tier
        // (favorites isn't a multi-drop target, so a release over the grid just
        // snaps the stack back). Mirrors the row multi-drag commit.
        if session.isMulti { commitMultiTileDrag(); return }
        // Dragging a combined split tile → move both members together, keeping
        // the split (morphs to a row split pill in a list tier).
        if let esplit = essentialsSplits.first(where: { $0.primary.id == session.draggedNoteID }) {
            commitEssentialsSplitDrag(esplit); return
        }
        guard let id = session.draggedNoteID,
              let source = allNotes.first(where: { $0.id == id }) else {
            wipe()
            return
        }
        // Released over the editor → make a split, NOT a grid reorder/demote.
        // Must short-circuit BEFORE the settle animation below: the editor's
        // split-preview relayout can interrupt that animation's completion,
        // leaving the session never reset (every later drag then jams).
        if let side = session.editorDropSide {
            onSplitDrop(source, side)
            wipe()
            return
        }
        guard let dest = session.currentTier else {
            wipe()
            return
        }
        let destIndex = session.currentIndex
        let crossTier = dest != .favorite

        // Freeze the floating tile's width to its FINAL resting width so
        // the @Query refresh (which mutates noteCountsByTier the instant
        // we commit below) can't resize the ghost mid-snap. Only relevant
        // when landing in the Essentials grid (tile shape).
        // Lock the ghost's shape for the whole snap. Landing in
        // Essentials = tile; anywhere else = row. Prevents the
        // mid-settle shape flash.
        session.frozenAsTile = (dest == .favorite)

        if dest == .favorite, let gw = session.tierFrames[.favorite]?.width, gw > 0 {
            // Total column-units after the drop (singles 1, split tiles 2);
            // a promote adds one single unit. Drives both the ghost's frozen
            // width and the column-count lock.
            let isPromote = session.sourceTier != .favorite
            let restingUnits = restingEntries.reduce(0) { $0 + $1.span }
            let landedUnits = max(1, restingUnits + (isPromote ? 1 : 0))
            session.frozenTileWidth = CrossTierDragSession.favoriteCellWidth(
                gridWidth: gw, count: landedUnits
            ) - 16
            // For a promote, also lock the grid's column count to the
            // post-commit value so the whole grid doesn't resize during
            // the @Query lag. Cleared once notes.count catches up.
            if isPromote {
                session.frozenFavoriteColumnCount =
                    CrossTierDragSession.favoriteColumnCount(for: landedUnits)
            }
        }

        let destFrame = session.tierFrames[dest] ?? .zero
        // For grid destinations (within-Essentials reorder), aim at the live
        // gap's center. For row destinations (demote), use the row slot's Y.
        let targetCenterX: CGFloat
        let targetCenterY: CGFloat
        if dest == .favorite, let cell = essentialsDropCenter() {
            targetCenterX = cell.x
            targetCenterY = cell.y
        } else {
            targetCenterX = destFrame.midX
            targetCenterY = destFrame.minY + CGFloat(destIndex) * rowHeight + rowHeight / 2
        }

        // If this is the last essential and we're moving it OUT, the
        // sidebar will collapse by `essentialsSectionHeight` once
        // `favoriteNotes` empties. Pre-shift the ghost's target by the
        // same amount so it lands on the slot's POST-collapse position —
        // letting us fire the data commit in parallel with the ghost
        // spring (instead of after it).
        let essentialsWillEmpty = crossTier && visibleFavorites.count == 1 && essentialsSplits.isEmpty
        let shift: CGFloat = essentialsWillEmpty ? session.essentialsSectionHeight : 0
        let targetTranslationX = targetCenterX - session.sourceRowCenter.x
        let targetTranslationY = (targetCenterY - shift) - session.sourceRowCenter.y

        if crossTier {
            // Demote: fire data commit immediately so the
            // EssentialsLayoutKey spring starts in parallel.
            performDemote(to: dest, destIndex: destIndex, noteID: id)
        } else if destIndex != session.sourceIndex {
            // Within-Essentials reorder: rebuild manualSortIndex now so
            // the grid lands silently when session.reset clears (the
            // the displayed entries already show the target order during drag).
            reorderFavorites(noteID: id, toIndex: destIndex)
        }

        // Match the grid's reflow curve (0.18) so the ghost and any
        // settling tiles move in lockstep instead of arriving at
        // different times.
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(
                width: dest == .favorite ? targetTranslationX : 0,
                height: targetTranslationY
            )
        } completion: {
            // Defer session.reset so `@Query` refreshes `favoriteNotes`
            // first — otherwise the source tile briefly becomes visible
            // again before the grid is removed.
            DispatchQueue.main.async {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.reset()
                }
            }
        }
    }

    /// Release path for dragging a combined split tile. Both notes move
    /// together and the `EditorSplit` is preserved: dropping back over
    /// Essentials keeps it a combined tile (both stay/become favorites);
    /// dropping over a list tier demotes BOTH into this space so it re-renders
    /// as a row split pill there. Never dissolves the split.
    private func commitEssentialsSplitDrag(_ esplit: EssentialsSplit) {
        guard let dest = session.currentTier else { wipe(); return }
        let primary = esplit.primary
        let secondary = esplit.secondary

        // Over the editor → not a re-split target here; snap the tile back.
        if session.editorDropSide != nil { settleSplitTile(to: .zero); return }

        if dest == .favorite {
            // Stays an Essentials combined tile. Promote both to favorites
            // (covers a favorite+list split fully entering Essentials), then
            // glide the ghost to the DROP slot (not back to the start).
            moveSplitMembers(primary: primary, secondary: secondary, to: .favorite)
            if let cell = essentialsDropCenter() {
                settleSplitTile(to: CGSize(
                    width: cell.x - session.sourceRowCenter.x,
                    height: cell.y - session.sourceRowCenter.y
                ))
            } else {
                settleSplitTile(to: .zero)
            }
            return
        }

        // Demote both into this space's list tier → row split pill.
        session.frozenAsTile = false
        let destFrame = session.tierFrames[dest] ?? .zero
        let destIndex = session.currentIndex
        let targetCenterY = destFrame.minY + CGFloat(destIndex) * rowHeight + rowHeight / 2
        moveSplitMembers(primary: primary, secondary: secondary, to: dest)
        settleSplitTile(to: CGSize(width: 0, height: targetCenterY - session.sourceRowCenter.y))
    }

    /// Glide the floating split ghost to `target`, then commit-reset off the
    /// animation (so `@Query` repaints the real pill/tile before the ghost is
    /// removed — clean handoff, no flash).
    private func settleSplitTile(to target: CGSize) {
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = target
        } completion: {
            DispatchQueue.main.async {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { session.reset() }
            }
        }
    }

    /// Move both split members into `dest` (favorites are global → no space),
    /// placed adjacently at the hit-test index, primary first. Keeps the split.
    private func moveSplitMembers(primary: Note, secondary: Note, to dest: NoteTier) {
        let now = Date()
        for n in [primary, secondary] {
            n.tier = dest
            n.space = dest == .favorite ? nil : space
            n.folder = nil
            n.updatedAt = now
        }
        let destOthers = allNotes
            .filter { $0.tier == dest
                && (dest == .favorite || $0.space?.id == space.id)
                && $0.folder == nil
                && $0.id != primary.id && $0.id != secondary.id }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        var reordered = destOthers
        let insertIdx = min(max(0, session.currentIndex), reordered.count)
        reordered.insert(contentsOf: [primary, secondary], at: insertIdx)
        for (i, n) in reordered.enumerated() { n.manualSortIndex = i }

        // Renumber the favorites tier the pair may have left.
        if dest != .favorite {
            let leftFavorites = allNotes
                .filter { $0.tier == .favorite && $0.id != primary.id && $0.id != secondary.id }
                .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            for (i, n) in leftFavorites.enumerated() { n.manualSortIndex = i }
        }
        try? modelContext.save()
    }

    /// Release path for a multi-TILE drag — demote the dragged set as a block
    /// into the target list tier. Mirrors `MacSidebarGroup.commitMultiDrag`
    /// (favorites isn't a multi-drop target → snap back).
    private func commitMultiTileDrag() {
        guard let dest = session.currentTier else { wipe(); return }
        let ids = session.draggedNoteIDs
        // Reorder/keep the group WITHIN Essentials at the grid hit-test index.
        // Glide the strip so the grabbed tile lands on its target cell (snaps
        // back when released far from the slot, like tabs/spaces).
        if dest == .favorite {
            let destIndex = session.currentIndex
            session.frozenAsTile = true
            if let cell = essentialsDropCenter() {
                let target = CGSize(
                    width: cell.x - session.sourceRowCenter.x,
                    height: cell.y - session.sourceRowCenter.y
                )
                withAnimation(.smooth(duration: 0.2)) {
                    session.isSettling = true
                    session.translation = target
                } completion: {
                    performMoveMultiTile(ids: ids, dest: .favorite, destIndex: destIndex)
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { session.reset() }
                }
            } else {
                performMoveMultiTile(ids: ids, dest: .favorite, destIndex: destIndex)
                wipe()
            }
            return
        }
        let rawDestIndex = max(0, session.currentIndex - session.primaryGroupIndex)
        let destVisibleCount = allNotes.filter {
            $0.tier == dest && $0.space?.id == space.id && $0.folder == nil && !session.isDragged($0.id)
        }.count
        let destIndex = min(rawDestIndex, destVisibleCount)

        // Land as rows (not tiles).
        session.frozenAsTile = false
        let destFrame = session.tierFrames[dest] ?? .zero
        let primaryLandedSlot = destIndex + session.primaryGroupIndex
        let primaryTargetCenterY = destFrame.minY
            + CGFloat(primaryLandedSlot) * rowHeight
            + CrossTierDragSession.noteRowContentHeight / 2
        let targetTranslationY = primaryTargetCenterY - session.sourceRowCenter.y

        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(width: 0, height: targetTranslationY)
        } completion: {
            performMoveMultiTile(ids: ids, dest: dest, destIndex: destIndex)
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { session.reset() }
        }
    }

    private func performMoveMultiTile(ids: [UUID], dest: NoteTier, destIndex: Int) {
        let movers = ids.compactMap { id in allNotes.first { $0.id == id } }
        guard !movers.isEmpty else { return }
        for m in movers {
            m.tier = dest
            m.space = dest == .favorite ? nil : space   // favorites are global
            m.folder = nil
        }
        let destOthers = allNotes
            .filter { $0.tier == dest && (dest == .favorite || $0.space?.id == space.id) && $0.folder == nil && !ids.contains($0.id) }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        var reordered = destOthers
        let insertIdx = min(max(0, destIndex), reordered.count)
        reordered.insert(contentsOf: movers, at: insertIdx)
        for (i, n) in reordered.enumerated() { n.manualSortIndex = i }

        // Renumber the row tiers the group left behind.
        for srcTier in [NoteTier.pinned, .random] where srcTier != dest {
            let remaining = allNotes
                .filter { $0.tier == srcTier && $0.space?.id == space.id && $0.folder == nil && !ids.contains($0.id) }
                .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            for (i, n) in remaining.enumerated() { n.manualSortIndex = i }
        }

        let now = Date()
        for m in movers { m.updatedAt = now }
        try? modelContext.save()
    }

    private func reorderFavorites(noteID: UUID, toIndex: Int) {
        let favorites = allNotes
            .filter { $0.tier == .favorite && $0.folder == nil }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        guard let source = favorites.first(where: { $0.id == noteID }) else { return }
        // `toIndex` is an insertion index among the NON-dragged favorites
        // (the unified grid hit-test indexes the full favorites note space).
        var reordered = favorites.filter { $0.id != noteID }
        let insertIdx = min(max(0, toIndex), reordered.count)
        reordered.insert(source, at: insertIdx)
        for (i, n) in reordered.enumerated() { n.manualSortIndex = i }
        source.updatedAt = Date()
        try? modelContext.save()
    }

    private func performDemote(to dest: NoteTier, destIndex: Int, noteID: UUID) {
        guard let source = allNotes.first(where: { $0.id == noteID }) else { return }
        source.tier = dest
        source.space = space
        source.folder = nil

        let destExisting = allNotes
            .filter { $0.tier == dest && $0.space?.id == space.id && $0.folder == nil && $0.id != noteID }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        var destReordered = destExisting
        let insertIdx = min(destIndex, destReordered.count)
        destReordered.insert(source, at: insertIdx)
        for (i, n) in destReordered.enumerated() { n.manualSortIndex = i }
        source.updatedAt = Date()
        try? modelContext.save()
    }

    private func wipe() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            session.reset()
        }
    }
}

/// Lightweight shared session for detecting cross-tier drag intent. The
/// within-tier reorder still runs inside `MacSidebarGroup` as before; this
/// session is only consulted to (a) suppress the local reshuffle when the
/// cursor has left the source tier, (b) highlight the destination tier, and
/// (c) decide on release whether to commit a cross-tier move. No phantom
/// slots, no floating overlay — keeps the visual model identical to the
/// within-tier system you signed off on.
@Observable
@MainActor
final class CrossTierDragSession {
    // Source identity
    var draggedNoteID: UUID? = nil
    /// Set when dragging a FOLDER header (instead of a note). The folder is
    /// genuinely collapsed for the drag and reorders among its tier's top-level
    /// items; never promotable to Essentials.
    var draggedFolderID: UUID? = nil
    /// Whether the dragged folder was expanded before the grab, so it can be
    /// re-opened (as a separate clean animation) once the drag settles.
    @ObservationIgnored var draggedFolderWasExpanded = false
    /// The source tier's RESTING flat rows (the tier MINUS the dragged row),
    /// published at drag start. The hit-test resolves the drop slot against this
    /// fixed layout (via the ghost center) so it never oscillates, and treats
    /// folder headers as nest bands. `folderID` = the folder to nest into (for a
    /// header row) or the row's membership (for a note row).
    @ObservationIgnored var tierFolderRows: [NoteTier: [(isFolder: Bool, folderID: UUID?, depth: Int)]] = [:]
    /// The resolved PARENT folder for the dragged note (indent model): nil =
    /// top-level, else the folder it will nest into at the current depth. Drives
    /// the folder highlight + the commit's membership.
    var nestTargetFolderID: UUID? = nil
    /// Folders spring-loaded open mid-drag (the ghost dwelled over a collapsed
    /// folder), mapped to their member count at expand time. On drag end the
    /// sidebar collapses back only the ones nothing was dropped into (count
    /// unchanged). Survives `reset()` — drained by the group's drag-end handler.
    @ObservationIgnored var autoExpandedDuringDrag: [UUID: Int] = [:]
    /// Cursor X (notes-column coords) at grab + the dragged row's depth at grab,
    /// so the live depth is steered relative to where you started.
    @ObservationIgnored var dragStartCursorX: CGFloat = 0
    @ObservationIgnored var dragSourceDepth: Int = 0
    /// Max depth the dragged item may reach: a note can be one deeper than the
    /// deepest folder; a dragged folder is limited so its deepest descendant
    /// still fits under `Folder.maxDepth`.
    @ObservationIgnored var draggedDepthCap: Int = 0
    /// Live center of the indent drop indicator (notes-column coords) — the
    /// ghost settles exactly here so the release lands where the bar shows.
    @ObservationIgnored var dropIndicatorCenter: CGPoint? = nil
    var sourceTier: NoteTier? = nil
    var sourceIndex: Int = 0
    var sourceRowCenter: CGPoint = .zero

    /// The full ordered set of notes being dragged. For a single drag this is
    /// just `[draggedNoteID]`; for a multi-drag it's the whole selection in
    /// display order, with `draggedNoteID` the grabbed "primary" row that the
    /// ghost anchors to. Multi-specific layout/commit branches key off this.
    var draggedNoteIDs: [UUID] = []
    var isMulti: Bool { draggedNoteIDs.count > 1 }
    var draggedCount: Int { max(1, draggedNoteIDs.count) }
    func isDragged(_ id: UUID) -> Bool { draggedNoteIDs.contains(id) }

    /// The currently-active space the drag would drop into. Set by the active
    /// column; when edge-switching changes the active space mid-drag this
    /// becomes the *destination*, so a release commits a cross-space move.
    @ObservationIgnored var dropSpace: Space?
    /// The space the drag started in (to detect a cross-space drop).
    @ObservationIgnored var sourceSpaceID: UUID?
    /// Bottom space-chip frames in "notes-column" coords, for hit-testing a
    /// note dragged over a chip (→ switch to that space).
    @ObservationIgnored var spaceChipFrames: [UUID: CGRect] = [:]
    /// Set by the editor pane while a single note is dragged over it: which
    /// edge → on release `commitDrag` makes a split instead of a reorder.
    @ObservationIgnored var editorDropSide: SplitDropSide?
    /// Position of the grabbed (primary) row within the dragged group. The
    /// floating stack and the list gap are anchored so this row lands under
    /// the cursor — so a multi-drag feels like dragging that row alone.
    var primaryGroupIndex: Int {
        guard let id = draggedNoteID, let idx = draggedNoteIDs.firstIndex(of: id) else { return 0 }
        return idx
    }

    // Live cursor state
    @ObservationIgnored var cursorY: CGFloat? = nil
    @ObservationIgnored var cursorX: CGFloat? = nil
    /// True while the drag cursor is inside the editor pane — drives the big
    /// floating-tile ghost regardless of whether a split side has engaged
    /// (middle = no split, but the tile still floats over the note).
    var cursorOverEditor: Bool = false
    /// Bumped each time a drag begins — lets the stuck-drag watchdog tell its
    /// own drag apart from a fresh re-drag of the same note.
    @ObservationIgnored var dragGeneration = 0
    var translation: CGSize = .zero

    /// Set on drag release to lock the floating tile's width during the
    /// snap. Without this, the data commit's `@Query` refresh updates
    /// `noteCountsByTier` mid-snap and `ghostTileWidth` recomputes to a
    /// stale count's width — the tile visibly resizes wide, then settles.
    var frozenTileWidth: CGFloat? = nil

    /// Set on a PROMOTE release to lock the Essentials grid's column
    /// count to its post-commit value. The data commit's `@Query`
    /// refresh lags `session.reset()`, so for a frame the grid would lay
    /// out with the old (fewer) columns — wider cells — then snap
    /// narrower. Held until `notes.count` catches up to the new count.
    var frozenFavoriteColumnCount: Int? = nil

    /// Set on release to lock the floating ghost's SHAPE (tile vs row)
    /// during the snap. The ghost's shape is normally derived from
    /// `currentTier ?? sourceTier`; if that momentarily resolves to a
    /// non-favorite tier while the ghost is still on screen (which can
    /// happen as the commit / reset settles), the ghost snaps to a
    /// full-tier-width ROW for a frame — the "glitches wider" flash.
    /// Freezing pins it to whatever it was at release.
    var frozenAsTile: Bool? = nil

    /// True for the duration of the release glide. Drives the floating
    /// ghost's shadow easing down from its "picked up" lift (radius 8) to the
    /// resting pill's shadow (radius 4) so the handoff to the real row has no
    /// shadow step. Set inside the commit's `withAnimation`, cleared by `reset`.
    var isSettling: Bool = false

    // Live target (where the row would land if released right now)
    var currentTier: NoteTier? = nil
    var currentIndex: Int = 0

    // Tier geometry / counts, populated by each MacSidebarGroup.
    @ObservationIgnored var tierFrames: [NoteTier: CGRect] = [:]
    @ObservationIgnored var noteCountsByTier: [NoteTier: Int] = [:]
    /// Per-entry layout of the RESTING Essentials grid (the dragged entry
    /// excluded), in display order: `span` = columns the entry occupies
    /// (single tile 1, combined split tile 2), `noteCount` = how many favorite
    /// notes it represents (single 1, fav+list split 1, fav+fav split 2). The
    /// view publishes this; the favorite hit-test uses `span` for the flow
    /// geometry and `noteCount` to convert the entry slot to a favorites note
    /// index (so existing reorder/promote commits stay in note-index space).
    @ObservationIgnored var favoriteEntryLayout: [(span: Int, noteCount: Int)] = []
    /// Measured width of the dragged Essentials tile at pickup (combined split
    /// tile = 2 columns), so the floating ghost matches it exactly.
    @ObservationIgnored var draggedTileWidth: CGFloat? = nil

    /// Folder nesting depth the dragged row PREVIEWS at (0 = standalone,
    /// 1 = inside a top-level folder, …). Updated live from the drop slot so the
    /// floating row ghost insets/narrows to match a member tab as it moves
    /// in/out of folders.
    var draggedRowDepth: Int = 0
    var favoriteDropZoneVisible: Bool = false
    var showsAddToEssentialsBanner: Bool = false

    // Bottom edge of the active column's space-name label, in
    // "notes-column" coords. Used as the threshold for showing the
    // "Add to Essentials" banner — cursor must rise above it to trigger.
    @ObservationIgnored var spaceNameMaxY: CGFloat = 0

    // Grid layout constants for the Essentials section.
    static let noteRowHeight: CGFloat = 35 // 32pt row + 3pt spacing
    static let noteRowContentHeight: CGFloat = 32 // visible row (excludes the 3pt gap)

    // Shared drag-system animation curves — keep the sidebar's drag feel
    // coherent. `commitGlide` is the settle/commit motion (the ghost gliding to
    // its slot); `rowShuffle` is the faster live reflow + drop-target highlight;
    // `folderToggle` is the collapse/expand chevron. Use these everywhere in the
    // folders/notes drag system instead of ad-hoc literals.
    static let commitGlide = Animation.smooth(duration: 0.18)
    static let rowShuffle = Animation.smooth(duration: 0.14)
    static let folderToggle = Animation.smooth(duration: 0.2)

    static let favoriteCellSpacing: CGFloat = 7
    static let favoriteCellHeight: CGFloat = 82 // 66 minHeight + 16 padding

    /// Dynamic column count for the Essentials grid — mirrors Zen's
    /// behavior of letting tiles fill the available row width. 1 → 1 col
    /// (100% wide), 2 → 2 cols (50% each), 3 → 3 cols (33% each), 4 →
    /// 2x2 (50% each), 5+ → 3 per row.
    nonisolated static func favoriteColumnCount(for count: Int) -> Int {
        switch count {
        case 0, 1: return 1
        case 2:    return 2
        case 3:    return 3
        case 4:    return 2
        default:   return 3
        }
    }

    /// Inner padding inside `MacEssentialsRow`'s grid (`.padding(2)` on
    /// the LazyVGrid) — added to cell origin & subtracted from cell
    /// width so the predicted snap target matches the actual rendered
    /// tile position to the pixel.
    static let favoriteGridPadding: CGFloat = 2

    /// Width of a single Essentials grid cell, given the grid's full
    /// width and the displayed tile count.
    static func favoriteCellWidth(gridWidth: CGFloat, count: Int) -> CGFloat {
        let n = favoriteColumnCount(for: count)
        let contentWidth = gridWidth - 2 * favoriteGridPadding
        return max(0, (contentWidth - CGFloat(n - 1) * favoriteCellSpacing) / CGFloat(n))
    }

    /// Greedy wrapping flow for the unified Essentials grid where each entry
    /// occupies `span` columns (single tile = 1, combined split tile = 2).
    /// Returns each entry's rect in the grid's local coords (origin at the
    /// grid's top-left, INCLUDING the `favoriteGridPadding` inset) plus the
    /// total height. The renderer and the drag hit-test both call this so the
    /// predicted slots match the rendered tiles to the pixel.
    nonisolated static func essentialsLayout(spans: [Int], gridWidth: CGFloat)
        -> (rects: [CGRect], totalHeight: CGFloat) {
        let pad = favoriteGridPadding
        let spacing = favoriteCellSpacing
        let cellH = favoriteCellHeight
        let units = max(1, spans.reduce(0) { $0 + max(1, $1) })
        let n = max(1, favoriteColumnCount(for: units))
        let contentWidth = gridWidth - 2 * pad
        let unitW = max(0, (contentWidth - CGFloat(n - 1) * spacing) / CGFloat(n))
        var rects: [CGRect] = []
        var col = 0
        var row = 0
        for rawSpan in spans {
            let s = min(max(1, rawSpan), n)
            if col + s > n { col = 0; row += 1 }
            let x = pad + CGFloat(col) * (unitW + spacing)
            let y = pad + CGFloat(row) * (cellH + spacing)
            let w = CGFloat(s) * unitW + CGFloat(s - 1) * spacing
            rects.append(CGRect(x: x, y: y, width: w, height: cellH))
            col += s
        }
        let rows = spans.isEmpty ? 0 : row + 1
        let totalHeight = 2 * pad + CGFloat(rows) * cellH
            + CGFloat(max(0, rows - 1)) * spacing
        return (rects, totalHeight)
    }

    // Total vertical footprint of the Essentials section in the sidebar
    // (the grid plus the surrounding paddings). When the last essential
    // leaves, this is exactly the height the sidebar collapses by — we
    // use it to pre-shift the ghost's drop target so the ghost slide
    // and the sidebar's collapse can run in parallel.
    @ObservationIgnored var essentialsSectionHeight: CGFloat = 0

    var isActive: Bool { draggedNoteID != nil || draggedFolderID != nil }

    var isCrossTier: Bool {
        guard let s = sourceTier, let c = currentTier else { return false }
        return s != c
    }

    func syncFavoriteDropZone(favoriteCount: Int) {
        noteCountsByTier[.favorite] = favoriteCount
        refreshFavoriteDropZoneVisibility()
    }

    func setSpaceNameMaxY(_ maxY: CGFloat) {
        guard abs(spaceNameMaxY - maxY) > 0.5 else { return }
        spaceNameMaxY = maxY
        refreshFavoriteDropZoneVisibility()
    }

    func updateDrag(location: CGPoint, translation newTranslation: CGSize, rowHeight: CGFloat) {
        cursorY = location.y
        cursorX = location.x
        if translation != newTranslation {
            translation = newTranslation
        }
        updateTarget(rowHeight: rowHeight)
    }

    func refreshFavoriteDropZoneVisibility() {
        let hasFavorites = (noteCountsByTier[.favorite] ?? 0) > 0
        let shouldShowBanner = shouldShowEmptyFavoriteBanner()
        if showsAddToEssentialsBanner != shouldShowBanner {
            showsAddToEssentialsBanner = shouldShowBanner
        }

        let shouldShowDropZone = hasFavorites || shouldShowBanner
        if favoriteDropZoneVisible != shouldShowDropZone {
            favoriteDropZoneVisible = shouldShowDropZone
        }

        if !shouldShowDropZone {
            tierFrames[.favorite] = nil
            if currentTier == .favorite, sourceTier != .favorite {
                currentTier = sourceTier
                currentIndex = sourceIndex
            }
        }
    }

    private func shouldShowEmptyFavoriteBanner() -> Bool {
        guard isActive,
              sourceTier != .favorite,
              (noteCountsByTier[.favorite] ?? 0) == 0,
              let cursorY else { return false }

        let threshold: CGFloat
        if spaceNameMaxY > 0 {
            threshold = spaceNameMaxY
        } else if let firstTierTop = [NoteTier.pinned, .random].compactMap({ tierFrames[$0]?.minY }).min(),
                  firstTierTop > 0 {
            threshold = firstTierTop
        } else {
            threshold = 120
        }
        return cursorY < threshold
    }

    /// Recomputes `currentTier` and `currentIndex` from the live cursor.
    /// The actual sibling-row animation is provided by `.animation(value:)`
    /// on the consuming views — no `withAnimation` here would just double
    /// up and make things feel laggy.
    func updateTarget(rowHeight: CGFloat) {
        guard let y = cursorY else { return }
        // While the cursor is over the editor (forming a split), the sidebar
        // list must hold still — moving the ghost tile up/down shouldn't
        // reshuffle the tabs. Park the target back at the source so the rows
        // sit at rest until the cursor returns to the sidebar.
        //
        // Gate on `cursorOverEditor`, NOT just `editorDropSide != nil`: in the
        // MIDDLE (no-split) zone the cursor is over the editor but no edge has
        // engaged (`editorDropSide == nil`), and the old guard let the list
        // reshuffle there.
        if cursorOverEditor || editorDropSide != nil {
            if currentTier != sourceTier { currentTier = sourceTier }
            if currentIndex != sourceIndex { currentIndex = sourceIndex }
            return
        }
        refreshFavoriteDropZoneVisibility()

        // Pick the tier whose frame is *closest* to the cursor — exact
        // containment first, otherwise minimum vertical distance. Avoids
        // the dragged note staying classified as its source tier when the
        // cursor lands in a gap between sections (e.g., separator + New
        // Note row, which belong to no tier).
        var bestTier: NoteTier? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for tier in [NoteTier.favorite, .pinned, .random] {
            if tier == .favorite && !favoriteDropZoneVisible { continue }
            guard let frame = tierFrames[tier] else { continue }
            let distance: CGFloat
            if y >= frame.minY, y <= frame.maxY {
                distance = 0
            } else if y < frame.minY {
                distance = frame.minY - y
            } else {
                distance = y - frame.maxY
            }
            if distance < bestDistance {
                bestDistance = distance
                bestTier = tier
            }
        }
        // Defensive: if the only matched tier is .favorite but the
        // cursor is clearly below the essentials section, fall through
        // to whichever row tier we know about (or .random as a default)
        // so a demote drag still works even when row-tier frames haven't
        // been pushed into the session yet.
        if let bt = bestTier, bt == .favorite,
           let favFrame = tierFrames[.favorite],
           y > favFrame.maxY + 8 {
            if tierFrames[.pinned] != nil {
                bestTier = .pinned
            } else if tierFrames[.random] != nil {
                bestTier = .random
            } else {
                bestTier = .random
            }
        }

        var newTier = bestTier ?? sourceTier
        // Folders can't promote to Essentials — clamp a folder drag back to its
        // source (list) tier when the cursor wanders over the favorites grid.
        if draggedFolderID != nil, newTier == .favorite { newTier = sourceTier }
        guard let target = newTier else { return }

        let frame = tierFrames[target] ?? .zero
        let baseCount = noteCountsByTier[target] ?? 0
        let effective = target == sourceTier ? max(1, baseCount) : (baseCount + 1)

        var resolvedDepth = 0
        let newIndex: Int
        if target == .favorite, frame.width > 0, !favoriteEntryLayout.isEmpty {
            // Span-aware flow hit-test: lay out the resting entries (singles =
            // 1 col, split tiles = 2 cols), find which reading-order slot the
            // cursor falls into, then convert that entry slot to a favorites
            // NOTE index via each entry's `noteCount` (so the reorder/promote
            // commits keep operating in note-index space).
            let spans = favoriteEntryLayout.map { $0.span }
            let (rects, _) = Self.essentialsLayout(spans: spans, gridWidth: frame.width)
            let cx = cursorX ?? frame.midX
            let rowPitch = Self.favoriteCellHeight + Self.favoriteCellSpacing
            func rowOf(_ localY: CGFloat) -> Int {
                max(0, Int(((localY - Self.favoriteGridPadding) / rowPitch).rounded(.down)))
            }
            let cursorRow = rowOf(y - frame.minY)
            var entryInsert = rects.count
            for (i, r) in rects.enumerated() {
                let entryRow = rowOf(r.midY)
                let centerX = frame.minX + r.midX
                if entryRow > cursorRow || (entryRow == cursorRow && cx < centerX) {
                    entryInsert = i
                    break
                }
            }
            var note = 0
            for i in 0..<entryInsert { note += favoriteEntryLayout[i].noteCount }
            newIndex = min(max(0, note), max(0, effective - 1))
        } else if target == .favorite, frame.width > 0 {
            // Fallback (layout not yet published): uniform-cell 2D hit-test.
            let pad = Self.favoriteGridPadding
            let xInGrid = max(0, (cursorX ?? frame.midX) - frame.minX - pad)
            let yInGrid = max(0, y - frame.minY - pad)
            let N = Self.favoriteColumnCount(for: effective)
            let cellW = Self.favoriteCellWidth(gridWidth: frame.width, count: effective)
            let col = min(N - 1, max(0, Int(xInGrid / (cellW + Self.favoriteCellSpacing))))
            let row = max(0, Int(yInGrid / (Self.favoriteCellHeight + Self.favoriteCellSpacing)))
            let proposed = row * N + col
            newIndex = min(max(0, proposed), max(0, effective - 1))
        } else {
            let restInfo = tierFolderRows[target] ?? []
            // Notes use the indent model in ANY list tier (so dragging a note
            // from Notes into a Pinned folder previews + nests). Folders use it
            // only within their own tier (cross-tier folders land top-level).
            let useIndent = !restInfo.isEmpty
                && (draggedNoteID != nil || draggedFolderID != nil)
            if useIndent {
                // Indent / horizontal model (file-tree style). VERTICAL (ghost
                // center) picks the insertion gap; HORIZONTAL (cursor delta from
                // grab) picks the depth, clamped to the legal [minDepth,maxDepth]
                // for that gap so the tree stays valid. `restInfo` is the tier
                // MINUS the dragged row, so positions are fixed (no feedback).
                let ghostY = sourceRowCenter.y + translation.height
                let m = restInfo.count
                // Nearest gap to the ghost (a note inserted at gap g renders at
                // index g → center = minY + g*rowHeight + rowHeight/2).
                let g = min(max(0, Int(((ghostY - frame.minY - rowHeight / 2) / rowHeight).rounded())), m)
                let prev = g > 0 ? restInfo[g - 1] : nil
                let next = g < m ? restInfo[g] : nil
                let minD = next?.depth ?? 0
                var maxD = prev == nil ? 0 : (prev!.isFolder ? prev!.depth + 1 : prev!.depth)
                maxD = max(minD, min(maxD, draggedDepthCap))
                let dx = (cursorX ?? dragStartCursorX) - dragStartCursorX
                let steps = Int((dx / 22).rounded())
                // Within-tier: steer relative to the row's own depth. Cross-tier:
                // arrives at top level (0), drag right to nest into a dest folder.
                let baseDepth = (target == sourceTier) ? dragSourceDepth : 0
                let d = max(minD, min(maxD, baseDepth + steps))
                newIndex = g
                resolvedDepth = d
            } else {
                let yInTier = max(0, y - frame.minY)
                let raw = Int((yInTier / rowHeight).rounded(.down))
                newIndex = min(max(0, raw), max(0, effective - 1))
            }
        }

        let depthChanged = draggedRowDepth != resolvedDepth
        if currentTier != target || currentIndex != newIndex || depthChanged {
            let tierChanged = currentTier != target
            currentTier = target
            currentIndex = newIndex
            // The resolver drives the ghost indent (0 for the continuous path).
            // The PARENT folder (membership) is computed view-side from
            // `currentIndex` + this depth.
            draggedRowDepth = resolvedDepth
            // Trackpad detent when the drop target moves (discrete — fires once
            // per row/folder/depth crossing, not per frame). Heavier across tiers.
            playDragDetent(tierChanged: tierChanged)
        }
    }

    /// Single-tick haptic for crossing into a new drop slot. `.levelChange` is
    /// the FIRMEST of macOS's three patterns; `.alignment` the lightest — this
    /// is the maximum contrast a single tick can have, since AppKit exposes no
    /// haptic intensity (and Core Haptics doesn't drive the Mac trackpad). Fired
    /// `.now` for immediacy. Only fires on capable trackpads with haptics on.
    private func playDragDetent(tierChanged: Bool) {
        #if canImport(AppKit)
        let pattern: NSHapticFeedbackManager.FeedbackPattern = tierChanged ? .levelChange : .alignment
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        #endif
    }

    /// Safety net for the drag engine: each commit defers `reset()` inside a
    /// `withAnimation { … } completion:` closure, and that completion can fail
    /// to fire if the dragged row's identity changes mid-settle (e.g. a split
    /// forms). The session would then stay `isActive` and jam every later drag.
    /// A beat after release, if the SAME drag is still active, force-reset.
    func scheduleWatchdog(for id: UUID?, generation: Int) {
        guard let id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, (self.draggedNoteID == id || self.draggedFolderID == id),
                  self.dragGeneration == generation else { return }
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { self.reset() }
        }
    }

    func reset() {
        draggedNoteID = nil
        draggedNoteIDs = []
        sourceTier = nil
        sourceIndex = 0
        sourceRowCenter = .zero
        cursorY = nil
        cursorX = nil
        translation = .zero
        currentTier = nil
        currentIndex = 0
        frozenTileWidth = nil
        frozenAsTile = nil
        draggedTileWidth = nil
        draggedRowDepth = 0
        draggedFolderID = nil
        nestTargetFolderID = nil
        dropIndicatorCenter = nil
        isSettling = false
        sourceSpaceID = nil
        editorDropSide = nil
        cursorOverEditor = false
        // dropSpace is left as-is (it tracks the active column, re-set on each
        // active-space change); it's only consulted during a live drag.
        // NOTE: frozenFavoriteColumnCount is intentionally NOT cleared
        // here — it must survive `reset()` (which fires before @Query
        // catches up) and is released by the notes.count onChange once
        // the live layout matches. It's re-set fresh on each release.
        refreshFavoriteDropZoneVisibility()
    }
}

/// Active-space header (Arc-style): `[icon] name … ⋯`. Hover reveals the ⋯
/// menu; right-click opens the same menu. Rename is inline (header becomes a
/// text field + Done). This is a presentation view — the editing STATE, the
/// menu items, and the icon/theme popovers live in `MacSpaceNotesColumn` so
/// the empty-sidebar right-click and the header share one source of truth.
private struct MacSpaceHeaderView<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let space: Space
    @Binding var isRenaming: Bool
    @Binding var draftName: String
    let onCommitRename: () -> Void
    /// A dragged tab is targeting the top level (no folder) → the space name
    /// lights up like hover, to show "this is where it'll land."
    var isDropTarget: Bool = false
    @ViewBuilder var menuItems: () -> MenuItems

    @State private var isHovering = false
    @FocusState private var renameFocused: Bool

    private var spaceHeaderFill: Color {
        if isDropTarget { return Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12) }
        if isHovering && !isRenaming { return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 8) {
            MacSpaceIcon.view(space.emoji, size: 15)
                .foregroundStyle(.primary.opacity(0.82))

            if isRenaming {
                TextField("Space Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .focused($renameFocused)
                    .onSubmit(onCommitRename)
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { onCommitRename() }
                    }
                Spacer(minLength: 0)
                Button("Done", action: onCommitRename)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.6))
            } else {
                Text(space.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Menu {
                    menuItems()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary.opacity(0.6))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(spaceHeaderFill)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu { if !isRenaming { menuItems() } }
        .onChange(of: isRenaming) { _, now in
            if now { renameFocused = true }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(CrossTierDragSession.rowShuffle, value: isDropTarget)
    }
}

private struct MacSidebarGroup: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let space: Space
    let allNotes: [Note] // unfiltered — needed to look up cross-tier sources
    let notes: [Note]
    let folders: [Folder]
    let selectedNoteID: UUID?
    let selectNote: (Note) -> Void
    let tier: NoteTier
    let session: CrossTierDragSession
    let selection: NoteSelectionModel
    let performBatch: (NoteBatchAction) -> Void
    let openInSplit: (Note) -> Void
    let addToSplit: (Note) -> Void
    var onSplitDrop: (Note, SplitDropSide) -> Void = { _, _ in }
    /// Split pairs hosted by this space. Each pair carries the row ID that
    /// renders its combined pill.
    var splitPairs: [MacSidebarSplitPair] = []
    var pendingSplitPrimaryID: UUID?
    var dissolveSplit: (UUID, NoteTier, Space) -> Void = { _, _, _ in }
    var cancelPendingSplit: () -> Void = { }
    @Binding var renamingFolderID: UUID?
    var isActiveSpace: Bool = true
    var columnWidth: CGFloat = 300

    /// This tier's displayed note order — the ⇧-range domain handed to rows.
    private var orderedNoteIDs: [UUID] { notes.map(\.id) }

    private let rowHeight = CrossTierDragSession.noteRowHeight

    // Latest measured frame for this group, in "notes-column" coords.
    // Cached locally so we can push it into `session.tierFrames[tier]`
    // when this column becomes the active one (even when its layout
    // didn't change — e.g., the very first time it appears active).
    @State private var lastMeasuredFrame: CGRect = .zero
    // Spring-load: dwell timer that opens a collapsed folder the ghost hovers.
    @State private var springTask: Task<Void, Never>? = nil

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private var isSourceTier: Bool { session.sourceTier == tier }
    private var isCurrentTier: Bool { session.currentTier == tier }

    var body: some View {
        let rows = displayedFlatRows
        return LazyVStack(spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                flatRowView(row, at: index)
            }
            // Gate on `isActive`: during a drag this animates the live
            // reshuffle, but `.animation(value:)` is transaction-independent
            // and would re-fire when the session clears on release — animating
            // the dragged row's opacity reveal as the ghost hands off (the
            // subtle residual movement). With the param nil while inactive,
            // the settle frame is instant.
            .animation(session.isActive ? CrossTierDragSession.rowShuffle : nil,
                       value: dragSignature)

            tierEndDropZone
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            // Cache the frame regardless of active state so we can push
            // it later when this column becomes active.
            lastMeasuredFrame = newFrame
            // Only the active (centered) column reports tier frames so
            // off-screen columns don't overwrite the live geometry.
            if isActiveSpace { session.tierFrames[tier] = newFrame }
        }
        .onAppear {
            if isActiveSpace {
                try? FolderService(context: modelContext).normalizeTierOrder(tier: tier, in: space)
                session.noteCountsByTier[tier] = flatRows.count
                session.dropSpace = space
                // If we already have a measured frame, push it now —
                // covers the case where geometry was reported before
                // `isActiveSpace` flipped true.
                if lastMeasuredFrame.height > 0 {
                    session.tierFrames[tier] = lastMeasuredFrame
                }
            }
        }
        .onChange(of: flatRows.count) { _, newValue in
            if isActiveSpace { session.noteCountsByTier[tier] = newValue }
        }
        .onAppear { publishTierRows() }
        .onChange(of: tierRowsKey) { _, _ in publishTierRows() }
        .onChange(of: isActiveSpace) { _, newValue in
            // When this column becomes the active one (after a swipe, edge
            // auto-switch, or the first time `selectedSpaceID` resolves),
            // refresh its frames/counts and mark it as the live drop space.
            if newValue {
                try? FolderService(context: modelContext).normalizeTierOrder(tier: tier, in: space)
                session.noteCountsByTier[tier] = flatRows.count
                session.dropSpace = space
                publishTierRows()
                if lastMeasuredFrame.height > 0 {
                    session.tierFrames[tier] = lastMeasuredFrame
                }
            }
        }
        // Spring-load: dwell ~0.4s over a collapsed folder → open it so you can
        // see/drop inside. The target is whatever folder the ghost is nesting
        // into; a change restarts the timer.
        .onChange(of: session.nestTargetFolderID) { _, newID in
            handleSpringLoad(newID)
        }
        // Drag end → cancel any pending open + collapse back folders nothing
        // landed in.
        .onChange(of: session.isActive) { _, active in
            if !active {
                springTask?.cancel(); springTask = nil
                drainAutoExpanded()
            }
        }
    }

    /// Look up a folder by id, but only if it lives in THIS group's tier+space —
    /// so each tier's group handles only its own spring-load / collapse-back.
    private func folderInThisTier(_ id: UUID) -> Folder? {
        guard let f = try? modelContext.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first,
              f.tier == tier, f.space?.id == space.id else { return nil }
        return f
    }

    /// Start (or restart) the dwell timer toward `targetID`. Fires only if the
    /// target is a collapsed folder in this tier and the ghost stays on it.
    private func handleSpringLoad(_ targetID: UUID?) {
        springTask?.cancel(); springTask = nil
        guard session.isActive, isActiveSpace, let fid = targetID,
              let folder = folderInThisTier(fid), folder.isCollapsed else { return }
        springTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, session.isActive,
                  session.nestTargetFolderID == fid, folder.isCollapsed else { return }
            session.autoExpandedDuringDrag[fid] = (folder.notes ?? []).count
            withAnimation(CrossTierDragSession.folderToggle) {
                try? FolderService(context: modelContext).setCollapsed(folder, false)
            }
            // Republish so the resolver sees the freshly revealed member rows.
            publishTierRows()
        }
    }

    /// On drag end, collapse back each spring-loaded folder in this tier that
    /// nothing was dropped into (its member count didn't grow).
    private func drainAutoExpanded() {
        guard !session.autoExpandedDuringDrag.isEmpty else { return }
        let svc = FolderService(context: modelContext)
        for (fid, priorCount) in session.autoExpandedDuringDrag {   // snapshot copy
            guard let folder = folderInThisTier(fid) else { continue }
            if (folder.notes ?? []).count <= priorCount {
                withAnimation(CrossTierDragSession.folderToggle) {
                    try? svc.setCollapsed(folder, true)
                }
            }
            session.autoExpandedDuringDrag.removeValue(forKey: fid)
        }
    }

    /// Publish this tier's resting rows (minus any dragged items that belong to
    /// it) so the hit-test/commit can resolve drops in EITHER tier — including a
    /// cross-tier folder move landing positionally in the destination.
    private func publishTierRows() {
        guard isActiveSpace else { return }
        var dragged = Set(session.draggedNoteIDs)
        if let fid = session.draggedFolderID { dragged.insert(fid) }
        session.tierFolderRows[tier] = flatRows
            .filter { !dragged.contains($0.rowID) && !$0.isEmpty }
            .map { (isFolder: $0.isFolder,
                    folderID: $0.isFolder ? $0.rowID : $0.folderID,
                    depth: $0.depth) }
    }

    private var tierRowsKey: String {
        var dragged = session.draggedNoteIDs.map(\.uuidString)
        if let fid = session.draggedFolderID { dragged.append(fid.uuidString) }
        let rows = flatRows.map { ($0.isFolder ? "F" : "n") + $0.rowID.uuidString.prefix(4) }.joined()
        return dragged.joined() + "|" + rows
    }

    /// Single value that captures any state change that should re-trigger
    /// the row-shuffle animation. Used as the `value:` for `.animation(...)`.
    private var dragSignature: String {
        let st = session.sourceTier?.rawValue ?? "_"
        let ct = session.currentTier?.rawValue ?? "_"
        // Include depth + nest target so the indent indicator animates as the
        // horizontal/depth resolution changes.
        return "\(st)|\(session.sourceIndex)|\(ct)|\(session.currentIndex)|\(session.draggedRowDepth)|\(session.nestTargetFolderID?.uuidString ?? "_")"
    }

    private func tabPresentationID(for note: Note) -> String {
        if let splitPair = splitPairs.first(where: { $0.anchorID == note.id }) {
            return "\(note.id.uuidString)|split|\(splitPair.primary.id.uuidString)|\(splitPair.secondary.id.uuidString)"
        }
        if note.id == pendingSplitPrimaryID {
            return "\(note.id.uuidString)|pending"
        }
        return "\(note.id.uuidString)|single"
    }

    // MARK: - Flat entry list (folder headers + notes interleaved)

    private static let folderIndentStep: CGFloat = 14

    struct SidebarRow: Identifiable {
        // `.empty` is a render-only "this folder has no notes" hint shown at rest
        // inside an expanded empty folder; it's stripped during drag and excluded
        // from the resolver so it never shifts drop indices.
        enum Kind { case folderHeader(Folder); case note(Note); case empty(folderID: UUID) }
        let kind: Kind
        let depth: Int
        let folderID: UUID?   // membership of a note row (nil = standalone)
        /// Cross-tier folder drag: placeholder row in the destination tier that
        /// renders the landing indicator (drop bar or folder highlight gap).
        var isCrossTierPlaceholder: Bool = false
        var crossTierFolderID: UUID? = nil
        var isEmpty: Bool { if case .empty = kind { return true }; return false }
        var rowID: UUID {
            if isCrossTierPlaceholder, let fid = crossTierFolderID { return fid }
            switch kind {
            case .folderHeader(let f): return f.id
            case .note(let n): return n.id
            case .empty(let fid): return fid
            }
        }
        var isFolder: Bool { if case .folderHeader = kind { return true }; return false }
        var id: String {
            if isCrossTierPlaceholder, let fid = crossTierFolderID { return "xfolder-\(fid.uuidString)" }
            switch kind {
            case .folderHeader(let f): return "folder-\(f.id.uuidString)"
            case .note(let n): return "note-\(n.id.uuidString)"
            case .empty(let fid): return "empty-\(fid.uuidString)"
            }
        }
    }

    /// The tier rendered as ONE flat list: top-level folders + standalone notes
    /// interleaved by their shared order counter, each expanded folder followed
    /// by its child folders + member notes (indented). Every row is the same
    /// 35pt pitch so the uniform-row drag engine indexes it directly.
    var flatRows: [SidebarRow] {
        enum Top { case folder(Folder); case note(Note) }
        func createdAt(_ t: Top) -> Date {
            switch t { case .folder(let f): return f.createdAt; case .note(let n): return n.createdAt }
        }
        func order(_ t: Top) -> Int {
            switch t { case .folder(let f): return f.sortIndex; case .note(let n): return n.manualSortIndex ?? Int.max }
        }
        var top: [Top] = folders.map { .folder($0) } + notes.map { .note($0) }
        top.sort { order($0) != order($1) ? order($0) < order($1) : createdAt($0) < createdAt($1) }

        var rows: [SidebarRow] = []
        for item in top {
            switch item {
            case .note(let n):
                rows.append(SidebarRow(kind: .note(n), depth: 0, folderID: nil))
            case .folder(let f):
                rows.append(SidebarRow(kind: .folderHeader(f), depth: 0, folderID: f.parent?.id))
                if !f.isCollapsed { appendFolderRows(f, depth: 1, into: &rows) }
            }
        }
        return rows
    }

    private func appendFolderRows(_ f: Folder, depth: Int, into rows: inout [SidebarRow]) {
        // Child folders + member notes INTERLEAVE by one shared order, so a note
        // can sit above/below a sub-folder within the same parent.
        enum Item { case folder(Folder); case note(Note) }
        func order(_ i: Item) -> Int {
            switch i { case .folder(let c): return c.sortIndex; case .note(let n): return n.manualSortIndex ?? Int.max }
        }
        func created(_ i: Item) -> Date {
            switch i { case .folder(let c): return c.createdAt; case .note(let n): return n.createdAt }
        }
        var items: [Item] = (f.children ?? []).map { .folder($0) } + (f.notes ?? []).map { .note($0) }
        items.sort { order($0) != order($1) ? order($0) < order($1) : created($0) < created($1) }
        // Expanded but empty → a faint "no notes" hint so it reads as an open
        // container (and a visible drop target). Render-only; see SidebarRow.empty.
        if items.isEmpty {
            rows.append(SidebarRow(kind: .empty(folderID: f.id), depth: depth, folderID: f.id))
            return
        }
        for item in items {
            switch item {
            case .note(let n):
                rows.append(SidebarRow(kind: .note(n), depth: depth, folderID: f.id))
            case .folder(let c):
                rows.append(SidebarRow(kind: .folderHeader(c), depth: depth, folderID: f.id))
                if !c.isCollapsed { appendFolderRows(c, depth: depth + 1, into: &rows) }
            }
        }
    }

    /// A within-tier single-note drag renders via list REORDER (the dragged
    /// row is repositioned to the resolved slot, invisible — it IS the gap), not
    /// via per-row offsets. This keeps resting positions == on-screen positions,
    /// so the folder hit-test never drifts.
    private var usesReorderRender: Bool {
        guard session.isActive else { return false }
        guard session.draggedNoteID != nil || session.draggedFolderID != nil else { return false }
        // Source tier (within-tier reorder) OR destination tier of a cross-tier
        // folder drag (show the landing gap in the destination list).
        return session.currentTier == tier
    }

    /// The within-tier dragged row ids (one note/folder, or the whole multi
    /// selection) in flat order.
    private var draggedRowIDs: [UUID] {
        if session.isMulti { return session.draggedNoteIDs }
        if let id = session.draggedNoteID ?? session.draggedFolderID { return [id] }
        return []
    }

    /// The rendered rows: normally `flatRows`, but during a drag the dragged
    /// row(s) are lifted and re-inserted at the resolved slot so the render ==
    /// the eventual commit. For cross-tier folder drags the dragged folder isn't
    /// in this tier's rows; insert the drop indicator only.
    private var displayedFlatRows: [SidebarRow] {
        guard usesReorderRender else { return flatRows }
        let ids = Set(draggedRowIDs)
        guard !ids.isEmpty else { return flatRows }
        // Drop the at-rest "empty folder" hints during a drag: they aren't in the
        // resolver's published rows, so leaving them in would shift the render's
        // insertion index out of sync with `currentIndex`.
        var rows = flatRows.filter { !$0.isEmpty }
        let movers = rows.filter { ids.contains($0.rowID) }

        // Cross-tier folder drag: the folder lives in another tier's rows.
        // Insert a placeholder indicator at the resolved slot so the destination
        // shows the landing gap + folder highlight when nesting.
        if movers.isEmpty, let fid = session.draggedFolderID {
            let c = min(max(0, session.currentIndex), rows.count)
            // Borrow any note's kind to form a valid row; the placeholder flag
            // makes flatRowView render it as a drop indicator bar, not a note.
            let dummyKind: SidebarRow.Kind
            if let first = rows.first { dummyKind = first.kind }
            else { return rows }    // empty tier, no gap needed (tierEndExpansion covers it)
            let placeholder = SidebarRow(
                kind: dummyKind,
                depth: session.draggedRowDepth,
                folderID: session.nestTargetFolderID,
                isCrossTierPlaceholder: true,
                crossTierFolderID: fid
            )
            rows.insert(placeholder, at: c)
            return rows
        }

        rows.removeAll { ids.contains($0.rowID) }
        let c = min(max(0, session.currentIndex), rows.count)
        let rekeyed = movers.map {
            SidebarRow(kind: $0.kind, depth: session.draggedRowDepth,
                       folderID: session.nestTargetFolderID)
        }
        rows.insert(contentsOf: rekeyed, at: c)
        return rows
    }

    @ViewBuilder
    private func flatRowView(_ row: SidebarRow, at index: Int) -> some View {
        if row.isCrossTierPlaceholder {
            // Cross-tier folder drag: drop indicator bar in the destination tier.
            dropIndicatorRow(depth: row.depth).frame(height: nil)
        } else if case .empty = row.kind {
            emptyFolderHintRow(depth: row.depth)
        } else {
        switch row.kind {
        case .folderHeader(let folder):
            let isDraggedFolder = session.draggedFolderID == folder.id
            if isDraggedFolder && usesReorderRender {
                // The dragged folder collapses to the floating pill; its slot is
                // the indent drop indicator at the resolved depth.
                dropIndicatorRow(depth: row.depth)
                    .simultaneousGesture(folderDragGesture(for: folder, at: index))
            } else {
                MacFolderRow(
                    folder: folder, space: space, selectedNoteID: selectedNoteID,
                    selectNote: selectNote, selection: selection, performBatch: performBatch,
                    openInSplit: openInSplit, addToSplit: addToSplit, session: session,
                    renamingFolderID: $renamingFolderID, depth: row.depth
                )
                .opacity(isDraggedFolder ? 0 : 1)
                .offset(y: usesReorderRender ? 0 : offset(forIndex: index))
                .simultaneousGesture(folderDragGesture(for: folder, at: index))
            }
        case .note(let note):
            let isSource = session.isMulti
                ? session.isDragged(note.id)
                : (session.draggedNoteID == note.id && isSourceTier)
            // NOTE: do NOT collapse the source row while nesting — removing a
            // row mid-aim shifts the list and the folder slips out from under
            // the cursor, oscillating the hit-test. Keep its slot (opacity 0).
            let collapse = session.isMulti
                ? isSource
                : (isSource && session.isCrossTier)
            if isSource && usesReorderRender && session.isMulti {
                // Multi-drag: each dragged row is an invisible full-height
                // placeholder (forms the block gap; the stack ghost shows them).
                noteRowBody(note)
                    .id(tabPresentationID(for: note))
                    .padding(.leading, CGFloat(row.depth) * Self.folderIndentStep)
                    .opacity(0)
                    .simultaneousGesture(liveDragGesture(for: note, at: index))
            } else if isSource && usesReorderRender {
                // Single drag: a thin insertion indicator at the resolved depth
                // (the floating ghost shows the content).
                dropIndicatorRow(depth: row.depth)
                    .frame(height: nil)
                    .simultaneousGesture(liveDragGesture(for: note, at: index))
            } else {
                noteRowBody(note)
                    .id(tabPresentationID(for: note))
                    .padding(.leading, CGFloat(row.depth) * Self.folderIndentStep)
                    .opacity(isSource ? 0 : 1)
                    .frame(height: collapse ? 0 : nil)
                    .offset(y: usesReorderRender ? 0 : offset(forIndex: index))
                    .simultaneousGesture(liveDragGesture(for: note, at: index))
            }
        case .empty:
            // Handled by the outer branch; unreachable, here for exhaustiveness.
            EmptyView()
        }
        } // end else (not cross-tier placeholder)
    }

    /// Faint "no notes" line shown inside an expanded empty folder. Same 32pt
    /// content pitch as a note row so the uniform-row geometry is preserved.
    private func emptyFolderHintRow(depth: Int) -> some View {
        HStack(spacing: 0) {
            Text("Empty")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary.opacity(0.55))
            Spacer(minLength: 0)
        }
        .frame(height: CrossTierDragSession.noteRowContentHeight)
        .padding(.leading, CGFloat(depth) * Self.folderIndentStep + 12)
        .padding(.trailing, 10)
        .allowsHitTesting(false)
    }

    /// A thin insertion bar at `depth`'s indent — the visible placeholder for
    /// the dragged row while reordering (shows where + how deep it'll land).
    private func dropIndicatorRow(depth: Int) -> some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(spaceColor)
                .frame(height: 3)
        }
        .frame(height: CrossTierDragSession.noteRowContentHeight)
        .padding(.leading, CGFloat(depth) * Self.folderIndentStep + 10)
        .padding(.trailing, 10)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { f in
            session.dropIndicatorCenter = CGPoint(x: f.midX, y: f.midY)
        }
    }

    @ViewBuilder
    private func noteRowBody(_ note: Note) -> some View {
        if let splitPair = splitPairs.first(where: { $0.anchorID == note.id }) {
            MacSplitTabRow(
                primary: splitPair.primary,
                secondary: splitPair.secondary,
                onSelect: { selectNote(splitPair.primary) },
                onSeparate: { dissolveSplit(splitPair.primary.id, tier, space) },
                isFocused: selectedNoteID == splitPair.primary.id
                    || selectedNoteID == splitPair.secondary.id,
                tint: spaceColor
            )
        } else if note.id == pendingSplitPrimaryID {
            MacSplitTabRow(
                primary: note,
                secondary: nil,
                onSelect: { selectNote(note) },
                isFocused: true,
                onCancelPending: cancelPendingSplit,
                tint: spaceColor
            )
        } else {
            MacNoteRow(
                note: note,
                space: space,
                isSelected: selectedNoteID == note.id,
                showDropIndicator: false,
                indicatorColor: spaceColor,
                selectNote: selectNote,
                selection: selection,
                performBatch: performBatch,
                openInSplit: openInSplit,
                addToSplit: addToSplit,
                orderedIDs: orderedNoteIDs
            )
        }
    }

    /// Unified vertical offset for the row at `index` in this tier.
    ///
    /// Source tier within-tier reorder: shift siblings to open a gap at
    /// `currentIndex` (existing within-tier behavior).
    ///
    /// Source tier cross-tier mode: source row collapses out of layout via
    /// `.frame(height: 0)`, so siblings flow up naturally. Offsets here are 0.
    ///
    /// Destination tier (different from source): push every row at
    /// `currentIndex` or later down by `rowHeight` so the dragged row has a
    /// visible landing slot — identical to the within-tier gap.
    private func tierRank(_ tier: NoteTier) -> Int {
        switch tier {
        case .pinned: return 0
        case .random: return 1
        case .favorite: return 2
        case .archived: return 3
        }
    }

    /// Multi-drag offset: dragged rows are collapsed (return 0); in the
    /// destination tier, push the visible rows at/after the drop slot down by
    /// the whole group's height so the N-row gap opens. Visible index is the
    /// count of non-dragged rows before `i` (collapsed rows take no space, so
    /// the cursor-derived `currentIndex` is already in visible terms).
    private func multiOffset(forIndex i: Int) -> CGFloat {
        let rows = flatRows
        guard i < rows.count else { return 0 }
        if session.isDragged(rows[i].rowID) { return 0 }
        guard isCurrentTier else { return 0 }
        var visibleIndex = 0
        for j in 0..<i where !session.isDragged(rows[j].rowID) { visibleIndex += 1 }
        // Gap opens so the grabbed row lands at currentIndex (block top is
        // currentIndex - primaryGroupIndex), matching the floating stack.
        let gapStart = max(0, session.currentIndex - session.primaryGroupIndex)
        return visibleIndex >= gapStart
            ? CGFloat(session.draggedCount) * rowHeight
            : 0
    }

    private func offset(forIndex i: Int) -> CGFloat {
        guard session.isActive else { return 0 }
        if session.isMulti { return multiOffset(forIndex: i) }

        // Post-commit short-circuit: the dragged note is now at its target
        // slot in this tier's flat list (true for within-tier reorder once
        // the order update lands, and for cross-tier destinations once the
        // tier change lands). Return 0 for every row so nothing visibly
        // shifts before `session.reset()`.
        if let id = session.draggedNoteID,
           let idx = flatRows.firstIndex(where: { $0.rowID == id }),
           idx == session.currentIndex {
            return 0
        }

        if isSourceTier {
            if i == session.sourceIndex { return 0 } // source row, will be hidden
            if session.isCrossTier {
                // Source row is collapsed (height 0) but its 3pt
                // LazyVStack spacing slot is still in layout. After commit
                // the row is gone entirely and that spacing collapses,
                // pulling every row below source up by 3pt — visible jitter
                // at release. Pre-shift those rows by -3 during the drag
                // so they're already at their post-commit positions.
                if let id = session.draggedNoteID,
                   flatRows.contains(where: { $0.rowID == id }),
                   i > session.sourceIndex {
                    return -3
                }
                return 0
            }
            // Within-tier reshuffle
            let s = session.sourceIndex
            let c = session.currentIndex
            if c > s, i > s, i <= c { return -rowHeight }
            if c < s, i >= c, i < s { return rowHeight }
            return 0
        }

        if isCurrentTier {
            return i >= session.currentIndex ? rowHeight : 0
        }

        return 0
    }

    private func liveDragGesture(for note: Note, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedNoteID == nil {
                    session.dragGeneration &+= 1
                    session.draggedNoteID = note.id
                    // Multi-drag when the grabbed row is part of an active
                    // multi-selection: drag the whole set in display order
                    // (Pinned before Random, then manual order). Otherwise a
                    // normal single drag.
                    if selection.contains(note.id), selection.count > 1 {
                        session.draggedNoteIDs = allNotes
                            .filter { selection.contains($0.id) }
                            .sorted { a, b in
                                let ra = tierRank(a.tier), rb = tierRank(b.tier)
                                return ra == rb ? noteSort(a, b) : ra < rb
                            }
                            .map(\.id)
                    } else {
                        session.draggedNoteIDs = [note.id]
                    }
                    session.sourceSpaceID = space.id
                    session.sourceTier = tier
                    session.sourceIndex = index
                    session.currentTier = tier
                    session.currentIndex = index
                    // Compute the source row's natural center from this
                    // tier's frame. If `.onGeometryChange` hasn't fired
                    // yet (first drag after launch), `tierFrame` is
                    // `.zero` — fall back to the cursor's start position
                    // so the floating ghost still anchors near the row
                    // instead of jumping to (0, 0).
                    let tierFrame = session.tierFrames[tier] ?? .zero
                    if tierFrame.height > 0 {
                        session.sourceRowCenter = CGPoint(
                            x: tierFrame.midX,
                            // Center on the row's visible content (32pt), not
                            // half the pitch (35pt) — the 3pt gap sits below
                            // the row, so +17.5 lands 1.5pt low and shows as a
                            // subtle snap on release.
                            y: tierFrame.minY + CGFloat(index) * rowHeight
                                + CrossTierDragSession.noteRowContentHeight / 2
                        )
                    } else {
                        // First drag before `.onGeometryChange` has fired.
                        // Use the active column's known midX so the ghost
                        // is horizontally centered like a normal row,
                        // regardless of where exactly the user clicked.
                        session.sourceRowCenter = CGPoint(
                            x: columnWidth / 2,
                            y: value.startLocation.y
                        )
                    }
                    session.noteCountsByTier[tier] = flatRows.count
                    // Grab anchors for the horizontal/indent steering.
                    session.dragStartCursorX = value.location.x
                    session.dragSourceDepth = flatRows.first { $0.rowID == note.id }?.depth ?? 0
                    // A note can be one level deeper than the deepest folder.
                    session.draggedDepthCap = Folder.maxDepth + 1
                    // Publish the RESTING rows (this tier minus ALL dragged
                    // notes) so the hit-test resolves a stable drop slot.
                    let dragged = Set(session.draggedNoteIDs)
                    session.tierFolderRows[tier] = flatRows
                        .filter { !dragged.contains($0.rowID) }
                        .map { (isFolder: $0.isFolder,
                                folderID: $0.isFolder ? $0.rowID : $0.folderID,
                                depth: $0.depth) }
                }
                session.updateDrag(location: value.location, translation: value.translation, rowHeight: rowHeight)
                // Resolve the PARENT folder for the current (gap, depth) — in
                // ANY list tier, so a cross-tier drop into a folder highlights +
                // nests too.
                if session.draggedFolderID == nil,
                   let ct = session.currentTier, ct == .pinned || ct == .random {
                    session.nestTargetFolderID = resolveParentFolderID(
                        gap: session.currentIndex, depth: session.draggedRowDepth)
                } else {
                    session.nestTargetFolderID = nil
                }
            }
            .onEnded { _ in
                let stuckID = session.draggedNoteID
                let gen = session.dragGeneration
                commitDrag()
                session.scheduleWatchdog(for: stuckID, generation: gen)
            }
    }


    /// Drag a top-level folder header to reorder it among the tier's top-level
    /// items. The folder collapses to a single row for the drag; its contents
    /// follow it to the new position (they render after the header).
    private func folderDragGesture(for folder: Folder, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedFolderID == nil && session.draggedNoteID == nil {
                    let folderDepth = flatRows.first { $0.rowID == folder.id }?.depth ?? 0
                    session.dragGeneration &+= 1
                    session.draggedFolderID = folder.id
                    session.draggedFolderWasExpanded = !folder.isCollapsed
                    session.draggedNoteIDs = []
                    session.sourceSpaceID = space.id
                    session.sourceTier = tier
                    session.sourceIndex = index
                    session.currentTier = tier
                    session.currentIndex = index
                    session.dragStartCursorX = value.location.x
                    session.dragSourceDepth = folderDepth
                    // A folder may descend only so far that its DEEPEST child
                    // still fits under Folder.maxDepth.
                    session.draggedDepthCap = max(0, Folder.maxDepth - folderSubtreeHeight(folder))
                    let tierFrame = session.tierFrames[tier] ?? .zero
                    session.sourceRowCenter = tierFrame.height > 0
                        ? CGPoint(x: tierFrame.midX,
                                  y: tierFrame.minY + CGFloat(index) * rowHeight
                                     + CrossTierDragSession.noteRowContentHeight / 2)
                        : CGPoint(x: columnWidth / 2, y: value.startLocation.y)
                    // Collapse the folder (real `isCollapsed`) so it + its subtree
                    // lift as a single clean row; publish the resting rows minus
                    // this folder header (descendants are now folded away).
                    if !folder.isCollapsed {
                        withAnimation(.smooth(duration: 0.18)) {
                            try? FolderService(context: modelContext).setCollapsed(folder, true)
                        }
                    }
                    session.noteCountsByTier[tier] = flatRows.count
                    session.tierFolderRows[tier] = flatRows
                        .filter { $0.rowID != folder.id }
                        .map { (isFolder: $0.isFolder,
                                folderID: $0.isFolder ? $0.rowID : $0.folderID,
                                depth: $0.depth) }
                }
                session.updateDrag(location: value.location, translation: value.translation, rowHeight: rowHeight)
                // Resolve the nest target in ANY list tier (cross-tier folder drag
                // can target a folder in the destination too, depth > 0).
                if let ct = session.currentTier, ct == .pinned || ct == .random {
                    session.nestTargetFolderID = resolveParentFolderID(
                        gap: session.currentIndex, depth: session.draggedRowDepth)
                } else {
                    session.nestTargetFolderID = nil
                }
            }
            .onEnded { _ in
                let stuckID = session.draggedFolderID
                let gen = session.dragGeneration
                commitDrag()
                session.scheduleWatchdog(for: stuckID, generation: gen)
            }
    }

    /// Deepest nesting below `folder` (0 = no sub-folders).
    private func folderSubtreeHeight(_ folder: Folder) -> Int {
        let children = folder.children ?? []
        guard !children.isEmpty else { return 0 }
        return 1 + (children.map { folderSubtreeHeight($0) }.max() ?? 0)
    }

    /// Parent folder id for the indent-model drop at (`gap`, `depth`) — the
    /// ancestor folder at `depth-1` on the previous row's chain, or nil for
    /// top-level. `gap` is an index into the resting (dragged-excluded) rows.
    private func resolveParentFolderID(gap: Int, depth d: Int) -> UUID? {
        guard d > 0, let ct = session.currentTier else { return nil }
        // Resolve against the RESOLVED tier's published rows so it works for a
        // cross-tier drop too (folder header `folderID` = its own id there).
        let rows = session.tierFolderRows[ct] ?? []
        var i = min(gap, rows.count) - 1
        while i >= 0 {
            let r = rows[i]
            if r.isFolder && r.depth == d - 1 { return r.folderID }
            if r.depth < d - 1 { break }   // exited to a shallower container
            i -= 1
        }
        return nil
    }

    /// Unified release path: animate the floating ghost (via
    /// `session.translation`) to sit exactly over the destination slot, then
    /// commit the data and clear the session non-animated. Identical for
    /// within-tier reorder and cross-tier promotion/demotion.
    private func commitDrag() {
        if let fid = session.draggedFolderID { commitFolderDrag(folderID: fid); return }
        if session.isMulti { commitMultiDrag(); return }

        guard let id = session.draggedNoteID,
              let source = allNotes.first(where: { $0.id == id }) else {
            wipe()
            return
        }
        // Released over the editor → make a split instead of a reorder.
        if let side = session.editorDropSide {
            onSplitDrop(source, side)
            wipe()
            return
        }
        guard let dest = session.currentTier else {
            wipe()
            return
        }
        let destIndex = session.currentIndex
        let crossTier = dest != session.sourceTier
        // After an edge auto-switch the active (drop) space may differ from
        // this column's space → commit a cross-space move into it.
        let destSpace = session.dropSpace ?? space

        // Where on the column should the ghost end up?
        let destFrame = session.tierFrames[dest] ?? .zero
        let targetCenterX: CGFloat
        let targetCenterY: CGFloat
        if dest == .favorite, destFrame.width > 0 {
            // Promotion into Essentials — snap to the post-commit grid
            // cell, not to a row slot. Without this the ghost lands on a
            // y derived from `rowHeight`, then session.reset reveals the
            // tile sitting at the correct cell — reading as a jump.
            let pad = CrossTierDragSession.favoriteGridPadding
            let spacing = CrossTierDragSession.favoriteCellSpacing
            let cellH = CrossTierDragSession.favoriteCellHeight
            let postCount = max(1, (session.noteCountsByTier[.favorite] ?? 0)
                                + (crossTier ? 1 : 0))
            let N = CrossTierDragSession.favoriteColumnCount(for: postCount)
            let cellW = CrossTierDragSession.favoriteCellWidth(gridWidth: destFrame.width,
                                                               count: postCount)
            let col = destIndex % N
            let row = destIndex / N
            targetCenterX = destFrame.minX + pad + CGFloat(col) * (cellW + spacing) + cellW / 2
            targetCenterY = destFrame.minY + pad + CGFloat(row) * (cellH + spacing) + cellH / 2

            // CRITICAL for promotes: this row-drag path (not commitTileDrag)
            // is what runs when a note is dragged up from another section.
            // Lock the grid's column count, the ghost's tile shape, and the
            // ghost width to their post-commit values so the @Query refresh
            // (which lands mid-snap and changes the favorite count) can't
            // briefly relayout the grid to a wider, fewer-column state —
            // the "glitches wider, then settles" you saw on promote only.
            session.frozenFavoriteColumnCount = N
            session.frozenAsTile = true
            session.frozenTileWidth = cellW - 16
        } else {
            targetCenterX = destFrame.midX
            // Within-tier indent drag: settle to the live drop-indicator's
            // actual position (WYSIWYG) so release lands exactly on the bar.
            // Other cases use the row-slot convention.
            if !crossTier, let c = session.dropIndicatorCenter {
                targetCenterY = c.y
            } else {
                targetCenterY = destFrame.minY + CGFloat(destIndex) * rowHeight
                    + CrossTierDragSession.noteRowContentHeight / 2
            }
            session.frozenAsTile = false
        }
        let targetTranslationX = targetCenterX - session.sourceRowCenter.x
        let targetTranslationY = targetCenterY - session.sourceRowCenter.y

        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(
                width: dest == .favorite ? targetTranslationX : 0,
                height: targetTranslationY
            )
        } completion: {
            // Within-tier (same tier + space): membership-aware flat commit —
            // the note lands at its flat slot and joins / leaves a folder based
            // on the row above the drop. Cross-tier keeps the standalone move
            // (performMove clears `folder`).
            if !crossTier && source.space?.id == destSpace.id {
                commitWithinTierFlat(source: source, flatDropIndex: destIndex)
            } else if dest != .favorite,
                      let fid = session.nestTargetFolderID,
                      let folder = try? modelContext.fetch(
                        FetchDescriptor<Folder>(predicate: #Predicate { $0.id == fid })).first {
                // Cross-tier / cross-space drop INTO a folder.
                commitNoteIntoFolder(source, folder: folder)
            } else {
                performMove(source: source, dest: dest, destIndex: destIndex, crossTier: crossTier, destSpace: destSpace)
            }
            // Dragging the split tab moves the pair: place the secondary right
            // after the primary in its new tier/space, keeping the split.
            // EXCEPT into Essentials — favorites are single tiles, so dragging
            // the secondary along would spawn a stray second tile. Only the
            // primary becomes essential (the split breaks).
            if let splitPair = splitPairs.first(where: { $0.primary.id == source.id }),
               dest != .favorite {
                placeSplitSecondaryAfterPrimary(splitPair)
            }
            DispatchQueue.main.async {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.reset()
                }
            }
        }
    }

    /// Within-tier release (indent model): place `source` at flat gap
    /// `flatDropIndex` with membership = the resolved parent folder
    /// (`nestTargetFolderID`, nil = top-level), then renumber the tier. A closed
    /// parent opens so the note is revealed.
    private func commitWithinTierFlat(source: Note, flatDropIndex: Int) {
        // Commit EXACTLY what's on screen: `displayedFlatRows` already has the
        // dragged row at its drop slot with the resolved parent (folderID), so
        // committing that order is guaranteed WYSIWYG — the note lands on the
        // bar, never elsewhere.
        let rows = displayedFlatRows
        guard let srcRow = rows.first(where: { $0.rowID == source.id }) else { return }
        let parentID = srcRow.folderID
        let parent = parentID.flatMap { id in
            try? modelContext.fetch(
                FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
        }
        let wasCollapsed = parent?.isCollapsed ?? false
        if let parent {
            source.folder = parent
            source.tier = parent.tier
            if let sp = parent.space { source.space = sp }
        } else {
            source.folder = nil
        }
        source.updatedAt = Date()
        renumber(rows)
        try? modelContext.save()
        if wasCollapsed, let parent {
            withAnimation(CrossTierDragSession.folderToggle) {
                try? FolderService(context: modelContext).setCollapsed(parent, false)
            }
        }
    }

    /// Cross-tier / cross-space drop of a note INTO a folder: re-tier/space the
    /// note to the folder's, slot it among the folder's members at the resolved
    /// position, open the folder if closed, and renumber both tiers.
    private func commitNoteIntoFolder(_ source: Note, folder: Folder) {
        let destTier = folder.tier
        let destSpace = folder.space
        source.folder = folder
        source.tier = destTier
        if let sp = destSpace { source.space = sp }
        source.updatedAt = Date()

        // Member insertion index = count of the folder's member rows before the
        // resolved flat slot (in the destination tier's published rows).
        let destRows = session.tierFolderRows[destTier] ?? []
        let c = min(max(0, session.currentIndex), destRows.count)
        let memberBefore = destRows.prefix(c).filter { !$0.isFolder && $0.folderID == folder.id }.count
        var members = (folder.notes ?? []).filter { $0.id != source.id }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        members.insert(source, at: min(max(0, memberBefore), members.count))
        for (i, n) in members.enumerated() { n.manualSortIndex = i }

        let wasCollapsed = folder.isCollapsed
        let svc = FolderService(context: modelContext)
        if let srcTier = session.sourceTier { try? svc.normalizeTierOrder(tier: srcTier, in: space) }
        try? modelContext.save()
        if wasCollapsed {
            withAnimation(CrossTierDragSession.folderToggle) { try? svc.setCollapsed(folder, false) }
        }
    }

    /// One shared 0..n counter PER CONTAINER (keyed by `row.folderID`, nil =
    /// top-level) across both child folders and member notes — so they interleave
    /// and the rendered order matches the committed order exactly.
    private func renumber(_ rows: [SidebarRow]) {
        var counter: [String: Int] = [:]
        for row in rows {
            if row.isEmpty { continue }   // render-only hint, no order to assign
            let key = row.folderID?.uuidString ?? "_top"
            let v = counter[key] ?? 0
            counter[key] = v + 1
            switch row.kind {
            case .note(let n): n.manualSortIndex = v
            case .folderHeader(let f): f.sortIndex = v
            case .empty: break
            }
        }
    }

    /// Release path for a folder header drag (indent model): RE-PARENT the
    /// folder to the resolved parent (nil = top-level) at the drop slot — its
    /// whole subtree travels with it. Within-tier only — a drop over another
    /// tier snaps back.
    private func commitFolderDrag(folderID: UUID) {
        let wasExpanded = session.draggedFolderWasExpanded
        guard let folder = try? modelContext.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate { $0.id == folderID })).first
        else { settleFolderBack(); return }
        // Cross-tier (Pinned ↔ Notes) or cross-space: move the whole subtree to
        // the destination tier/space at top level (favorites excluded upstream).
        let destSpace = session.dropSpace ?? space
        let destTier = session.currentTier ?? session.sourceTier ?? .pinned
        if destTier != session.sourceTier || destSpace.id != space.id {
            commitFolderMove(folder: folder, destTier: destTier, destSpace: destSpace, wasExpanded: wasExpanded)
            return
        }

        let parentID = session.nestTargetFolderID
        let parent = parentID.flatMap { id in
            try? modelContext.fetch(
                FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
        }
        // Safety: never nest a folder into itself / a descendant.
        let svc = FolderService(context: modelContext)
        let safeParent = (parent != nil && svc.canNest(folder, under: parent)) ? parent : nil
        let safeParentID = (parent == nil || safeParent != nil) ? parentID : nil

        // Commit exactly the previewed order: displayedFlatRows has the folder
        // header at its drop slot with folderID = the resolved parent.
        let rows = displayedFlatRows
        folder.parent = safeParent
        let wasParentCollapsed = safeParent?.isCollapsed ?? false
        // Re-key the folder header row to the safe parent before renumbering.
        let committed = rows.map { r -> SidebarRow in
            r.rowID == folderID
                ? SidebarRow(kind: r.kind, depth: r.depth, folderID: safeParentID)
                : r
        }
        renumber(committed)
        try? modelContext.save()

        let target = session.dropIndicatorCenter
        let destFrame = session.tierFrames[tier] ?? .zero
        let targetCenterY = target?.y
            ?? (destFrame.minY + CGFloat(session.currentIndex) * rowHeight
                + CrossTierDragSession.noteRowContentHeight / 2)
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(width: 0, height: targetCenterY - session.sourceRowCenter.y)
        } completion: {
            DispatchQueue.main.async {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { session.reset() }
                // Re-open the moved folder (and its new parent if it was closed)
                // as a separate chevron animation, decoupled from the drag.
                if wasParentCollapsed, let safeParent {
                    withAnimation(CrossTierDragSession.folderToggle) {
                        try? FolderService(context: modelContext).setCollapsed(safeParent, false)
                    }
                }
                reExpandDraggedFolder(folder, wasExpanded: wasExpanded)
            }
        }
    }

    /// Move a dragged folder's subtree to another tier and/or SPACE, landing at
    /// top level positionally, then glide the ghost to the destination.
    private func commitFolderMove(folder: Folder, destTier: NoteTier, destSpace: Space, wasExpanded: Bool) {
        let svc = FolderService(context: modelContext)
        let sourceTier = session.sourceTier
        if destSpace.id != space.id {
            try? svc.move(folder, toTier: destTier, toSpace: destSpace)
        } else {
            try? svc.changeTier(folder, to: destTier)
        }

        // Nest into a target folder if one was previewed (depth > 0 drop),
        // otherwise land top-level.
        let nestParentID = session.nestTargetFolderID
        let nestParent = nestParentID.flatMap { id in
            try? modelContext.fetch(FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
        }
        let safeParent = (nestParent != nil && svc.canNest(folder, under: nestParent)) ? nestParent : nil
        folder.parent = safeParent
        let wasParentCollapsed = safeParent?.isCollapsed ?? false

        let destRows = session.tierFolderRows[destTier] ?? []
        let c = min(max(0, session.currentIndex), destRows.count)

        if let parent = safeParent {
            // Nested: slot among the parent's children + member notes.
            let memberBefore = destRows.prefix(c).filter { !$0.isFolder && $0.folderID == parent.id }.count
            let folderBefore = destRows.prefix(c).filter { $0.isFolder && $0.folderID == parent.id }.count
            var siblings = (parent.children ?? []).filter { $0.id != folder.id }
                .sorted { $0.sortIndex < $1.sortIndex }
            siblings.insert(folder, at: min(max(0, folderBefore), siblings.count))
            for (i, f) in siblings.enumerated() { f.sortIndex = i }
            var members = (parent.notes ?? [])
                .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            _ = memberBefore  // member position handled by normalizeTierOrder below
            _ = members
        } else {
            // Top-level: slot among the dest tier's top-level items.
            let topInsert = destRows.prefix(c).filter { $0.depth == 0 }.count
            enum Item { case folder(Folder); case note(Note) }
            func order(_ i: Item) -> Int {
                switch i { case .folder(let f): return f.sortIndex; case .note(let n): return n.manualSortIndex ?? Int.max }
            }
            let destSpaceID = destSpace.id
            let destFolders = ((try? modelContext.fetch(FetchDescriptor<Folder>(predicate: #Predicate {
                $0.space?.id == destSpaceID
            }))) ?? []).filter { $0.tier == destTier && $0.parent == nil && $0.id != folder.id }
            let destNotes = ((try? modelContext.fetch(FetchDescriptor<Note>(predicate: #Predicate {
                $0.space?.id == destSpaceID
            }))) ?? []).filter { $0.tier == destTier && $0.folder == nil }
            var items: [Item] = (destFolders.map { Item.folder($0) } + destNotes.map { Item.note($0) })
                .sorted { order($0) < order($1) }
            items.insert(.folder(folder), at: min(max(0, topInsert), items.count))
            var counter = 0
            for it in items {
                switch it {
                case .folder(let f): f.sortIndex = counter
                case .note(let n): n.manualSortIndex = counter
                }
                counter += 1
            }
        }

        if let src = sourceTier { try? svc.normalizeTierOrder(tier: src, in: space) }
        try? svc.normalizeTierOrder(tier: destTier, in: destSpace)
        try? modelContext.save()

        let destFrame = session.tierFrames[destTier] ?? .zero
        let targetCenterY = destFrame.minY + CGFloat(c) * rowHeight
            + CrossTierDragSession.noteRowContentHeight / 2
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(width: 0, height: targetCenterY - session.sourceRowCenter.y)
        } completion: {
            DispatchQueue.main.async {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { session.reset() }
                if wasParentCollapsed, let safeParent {
                    withAnimation(CrossTierDragSession.folderToggle) {
                        try? svc.setCollapsed(safeParent, false)
                    }
                }
                reExpandDraggedFolder(folder, wasExpanded: wasExpanded)
            }
        }
    }

    private func settleFolderBack() {
        let wasExpanded = session.draggedFolderWasExpanded
        let fid = session.draggedFolderID
        let folder = fid.flatMap { id in
            try? modelContext.fetch(
                FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
        }
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = .zero
        } completion: {
            DispatchQueue.main.async {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { session.reset() }
                reExpandDraggedFolder(folder, wasExpanded: wasExpanded)
            }
        }
    }

    private func reExpandDraggedFolder(_ folder: Folder?, wasExpanded: Bool) {
        guard wasExpanded, let folder else { return }
        withAnimation(CrossTierDragSession.folderToggle) {
            try? FolderService(context: modelContext).setCollapsed(folder, false)
        }
    }

    /// Keep the split pair together after the primary is dragged: move the
    /// secondary into the primary's (possibly new) tier/space, right after it.
    private func placeSplitSecondaryAfterPrimary(_ splitPair: MacSidebarSplitPair) {
        let primary = splitPair.primary
        let secondary = splitPair.secondary
        let pid = primary.id
        let sid = secondary.id
        secondary.tier = primary.tier
        secondary.space = primary.space
        secondary.folder = nil
        let tier = primary.tier
        let spaceID = primary.space?.id
        var list = allNotes
            .filter { $0.tier == tier && $0.space?.id == spaceID && $0.folder == nil && $0.id != sid }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        if let pidx = list.firstIndex(where: { $0.id == pid }) {
            list.insert(secondary, at: pidx + 1)
        } else {
            list.append(secondary)
        }
        for (i, n) in list.enumerated() { n.manualSortIndex = i }
        try? modelContext.save()
    }

    /// `destSpace` is the space to land in — normally this column's `space`,
    /// but after an edge auto-switch it's the now-active space (a cross-space
    /// move). Favorites are global so `destSpace` is ignored there.
    private func performMove(source: Note, dest: NoteTier, destIndex: Int, crossTier: Bool, destSpace: Space) {
        let crossSpace = dest != .favorite && source.space?.id != destSpace.id
        if crossTier || crossSpace {
            source.tier = dest
            source.space = dest == .favorite ? nil : destSpace
            source.folder = nil
        }

        // Rebuild destination tier (in destSpace).
        let destOthers: [Note] = dest == .favorite
            ? allNotes.filter { $0.tier == .favorite && $0.id != source.id }
            : allNotes.filter { $0.tier == dest && $0.space?.id == destSpace.id && $0.folder == nil && $0.id != source.id }
        var destReordered = destOthers.sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        let insertIdx = min(destIndex, destReordered.count)
        destReordered.insert(source, at: insertIdx)
        for (i, n) in destReordered.enumerated() { n.manualSortIndex = i }

        // Renumber the tier the note left (its original space + tier).
        if crossTier || crossSpace, let srcTier = session.sourceTier {
            let srcSpaceID = session.sourceSpaceID ?? space.id
            let srcOthers: [Note] = srcTier == .favorite
                ? allNotes.filter { $0.tier == .favorite && $0.id != source.id }
                : allNotes.filter { $0.tier == srcTier && $0.space?.id == srcSpaceID && $0.folder == nil && $0.id != source.id }
            let srcSorted = srcOthers.sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            for (i, n) in srcSorted.enumerated() { n.manualSortIndex = i }
        }

        source.updatedAt = Date()
        try? modelContext.save()
    }

    /// Release path for a multi-drag. Springs the floating stack so the grabbed
    /// (primary) row lands in its reserved gap slot — when you've dragged the
    /// stack far past the drop point, this is the satisfying snap back to where
    /// it belongs — then commits the data and clears the session in a deferred,
    /// non-animated transaction (resetting inside the animation would make the
    /// ghost fly to zero). The deferral lets `@Query` refresh first so the real
    /// rows are already in place when the ghost is removed (clean handoff).
    private func commitMultiDrag() {
        guard let dest = session.currentTier else { wipe(); return }
        let ids = session.draggedNoteIDs
        let destSpace = session.dropSpace ?? space
        let crossSpace = destSpace.id != space.id
        // Within-tier + within-space multi-drag → indent-model commit (the whole
        // block moves to the resolved parent/depth at the drop slot).
        if !crossSpace && dest == session.sourceTier {
            commitMultiWithinTier()
            return
        }
        // Promote the whole group INTO Essentials (a grid, not rows) — commit at
        // the grid hit-test index and let the grid reflow in (no row-glide math).
        if dest == .favorite {
            performMoveMulti(ids: ids, dest: .favorite, destIndex: session.currentIndex, destSpace: destSpace)
            wipe()
            return
        }
        // Block lands so the grabbed row sits at currentIndex (see multiOffset).
        let rawDestIndex = max(0, session.currentIndex - session.primaryGroupIndex)

        // Clamp the insert to the count of VISIBLE (non-dragged) rows in the
        // destination — `currentIndex` is bounded by the full row count, which
        // includes the collapsed dragged rows, so an unclamped target sits too
        // low and the glide visibly stops short before the rows appear higher.
        let destSpaceID = destSpace.id
        let destVisibleCount = allNotes.filter {
            $0.tier == dest && $0.space?.id == destSpaceID && $0.folder == nil && !session.isDragged($0.id)
        }.count
        let destIndex = min(rawDestIndex, destVisibleCount)

        // Where the grabbed row's center ends up: its slot within the open gap.
        let destFrame = session.tierFrames[dest] ?? .zero
        let primaryLandedSlot = destIndex + session.primaryGroupIndex
        let primaryTargetCenterY = destFrame.minY
            + CGFloat(primaryLandedSlot) * rowHeight
            + CrossTierDragSession.noteRowContentHeight / 2
        let targetTranslationY = primaryTargetCenterY - session.sourceRowCenter.y

        // Same glide as single-drag (no spring overshoot/settle, which read as
        // jitter here) so the stack snaps cleanly to its slot. Commit + reset
        // happen synchronously the instant the glide lands — deferring the
        // reset to a later runloop made the ghost sit at the target for a
        // frame or more (waiting on the @Query refresh of N notes) before the
        // real rows appeared, which read as a "stop" at the end of the snap.
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(width: 0, height: targetTranslationY)
        } completion: {
            performMoveMulti(ids: ids, dest: dest, destIndex: destIndex, destSpace: destSpace)
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                session.reset()
            }
        }
    }

    /// Within-tier multi-drag commit (indent model): move the whole selection
    /// to the resolved parent/depth at the drop slot, committing exactly the
    /// previewed order (`displayedFlatRows`).
    private func commitMultiWithinTier() {
        let ids = Set(session.draggedNoteIDs)
        let parentID = session.nestTargetFolderID
        let parent = parentID.flatMap { id in
            try? modelContext.fetch(
                FetchDescriptor<Folder>(predicate: #Predicate { $0.id == id })).first
        }
        let wasCollapsed = parent?.isCollapsed ?? false

        // Capture the previewed order BEFORE mutating membership. `displayedFlatRows`
        // recomputes `flatRows` from the live model, so changing `n.folder` here
        // would empty the source folder, shift every row below it, and reset the
        // popped notes to stale low sort-indices — making the drag-resolved
        // `currentIndex` land them somewhere else (the "released at the top" bug).
        // The rekeyed movers already carry `folderID = nestTargetFolderID`, so
        // `renumber` keys them to the right container.
        let finalRows = displayedFlatRows

        let now = Date()
        for n in allNotes where ids.contains(n.id) {
            n.folder = parent
            if let parent { n.tier = parent.tier; if let sp = parent.space { n.space = sp } }
            n.updatedAt = now
        }
        renumber(finalRows)
        try? modelContext.save()

        // The grabbed row sits at block-top (currentIndex) + its index in the
        // block, so glide the stack so its primary lands there.
        let destFrame = session.tierFrames[tier] ?? .zero
        let primarySlot = session.currentIndex + session.primaryGroupIndex
        let targetCenterY = destFrame.minY + CGFloat(primarySlot) * rowHeight
            + CrossTierDragSession.noteRowContentHeight / 2
        withAnimation(CrossTierDragSession.commitGlide) {
            session.isSettling = true
            session.translation = CGSize(width: 0, height: targetCenterY - session.sourceRowCenter.y)
        } completion: {
            DispatchQueue.main.async {
                var tx = Transaction(); tx.disablesAnimations = true
                withTransaction(tx) { session.reset() }
                if wasCollapsed, let parent {
                    withAnimation(CrossTierDragSession.folderToggle) {
                        try? FolderService(context: modelContext).setCollapsed(parent, false)
                    }
                }
            }
        }
    }

    /// Move the whole dragged set to `dest` (in `destSpace`) at `destIndex`,
    /// preserving the group's order, and renumber any source tiers they left.
    /// `destSpace` differs from this column's space after a cross-space drag.
    private func performMoveMulti(ids: [UUID], dest: NoteTier, destIndex: Int, destSpace: Space) {
        let movers = ids.compactMap { id in allNotes.first { $0.id == id } }
        guard !movers.isEmpty else { return }
        for m in movers {
            m.tier = dest
            m.space = dest == .favorite ? nil : destSpace   // favorites are global
            m.folder = nil
        }

        // Rebuild the destination tier with the group inserted as a block.
        // (Favorites are global → match on tier alone, ignore space.)
        let destSpaceID = destSpace.id
        let destOthers = allNotes
            .filter { $0.tier == dest && (dest == .favorite || $0.space?.id == destSpaceID) && $0.folder == nil && !ids.contains($0.id) }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        var reordered = destOthers
        let insertIdx = min(max(0, destIndex), reordered.count)
        reordered.insert(contentsOf: movers, at: insertIdx)
        for (i, n) in reordered.enumerated() { n.manualSortIndex = i }

        // Renumber the tiers the group left behind (incl. favorites).
        for srcTier in [NoteTier.pinned, .random, .favorite] where srcTier != dest {
            let remaining = allNotes
                .filter { $0.tier == srcTier && (srcTier == .favorite || $0.space?.id == space.id) && $0.folder == nil && !ids.contains($0.id) }
                .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            for (i, n) in remaining.enumerated() { n.manualSortIndex = i }
        }

        let now = Date()
        for m in movers { m.updatedAt = now }
        try? modelContext.save()
    }

    private func wipe() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            session.reset()
        }
    }

    /// While this tier is a cross-tier destination AND the source row is
    /// not yet in our `notes` array, the drop zone reserves `rowHeight` of
    /// extra layout space — matching the post-commit layout (one more
    /// row). Once the row is committed (notes contains it), the expansion
    /// collapses to 0 since the real row now occupies that slot.
    private var tierEndExpansion: CGFloat {
        // Multi-drag: the destination tier reserves the whole group's height
        // for the N-row gap (favorites isn't a multi-drop target). Collapses
        // to 0 on commit+reset (isActive flips false), animating the gap shut.
        if session.isMulti {
            guard session.isActive, isCurrentTier, session.currentTier != .favorite else { return 0 }
            return CGFloat(session.draggedCount) * rowHeight
        }
        guard session.isActive, isCurrentTier, session.isCrossTier else { return 0 }
        if let id = session.draggedNoteID, notes.contains(where: { $0.id == id }) {
            return 0
        }
        return rowHeight
    }

    /// Source tier of a cross-tier drag: compensates for the
    /// `LazyVStack(spacing: 3)` slot around the collapsed source row.
    /// The compensation only applies while the row is still in `notes`
    /// (pre-commit). After commit removes it, the spacing slot is gone
    /// too — no contraction needed.
    private var tierEndContraction: CGFloat {
        guard session.isActive, isSourceTier, session.isCrossTier else { return 0 }
        if let id = session.draggedNoteID, notes.contains(where: { $0.id == id }) {
            return 3
        }
        return 0
    }

    @ViewBuilder
    private var tierEndDropZone: some View {
        Color.clear
            .frame(height: max(0, 16 + tierEndExpansion - tierEndContraction))
            // Gated on `isActive` so the spacer collapses instantly on release
            // (the transaction-independent animation would otherwise slide the
            // rows below it shut over 0.14s — residual movement after the drop).
            .animation(session.isActive ? CrossTierDragSession.rowShuffle : nil, value: tierEndExpansion)
            .animation(session.isActive ? CrossTierDragSession.rowShuffle : nil, value: tierEndContraction)
            // Right-click the empty area below a section → make a folder IN that
            // section's tier (the toolbar / space-menu "New Folder" are space-level
            // and default to Pinned; this is the only Notes-tier entry point).
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    createFolderInThisTier()
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
    }

    /// Create a top-level folder in THIS group's tier and enter inline rename —
    /// so a right-click in the Notes section yields a Notes folder (not Pinned).
    private func createFolderInThisTier() {
        if let folder = try? FolderService(context: modelContext)
            .create(in: space, tier: tier, parent: nil) {
            renamingFolderID = folder.id
        }
    }
}

private struct MacFolderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let folder: Folder
    let space: Space
    let selectedNoteID: UUID?
    let selectNote: (Note) -> Void
    let selection: NoteSelectionModel
    let performBatch: (NoteBatchAction) -> Void
    let openInSplit: (Note) -> Void
    let addToSplit: (Note) -> Void
    let session: CrossTierDragSession
    @Binding var renamingFolderID: UUID?
    var depth: Int = 0

    @State private var isHovering = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private let indentStep: CGFloat = 14

    private var isExpanded: Bool { !folder.isCollapsed }
    private var isRenaming: Bool { renamingFolderID == folder.id }
    /// A dragged note is aimed at this folder → it will drop inside (highlight).
    private var isNestTarget: Bool { session.nestTargetFolderID == folder.id }
    private var folderTint: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }
    private var canAddSubfolder: Bool { folder.depth < Folder.maxDepth }

    private var childFolders: [Folder] {
        (folder.children ?? []).sorted {
            $0.sortIndex == $1.sortIndex ? $0.createdAt < $1.createdAt : $0.sortIndex < $1.sortIndex
        }
    }

    private var notes: [Note] {
        (folder.notes ?? []).sorted(by: noteSort)
    }

    private var totalCount: Int { notes.count + childFolders.count }

    // Header-only: the folder's child folders + member notes are rendered as
    // sibling rows in the tier's flat list (`MacSidebarGroup.flatRows`), not
    // nested here — so every row shares one identity space and the drag engine
    // can reorder across folder boundaries without rebuilding views.
    var body: some View {
        header
    }

    // Nest target = a stronger version of the neutral hover fill (reads clearly
    // against the colored space background, unlike a space-tinted fill).
    private var headerFillColor: Color {
        if isNestTarget { return Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12) }
        if isHovering && !isRenaming { return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07) }
        return .clear
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(.secondary)

            if isRenaming {
                TextField("Folder name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(folder.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if !isRenaming {
                Text("\(totalCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(headerFillColor)
        }
        .animation(CrossTierDragSession.rowShuffle, value: isNestTarget)
        .padding(.leading, CGFloat(depth) * indentStep)
        .onTapGesture { if !isRenaming { toggleExpanded() } }
        .onHover { isHovering = $0 }
        .contextMenu { menu }
        .onChange(of: isRenaming) { _, now in
            if now { draftName = folder.name; renameFocused = true }
        }
        .onAppear {
            if isRenaming { draftName = folder.name; renameFocused = true }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if canAddSubfolder {
            Button("New Subfolder", systemImage: "folder.badge.plus") { addSubfolder() }
        }
        Button("Rename", systemImage: "pencil") { renamingFolderID = folder.id }
        moveMenu
        Divider()
        Button("Delete Folder", systemImage: "trash", role: .destructive) { deleteFolder() }
    }

    @ViewBuilder
    private var moveMenu: some View {
        let targets = moveTargets
        if !targets.isEmpty || folder.parent != nil {
            Menu("Move to") {
                if folder.parent != nil {
                    Button("Top Level", systemImage: "arrow.up.to.line") { reparent(nil) }
                }
                ForEach(targets) { target in
                    Button(target.name, systemImage: "folder") { reparent(target) }
                }
            }
        }
    }

    /// Folders in the same space + tier that this folder could legally nest
    /// under (no cycles, within the depth cap).
    private var moveTargets: [Folder] {
        let service = FolderService(context: modelContext)
        let spaceID = space.id
        let descriptor = FetchDescriptor<Folder>(predicate: #Predicate { $0.space?.id == spaceID })
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all
            .filter { $0.tier == folder.tier
                && $0.id != folder.id
                && $0.id != folder.parent?.id
                && service.canNest(folder, under: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func toggleExpanded() {
        withAnimation(CrossTierDragSession.folderToggle) {
            try? FolderService(context: modelContext).setCollapsed(folder, !folder.isCollapsed)
        }
    }

    private func addSubfolder() {
        let service = FolderService(context: modelContext)
        guard let child = try? service.create(in: space, tier: folder.tier, parent: folder) else { return }
        try? service.setCollapsed(folder, false) // reveal the new child
        renamingFolderID = child.id
    }

    private func reparent(_ parent: Folder?) {
        try? FolderService(context: modelContext).reparent(folder, under: parent)
    }

    private func deleteFolder() {
        try? FolderService(context: modelContext).delete(folder)
    }

    private func commitRename() {
        guard isRenaming else { return }
        try? FolderService(context: modelContext).rename(folder, to: draftName)
        renamingFolderID = nil
    }
}

private struct MacNoteRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let note: Note
    let space: Space
    /// Whether this is the active space's *open* note (shown in the editor).
    let isSelected: Bool
    var showDropIndicator: Bool = false
    var indicatorColor: Color = .accentColor
    let selectNote: (Note) -> Void
    /// Shared multi-select set (⌘/⇧-click). The row both reads it (highlight,
    /// menu mode) and mutates it (toggle/range on modified clicks).
    var selection: NoteSelectionModel
    /// Apply a batch action over the whole selection (menu only).
    var performBatch: (NoteBatchAction) -> Void = { _ in }
    /// Open this note beside the currently-open one (editor split).
    var openInSplit: (Note) -> Void = { _ in }
    /// Add an empty note beside this one (when it's the open note).
    var addToSplit: (Note) -> Void = { _ in }
    /// This tier's displayed note order — the domain for ⇧-range selection.
    var orderedIDs: [UUID] = []

    @State private var isHovering = false
    @State private var isHoveringDelete = false

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    /// Highlighted when it's a member of an active multi-selection, or — when
    /// nothing is multi-selected — when it's the open note.
    private var isHighlighted: Bool {
        selection.isActive ? selection.contains(note.id) : isSelected
    }

    /// Elevated, space-tinted fill for the selected pill (lifts off the bg).
    private var selectionFill: Color { spaceColor.elevatedSelectionFill(scheme: colorScheme) }

    /// Readable ink chosen from the *pill* color, so text/glyphs stay legible
    /// whatever the elevated fill resolves to (light pill → dark ink, lifted
    /// dark pill → light ink).
    private var selectionInk: Color { selectionFill.selectionInk }

    /// The × glyph color — brightens when hovering the button itself.
    private var deleteInk: Color {
        if isHighlighted { return selectionInk.opacity(isHoveringDelete ? 1 : 0.7) }
        return Color.primary.opacity(isHoveringDelete ? 0.9 : 0.5)
    }
    /// Circular highlight behind the × on direct hover.
    private var deleteHoverFill: Color {
        guard isHoveringDelete else { return .clear }
        return isHighlighted ? selectionInk.opacity(0.18) : Color.primary.opacity(0.12)
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(note.title)
                .font(.system(size: 13, weight: isHighlighted ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: deleteNote) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(deleteInk)
                    .frame(width: 18, height: 18)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(deleteHoverFill)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if isHoveringDelete != hovering { isHoveringDelete = hovering }
            }
            .help("Delete note")
            .opacity(isHovering ? 1 : 0)
            .scaleEffect(isHovering ? 1 : 0.92)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .animation(.easeOut(duration: 0.1), value: isHoveringDelete)
        }
        .foregroundStyle(isHighlighted ? selectionInk : Color.primary.opacity(0.86))
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background {
            // Soft shadow lives on the pill shape (not the row) so only the
            // selected card casts it — the lift that reads as "modern". The
            // shape is drawn over a faint hairline so the light pill keeps a
            // crisp edge where the shadow is too subtle to define it.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(rowBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            isHighlighted ? Color.black.opacity(colorScheme == .dark ? 0.0 : 0.05) : .clear,
                            lineWidth: 0.5
                        )
                }
                .shadow(
                    color: isHighlighted ? Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14) : .clear,
                    radius: isHighlighted ? 4 : 0, x: 0, y: isHighlighted ? 1.5 : 0
                )
        }
        .overlay(alignment: .top) {
            if showDropIndicator {
                Capsule()
                    .fill(indicatorColor.opacity(0.9))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: -2)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(pressSelectionGesture)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
        .contextMenu {
            if selection.count > 1 && selection.contains(note.id) {
                batchMenu
            } else {
                singleMenu
            }
        }
        .animation(.easeOut(duration: 0.08), value: isHovering)
        .animation(.easeOut(duration: 0.06), value: isHighlighted)
    }

    @ViewBuilder
    private var singleMenu: some View {
        Button("Open", systemImage: "doc.text") { selectNote(note) }
        if isSelected {
            // This is the open note → add an empty pane beside it.
            Button("Add to Split View", systemImage: "rectangle.split.2x1") { addToSplit(note) }
        } else {
            Button("Open in Split View", systemImage: "rectangle.split.2x1") { openInSplit(note) }
        }
        Divider()
        Button("Make Essential", systemImage: "star.fill") { promote(to: .favorite) }
        Button("Pin", systemImage: "pin.fill") { promote(to: .pinned) }
        Button("Move to Notes", systemImage: "tray") { promote(to: .random) }
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicateNote() }
        Button("Archive", systemImage: "archivebox") { archiveNote() }
        Button("Delete", systemImage: "trash", role: .destructive) { deleteNote() }
    }

    @ViewBuilder
    private var batchMenu: some View {
        let n = selection.count
        if n == 2 {
            Button("Open in Split View", systemImage: "rectangle.split.2x1") { performBatch(.openSplit) }
            Divider()
        }
        Button("New Folder from \(n) Notes", systemImage: "folder.badge.plus") { performBatch(.group) }
        Divider()
        Button("Make \(n) Essential", systemImage: "star.fill") { performBatch(.makeEssential) }
        Button("Pin \(n) Notes", systemImage: "pin.fill") { performBatch(.pin) }
        Button("Move \(n) to Notes", systemImage: "tray") { performBatch(.moveToNotes) }
        Divider()
        Button("Duplicate \(n) Notes", systemImage: "plus.square.on.square") { performBatch(.duplicate) }
        Button("Archive \(n) Notes", systemImage: "archivebox") { performBatch(.archive) }
        Button("Delete \(n) Notes", systemImage: "trash", role: .destructive) { performBatch(.delete) }
    }

    private var rowBackground: Color {
        if isHighlighted {
            // Elevated tinted pill: lighter than the space-tinted bg so it
            // lifts off the surface (Arc-style), with a hint of the space hue.
            return selectionFill
        }
        return isHovering ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07) : Color.clear
    }

    private var pressSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 4
                // A press that became a drag NEVER selects/opens the note — the
                // drag owns the interaction. This is what lets you drag a tab
                // onto the open note to split: the currently-open note must
                // stay primary, so the dragged note must not steal selection on
                // press. Only a true click (release without movement) selects.
                guard !moved else { return }
                handleClick()
            }
    }

    /// Modifier-aware click: ⌘ toggles membership, ⇧ selects a range, plain
    /// opens the note (clearing any selection upstream). Reads live keyboard
    /// flags so it composes with the existing press/drag gestures.
    private func handleClick() {
        #if canImport(AppKit)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.toggle(note.id)
            return
        }
        if flags.contains(.shift) {
            selection.selectRange(to: note.id, in: orderedIDs)
            return
        }
        #endif
        selectNote(note)
    }

    private func promote(to tier: NoteTier) {
        try? NoteService(context: modelContext).promote(note, to: tier, currentSpace: space)
    }

    private func archiveNote() {
        try? NoteService(context: modelContext).archive(note)
    }

    private func duplicateNote() {
        if let copy = try? NoteService(context: modelContext).duplicate(note) {
            selectNote(copy)
        }
    }

    private func deleteNote() {
        try? NoteService(context: modelContext).delete(note)
    }
}

private struct MacNoteMiniIcon: View {
    let note: Note
    let size: CGFloat
    /// When set, the glyph sits on a selected pill — tile + letter adopt this
    /// readable ink. `nil` = the default unselected (neutral) treatment.
    var ink: Color? = nil

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(ink.map { $0.opacity(0.22) } ?? Color.primary.opacity(0.10))
            .overlay {
                Text(String(note.title.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "N"))
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(ink ?? Color.secondary)
            }
            .frame(width: size, height: size)
    }
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

// MARK: - Manage Spaces board (Arc-style overview)

/// Full-window overview of every space as a themed column, reorderable by
/// dragging. Mirrors Arc's "Manage Spaces" board. Columns are a fixed width,
/// so reorder uses a constant pitch (simpler than the bottom strip). Per-column
/// ⋯ offers Open / Delete; editing (rename/theme/icon) stays in the sidebar.
/// Column reorder handle with the shared soft-grey hover chip. Its own struct
/// so each column tracks hover independently (a single `@State` on the parent
/// would light every handle at once). The whole column owns the drag gesture;
/// this is purely the visual affordance, and the hover tracking view sits in
/// the background so it never swallows the drag.
private struct ColumnDragHandle: View {
    /// True while any column reorder drag is in flight. During a drag the
    /// tracking area never gets a `mouseExited` (the drag captures the mouse),
    /// so `isHovered` would stay stale-true after release — clear it here.
    var isDragging: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary.opacity(isHovered ? 0.85 : 0.5))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(
                        isHovered ? (colorScheme == .dark ? 0.20 : 0.16) : 0.0
                    ))
            )
            .contentShape(Rectangle())
            .help("Drag the column to reorder")
            .onHoverTracked {
                if isHovered != $0 { isHovered = $0 }
                // Open/grab hand — the standard cursor for a drag affordance
                // (vs. the pointing finger used for buttons like the ⋯ menu).
                OverlayCursor.shared.desired = $0 ? .openHand : .arrow
            }
            .onChange(of: isDragging) { _, dragging in
                if dragging {
                    isHovered = false
                    OverlayCursor.shared.desired = .arrow
                }
            }
            .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

/// The "⋯" column menu glyph, with the shared soft-grey hover chip (cursor
/// stays the default arrow). Own struct so each column tracks hover
/// independently (mirrors [ColumnDragHandle]).
private struct ColumnMenuGlyph: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary.opacity(isHovered ? 0.85 : 0.55))
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.primary.opacity(
                        isHovered ? (colorScheme == .dark ? 0.20 : 0.16) : 0.0
                    ))
            )
            .contentShape(Rectangle())
            .onHoverTracked {
                if isHovered != $0 { isHovered = $0 }
                // Keep the plain arrow over the menu (no pointing hand), but
                // assert it so the pump steadily overwrites any I-beam the
                // editor / Menu control tries to set — otherwise it flickers.
                OverlayCursor.shared.desired = .arrow
            }
            .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

struct MacManageSpacesView: View {
    let spaces: [Space]
    let activeSpaceID: UUID?
    let notesProvider: (Space) -> [Note]
    let onClose: () -> Void
    let onOpenSpace: (Space) -> Void
    let requestDeleteSpace: (Space) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    // Column (space) reorder — driven by the bottom-left handle only, so it
    // never clashes with note dragging inside a column.
    @State private var draggingSpaceID: UUID?
    @State private var spaceSourceIndex = 0
    @State private var spaceCurrentIndex = 0
    @State private var spaceDragX: CGFloat = 0

    // Note reorder, scoped to a single column + tier section.
    @State private var draggingNoteID: UUID?
    @State private var noteDragSpaceID: UUID?
    @State private var noteDragTier: NoteTier?
    @State private var noteSourceIndex = 0
    @State private var noteCurrentIndex = 0   // within-tier reorder slot
    @State private var noteCrossIndex = 0     // insert slot when over the other tier
    @State private var noteDragY: CGFloat = 0
    /// The tier section the cursor is currently over. When it differs from the
    /// dragged note's own tier, the note will move into it (live gap + release).
    @State private var noteHoverTier: NoteTier?
    /// Section frames in the board coordinate space, keyed "spaceID|tier",
    /// used to hit-test which section the cursor is over during a note drag.
    @State private var sectionFrames: [String: CGRect] = [:]
    /// The note being dragged + its floating ghost position (board coords).
    /// The real row is hidden while this floats — same as the sidebar.
    @State private var draggedNote: Note?
    @State private var noteGhostPoint: CGPoint = .zero

    /// ⌘/⇧ multi-select set for batch actions (shared model with the sidebar).
    @State private var selection = NoteSelectionModel()
    /// Guards the single-fire of the modified-click on a press.
    @State private var selectPressHandled = false

    private let boardSpace = "manage-board"

    /// The space whose column the cursor is over (may differ from the source —
    /// that's a cross-space move).
    @State private var noteHoverSpaceID: UUID?

    /// True when the cursor is still over the dragged note's own section. When
    /// false the note is heading to a different tier and/or space, so the
    /// source row collapses and the target section reserves a gap.
    private var isSameSection: Bool {
        noteHoverSpaceID == noteDragSpaceID && noteHoverTier == noteDragTier
    }

    private let columnWidth: CGFloat = 248
    private let columnGap: CGFloat = 18
    private var spacePitch: CGFloat { columnWidth + columnGap }
    private let noteRowHeight: CGFloat = 30
    private let noteSpacing: CGFloat = 2
    private var notePitch: CGFloat { noteRowHeight + noteSpacing }

    private var activeSpaceColor: Color {
        let s = spaces.first { $0.id == activeSpaceID } ?? spaces.first
        guard let s else { return .gray }
        return Color.spaceColor(lightHex: s.colorHex, darkHex: s.darkColorHex, scheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                // Shorter columns with generous top + bottom margins so the
                // board breathes: pushed down from the header and lifted off
                // the window's bottom edge (top 18 + bottom 72 = 90).
                let columnHeight = max(340, geo.size.height - 90)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: columnGap) {
                        ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                            column(space, index: index, height: columnHeight)
                                .frame(width: columnWidth)
                                .offset(x: spaceOffset(index: index, id: space.id))
                                .zIndex(draggingSpaceID == space.id ? 2 : 0)
                                .opacity(draggingSpaceID == space.id ? 0.95 : 1)
                                // Whole column drags to reorder spaces. Note rows
                                // use a high-priority gesture so dragging a row
                                // reorders the note instead of the column.
                                .gesture(spaceReorderGesture(space: space, index: index))
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 18)
                    .padding(.bottom, 72)
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
            }
        }
        .onExitCommand(perform: onClose)
        .overlay {
            // Floating ghost of the dragged note (the real row is hidden),
            // mirroring the sidebar's drag model.
            if let note = draggedNote {
                ManageBoardNoteRow(note: note, height: noteRowHeight, isDragging: true)
                    .frame(width: ghostWidth)
                    .background(.white.opacity(colorScheme == .dark ? 0.12 : 0.55),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
                    .position(noteGhostPoint)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: boardSpace)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Forcibly own the cursor across the whole board so the note editor /
        // sidebar BEHIND this full-window overlay can't leak their I-beam /
        // resize cursors through the board's empty regions. The pump re-applies
        // OverlayCursor.desired on every move (async, so it wins over whatever
        // the covered content sets) and blocks click-through; the handle / ⋯
        // set .desired = .pointingHand on hover.
        .background(CursorPump())
        .background {
            ZStack {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                Rectangle().fill(activeSpaceColor.opacity(colorScheme == .dark ? 0.55 : 0.42))
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep the window's traffic lights in their usual spot at the very
            // top-left (they were missing in this full-window overlay).
            HStack(spacing: 0) {
                EmbeddedTrafficLights()
                    .frame(width: 76, height: 22)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)

            // Title row: a back chevron to the title's left (the × was removed
            // as redundant with it). Back button shares the New Note button's
            // hover treatment — grey chip + 1.03 lift — via SoftHoverIconButton.
            // Leading aligns with the column grid (28) so the title block and
            // first column share a left edge.
            HStack(alignment: .center, spacing: 10) {
                SoftHoverIconButton(systemName: "chevron.left", diameter: 30, iconSize: 15,
                                    hoverScale: 1.08, help: "Back", action: onClose)
                Text("Manage Spaces")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            .padding(.leading, 28)
            .padding(.trailing, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
    }

    private func column(_ space: Space, index: Int, height: CGFloat) -> some View {
        let color = Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
        let pinned = tierNotes(space, tier: .pinned)
        let random = tierNotes(space, tier: .random)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                MacSpaceIcon.view(space.emoji, size: 15)
                Text(space.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                if space.id == activeSpaceID {
                    Circle().fill(.primary.opacity(0.4)).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(.primary.opacity(0.88))
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    // Both sections always render (even empty) so each stays a
                    // drop target for promote/demote, mirroring the sidebar.
                    noteSection(space, tier: .pinned, notes: pinned)
                    Rectangle()
                        .fill(.primary.opacity(0.12))
                        .frame(height: 1)
                        .padding(.horizontal, 14)
                    noteSection(space, tier: .random, notes: random)
                }
                .padding(.vertical, 6)
                // Clear the floating controls so the last note never sits under
                // the handle / menu.
                .padding(.bottom, 32)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height)
        .background(color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // No separate footer bar: a soft fade dissolves a long list into the
        // column color, with the move handle + menu floating at the corners.
        .overlay(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: color.opacity(0), location: 0),
                    .init(color: color, location: 0.7)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 52)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            columnHandle.padding(.leading, 12).padding(.bottom, 9)
        }
        .overlay(alignment: .bottomTrailing) {
            columnMenu(space).padding(.trailing, 12).padding(.bottom, 9)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.06 : 0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.14),
                radius: draggingSpaceID == space.id ? 18 : 8, x: 0, y: draggingSpaceID == space.id ? 10 : 4)
    }

    @ViewBuilder
    private func noteMenu(_ note: Note, space: Space) -> some View {
        if selection.count > 1, selection.contains(note.id) {
            let n = selection.count
            Button("Make \(n) Essential", systemImage: "star.fill") { batch(space) { promote($0, to: .favorite, space: space) } }
            Button("Pin \(n) Notes", systemImage: "pin.fill") { batch(space) { promote($0, to: .pinned, space: space) } }
            Button("Move \(n) to Notes", systemImage: "tray") { batch(space) { promote($0, to: .random, space: space) } }
            Divider()
            Button("Delete \(n) Notes", systemImage: "trash", role: .destructive) {
                batch(space) { try? NoteService(context: modelContext).delete($0) }
            }
        } else {
            Button("Open", systemImage: "doc.text") { onOpenSpace(space) }
            Divider()
            Button("Make Essential", systemImage: "star.fill") { promote(note, to: .favorite, space: space) }
            Button("Pin", systemImage: "pin.fill") { promote(note, to: .pinned, space: space) }
            Button("Move to Notes", systemImage: "tray") { promote(note, to: .random, space: space) }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") { _ = try? NoteService(context: modelContext).duplicate(note) }
            Button("Archive", systemImage: "archivebox") { try? NoteService(context: modelContext).archive(note) }
            Button("Delete", systemImage: "trash", role: .destructive) { try? NoteService(context: modelContext).delete(note) }
        }
    }

    private func promote(_ note: Note, to tier: NoteTier, space: Space) {
        try? NoteService(context: modelContext).promote(note, to: tier, currentSpace: space)
    }

    /// Apply an action to every selected note in this space, then clear.
    private func batch(_ space: Space, _ action: (Note) -> Void) {
        for note in notesProvider(space).filter({ selection.contains($0.id) }) { action(note) }
        selection.clear()
    }

    /// ⌘-click toggles a row, ⇧-click selects a range, plain click (no drag)
    /// clears. Reads live modifier flags so it composes with the reorder drag.
    private func selectionGesture(note: Note, orderedIDs: [UUID]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                guard !selectPressHandled else { return }
                selectPressHandled = true
                #if canImport(AppKit)
                let flags = NSEvent.modifierFlags
                if flags.contains(.command) { selection.toggle(note.id) }
                else if flags.contains(.shift) { selection.selectRange(to: note.id, in: orderedIDs) }
                #endif
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 4
                #if canImport(AppKit)
                let flags = NSEvent.modifierFlags
                let modified = flags.contains(.command) || flags.contains(.shift)
                if !moved, !modified { selection.clear() }
                #endif
                selectPressHandled = false
            }
    }

    /// Decorative drag affordance (the whole column is the reorder drag target).
    private var columnHandle: some View {
        ColumnDragHandle(isDragging: draggingSpaceID != nil)
    }

    private func columnMenu(_ space: Space) -> some View {
        Menu {
            Button("Open Space", systemImage: "arrow.right.circle") { onOpenSpace(space) }
            if spaces.count > 1 {
                Divider()
                Button("Delete Space", systemImage: "trash", role: .destructive) { requestDeleteSpace(space) }
            }
        } label: {
            ColumnMenuGlyph()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }

    // MARK: - Space (column) reorder — fixed pitch

    private func spaceOffset(index: Int, id: UUID) -> CGFloat {
        guard draggingSpaceID != nil else { return 0 }
        if id == draggingSpaceID { return spaceDragX }
        let s = spaceSourceIndex, c = spaceCurrentIndex
        if c > s, index > s, index <= c { return -spacePitch }
        if c < s, index >= c, index < s { return spacePitch }
        return 0
    }

    private func spaceReorderGesture(space: Space, index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard spaces.count > 1 else { return }
                if draggingSpaceID == nil {
                    draggingSpaceID = space.id
                    spaceSourceIndex = index
                    spaceCurrentIndex = index
                }
                spaceDragX = value.translation.width
                let shift = Int((spaceDragX / spacePitch).rounded())
                let clamped = min(max(0, spaceSourceIndex + shift), spaces.count - 1)
                if clamped != spaceCurrentIndex {
                    withAnimation(.smooth(duration: 0.18)) { spaceCurrentIndex = clamped }
                }
            }
            .onEnded { _ in
                // Glide the column to its target slot, then commit — so a column
                // dragged far past its landing spot snaps cleanly into place.
                let target = CGFloat(spaceCurrentIndex - spaceSourceIndex) * spacePitch
                withAnimation(.smooth(duration: 0.18)) {
                    spaceDragX = target
                } completion: {
                    commitSpaceReorder()
                }
            }
    }

    private func commitSpaceReorder() {
        if draggingSpaceID != nil, spaces.indices.contains(spaceSourceIndex) {
            var ids = spaces.map(\.id)
            let moved = ids.remove(at: spaceSourceIndex)
            ids.insert(moved, at: min(spaceCurrentIndex, ids.count))
            for (i, sid) in ids.enumerated() {
                spaces.first(where: { $0.id == sid })?.sortIndex = i
            }
            try? modelContext.save()
        }
        draggingSpaceID = nil
        spaceDragX = 0
    }

    // MARK: - Tier sections + note reorder within a column

    /// Notes of one tier (Pinned or Random) for a space, preserving the order
    /// from `notesProvider` (which is already manual-sorted).
    private func tierNotes(_ space: Space, tier: NoteTier) -> [Note] {
        notesProvider(space).filter { $0.tier == tier }
    }

    private func noteSection(_ space: Space, tier: NoteTier, notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: noteSpacing) {
            ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                let isSource = draggingNoteID == note.id
                ManageBoardNoteRow(note: note, height: noteRowHeight,
                                   isDragging: false, isSelected: selection.contains(note.id))
                    // Hidden while dragging (the ghost shows it). Collapsed to 0
                    // height once it's heading to a different section (other
                    // tier and/or other space's column) so the source shrinks
                    // and the separator slides — like the sidebar.
                    .opacity(isSource ? 0 : 1)
                    .frame(height: (isSource && !isSameSection) ? 0 : noteRowHeight)
                    .clipped()
                    .offset(y: noteOffset(spaceID: space.id, tier: tier, index: i, id: note.id))
                    .contextMenu { noteMenu(note, space: space) }
                    .highPriorityGesture(noteReorderGesture(note: note, space: space, tier: tier, index: i, count: notes.count))
                    .simultaneousGesture(selectionGesture(note: note, orderedIDs: notes.map(\.id)))
            }
            // Real gap height reserved in the tier the cursor is hovering (when
            // it differs from the note's own tier) so that section actually
            // grows — this is what makes the separator move (sidebar parity).
            Color.clear.frame(height: trailingGap(space: space, tier: tier))
        }
        .frame(maxWidth: .infinity, minHeight: notes.isEmpty ? 30 : nil, alignment: .top)
        .padding(.horizontal, 8)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(boardSpace))
        } action: { sectionFrames["\(space.id.uuidString)|\(tier.rawValue)"] = $0 }
    }

    /// Visual gap: rows shift to open the landing slot. Within the source
    /// section it shifts the rows between source and target; for any other
    /// section (other tier and/or other space) it pushes the hovered section's
    /// rows down from the insert slot. (The dragged row is hidden — the ghost
    /// carries it.)
    private func noteOffset(spaceID: UUID, tier: NoteTier, index: Int, id: UUID) -> CGFloat {
        guard draggingNoteID != nil, id != draggingNoteID else { return 0 }
        if isSameSection {
            guard spaceID == noteDragSpaceID, tier == noteDragTier else { return 0 }
            let s = noteSourceIndex, c = noteCurrentIndex
            if c > s, index > s, index <= c { return -notePitch }
            if c < s, index >= c, index < s { return notePitch }
            return 0
        } else {
            if spaceID == noteHoverSpaceID, tier == noteHoverTier {
                return index >= noteCrossIndex ? notePitch : 0
            }
            return 0
        }
    }

    /// Real height reserved at the hovered target section (when it differs from
    /// the source) so it grows and the separator moves — sidebar parity.
    private func trailingGap(space: Space, tier: NoteTier) -> CGFloat {
        guard draggingNoteID != nil, !isSameSection else { return 0 }
        return (space.id == noteHoverSpaceID && tier == noteHoverTier) ? notePitch : 0
    }

    /// The space + tier section under a board-space point: nearest column by X,
    /// then tier by Y. Enables dragging a note into another space's column.
    private func hoverTarget(at point: CGPoint) -> (UUID, NoteTier)? {
        var bestSpace: UUID?
        var bestDx = CGFloat.greatestFiniteMagnitude
        for s in spaces {
            let f = sectionFrames["\(s.id.uuidString)|\(NoteTier.pinned.rawValue)"]
                ?? sectionFrames["\(s.id.uuidString)|\(NoteTier.random.rawValue)"]
            guard let f else { continue }
            let dx = point.x < f.minX ? f.minX - point.x : (point.x > f.maxX ? point.x - f.maxX : 0)
            if dx < bestDx { bestDx = dx; bestSpace = s.id }
        }
        guard let sid = bestSpace else { return nil }
        let pinnedKey = "\(sid.uuidString)|\(NoteTier.pinned.rawValue)"
        let tier: NoteTier = (sectionFrames[pinnedKey].map { point.y <= $0.maxY } ?? false) ? .pinned : .random
        return (sid, tier)
    }

    private func noteReorderGesture(note: Note, space: Space, tier: NoteTier, index: Int, count: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(boardSpace))
            .onChanged { value in
                if draggingNoteID == nil {
                    draggingNoteID = note.id
                    draggedNote = note
                    noteDragSpaceID = space.id
                    noteHoverSpaceID = space.id
                    noteDragTier = tier
                    noteHoverTier = tier
                    noteSourceIndex = index
                    noteCurrentIndex = index
                    noteCrossIndex = index
                }
                noteDragY = value.translation.height
                noteGhostPoint = value.location   // ghost tracks the cursor

                if let (hSpace, hTier) = hoverTarget(at: value.location),
                   hSpace != noteHoverSpaceID || hTier != noteHoverTier {
                    withAnimation(.smooth(duration: 0.18)) {
                        noteHoverSpaceID = hSpace
                        noteHoverTier = hTier
                    }
                }

                if isSameSection {
                    if count > 1 {
                        let shift = Int((noteDragY / notePitch).rounded())
                        let clamped = min(max(0, noteSourceIndex + shift), count - 1)
                        if clamped != noteCurrentIndex {
                            withAnimation(.smooth(duration: 0.18)) { noteCurrentIndex = clamped }
                        }
                    }
                } else if let hsid = noteHoverSpaceID, let hTier = noteHoverTier,
                          let hSpace = spaces.first(where: { $0.id == hsid }) {
                    let frame = sectionFrames["\(hsid.uuidString)|\(hTier.rawValue)"] ?? .zero
                    let localY = value.location.y - frame.minY
                    let raw = Int((localY / notePitch).rounded(.down))
                    let cnt = tierNotes(hSpace, tier: hTier).count
                    let clamped = min(max(0, raw), cnt)
                    if clamped != noteCrossIndex {
                        withAnimation(.smooth(duration: 0.18)) { noteCrossIndex = clamped }
                    }
                }
            }
            .onEnded { _ in commitNoteDrag(note: note, sourceSpace: space) }
    }

    private func commitNoteDrag(note: Note, sourceSpace: Space) {
        guard let dragTier = noteDragTier else { clearNoteDrag(); return }
        let same = isSameSection
        let targetTier = noteHoverTier ?? dragTier
        let targetSpaceID = noteHoverSpaceID ?? sourceSpace.id
        let targetIndex = same ? noteCurrentIndex : noteCrossIndex

        // Glide the ghost into the open gap (in whatever column/tier), commit.
        let tgtFrame = sectionFrames["\(targetSpaceID.uuidString)|\(targetTier.rawValue)"] ?? .zero
        let targetPoint = CGPoint(
            x: tgtFrame.midX,
            y: tgtFrame.minY + CGFloat(targetIndex) * notePitch + noteRowHeight / 2
        )

        withAnimation(.smooth(duration: 0.18)) {
            noteGhostPoint = targetPoint
        } completion: {
            if same {
                commitNoteReorder(space: sourceSpace, tier: dragTier)
            } else if let target = spaces.first(where: { $0.id == targetSpaceID }) {
                commitMove(note: note, from: sourceSpace, fromTier: dragTier,
                           to: target, tier: targetTier, at: targetIndex)
            }
            clearNoteDrag()
        }
    }

    /// Reorders one tier's notes and writes sequential `manualSortIndex`.
    private func commitNoteReorder(space: Space, tier: NoteTier) {
        var arr = tierNotes(space, tier: tier)
        guard arr.indices.contains(noteSourceIndex) else { return }
        let moved = arr.remove(at: noteSourceIndex)
        arr.insert(moved, at: min(noteCurrentIndex, arr.count))
        for (i, n) in arr.enumerated() { n.manualSortIndex = i }
        try? modelContext.save()
    }

    /// Moves a note to another tier and/or space at a specific slot, reindexing
    /// both the destination tier and the tier it left.
    private func commitMove(note: Note, from sourceSpace: Space, fromTier: NoteTier,
                            to targetSpace: Space, tier: NoteTier, at index: Int) {
        // Destination peers captured before mutating the note.
        let destOthers = notesProvider(targetSpace).filter { $0.tier == tier && $0.id != note.id }
        note.tier = tier
        note.space = targetSpace
        note.folder = nil
        var dest = destOthers
        dest.insert(note, at: min(max(0, index), dest.count))
        for (i, n) in dest.enumerated() { n.manualSortIndex = i }
        // Reindex the tier it left (it's gone from there now).
        let src = notesProvider(sourceSpace).filter { $0.tier == fromTier && $0.id != note.id }
        for (i, n) in src.enumerated() { n.manualSortIndex = i }
        try? modelContext.save()
    }

    private func clearNoteDrag() {
        draggingNoteID = nil
        draggedNote = nil
        noteDragSpaceID = nil
        noteHoverSpaceID = nil
        noteDragTier = nil
        noteHoverTier = nil
        noteDragY = 0
    }

    private var ghostWidth: CGFloat { columnWidth - 24 }
}

/// One note row in the Manage Spaces board — icon + title with a hover tint.
private struct ManageBoardNoteRow: View {
    let note: Note
    let height: CGFloat
    let isDragging: Bool
    var isSelected: Bool = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            MacNoteMiniIcon(note: note, size: 18)
            Text(note.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                // Display-only — stop SwiftUI's selectable-Text I-beam cursor
                // (the row itself owns hover/click via its contentShape).
                .allowsHitTesting(false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(
            rowFill,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected { return .white.opacity(0.4) }
        if isHovering || isDragging { return .white.opacity(0.22) }
        return .clear
    }
}
#endif
