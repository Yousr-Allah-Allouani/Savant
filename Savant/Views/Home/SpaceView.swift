import SwiftData
import SwiftUI

struct SpaceView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Environment(TouchDragSession.self) private var dragSession
    @State private var interaction = InteractionMode()
    @State private var scrollPosition = ScrollPosition()

    let space: Space
    let spaces: [Space]
    let notes: [Note]
    let folders: [Folder]
    let latestTidyRun: TidyRun?
    let selectedIndex: Int
    let selectSpaceAtIndex: (Int) -> Void
    var topInset: CGFloat = 0
    let tidyNow: () -> Void

    /// Only the settled page feeds the drag engine's geometry (Essentials
    /// render on every page — ungated frames would collide across pages).
    private var isActivePage: Bool {
        spaces.indices.contains(selectedIndex) && spaces[selectedIndex].id == space.id
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SavantTheme.tierSpacing) {
                    SpaceHeaderView(
                        space: space,
                        spaces: spaces,
                        selectedIndex: selectedIndex,
                        selectSpaceAtIndex: selectSpaceAtIndex,
                        tidyNow: tidyNow
                    )
                    .padding(.top, topInset + 8)

                    if let latestTidyRun, !interaction.isEditing {
                        TidyBannerView(run: latestTidyRun)
                            .padding(.top, 2)
                    }

                    contentSections
                        .padding(.bottom, 160)
                }
                .padding(.horizontal, SavantTheme.pageMargin)
                // The drag engine's reference frame: row frames are reported
                // relative to this content space (stable while scrolling);
                // the live global origin converts finger ↔ content coords.
                .coordinateSpace(.named("spaceContent"))
                // `ActiveFrame` re-fires the report when this page becomes
                // active, not just when the geometry moves — without it only
                // the launch space ever fed the engine.
                .onGeometryChange(for: ActiveFrame.self) { proxy in
                    ActiveFrame(frame: proxy.frame(in: .global), active: isActivePage)
                } action: { report in
                    if report.active { dragSession.contentOriginChanged(report.frame.origin) }
                }
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.hidden)
            // See the pager: a scroll view engaging ANY finger mid-drag
            // cancels the drag touch. Auto-scroll drives `scrollPosition`
            // programmatically, which stays allowed.
            .scrollDisabled(dragSession.isActive)
            .refreshable { tidyNow() }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, offsetY in
                if isActivePage { dragSession.liveScrollOffsetY = offsetY }
            }
            .onGeometryChange(for: ActiveFrame.self) { proxy in
                ActiveFrame(frame: proxy.frame(in: .global), active: isActivePage)
            } action: { report in
                // Only SETTLED frames feed the edge bands. A page becomes
                // active the moment the pager starts animating toward it, so
                // it reports frames while still sliding in — a stationary
                // drag finger mid-screen would sit inside the moving frame's
                // "edge band" and fire a bounce-back switch.
                if report.active, abs(report.frame.minX) < 1 {
                    dragSession.viewportGlobal = report.frame
                }
            }
            .onChange(of: randomNotes.map(\.id)) { _, _ in
                scrollToBottom()
            }

            AutoScrollDriver(session: dragSession, position: $scrollPosition)

            if interaction.isEditing(spaceID: space.id) {
                MultiSelectActionBar(space: space, spaces: spaces, allNotes: notes)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environment(interaction)
        .environment(\.isActiveSpacePage, isActivePage)
        .onChange(of: space.id) { _, _ in
            if interaction.isEditing { interaction.exitEditMode() }
        }
        .onDisappear {
            if dragSession.isActive {
                print("🧭 DRAG-PROBE page VIEW disappeared mid-drag: \(space.name)")
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: interaction.isEditing)
    }

    /// Figma skeleton: essentials grid / divider / kept rows / divider / stream
    /// rows. Hairlines appear only between two non-empty sections — except
    /// mid-drag, when every tier gains presence (empty ones show drop bands)
    /// so the ghost always has a target.
    private var contentSections: some View {
        let dragActive = dragSession.isActive
        let hasEssentials = !favoriteNotes.isEmpty || dragActive
        let hasKept = !pinnedFolders.isEmpty || !pinnedNotes.isEmpty || dragActive

        return VStack(alignment: .leading, spacing: SavantTheme.tierSpacing) {
            FavoritesTileRow(
                notes: favoriteNotes,
                allNotes: notes,
                spaces: spaces,
                currentSpace: space
            )

            if hasEssentials && hasKept {
                tierDivider
            }

            TierRowList(
                tier: .pinned,
                folders: pinnedFolders,
                notes: pinnedNotes,
                allFolders: folders,
                allNotes: notes,
                currentSpace: space,
                showsPreview: true
            )

            if hasKept || hasEssentials {
                tierDivider
            }

            TierRowList(
                tier: .random,
                folders: randomFolders,
                notes: randomNotes,
                allFolders: folders,
                allNotes: notes,
                currentSpace: space,
                showsPreview: false,
                showsEmptyHint: true
            )
        }
    }

    private var tierDivider: some View {
        Rectangle()
            .fill(SavantTheme.hairline(colorScheme))
            .frame(height: 1)
            .padding(.horizontal, 2)
    }

    private var favoriteNotes: [Note] {
        notes
            .filter { $0.tier == .favorite }
            .sorted(by: TierRowsBuilder.noteSort)
    }

    private var pinnedNotes: [Note] {
        notes
            .filter { $0.tier == .pinned && $0.folder == nil && $0.space?.id == space.id }
            .sorted(by: TierRowsBuilder.noteSort)
    }

    private var randomNotes: [Note] {
        notes
            .filter { $0.tier == .random && $0.folder == nil && $0.space?.id == space.id }
            .sorted(by: TierRowsBuilder.noteSort)
    }

    private var pinnedFolders: [Folder] {
        folders
            .filter { $0.tier == .pinned && $0.parent == nil && $0.space?.id == space.id }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private var randomFolders: [Folder] {
        folders
            .filter { $0.tier == .random && $0.parent == nil && $0.space?.id == space.id }
            .sorted { $0.sortIndex < $1.sortIndex }
    }

    private func scrollToBottom() {
        guard !randomNotes.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }
}

/// Drives auto-scroll while a drag holds the ghost in the viewport's edge
/// bands. A zero-size leaf — the only view observing `autoScrollVelocity`,
/// so band changes never invalidate the page body. The timer ticks on the
/// `.common` run-loop mode so it keeps firing during touch tracking.
private struct AutoScrollDriver: View {
    let session: TouchDragSession
    @Binding var position: ScrollPosition

    @State private var timer: Timer?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: session.autoScrollVelocity) { _, velocity in
                if velocity == 0 {
                    stop()
                } else if timer == nil {
                    start()
                }
            }
            .onDisappear { stop() }
    }

    private func start() {
        let newTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let velocity = session.autoScrollVelocity
                guard velocity != 0 else { return }
                $position.wrappedValue.scrollTo(y: session.liveScrollOffsetY + velocity)
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
