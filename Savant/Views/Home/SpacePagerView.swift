import SwiftData
import SwiftUI

struct SpacePagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @Query(sort: \Space.sortIndex) private var spaces: [Space]
    @Query(sort: \Note.createdAt) private var notes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]
    @Query(sort: \TidyRun.startedAt, order: .reverse) private var tidyRuns: [TidyRun]

    @State private var keyboardDismissRequest = 0
    @State private var isInputFocused = false

    /// Edit (multi-select) mode. ONE instance for the whole pager — it keys on
    /// `spaceID`, so the single anchored header and the per-space rows all read
    /// the same source of truth, and the action bar floats once at the bottom.
    @State private var interaction = InteractionMode()

    /// The space the inner pager is currently scrolled to (two-way bound to the
    /// inner paging scroll). Kept in sync with `appState.selectedSpaceID`.
    @State private var pagerID: UUID?
    /// Fractional page index from the inner pager's live scroll offset. Lives in
    /// an @Observable model so per-frame swipe updates invalidate ONLY the leaf
    /// views that read it (`SpaceColorFill`) — never this pager body.
    @State private var pageOffset = SpacePageOffsetModel()
    /// The custom drag engine — one instance for the whole pager so a drag can
    /// outlive page switches (P4 cross-space). Injected into every page.
    @State private var dragSession = TouchDragSession()
    /// Drives the shared outer vertical scroll programmatically during a drag
    /// (auto-scroll); also lets external code scroll to the bottom on new notes.
    @State private var outerScroll = ScrollPosition()

    /// Measured natural height per space, so the inner paging scroll can be laid
    /// out at the active space's full content height (the outer scroll scrolls).
    @State private var pageHeights: [UUID: CGFloat] = [:]
    @State private var viewportHeight: CGFloat = 700
    @State private var viewportWidth: CGFloat = 390
    /// Live manual horizontal offset of the inner pager during second-finger
    /// steering (the pager is scroll-disabled mid-drag, so steering can't use
    /// the native scroll). 0 whenever not steering.
    @State private var steerOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Continuous background tint that interpolates between adjacent
                // spaces as you swipe, plus the identity film grain.
                SpaceBackdrop(spaces: spaces, pageOffset: pageOffset)
                    .ignoresSafeArea()

                if spaces.isEmpty {
                    EmptyWorkspaceView()
                } else {
                    outerScrollView

                    InputBarView(
                        currentSpace: activeSpace,
                        keyboardDismissRequest: keyboardDismissRequest,
                        isInputFocused: $isInputFocused
                    )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .zIndex(2)

                    if let activeSpace, interaction.isEditing(spaceID: activeSpace.id) {
                        MultiSelectActionBar(space: activeSpace, spaces: spaces, allNotes: notes)
                            .padding(.bottom, 8)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .zIndex(2.5)
                    }

                    DragGhostOverlay(session: dragSession)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .environment(dragSession)
            .environment(interaction)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: interaction.isEditing)
            .onAppear { viewportHeight = proxy.size.height; viewportWidth = proxy.size.width }
            .onChange(of: proxy.size.height) { _, h in viewportHeight = h }
            .onChange(of: proxy.size.width) { _, w in viewportWidth = w }
        }
    }

    // MARK: - Pinned header bar (anchored — never scrolls, never translates)

    /// The locked header, pinned via `.safeAreaInset` so the scroll content is
    /// inset to exactly its height (no manual measurement) yet still slides
    /// UNDER it as you scroll. Solid blended-space-color backing makes the rows
    /// + Essentials vanish seamlessly underneath.
    private var headerBar: some View {
        Group {
            if let activeSpace {
                SpaceHeaderView(
                    space: activeSpace,
                    spaces: spaces,
                    selectedIndex: selectedIndex,
                    selectSpaceAtIndex: selectSpace(at:),
                    tidyNow: { tidy(activeSpace) },
                    pageOffset: pageOffset
                )
                // Horizontal insets now live INSIDE the header (title rest-inset
                // + trailing control padding) so the title can slide to the real
                // screen edge instead of clipping at the page margin.
                .padding(.top, 8)
                .padding(.bottom, 10)
                // Full backdrop (color blend + grain), NOT a flat fill, so the
                // locked header carries the same texture as the rest of the
                // screen — grain is random noise, so the header patch meets the
                // backdrop behind it seamlessly. Still opaque, so content
                // vanishes under the header as it scrolls.
                .background {
                    SpaceBackdrop(spaces: spaces, pageOffset: pageOffset)
                        .ignoresSafeArea(edges: .top)
                }
            }
        }
    }

    // MARK: - Shared outer vertical scroll (Essentials + inner rows pager)

    private var outerScrollView: some View {
        ScrollView(.vertical) {
            VStack(spacing: SavantTheme.tierSpacing) {
                if let latestVisibleRun, !interaction.isEditing {
                    TidyBannerView(run: latestVisibleRun)
                        .padding(.horizontal, SavantTheme.pageMargin)
                }

                // Essentials — rendered ONCE (favorites are space-agnostic), so
                // it's a single horizontally-anchored instance that still scrolls
                // away vertically. Always the "active" page for the engine.
                FavoritesTileRow(
                    notes: favoriteNotes,
                    allNotes: notes,
                    spaces: spaces,
                    currentSpace: activeSpace ?? spaces[0]
                )
                .environment(\.isActiveSpacePage, true)
                .padding(.horizontal, SavantTheme.pageMargin)

                innerPager
            }
            // ONE coordinate space for the entire drag surface: Essentials cards
            // AND the active page's rows report frames here, so cross-tier drags
            // resolve in a single space. Stable under vertical scroll (only the
            // origin moves — tracked via `contentOriginChanged`).
            .coordinateSpace(.named("spaceContent"))
            .onGeometryChange(for: CGPoint.self) { proxy in
                proxy.frame(in: .global).origin
            } action: { origin in
                dragSession.contentOriginChanged(origin)
            }
        }
        .scrollPosition($outerScroll)
        .scrollIndicators(.hidden)
        // Mid-drag, NO native scroll may engage a touch: a UIScrollView that
        // starts dragging cancels every content touch — including the drag
        // finger. Auto-scroll drives `outerScroll` programmatically (allowed).
        .scrollDisabled(dragSession.isActive)
        // THE lift recognizer — one for the WHOLE drag surface (Essentials +
        // the rows pager below), attached here on the stable outer scroll so it
        // covers both and survives the inner pager re-laying-out pages mid-drag.
        // Its delegate only takes touches that land on a registered active row.
        .gesture(DragLiftGesture(session: dragSession))
        // Second finger steers the pager mid-drag (one space per swipe step).
        .gesture(DragSpaceSwipeGesture(session: dragSession))
        // Pins the header and insets the content to its height automatically —
        // content still scrolls UNDER the opaque bar.
        .safeAreaInset(edge: .top, spacing: 0) { headerBar }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y
        } action: { _, offsetY in
            dragSession.liveScrollOffsetY = offsetY
        }
        // The outer scroll never translates horizontally, so its frame is the
        // stable reference for the edge bands + auto-scroll bands.
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            dragSession.viewportGlobal = frame
        }
        .overlay { AutoScrollDriver(session: dragSession, position: $outerScroll) }
    }

    /// Custom horizontal paging pager — ONLY the per-space note rows live here,
    /// so the header and Essentials stay put while the rows swipe. EAGER HStack
    /// (not lazy): tearing down the page that owns the drag's hit-tested row
    /// cancels the touch mid-drag. Laid out at the active space's full height;
    /// the outer scroll does the scrolling.
    private var innerPager: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(spaces, id: \.id) { space in
                    SpaceView(
                        space: space,
                        spaces: spaces,
                        notes: notes,
                        folders: folders,
                        selectedIndex: selectedIndex,
                        hasEssentials: hasEssentials,
                        // FREEZE the measured height during a drag: mid-drag the
                        // content changes height constantly (gaps, folder hovers,
                        // reveal bands). Letting that resize the page frame
                        // un-animated makes the pinned/flow boundary jump
                        // chaotically AND churns the layout under the live lift
                        // recognizer (which can orphan it → lifts stop working).
                        // The content reflows smoothly WITHIN the frozen frame.
                        onHeight: { if !dragSession.isActive { pageHeights[space.id] = $0 } }
                    )
                    // Force EVERY page to the same height (the pager's frame)
                    // and top-align it. Without this the HStack is as tall as
                    // the tallest space while the frame tracks the active one —
                    // a mismatch that mis-positions shorter active spaces (top
                    // rows hidden). `onHeight` measures the natural height
                    // INSIDE SpaceView (before this frame), so no layout loop.
                    .frame(height: innerPagerHeight, alignment: .top)
                    .containerRelativeFrame([.horizontal])
                    .id(space.id)
                }
            }
            .scrollTargetLayout()
            // Second-finger steering shifts the whole strip manually (the scroll
            // is disabled mid-drag); 0 except while steering, so normal swiping
            // is untouched.
            .offset(x: steerOffset)
        }
        .frame(height: innerPagerHeight)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerID)
        .scrollIndicators(.hidden)
        .scrollDisabled(dragSession.isActive)
        // Lift + steering gestures live on the outer scroll (they must cover the
        // anchored Essentials too) — see `outerScrollView`.
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.containerSize.width > 0 ? geo.contentOffset.x / geo.containerSize.width : 0
        } action: { _, newValue in
            pageOffset.value = newValue
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                if isInputFocused { dismissInputKeyboard() }
            }
        )
        .onAppear {
            ensureSelection()
            if pagerID == nil { pagerID = appState.selectedSpaceID }
            wireDragSession()
            dragSession.orderedSpaceIDs = spaces.map(\.id)
            dragSession.activeSpacePageChanged(pagerID)
        }
        .onChange(of: spaces.map(\.id)) { _, ids in
            ensureSelection()
            if pagerID == nil || !spaces.contains(where: { $0.id == pagerID }) {
                pagerID = appState.selectedSpaceID
            }
            dragSession.orderedSpaceIDs = ids
        }
        // Swipe settled on a new page → commit it as the selection, repoint the
        // engine, and leave any stale edit mode behind.
        .onChange(of: pagerID) { _, newID in
            if let newID, newID != appState.selectedSpaceID {
                appState.selectedSpaceID = newID
            }
            if interaction.isEditing, let newID, !interaction.isEditing(spaceID: newID) {
                interaction.exitEditMode()
            }
            dragSession.activeSpacePageChanged(newID)
        }
        // External selection (rail tap / switcher) → scroll the pager there,
        // animating through the intermediate colors.
        .onChange(of: appState.selectedSpaceID) { _, newID in
            if let newID, newID != pagerID {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    pagerID = newID
                }
            }
        }
    }

    /// Height every page (and the inner pager) is laid out at. The active
    /// space's natural height, but floored at the viewport so a short space
    /// still fills the screen and an incoming taller page is only ever clipped
    /// BELOW the fold during a swipe — never mid-screen. Reads only settle-time
    /// `pagerID` + measured heights (never `pageOffset`), so the body doesn't
    /// re-run every swipe frame (the per-frame perf invariant).
    private var innerPagerHeight: CGFloat {
        max(pagerID.flatMap { pageHeights[$0] } ?? 0, viewportHeight)
    }

    private var hasEssentials: Bool {
        // Real content only — see SpaceView: empty tiers don't pop on drag.
        !favoriteNotes.isEmpty
    }

    // MARK: - Derived data

    private var activeSpace: Space? {
        guard let selectedSpaceID = appState.selectedSpaceID else { return spaces.first }
        return spaces.first { $0.id == selectedSpaceID } ?? spaces.first
    }

    private var selectedIndex: Int {
        guard let activeSpace else { return 0 }
        return spaces.firstIndex(where: { $0.id == activeSpace.id }) ?? 0
    }

    private var favoriteNotes: [Note] {
        notes
            .filter { $0.tier == .favorite }
            .sorted(by: TierRowsBuilder.noteSort)
    }

    private var latestVisibleRun: TidyRun? {
        tidyRuns.first { $0.completedAt != nil && !$0.bannerDismissed && ($0.notesArchived > 0 || $0.foldersCreated > 0) }
    }

    private func ensureSelection() {
        guard appState.selectedSpaceID == nil || !spaces.contains(where: { $0.id == appState.selectedSpaceID }) else { return }
        appState.selectedSpaceID = spaces.first?.id
    }

    private func selectSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        appState.selectedSpaceID = spaces[index].id
    }

    private func tidy(_ space: Space) {
        Task { @MainActor in
            do {
                let run = try await TidyService(context: modelContext).tidy(
                    space: space,
                    notes: notes,
                    trigger: .manual
                )
                if run.notesProcessed > 0 || run.notesArchived > 0 || run.foldersCreated > 0 {
                    appState.presentedSheet = .tidyReview(run)
                }
            } catch {
                assertionFailure("Manual tidy failed: \(error)")
            }
        }
    }

    /// Cross-space drag hook (P4): the session asks the pager to page over
    /// (edge hold). Drops always commit through the active page's contexts.
    private func wireDragSession() {
        dragSession.requestSpaceSwitch = { id in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                pagerID = id
            }
        }
        // Continuous steering: translate the inner strip 1:1 with the finger,
        // clamped so you can't scrub past the first/last space.
        dragSession.steerChanged = { tx in
            let ids = dragSession.orderedSpaceIDs
            guard let pid = pagerID, let idx = ids.firstIndex(of: pid) else { return }
            let w = max(viewportWidth, 1)
            let minOff = -CGFloat(ids.count - 1 - idx) * w   // clamp at last space
            let maxOff = CGFloat(idx) * w                    // clamp at first space
            let clamped = min(max(tx, minOff), maxOff)
            steerOffset = clamped
            pageOffset.value = CGFloat(idx) - clamped / w
        }
        // Release: snap to the nearest space (honoring the flick), then hand the
        // committed page back to the real scroll position seamlessly.
        dragSession.steerEnded = { predicted in
            let ids = dragSession.orderedSpaceIDs
            guard let pid = pagerID, let idx = ids.firstIndex(of: pid) else { return }
            let w = max(viewportWidth, 1)
            let target = min(max(0, Int((CGFloat(idx) - predicted / w).rounded())), ids.count - 1)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                steerOffset = CGFloat(idx - target) * w
                pageOffset.value = CGFloat(target)
            }
            // After the snap settles, jump the scroll to the target page and
            // zero the manual offset in the SAME tick — the on-screen page is
            // identical before and after, so the swap is invisible.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                if pagerID != ids[target] { pagerID = ids[target] }
                steerOffset = 0
            }
        }
    }

    private func dismissInputKeyboard() {
        keyboardDismissRequest += 1
        isInputFocused = false
        dismissKeyboard()
    }
}

