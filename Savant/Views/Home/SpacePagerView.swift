import SwiftData
import SwiftUI

struct SpacePagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Space.sortIndex) private var spaces: [Space]
    @Query(sort: \Note.createdAt) private var notes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]
    @Query(sort: \TidyRun.startedAt, order: .reverse) private var tidyRuns: [TidyRun]

    @State private var keyboardDismissRequest = 0
    @State private var isInputFocused = false

    /// The space the pager is currently scrolled to (two-way bound to the
    /// scroll position). Kept in sync with `appState.selectedSpaceID`.
    @State private var pagerID: UUID?
    /// Fractional page index from the live scroll offset (e.g. 1.4 = 40% from
    /// space[1] → space[2]). Lives in an @Observable model so per-frame swipe
    /// updates invalidate ONLY the `SpaceBackdrop` leaf that reads it — never
    /// this pager body (the macOS `SpacePagerModel` perf invariant).
    @State private var pageOffset = SpacePageOffsetModel()
    /// The custom drag engine — one instance for the whole pager so a drag
    /// can outlive page switches (P4 cross-space drags). Injected into every
    /// page via the environment.
    @State private var dragSession = TouchDragSession()

    var body: some View {
        // GeometryReader gives us the real top safe-area inset (Dynamic Island
        // height). The paging ScrollView fills full height, so we push the
        // page content down by this inset explicitly.
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // Single background tint that interpolates between adjacent
                // spaces *continuously* as you swipe — not a crossfade-on-commit
                // — plus the identity film grain.
                SpaceBackdrop(spaces: spaces, pageOffset: pageOffset)
                    .ignoresSafeArea()

                if spaces.isEmpty {
                    EmptyWorkspaceView()
                } else {
                    spacePager(topInset: proxy.safeAreaInsets.top)

                    InputBarView(
                        currentSpace: currentSpace,
                        keyboardDismissRequest: keyboardDismissRequest,
                        isInputFocused: $isInputFocused
                    )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                        .zIndex(2)

                    DragGhostOverlay(session: dragSession)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(3)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .environment(dragSession)
        }
    }

    /// Custom paging pager (replaces `TabView(.page)`, which hid its swipe
    /// offset). A horizontal paging `ScrollView` whose live offset we read via
    /// `onScrollGeometryChange` to drive the background blend, while
    /// `scrollPosition` two-way-binds the committed page to the selection.
    private func spacePager(topInset: CGFloat) -> some View {
        ScrollView(.horizontal) {
            // EAGER on purpose (was LazyHStack): a lazy pager destroys pages
            // ~2 away, and tearing down the page that owns the drag's
            // hit-tested row CANCELS the touch mid-drag — cross-space drags
            // died and force-dropped. Page count is small and each page's
            // list is lazy vertically; do not swap back.
            HStack(spacing: 0) {
                ForEach(spaces, id: \.id) { space in
                    SpaceView(
                        space: space,
                        spaces: spaces,
                        notes: notes,
                        folders: folders,
                        latestTidyRun: latestVisibleRun,
                        selectedIndex: selectedIndex,
                        selectSpaceAtIndex: selectSpace(at:),
                        topInset: topInset,
                        tidyNow: { tidy(space) }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(space.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $pagerID)
        .scrollIndicators(.hidden)
        // Mid-drag, NO native scroll view may engage a touch: a UIScrollView
        // that starts dragging cancels every touch in its content — including
        // the drag finger (the "ghost snaps without release" bug). Steering
        // and paging mid-drag are all programmatic (edge hold + swipe pan).
        .scrollDisabled(dragSession.isActive)
        // THE lift recognizer — one for all rows, attached here so it
        // survives the LazyHStack tearing pages down mid-drag (cross-space).
        // Its delegate only takes touches that land on registered rows.
        .gesture(DragLiftGesture(session: dragSession))
        // Second finger steers the pager mid-drag (one space per swipe step).
        .gesture(DragSpaceSwipeGesture(session: dragSession))
        // Pages fill full height (full-bleed under the Dynamic Island); each
        // SpaceView pads its header down by `topInset` so the rail clears it.
        .ignoresSafeArea(edges: .top)
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
        // Swipe settled on a new page → commit it as the selection.
        .onChange(of: pagerID) { _, newID in
            if let newID, newID != appState.selectedSpaceID {
                appState.selectedSpaceID = newID
            }
            dragSession.activeSpacePageChanged(newID)
        }
        // External selection (symbol rail / switcher) → scroll the pager there,
        // animating through the intermediate colors.
        .onChange(of: appState.selectedSpaceID) { _, newID in
            if let newID, newID != pagerID {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.9)) {
                    pagerID = newID
                }
            }
        }
    }

    private var currentSpace: Space? {
        guard let selectedSpaceID = appState.selectedSpaceID else { return spaces.first }
        return spaces.first { $0.id == selectedSpaceID } ?? spaces.first
    }

    private var selectedIndex: Int {
        guard let currentSpace else { return 0 }
        return spaces.firstIndex(where: { $0.id == currentSpace.id }) ?? 0
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
        // Just set the selection; the pager's onChange animates the scroll
        // (which in turn blends the background through the intermediate colors).
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
    }

    private func dismissInputKeyboard() {
        keyboardDismissRequest += 1
        isInputFocused = false
        dismissKeyboard()
    }
}

/// Fractional page index holder. @Observable so only views that READ `value`
/// in their body (the backdrop leaf) re-evaluate per swipe frame.
@Observable @MainActor
final class SpacePageOffsetModel {
    var value: CGFloat = 0
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
            displaySpaceColor
            GrainOverlay(intensity: grainIntensity)
                .allowsHitTesting(false)
        }
    }

    /// Flat space color — identical to what the macOS shell renders for a
    /// space without a gradient config, so the two apps match exactly.
    private func color(for space: Space?) -> Color {
        guard let space else { return Color(hex: "#C8D5C0") }
        return Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private var clampedOffset: CGFloat {
        guard !spaces.isEmpty else { return 0 }
        return max(0, min(CGFloat(spaces.count - 1), pageOffset.value))
    }

    /// Continuous color interpolation driven by the live scroll offset — the
    /// macOS `displaySpaceColor` model. The offset is fractional, so the
    /// background blends smoothly between the two adjacent spaces mid-swipe.
    private var displaySpaceColor: Color {
        guard !spaces.isEmpty else { return color(for: nil) }
        let clamped = clampedOffset
        let floorIdx = Int(clamped.rounded(.down))
        let ceilIdx = min(floorIdx + 1, spaces.count - 1)
        let t = clamped - CGFloat(floorIdx)
        return color(for: spaces[floorIdx]).mixed(with: color(for: spaces[ceilIdx]), by: t)
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
