import SwiftData
import SwiftUI

/// One space's note rows — Kept (pinned) + Flow (random) — and nothing else.
/// This is the ONLY part of a space that translates horizontally when you swipe
/// between spaces; the header and the Essentials grid are anchored siblings
/// owned by `SpacePagerView`. The column lives inside the inner paging scroll,
/// which itself sits in the shared outer vertical scroll, so this view has no
/// ScrollView of its own — it just reports its natural height up so the pager
/// can size the page.
struct SpaceView: View {
    @Environment(\.colorScheme) private var colorScheme

    let space: Space
    let spaces: [Space]
    let notes: [Note]
    let folders: [Folder]
    let selectedIndex: Int
    /// Global Essentials presence (favorites are space-agnostic). Drives the top
    /// divider so it lines up with the anchored Essentials grid above.
    let hasEssentials: Bool
    /// Reports this column's natural content height so the pager can size the
    /// inner paging scroll to the visible space (the outer scroll does the
    /// scrolling; the inner pager is laid out at full content height).
    let onHeight: (CGFloat) -> Void

    /// Only the settled page feeds the drag engine's geometry (Essentials render
    /// once globally; the per-space rows gate on the active page).
    private var isActivePage: Bool {
        spaces.indices.contains(selectedIndex) && spaces[selectedIndex].id == space.id
    }

    var body: some View {
        // PRINCIPLE: lifting a note must not change the layout. Dividers track
        // real content only (no `|| isActive`) — an empty tier's drop affordance
        // is revealed by proximity later, not slammed in at drag start.
        let hasKept = !pinnedFolders.isEmpty || !pinnedNotes.isEmpty

        VStack(alignment: .leading, spacing: SavantTheme.tierSpacing) {
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
        .padding(.horizontal, SavantTheme.pageMargin)
        .padding(.bottom, 160)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.isActiveSpacePage, isActivePage)
        // Natural height (the VStack never stretches vertically) — stable
        // regardless of the height the inner pager proposes, so reporting it
        // back doesn't feed a layout loop.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeight(height)
        }
    }

    private var tierDivider: some View {
        Rectangle()
            .fill(SavantTheme.hairline(colorScheme))
            .frame(height: 1)
            .padding(.horizontal, 2)
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
}

/// Drives auto-scroll while a drag holds the ghost in the viewport's edge
/// bands. A zero-size leaf — the only view observing `autoScrollVelocity`,
/// so band changes never invalidate the page body. The timer ticks on the
/// `.common` run-loop mode so it keeps firing during touch tracking.
struct AutoScrollDriver: View {
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
