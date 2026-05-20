import SwiftData
import SwiftUI

#if os(macOS)
struct MacRootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Space.sortIndex) private var spaces: [Space]
    @Query(sort: \Note.createdAt) private var notes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]

    @State private var selectedSpaceID: UUID?
    @State private var selectedNoteIDsBySpace: [UUID: UUID] = [:]
    @State private var sidebarWidth: CGFloat = 300
    @State private var lastExpandedSidebarWidth: CGFloat = 300
    @State private var spacePageOffset: CGFloat = 0 // fractional page index, animated
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

    private func color(for space: Space?) -> Color {
        guard let space else { return Color(hex: "#C8D5C0") }
        return Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    /// Continuous color interpolation driven by the sidebar pager's scroll
    /// offset. `spacePageOffset` is fractional (e.g. 1.4 means we're 40% of
    /// the way from space[1] to space[2]).
    private var displaySpaceColor: Color {
        guard !spaces.isEmpty else { return color(for: nil) }
        let clamped = max(0, min(CGFloat(spaces.count - 1), spacePageOffset))
        let floorIdx = Int(clamped.rounded(.down))
        let ceilIdx = min(floorIdx + 1, spaces.count - 1)
        let t = clamped - CGFloat(floorIdx)
        let a = color(for: spaces[floorIdx])
        let b = color(for: spaces[ceilIdx])
        return a.mixed(with: b, by: t)
    }

    var body: some View {
        ZStack {
            MacSpaceBackground(tint: displaySpaceColor)

            HStack(spacing: 0) {
                MacNotesSidebar(
                    spaces: spaces,
                    notes: notes,
                    folders: folders,
                    selectedSpaceID: $selectedSpaceID,
                    selectedNoteIDsBySpace: $selectedNoteIDsBySpace,
                    spacePageOffset: spacePageOffset,
                    width: sidebarWidth,
                    selectNote: selectNote,
                    createNote: createNote,
                    createSpace: createSpace,
                    toggleSidebar: toggleSidebar
                )
                .frame(width: sidebarWidth)
                .opacity(sidebarWidth == 0 ? 0 : 1)

                MacSidebarResizer(
                    width: $sidebarWidth,
                    lastExpandedWidth: $lastExpandedSidebarWidth
                )

                if let selectedSpace {
                    MacNoteWorkspace(
                        space: selectedSpace,
                        note: selectedNote,
                        createNote: { createNote(in: selectedSpace) }
                    )
                    .id(selectedSpace.id)
                    .transition(.opacity)
                } else {
                    Color.clear
                }
            }

            // Always-mounted ⌘S shortcut to toggle the sidebar from anywhere.
            Button(action: toggleSidebar) { Color.clear }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
        }
        .overlay(alignment: .topLeading) {
            // Hover-reveal sidebar: when collapsed, hovering the left edge
            // slides a floating preview of the sidebar over the editor.
            // Ported from Nook's SidebarHoverOverlayView.
            if sidebarWidth == 0, hoverManager.isVisible {
                MacNotesSidebar(
                    spaces: spaces,
                    notes: notes,
                    folders: folders,
                    selectedSpaceID: $selectedSpaceID,
                    selectedNoteIDsBySpace: $selectedNoteIDsBySpace,
                    spacePageOffset: spacePageOffset,
                    width: lastExpandedSidebarWidth,
                    selectNote: selectNote,
                    createNote: createNote,
                    createSpace: createSpace,
                    toggleSidebar: toggleSidebar
                )
                .frame(width: lastExpandedSidebarWidth)
                .frame(maxHeight: .infinity)
                // The docked sidebar's translucent material is designed to
                // sit on top of the space-tinted window background. When
                // floating over the bright editor pane it shows through too
                // much, so we lay in an opaque tinted base + thick material
                // *behind* the sidebar content.
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
        // The window uses fullSizeContentView so content extends under the
        // traffic lights. Ignore the titlebar safe area so the sidebar's top
        // inset is measured from the actual window top, not from below the lights.
        .ignoresSafeArea()
        .frame(minWidth: 720, minHeight: 520)
        .background(MacWindowConfigurator())
        .task {
            swipeMonitor.onSwipe = { direction in
                if direction > 0 { selectNextSpace() } else { selectPreviousSpace() }
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
        .onChange(of: selectedSpaceID) { _, newID in
            guard let id = newID, let idx = spaces.firstIndex(where: { $0.id == id }) else { return }
            // Fixed-duration animation, independent of swipe input speed.
            withAnimation(.smooth(duration: 0.32)) {
                spacePageOffset = CGFloat(idx)
            }
        }
        .onChange(of: spaces.map(\.id)) { _, _ in
            if let id = selectedSpaceID, let idx = spaces.firstIndex(where: { $0.id == id }) {
                spacePageOffset = CGFloat(idx)
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
            selectDefaultsIfNeeded()
        }
        .animation(.easeInOut(duration: 0.22), value: selectedSpace?.id)
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

    private func selectNextSpace() {
        guard let current = selectedSpace,
              let idx = spaces.firstIndex(where: { $0.id == current.id }),
              idx + 1 < spaces.count else { return }
        withAnimation(.snappy(duration: 0.22)) {
            selectedSpaceID = spaces[idx + 1].id
        }
    }

    private func selectPreviousSpace() {
        guard let current = selectedSpace,
              let idx = spaces.firstIndex(where: { $0.id == current.id }),
              idx > 0 else { return }
        withAnimation(.snappy(duration: 0.22)) {
            selectedSpaceID = spaces[idx - 1].id
        }
    }

    private func selectNote(_ note: Note, in space: Space) {
        withAnimation(.easeOut(duration: 0.12)) {
            selectedSpaceID = space.id
            selectedNoteIDsBySpace[space.id] = note.id
        }
    }

    private func createNote() {
        guard let selectedSpace else { return }
        createNote(in: selectedSpace)
    }

    private func createNote(in space: Space) {
        do {
            let note = try NoteService(context: modelContext).createBlankNote(in: space)
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
                    .animation(.easeInOut(duration: 0.15), value: isResizing)
                    .animation(.easeInOut(duration: 0.15), value: isHovering)
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
                                isHovering = true
                                NSCursor.resizeLeftRight.set()
                            }
                        }
                    } else {
                        isHovering = false
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
        Task { @MainActor [weak self] in self?.handle() }
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

/// Trackpad swipe detector. Emits one `onSwipe(direction)` call per gesture,
/// regardless of velocity or accumulated delta — the actual animation is run
/// at a fixed duration by the caller. While an animation is in flight, further
/// scroll events in the same gesture are consumed and ignored, so a fast swipe
/// never skips multiple spaces.
@MainActor
final class SpaceSwipeDirectionMonitor: ObservableObject {
    var onSwipe: (Int) -> Void = { _ in }

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var firedThisGesture = false
    private var cooldownUntil: Date = .distantPast

    private let triggerDelta: CGFloat = 18 // pts of horizontal scroll to fire
    private let cooldown: TimeInterval = 0.34 // matches the animation duration

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

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // New gesture: reset.
        if event.phase == .began {
            accumulated = 0
            firedThisGesture = false
        }

        // Let clearly-vertical gestures pass through to scrollable content.
        if !firedThisGesture, abs(dy) > abs(dx) * 1.2 {
            return event
        }

        // While animating or in cooldown, swallow horizontal events.
        if Date() < cooldownUntil { return nil }

        if firedThisGesture {
            // Already fired this gesture — consume remaining events.
            if event.phase == .ended || event.momentumPhase == .ended {
                firedThisGesture = false
                accumulated = 0
            }
            return nil
        }

        accumulated += dx
        if abs(accumulated) >= triggerDelta {
            // Negative accumulated dx = fingers moved right = next space.
            let direction = accumulated < 0 ? 1 : -1
            firedThisGesture = true
            cooldownUntil = Date().addingTimeInterval(cooldown)
            onSwipe(direction)
            accumulated = 0
            return nil
        }

        // Below threshold — consume to prevent stray horizontal motion in
        // the editor / lists, but don't trigger.
        return nil
    }
}

#endif