/// Fractional page index holder. @Observable so only views that READ `value`
/// in their body (the color leaves) re-evaluate per swipe frame.
@Observable @MainActor
final class SpacePageOffsetModel {
    var value: CGFloat = 0
}

/// Continuous space-color fill, driven by the live fractional page offset.
/// A leaf so per-swipe-frame color changes invalidate only this view — used
/// both as the screen backdrop and as the locked header's solid backing.
struct SpaceColorFill: View {
    let spaces: [Space]
    let pageOffset: SpacePageOffsetModel
    let scheme: ColorScheme

    var body: some View {
        Rectangle().fill(displaySpaceColor)
    }

    private func color(for space: Space?) -> Color {
        guard let space else { return Color(hex: "#C8D5C0") }
        return Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: scheme)
    }

    private var clampedOffset: CGFloat {
        guard !spaces.isEmpty else { return 0 }
        return max(0, min(CGFloat(spaces.count - 1), pageOffset.value))
    }

    private var displaySpaceColor: Color {
        guard !spaces.isEmpty else { return color(for: nil) }
        let clamped = clampedOffset
        let floorIdx = Int(clamped.rounded(.down))
        let ceilIdx = min(floorIdx + 1, spaces.count - 1)
        let t = clamped - CGFloat(floorIdx)
        return color(for: spaces[floorIdx]).mixed(with: color(for: spaces[ceilIdx]), by: t)
    }
}

/// Leaf view owning the per-frame background work: continuous color blend
/// between adjacent spaces + the identity film grain. Nothing outside this
/// view observes the live offset.
private struct SpaceBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    let spaces: [Space]
    let pageOffset: SpacePageOffsetModel

    var body: some View {
        ZStack {
            SpaceColorFill(spaces: spaces, pageOffset: pageOffset, scheme: colorScheme)
            GrainOverlay(intensity: grainIntensity)
                .allowsHitTesting(false)
        }
    }

    private var clampedOffset: CGFloat {
        guard !spaces.isEmpty else { return 0 }
        return max(0, min(CGFloat(spaces.count - 1), pageOffset.value))
    }

    /// Grain follows the nearest space's gradient config (0…15 dial, same as
    /// macOS); spaces without a config get a subtle default.
    private var grainIntensity: Double {
        guard !spaces.isEmpty else { return 0.3 }
        let nearest = spaces[Int(clampedOffset.rounded())]
        guard let data = nearest.gradientConfigJSON,
              let config = ZenGradientConfig.decode(data)
        else { return 0.3 }
        return Double(config.grain) / 15.0
    }
}

private struct EmptyWorkspaceView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.square.filled.on.square")
                .font(.system(size: 44, weight: .semibold))
            Text("Create your first space")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Spaces give your notes a place to land.")
                .font(.body)
                .foregroundStyle(.secondary)
            GlassCapsuleButton {
                appState.presentedSheet = .newSpace
            } content: {
                Label("New space", systemImage: "plus")
            }
        }
        .padding(28)
        .multilineTextAlignment(.center)
    }
}
