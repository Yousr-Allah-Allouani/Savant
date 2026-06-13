import SwiftUI
import Observation

/// The custom touch drag engine — iOS port of the macOS `CrossTierDragSession`
/// pattern. One instance lives on `SpacePagerView` and is injected through the
/// environment; rows attach a `DragLiftGesture` that feeds it, tier sections
/// publish their layout + commit handlers every body pass, and the
/// `DragGhostOverlay` at the pager root renders the floating ghost.
///
/// Perf invariants (proven on macOS, non-negotiable):
/// - `ghostOrigin` updates every finger frame and is read ONLY by the ghost
///   overlay leaf. Rows must never read it.
/// - Rows read `shuffleOffset(for:)`, which depends only on DISCRETE state
///   (`currentTier`/`currentIndex`/nest state) — rows invalidate on slot/tier
///   changes, not per frame.
/// - ALL zone decisions (slots, folder hover, child insertion) are resolved
///   in STATIC space: the resting layout with the dragged block removed.
///   Static frames never move in response to the decision, so zones can't
///   oscillate and rows can't dodge the ghost. Shuffle offsets are visual
///   (`.offset`) and never alter layout geometry, so `rowFrames` stays the
///   resting layout for free.
@MainActor
@Observable
final class TouchDragSession {

    // MARK: - Shared curves (macOS parity)

    static let commitGlideDuration: Double = 0.18
    static let commitGlide: Animation = .easeOut(duration: commitGlideDuration)
    static let rowShuffle: Animation = .easeOut(duration: 0.14)
    static let folderToggle: Animation = .easeOut(duration: 0.2)
    /// The ghost reshaping into another tier's row style (or child width) —
    /// a touch softer than the row shuffle so the morph reads as one motion.
    static let ghostMorph: Animation = .smooth(duration: 0.22)
    /// Leading inset of child rows inside an expanded folder.
    static let childInset: CGFloat = 22

    // MARK: - Payload

    enum Payload: Equatable {
        case note(UUID)
        case folder(UUID)

        var id: UUID {
            switch self {
            case .note(let id), .folder(let id): id
            }
        }

        var isNote: Bool {
            if case .note = self { return true }
            return false
        }
    }

    /// What the floating ghost renders. Holds live model references — the
    /// ghost is only on screen while the drag (and its models) are alive.
    /// The VISUAL STYLE isn't part of the spec: the overlay resolves it from
    /// `currentTier` (and child-insertion state), so the ghost morphs into the
    /// target's row shape as it crosses and lands looking exactly like the row
    /// it becomes. `size` tracks the rendered (morphed) size, reported back by
    /// the overlay.
    struct GhostSpec {
        enum Content {
            case note(Note)
            case folder(Folder, count: Int)
        }
        let content: Content
        var size: CGSize
    }

    /// One tier's drag surface, published by its section view every body pass
    /// (active page only). Closures capture the section's current data, so a
    /// republish after any model change keeps them fresh.
    struct TierDragContext {
        let tier: NoteTier
        /// Ordered top-level blocks (note rows + folder headers, interleaved).
        var blocks: [UUID] = []
        /// Folder id → ordered DIRECT children (subfolder headers + note
        /// rows). Expanded folders only, any depth.
        var children: [UUID: [UUID]] = [:]
        /// Folder id → ALL rendered descendant row ids (any depth). Block
        /// unions and whole-block shifts use these; slot walking uses
        /// `children`.
        var descendants: [UUID: [UUID]] = [:]
        /// Which rendered rows are folder headers (nest targets), any depth.
        var folderBlocks: [UUID] = []
        /// Rendered folder id → nesting depth (0 = top level) — gates
        /// folder-into-folder zones against `Folder.maxDepth`.
        var folderDepths: [UUID: Int] = [:]
        var spacing: CGFloat = SavantTheme.rowSpacing
        /// Non-nil = blocks lay out in a grid (Essentials), `spacing` is the
        /// gutter. Slots are 2D cells; offsets wrap across rows.
        var gridColumns: Int? = nil
        var acceptsNotes = true
        var acceptsFolders = true
        /// Same-scope reorder of the top-level blocks.
        var commitReorder: ([UUID]) -> Void = { _ in }
        /// Reorder within one folder's children (parent id, new child order).
        var commitChildReorder: (UUID, [UUID]) -> Void = { _, _ in }
        /// Cross-tier arrival: promote/retier the payload, insert at slot.
        var commitInsert: (Payload, Int) -> Void = { _, _ in }
        /// Nest a dragged note into one of this tier's folders. Index nil =
        /// absorbed by a closed folder (lands last); index set = the child
        /// slot chosen by dragging inside the open folder.
        var commitNest: (UUID, UUID, Int?) -> Void = { _, _, _ in }
    }

    // MARK: - Observed state (discrete — rows may read these)

    private(set) var payload: Payload?
    private(set) var sourceTier: NoteTier?
    /// The tier the ghost is currently over (drop target).
    private(set) var currentTier: NoteTier?
    private(set) var sourceIndex: Int = 0
    /// Same-tier: the slot the dragged block would land in. Cross-tier: the
    /// insertion index into the target tier's blocks. Child insertion: the
    /// slot among `targetParentFolderID`'s children.
    private(set) var currentIndex: Int = 0
    /// Closed folder the ghost is hovering — release absorbs the note into it.
    private(set) var nestTargetFolderID: UUID?
    /// Open folder the ghost is inside — the note is being placed at a child
    /// slot (`currentIndex`); release nests it there.
    private(set) var targetParentFolderID: UUID?
    /// Drag-out preview: a lifted child note has crossed out of its folder's
    /// body — it resolves a TOP-LEVEL slot of its own tier (`currentIndex` is
    /// the outer insertion index) and release un-nests it there. Purely
    /// spatial: where the ghost is decides the depth. The ghost widens to
    /// full row width as the preview.
    private(set) var isUnnesting = false
    private(set) var isSettling = false
    /// Release glide shrinks/fades the ghost (closed-folder absorption).
    private(set) var settleFades = false
    private(set) var ghost: GhostSpec?

    /// Quantized auto-scroll velocity (pt per tick). Observed ONLY by the
    /// `AutoScrollDriver` leaf in the active `SpaceView`.
    private(set) var autoScrollVelocity: CGFloat = 0

    // MARK: - Observed per-frame (ghost overlay leaf ONLY)

    private(set) var ghostOrigin: CGPoint = .zero

    var isActive: Bool { payload != nil }
    /// Cross-space drags resolve EVERYTHING against the visible page's
    /// layout, so they behave as cross-tier even when the ghost is over the
    /// same tier it left — the source's rows aren't on screen.
    var isCrossTier: Bool { isActive && (currentTier != sourceTier || isCrossSpace) }
    /// The pager has carried the drag to a page other than the one it
    /// started on (P4) — release commits a cross-space move.
    var isCrossSpace: Bool { isActive && sourceSpaceID != nil && activeSpaceID != sourceSpaceID }
    func isDragged(_ id: UUID) -> Bool { payload?.id == id }

    /// Nesting depth of the open folder hosting the child slot (0 = top
    /// level) — the ghost insets one child inset per level below it.
    var targetParentDepth: Int {
        guard let id = targetParentFolderID else { return 0 }
        let depths = isCrossTier ? targetFolderDepths : sourceFolderDepths
        return depths[id] ?? 0
    }

    // MARK: - Section height adjustment (read by tier sections)

    /// Visual offsets alone can't make room past a section's last row or move
    /// the dividers between sections — the section itself must grow/shrink.
    /// Net animated bottom padding for one tier: +gap while it hosts an open
    /// insertion (cross-tier target, or an open folder growing around a child
    /// slot), −gap once the dragged row's hole is visually closed (left the
    /// tier, or absorbed into a folder). Grids grow/shrink only when the cell
    /// count change adds/drops a row.
    func bottomAdjustment(for tier: NoteTier) -> CGFloat {
        guard isActive else { return 0 }
        var delta: CGFloat = 0

        // Cross-space: the source tier's rows belong to another page — the
        // visible page's same-named tier must not shrink for them.
        if tier == sourceTier, !isCrossSpace, !sourceBlocks.isEmpty {
            if sourceHoleClosed {
                if let grid = sourceGrid {
                    if sourceBlocks.count % grid.columns == 1 {
                        delta -= grid.cellSize.height + grid.spacing
                    }
                } else {
                    delta -= sourceRowHeight + sourceSpacing
                }
            }
        }

        if tier == currentTier, nestTargetFolderID == nil, let ghost {
            if isCrossTier, !targetBlocks.isEmpty {
                if let grid = targetGrid {
                    if targetBlocks.count % grid.columns == 0 {
                        delta += grid.cellSize.height + grid.spacing
                    }
                } else {
                    delta += ghost.size.height + targetSpacing
                }
            } else if !isCrossTier, targetParentFolderID != nil || isUnnesting {
                delta += ghost.size.height + sourceSpacing
            }
        }
        return delta
    }

    /// The dragged row's hole no longer renders open in its source scope —
    /// rows after it have closed ranks (and, for a child source, everything
    /// below the parent folder has moved up by the same gap).
    private var sourceHoleClosed: Bool {
        isCrossTier || nestTargetFolderID != nil || targetParentFolderID != nil || isUnnesting
    }

    // MARK: - Geometry/context feeds (not observed; written by the active page)

    /// Row layout frames in the "spaceContent" named space (scroll-content
    /// coords — stable while scrolling). Active page rows only.
    @ObservationIgnored var rowFrames: [UUID: CGRect] = [:]
    /// Tier section frames in the same content space.
    @ObservationIgnored var tierFrames: [NoteTier: CGRect] = [:]
    @ObservationIgnored private(set) var tierContexts: [NoteTier: TierDragContext] = [:]
    /// Global origin of the scroll content (the coordinate-space view).
    @ObservationIgnored private var contentOriginGlobal: CGPoint = .zero
    /// Global frame of the vertical scroll viewport (auto-scroll edge bands).
    @ObservationIgnored var viewportGlobal: CGRect = .zero
    /// Live vertical content offset of the active page's scroll view.
    @ObservationIgnored var liveScrollOffsetY: CGFloat = 0
    /// Global origin of the ghost overlay (subtracted so the ghost can be
    /// positioned with global coordinates).
    @ObservationIgnored var overlayOriginGlobal: CGPoint = .zero

    func publishTier(_ context: TierDragContext) {
        tierContexts[context.tier] = context
    }

    // MARK: - Drag-internal (not observed)

    @ObservationIgnored private var sourceParentFolderID: UUID?
    @ObservationIgnored private var sourceBlocks: [UUID] = []
    @ObservationIgnored private var sourceChildren: [UUID: [UUID]] = [:]
    @ObservationIgnored private var sourceDescendants: [UUID: [UUID]] = [:]
    @ObservationIgnored private var sourceFolderDepths: [UUID: Int] = [:]
    /// Rows that were rendered UNDER the dragged block before it collapsed at
    /// lift — their frames are stale; every union/walk skips them.
    @ObservationIgnored private var payloadDescendants: Set<UUID> = []
    /// Dragged folder's subtree height (0 = leaf, notes don't count) — with
    /// the target's depth this decides whether a folder zone is legal.
    @ObservationIgnored private var payloadSubtreeHeight = 0
    @ObservationIgnored private var sourceSpacing: CGFloat = SavantTheme.rowSpacing
    @ObservationIgnored private var sourceGrid: GridGeometry?
    /// The lifted row's resting height — source-side gaps key off this, NOT
    /// the live ghost height (which morphs with the target tier's style).
    @ObservationIgnored private var sourceRowHeight: CGFloat = 0
    /// The lifted row's resting width — the ghost wears it while still in the
    /// source tier (child rows are narrower than the section).
    @ObservationIgnored private(set) var sourceRowWidth: CGFloat = 0
    @ObservationIgnored private var sourceRowBlockIndex: [UUID: Int] = [:]
    /// Child source only: the ENCLOSING top-level scope of the source tier
    /// (the folder's siblings at top level). Drag-out resolves against it,
    /// and rows below the parent folder shift up through it once the child's
    /// hole closes.
    @ObservationIgnored private var sourceOuterBlocks: [UUID] = []
    @ObservationIgnored private var sourceOuterChildren: [UUID: [UUID]] = [:]
    @ObservationIgnored private var sourceOuterIndexMap: [UUID: Int] = [:]
    @ObservationIgnored private var parentTopIndex: Int?
    @ObservationIgnored private var targetBlocks: [UUID] = []
    @ObservationIgnored private var targetChildren: [UUID: [UUID]] = [:]
    @ObservationIgnored private var targetDescendants: [UUID: [UUID]] = [:]
    @ObservationIgnored private var targetFolderDepths: [UUID: Int] = [:]
    @ObservationIgnored private var targetSpacing: CGFloat = SavantTheme.rowSpacing
    @ObservationIgnored private var targetGrid: GridGeometry?
    @ObservationIgnored private var targetRowBlockIndex: [UUID: Int] = [:]
    @ObservationIgnored private var grabOffset: CGPoint = .zero
    @ObservationIgnored private var lastFingerGlobal: CGPoint = .zero
    @ObservationIgnored private var dragGeneration = 0
    @ObservationIgnored private var hoverFolderID: UUID?
    @ObservationIgnored private var onSettled: (() -> Void)?
    /// Set by the lift gesture at drag start: whether its recognizer is
    /// still tracking the touch. The watchdog consults this — a stationary
    /// finger produces no events, so silence alone means NOTHING.
    @ObservationIgnored var recognizerStillTracking: (() -> Bool)?

    // MARK: - Cross-space (P4)

    /// Pager order, fed by `SpacePagerView` — edge-hold paging walks it.
    @ObservationIgnored var orderedSpaceIDs: [UUID] = []
    /// Set by the pager: animate the pager to the given space.
    @ObservationIgnored var requestSpaceSwitch: ((UUID) -> Void)?
    @ObservationIgnored private(set) var sourceSpaceID: UUID?
    @ObservationIgnored private var activeSpaceID: UUID?
    @ObservationIgnored private var edgeDirection = 0
    @ObservationIgnored private var edgeFireToken = UUID()

    // MARK: - Lift registry (root recognizer)

    /// What a row hands the ROOT lift recognizer: enough to start its drag
    /// when a long press lands on its frame. One recognizer lives on the
    /// pager (it must survive `LazyHStack` tearing source pages down during
    /// cross-space drags); rows just register here, active page only.
    struct LiftSpec {
        let payload: Payload
        let tier: NoteTier
        let parentFolderID: UUID?
        /// nil = renders identically on every page (Essentials).
        let spaceID: UUID?
        let ghost: () -> GhostSpec.Content
        let isEnabled: Bool
        let onWillLift: (() -> Void)?
        let onSettled: (() -> Void)?
    }

    @ObservationIgnored private var liftables: [UUID: LiftSpec] = [:]

    func registerLiftable(_ id: UUID, _ spec: LiftSpec) {
        liftables[id] = spec
    }

    func unregisterLiftable(_ id: UUID) {
        liftables.removeValue(forKey: id)
    }

    /// Delegate gate: only let the recognizer take a touch that lands on a
    /// liftable row of the active page — empty space, buttons, and the input
    /// bar keep their touches.
    func canLift(atGlobal point: CGPoint) -> Bool {
        liftableID(atGlobal: point) != nil
    }

    /// The root recognizer recognized: resolve the row under the finger and
    /// start its drag.
    func lift(atGlobal point: CGPoint) {
        guard let id = liftableID(atGlobal: point), let spec = liftables[id] else { return }
        spec.onWillLift?()
        beginDrag(
            payload: spec.payload,
            tier: spec.tier,
            parentFolderID: spec.parentFolderID,
            ghost: spec.ghost(),
            fingerGlobal: point,
            onSettled: spec.onSettled
        )
    }

    private func liftableID(atGlobal point: CGPoint) -> UUID? {
        guard !isActive, !isSettling else { return nil }
        let content = CGPoint(
            x: point.x - contentOriginGlobal.x,
            y: point.y - contentOriginGlobal.y
        )
        for (id, spec) in liftables {
            guard spec.isEnabled,
                  spec.spaceID == nil || spec.spaceID == activeSpaceID,
                  let frame = rowFrames[id], frame.contains(content)
            else { continue }
            return id
        }
        return nil
    }

    // MARK: - Grid geometry (Essentials)

    /// Analytic cell layout for a grid tier — derived from the first block's
    /// resting frame, so cell positions (including the wrap cell past the last
    /// card) are known without rendered frames.
    private struct GridGeometry {
        let columns: Int
        let spacing: CGFloat
        let cellSize: CGSize
        let origin: CGPoint

        func cellOrigin(_ index: Int) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(index % columns) * (cellSize.width + spacing),
                y: origin.y + CGFloat(index / columns) * (cellSize.height + spacing)
            )
        }

        func cellCenter(_ index: Int) -> CGPoint {
            let o = cellOrigin(index)
            return CGPoint(x: o.x + cellSize.width / 2, y: o.y + cellSize.height / 2)
        }
    }

    private func gridGeometry(for context: TierDragContext) -> GridGeometry? {
        guard let columns = context.gridColumns,
              let first = context.blocks.first,
              let frame = rowFrames[first]
        else { return nil }
        return GridGeometry(
            columns: columns, spacing: context.spacing,
            cellSize: frame.size, origin: frame.origin
        )
    }

    // MARK: - Lifecycle

    func beginDrag(
        payload: Payload,
        tier: NoteTier,
        parentFolderID: UUID? = nil,
        ghost content: GhostSpec.Content,
        fingerGlobal: CGPoint,
        onSettled: (() -> Void)? = nil
    ) {
        guard !isActive, !isSettling else { return }
        guard let context = tierContexts[tier] else { return }
        guard let rowFrame = rowFrames[payload.id] else { return }

        dragGeneration += 1
        self.payload = payload
        sourceTier = tier
        currentTier = tier
        sourceSpaceID = activeSpaceID
        sourceParentFolderID = parentFolderID
        sourceDescendants = context.descendants
        sourceFolderDepths = context.folderDepths
        payloadDescendants = Set(context.descendants[payload.id] ?? [])
        if case .folder(let folder, _) = content {
            payloadSubtreeHeight = Self.subtreeHeight(of: folder)
        }
        if let parentFolderID {
            sourceBlocks = context.children[parentFolderID] ?? []
            // Full child map: sibling blocks can be expanded subfolders whose
            // rows shuffle with them.
            sourceChildren = context.children
            sourceGrid = nil
            sourceOuterBlocks = context.blocks
            sourceOuterChildren = context.children
            sourceOuterIndexMap = Self.blockIndexMap(
                blocks: context.blocks, children: context.descendants
            )
            // The TOP-LEVEL block whose subtree holds the source — the parent
            // itself, or (for deep sources) the ancestor it renders under.
            // The whole tier resolves against this scope at any depth.
            parentTopIndex = context.blocks.firstIndex {
                $0 == parentFolderID
                    || context.descendants[$0]?.contains(parentFolderID) == true
            }
        } else {
            sourceBlocks = context.blocks
            sourceChildren = context.children
            sourceGrid = gridGeometry(for: context)
        }
        sourceSpacing = context.spacing
        sourceIndex = sourceBlocks.firstIndex(of: payload.id) ?? 0
        currentIndex = sourceIndex
        sourceRowBlockIndex = Self.blockIndexMap(blocks: sourceBlocks, children: sourceDescendants)
        clearTarget()

        let rowGlobal = rowFrame.offsetBy(dx: contentOriginGlobal.x, dy: contentOriginGlobal.y)
        grabOffset = CGPoint(x: fingerGlobal.x - rowGlobal.minX, y: fingerGlobal.y - rowGlobal.minY)
        sourceRowHeight = rowGlobal.height
        sourceRowWidth = rowGlobal.width
        ghost = GhostSpec(content: content, size: rowGlobal.size)
        ghostOrigin = rowGlobal.origin
        lastFingerGlobal = fingerGlobal
        self.onSettled = onSettled

        // Watchdog: if the recognizer dies without an end callback, force a
        // cancel so the row doesn't stay hidden (macOS stuck-drag pattern).
        scheduleWatchdog()
    }

    /// Re-arming dead-man switch. NEVER a flat timeout: long drags are
    /// legitimate (cross-space steering, edge dwells — the finger can sit
    /// still for ages producing zero events). Only a recognizer that reports
    /// it stopped tracking gets its drag cancelled.
    private func scheduleWatchdog() {
        let gen = dragGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.dragGeneration == gen, self.isActive, !self.isSettling else { return }
            if self.recognizerStillTracking?() == true {
                self.scheduleWatchdog()
            } else {
                print("🧭 DRAG-PROBE watchdog fired (recognizer confirmed dead)")
                self.endDrag(cancelled: true)
            }
        }
    }

    func updateDrag(fingerGlobal: CGPoint) {
        guard isActive, !isSettling else { return }
        lastFingerGlobal = fingerGlobal
        ghostOrigin = CGPoint(x: fingerGlobal.x - grabOffset.x, y: fingerGlobal.y - grabOffset.y)
        refreshTargets()
        updateAutoScroll()
        updateEdgeSwitch()
    }

    /// The pager's settled page changed (user selection, or a mid-drag edge
    /// hold / rail hover). Mid-drag, every per-page feed now belongs to the
    /// new space: contexts and tier/rail frames are dropped so the new active
    /// page's republish wins (row frames keep — IDs are globally unique, and
    /// returning to the source space must find its resting layout intact).
    func activeSpacePageChanged(_ id: UUID?) {
        guard id != activeSpaceID else { return }
        activeSpaceID = id
        guard isActive, !isSettling else { return }
        print("🧭 DRAG-PROBE page changed mid-drag → \(id?.uuidString.prefix(6) ?? "nil")")
        tierContexts = [:]
        tierFrames = [:]
        clearTarget()
        currentTier = nil
        setHoverFolder(nil)
        if targetParentFolderID != nil { targetParentFolderID = nil }
        if isUnnesting { isUnnesting = false }
    }

    /// Re-run the hit-test from the last finger position — called when the
    /// content scrolls under a stationary finger (auto-scroll).
    func contentOriginChanged(_ origin: CGPoint) {
        contentOriginGlobal = origin
        guard isActive, !isSettling else { return }
        refreshTargets()
    }

    /// The overlay reports the ghost's rendered size after a style morph —
    /// gaps and hit-tests track the morphed shape, and the grab point keeps
    /// its FRACTIONAL position inside the ghost so a card→row morph doesn't
    /// leave the row far from the finger.
    func ghostSizeChanged(_ size: CGSize) {
        guard isActive, var spec = ghost, spec.size != size else { return }
        let old = spec.size
        spec.size = size
        ghost = spec
        if old.width > 1 { grabOffset.x *= size.width / old.width }
        if old.height > 1 { grabOffset.y *= size.height / old.height }
        guard !isSettling else { return }
        ghostOrigin = CGPoint(x: lastFingerGlobal.x - grabOffset.x, y: lastFingerGlobal.y - grabOffset.y)
        refreshTargets()
    }

    private func refreshTargets() {
        retargetTierIfNeeded()
        resolveZone()
    }

    func endDrag(cancelled: Bool = false) {
        guard isActive, !isSettling, let payload else { return }
        print("🧭 DRAG-PROBE endDrag cancelled=\(cancelled) crossSpace=\(isCrossSpace) tier=\(String(describing: currentTier))")
        autoScrollVelocity = 0

        enum Outcome {
            case reorder(slot: Int)
            case insert(tier: NoteTier, index: Int)
            case nest(folderID: UUID, tier: NoteTier)
            case childInsert(folderID: UUID, slot: Int, tier: NoteTier)
        }

        let outcome: Outcome
        if !cancelled, let nestID = nestTargetFolderID, let tier = currentTier {
            outcome = .nest(folderID: nestID, tier: tier)
        } else if !cancelled, let folderID = targetParentFolderID, let tier = currentTier {
            outcome = .childInsert(folderID: folderID, slot: currentIndex, tier: tier)
        } else if !cancelled, isUnnesting, let tier = currentTier {
            // Drag-out: the child leaves its folder for the tier's top level.
            // `commitInsert` re-tiers in place (promote clears note.folder).
            outcome = .insert(tier: tier, index: currentIndex)
        } else if cancelled || !isCrossTier {
            outcome = .reorder(slot: cancelled ? sourceIndex : currentIndex)
        } else {
            outcome = .insert(tier: currentTier ?? sourceTier ?? .random, index: currentIndex)
        }

        // Resolve the glide destination (global coords) before any state moves.
        var landing: CGPoint?
        var fades = false
        switch outcome {
        case .reorder(let slot):
            landing = reorderLandingGlobal(for: slot)
            // A cancel on a far page can't resolve a frame — fade in place.
            fades = landing == nil
        case .insert(let tier, let index):
            landing = isUnnesting
                ? unnestLandingGlobal(index: index)
                : insertLandingGlobal(tier: tier, index: index)
            fades = landing == nil
        case .childInsert(let folderID, let slot, _):
            landing = childInsertLandingGlobal(folderID: folderID, slot: slot)
            fades = landing == nil
        case .nest(let folderID, _):
            if let frame = rowFrames[folderID] {
                let offset = shuffleOffset(for: folderID)
                landing = CGPoint(
                    x: frame.minX + offset.width + contentOriginGlobal.x,
                    y: frame.minY + offset.height + contentOriginGlobal.y
                )
            }
            fades = true
        }

        withAnimation(Self.commitGlide) {
            isSettling = true
            settleFades = fades
            if let landing { ghostOrigin = landing }
        }

        let gen = dragGeneration
        let settledCallback = onSettled
        // Settle via asyncAfter, NOT withAnimation completion — @Observable
        // animated properties don't reliably fire completion criteria.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitGlideDuration) { [weak self] in
            guard let self, self.dragGeneration == gen else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                switch outcome {
                case .reorder(let slot):
                    if slot != self.sourceIndex, !self.sourceBlocks.isEmpty,
                       let sourceTier = self.sourceTier,
                       let context = self.tierContexts[sourceTier] {
                        var ordered = self.sourceBlocks
                        ordered.remove(at: self.sourceIndex)
                        ordered.insert(payload.id, at: slot)
                        if let parent = self.sourceParentFolderID {
                            context.commitChildReorder(parent, ordered)
                        } else {
                            context.commitReorder(ordered)
                        }
                    }
                case .insert(let tier, let index):
                    self.tierContexts[tier]?.commitInsert(payload, index)
                case .nest(let folderID, let tier):
                    self.tierContexts[tier]?.commitNest(payload.id, folderID, nil)
                case .childInsert(let folderID, let slot, let tier):
                    self.tierContexts[tier]?.commitNest(payload.id, folderID, slot)
                }
                self.reset()
            }
            settledCallback?()
        }
    }

    private func reset() {
        payload = nil
        ghost = nil
        sourceTier = nil
        currentTier = nil
        nestTargetFolderID = nil
        targetParentFolderID = nil
        hoverFolderID = nil
        isSettling = false
        settleFades = false
        sourceIndex = 0
        currentIndex = 0
        autoScrollVelocity = 0
        sourceParentFolderID = nil
        sourceBlocks = []
        sourceChildren = [:]
        sourceDescendants = [:]
        sourceFolderDepths = [:]
        payloadDescendants = []
        payloadSubtreeHeight = 0
        sourceRowBlockIndex = [:]
        sourceOuterBlocks = []
        sourceOuterChildren = [:]
        sourceOuterIndexMap = [:]
        parentTopIndex = nil
        isUnnesting = false
        sourceGrid = nil
        sourceRowHeight = 0
        sourceRowWidth = 0
        clearTarget()
        onSettled = nil
        sourceSpaceID = nil
        edgeDirection = 0
        edgeFireToken = UUID()
    }

    private func clearTarget() {
        targetBlocks = []
        targetChildren = [:]
        targetDescendants = [:]
        targetFolderDepths = [:]
        targetRowBlockIndex = [:]
        targetSpacing = SavantTheme.rowSpacing
        targetGrid = nil
    }

    /// Folder-tree height of the dragged folder (leaf = 0; notes don't add
    /// depth) — mirrors `FolderService.subtreeHeight`.
    private static func subtreeHeight(of folder: Folder) -> Int {
        let kids = folder.children ?? []
        guard !kids.isEmpty else { return 0 }
        return 1 + (kids.map { subtreeHeight(of: $0) }.max() ?? 0)
    }

    private static func blockIndexMap(
        blocks: [UUID], children: [UUID: [UUID]]
    ) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, block) in blocks.enumerated() {
            map[block] = index
            for child in children[block] ?? [] {
                map[child] = index
            }
        }
        return map
    }

    // MARK: - Row offsets (rows read this; depends only on discrete state)

    /// Visual shift for a row while the drag's "hole" moves between slots,
    /// tiers, and folders. Children shift with their block; grid cards shift
    /// to neighbor cells (2D, wrapping across rows).
    func shuffleOffset(for rowID: UUID) -> CGSize {
        guard isActive, let ghost, rowID != payload?.id else { return .zero }

        if let blockIdx = sourceRowBlockIndex[rowID] {
            var offset = sourceScopeOffset(rowID: rowID, blockIdx: blockIdx, ghost: ghost)
            // Child source: siblings also ride their parent folder's outer
            // shift (a top-level insertion gap can open above the folder).
            if sourceParentFolderID != nil, let topIdx = sourceOuterIndexMap[rowID] {
                offset.height += outerScopeOffset(rowID: rowID, topIdx: topIdx, ghost: ghost).height
            }
            return offset
        }
        if sourceParentFolderID != nil, let topIdx = sourceOuterIndexMap[rowID] {
            return outerScopeOffset(rowID: rowID, topIdx: topIdx, ghost: ghost)
        }
        if isCrossTier, let blockIdx = targetRowBlockIndex[rowID] {
            return targetScopeOffset(rowID: rowID, blockIdx: blockIdx, ghost: ghost)
        }
        return .zero
    }

    private func sourceScopeOffset(rowID: UUID, blockIdx: Int, ghost: GhostSpec) -> CGSize {
        // Stale children of the dragged block (folder collapsed at lift).
        if blockIdx == sourceIndex { return .zero }

        if let grid = sourceGrid {
            if isCrossTier || nestTargetFolderID != nil {
                // Left the grid: close the hole, cards walk back one cell.
                return blockIdx > sourceIndex ? gridDelta(grid, from: blockIdx, to: blockIdx - 1) : .zero
            }
            // In-grid reorder: walking hole in index space.
            if sourceIndex < currentIndex, blockIdx > sourceIndex, blockIdx <= currentIndex {
                return gridDelta(grid, from: blockIdx, to: blockIdx - 1)
            }
            if currentIndex < sourceIndex, blockIdx >= currentIndex, blockIdx < sourceIndex {
                return gridDelta(grid, from: blockIdx, to: blockIdx + 1)
            }
            return .zero
        }

        let sourceGap = sourceRowHeight + sourceSpacing
        // The hole closes the moment the row stops landing back in this scope:
        // left the tier, hovering a closed folder, placing into an open
        // folder, or carried out of its own folder. (On folder hover this is
        // what visually re-coheres the list with the static hit space — the
        // folder sits exactly where the zones say it is.)
        let holeClosed = sourceHoleClosed
        var dy: CGFloat = 0
        if holeClosed {
            if blockIdx > sourceIndex { dy -= sourceGap }
        } else {
            if sourceIndex < currentIndex, blockIdx > sourceIndex, blockIdx <= currentIndex {
                dy -= sourceGap
            }
            if currentIndex < sourceIndex, blockIdx >= currentIndex, blockIdx < sourceIndex {
                dy += sourceGap
            }
        }
        if !isCrossTier, let folderID = targetParentFolderID {
            dy += childInsertShift(
                rowID: rowID, blockIdx: blockIdx, folderID: folderID,
                blocks: sourceBlocks, children: sourceChildren,
                descendants: sourceDescendants,
                spacing: sourceSpacing, ghost: ghost
            )
        }
        return CGSize(width: 0, height: dy)
    }

    /// Child source (any depth): shifts for the ENCLOSING top-level scope.
    /// Once the child's hole closes, everything below the source's top-level
    /// ancestor block moves up by one source gap (the block visually shrinks
    /// around the closed hole) — and so do rows INSIDE that block sitting
    /// below the chain that holds the hole; un-nesting opens the top-level
    /// insertion gap at the slot; placing into ANOTHER same-tier open folder
    /// grows that folder around the child slot.
    private func outerScopeOffset(rowID: UUID, topIdx: Int, ghost: GhostSpec) -> CGSize {
        guard let parentIdx = parentTopIndex else { return .zero }
        var dy: CGFloat = 0
        if sourceHoleClosed {
            if topIdx > parentIdx {
                dy -= sourceRowHeight + sourceSpacing
            } else if topIdx == parentIdx, afterSourceChain(rowID) {
                // Inside the ancestor block, below the hole's chain. (Rows
                // inside the source's own parent are the sibling scope's job
                // — `afterSourceChain` stops above them.)
                dy -= sourceRowHeight + sourceSpacing
            }
        }
        if isUnnesting, topIdx >= currentIndex {
            dy += ghost.size.height + sourceSpacing
        }
        if !isCrossTier, let folderID = targetParentFolderID {
            // The source's own parent block: its interior rows already get
            // their child-insert shift from the sibling scope — without the
            // skip they'd shift twice when the target nests inside it.
            dy += childInsertShift(
                rowID: rowID, blockIdx: topIdx, folderID: folderID,
                blocks: sourceOuterBlocks, children: sourceOuterChildren,
                descendants: sourceDescendants,
                spacing: sourceSpacing, ghost: ghost,
                interiorOwnedElsewhere: sourceParentFolderID
            )
        }
        return CGSize(width: 0, height: dy)
    }

    private func targetScopeOffset(rowID: UUID, blockIdx: Int, ghost: GhostSpec) -> CGSize {
        if nestTargetFolderID != nil { return .zero }
        if let grid = targetGrid {
            return blockIdx >= currentIndex ? gridDelta(grid, from: blockIdx, to: blockIdx + 1) : .zero
        }
        if let folderID = targetParentFolderID {
            let dy = childInsertShift(
                rowID: rowID, blockIdx: blockIdx, folderID: folderID,
                blocks: targetBlocks, children: targetChildren,
                descendants: targetDescendants,
                spacing: targetSpacing, ghost: ghost
            )
            return CGSize(width: 0, height: dy)
        }
        // Insertion gap at the slot, sized for the morphed ghost.
        let gap = ghost.size.height + targetSpacing
        return CGSize(width: 0, height: blockIdx >= currentIndex ? gap : 0)
    }

    /// Extra downward shift while an open folder grows around a child slot:
    /// every row rendered AFTER the insertion point moves down by one ghost
    /// gap. The target may be NESTED — its scope-level ancestor block is
    /// located first, then the containment chain decides which rows inside
    /// that block sit past the slot. Rows nested deeper than the chain move
    /// with their direct-child ancestor. `interiorOwnedElsewhere` skips the
    /// within-block portion when another scope already shifts that block's
    /// interior (outer scope vs the source's own sibling scope).
    private func childInsertShift(
        rowID: UUID, blockIdx: Int, folderID: UUID,
        blocks: [UUID], children: [UUID: [UUID]],
        descendants: [UUID: [UUID]],
        spacing: CGFloat, ghost: GhostSpec,
        interiorOwnedElsewhere: UUID? = nil
    ) -> CGFloat {
        guard let folderIdx = blocks.firstIndex(where: {
            $0 == folderID || descendants[$0]?.contains(folderID) == true
        }) else { return 0 }
        let gap = ghost.size.height + spacing
        if blockIdx > folderIdx { return gap }
        guard blockIdx == folderIdx else { return 0 }
        var container = blocks[folderIdx]
        while true {
            // Another scope owns this container's interior (the source's own
            // parent: its SIBLING scope shifts those rows) — checked at every
            // level, since a deep source's parent sits below the top.
            if container == interiorOwnedElsewhere { return 0 }
            if rowID == container { return 0 }   // headers don't move
            if container == folderID { break }
            guard let kids = children[container],
                  let chainIdx = kids.firstIndex(where: {
                      $0 == folderID || descendants[$0]?.contains(folderID) == true
                  }),
                  let rowIdx = directChildIndex(
                      of: rowID, in: container, children: children, descendants: descendants
                  )
            else { return 0 }
            if rowIdx > chainIdx { return gap }
            if rowIdx < chainIdx { return 0 }
            // Same direct child: the row is somewhere inside it — descend.
            container = kids[chainIdx]
        }
        guard let childIdx = directChildIndex(
            of: rowID, in: folderID, children: children, descendants: descendants
        ), childIdx >= currentIndex else { return 0 }
        return gap
    }

    /// Whether a row rendered inside the source's top-level ancestor block
    /// sits BELOW the containment chain that holds the dragged row — those
    /// rows ride the closed hole. Rows inside the source's own parent return
    /// false: the sibling scope shifts them.
    private func afterSourceChain(_ rowID: UUID) -> Bool {
        guard let payloadID = payload?.id, let parentIdx = parentTopIndex,
              sourceOuterBlocks.indices.contains(parentIdx)
        else { return false }
        var container = sourceOuterBlocks[parentIdx]
        while container != sourceParentFolderID {
            guard let kids = sourceOuterChildren[container],
                  let chainIdx = kids.firstIndex(where: {
                      $0 == payloadID || sourceDescendants[$0]?.contains(payloadID) == true
                  }),
                  let rowIdx = directChildIndex(
                      of: rowID, in: container,
                      children: sourceOuterChildren, descendants: sourceDescendants
                  )
            else { return false }
            if rowIdx > chainIdx { return true }
            if rowIdx < chainIdx { return false }
            let next = kids[chainIdx]
            if rowID == next { return false }
            container = next
        }
        return false
    }

    /// Index of the direct child of `folderID` that `rowID` belongs to —
    /// itself, or the expanded subfolder whose subtree contains it.
    private func directChildIndex(
        of rowID: UUID, in folderID: UUID,
        children: [UUID: [UUID]], descendants: [UUID: [UUID]]
    ) -> Int? {
        guard let kids = children[folderID] else { return nil }
        if let idx = kids.firstIndex(of: rowID) { return idx }
        for (idx, kid) in kids.enumerated() {
            if descendants[kid]?.contains(rowID) == true { return idx }
        }
        return nil
    }

    private func gridDelta(_ grid: GridGeometry, from: Int, to: Int) -> CGSize {
        let a = grid.cellOrigin(from)
        let b = grid.cellOrigin(to)
        return CGSize(width: b.x - a.x, height: b.y - a.y)
    }

    // MARK: - Tier retargeting

    private var ghostCenterContent: CGPoint {
        let size = ghost?.size ?? .zero
        return CGPoint(
            x: ghostOrigin.x + size.width / 2 - contentOriginGlobal.x,
            y: ghostOrigin.y + size.height / 2 - contentOriginGlobal.y
        )
    }

    private func retargetTierIfNeeded() {
        guard let payload, let sourceTier else { return }
        let center = ghostCenterContent

        var resolved: NoteTier?
        for tier in [NoteTier.favorite, .pinned, .random] {
            guard let context = tierContexts[tier],
                  let frame = tierFrames[tier]
            else { continue }
            guard payload.isNote ? context.acceptsNotes : context.acceptsFolders else { continue }
            let hitArea = frame.insetBy(dx: 0, dy: -SavantTheme.tierSpacing / 2)
            if hitArea.contains(center) {
                resolved = tier
                break
            }
        }
        // Sticky: between sections (or off every frame) keep the last target.
        guard let resolved, resolved != currentTier else { return }

        currentTier = resolved
        setHoverFolder(nil)
        if targetParentFolderID != nil { targetParentFolderID = nil }
        if isUnnesting { isUnnesting = false }
        if resolved == sourceTier, !isCrossSpace {
            clearTarget()
            currentIndex = sourceIndex
        } else if let context = tierContexts[resolved] {
            targetBlocks = context.blocks
            targetChildren = context.children
            targetDescendants = context.descendants
            targetFolderDepths = context.folderDepths
            targetSpacing = context.spacing
            targetGrid = gridGeometry(for: context)
            targetRowBlockIndex = Self.blockIndexMap(blocks: targetBlocks, children: targetDescendants)
            currentIndex = targetBlocks.count
        }
    }

    // MARK: - Zone resolution (static space)

    /// What the ghost's position means right now: a landing slot, a closed
    /// folder to absorb into, or a child slot inside an open folder.
    private enum Zone: Equatable {
        case slot(Int)
        case hover(folderID: UUID)
        case childInsert(folderID: UUID, slot: Int)
    }

    private func resolveZone() {
        guard isActive, ghost != nil else { return }
        switch computeZone() {
        case .slot(let index):
            setHoverFolder(nil)
            if targetParentFolderID != nil { targetParentFolderID = nil }
            // A child block (any depth) resolving a top-level slot of its own
            // tier is the drag-out preview — release un-nests it all the way
            // there. Leaving a deep folder for an ANCESTOR's body is NOT this:
            // that resolves childInsert(ancestor) and commits as a nest.
            let unnest = sourceParentFolderID != nil && parentTopIndex != nil && !isCrossTier
            if isUnnesting != unnest { isUnnesting = unnest }
            if index != currentIndex { currentIndex = index }
        case .hover(let folderID):
            if targetParentFolderID != nil { targetParentFolderID = nil }
            if isUnnesting { isUnnesting = false }
            setHoverFolder(folderID)
        case .childInsert(let folderID, let slot):
            setHoverFolder(nil)
            if isUnnesting { isUnnesting = false }
            if folderID == sourceParentFolderID, !isCrossTier {
                // Back inside its own folder: plain sibling reorder — the
                // collapsed child slot IS the walking-hole slot.
                if targetParentFolderID != nil { targetParentFolderID = nil }
            } else if targetParentFolderID != folderID {
                targetParentFolderID = folderID
            }
            if slot != currentIndex { currentIndex = slot }
        }
    }

    private func computeZone() -> Zone {
        let center = ghostCenterContent

        // Grid tier (Essentials): nearest cell, no folder zones.
        if isCrossTier {
            if let grid = targetGrid {
                return .slot(nearestGridSlot(grid, center: center, slots: targetBlocks.count + 1))
            }
        } else if let grid = sourceGrid {
            return .slot(nearestGridSlot(grid, center: center, slots: sourceBlocks.count))
        }

        let entries = zoneEntries()
        guard !entries.isEmpty else {
            return .slot(isCrossTier || sourceParentFolderID != nil ? 0 : sourceIndex)
        }
        // Slot boundaries sit at the midpoint between consecutive LANDING
        // positions (≈ half a row past each block's midY), so a swap takes
        // the same half-pitch of travel in both directions.
        let bias = slotBias

        var index = 0
        for entry in entries {
            let frame = entry.frame
            if entry.isFolder, folderZonesAllowed(entry.id) {
                if entry.isExpanded {
                    // Open folder: a thin strip above the header still means
                    // "insert before"; everything from mid-header to the
                    // block's end is INSIDE — place at a child slot (or
                    // absorb into a closed subfolder rendered there).
                    let headerBand = entry.headerFrame.minY + entry.headerFrame.height * 0.4
                    if center.y < headerBand { return .slot(index) }
                    if center.y <= frame.maxY {
                        return childZone(in: entry, centerY: center.y)
                    }
                } else {
                    // Closed folder: top/bottom strips insert around it; the
                    // generous middle band hovers (release absorbs).
                    if center.y < frame.minY + frame.height * 0.22 { return .slot(index) }
                    if center.y <= frame.maxY - frame.height * 0.22 {
                        return .hover(folderID: entry.id)
                    }
                }
            } else if center.y < frame.midY + bias {
                return .slot(index)
            }
            index += 1
        }
        return .slot(index)
    }

    /// Whether the payload may nest into `folderID`: notes always; a dragged
    /// folder only while the depth cap holds — its deepest leaf, re-rooted
    /// under the target, must not exceed `Folder.maxDepth`. (Cycles can't
    /// arise from visible zones: the dragged folder's own subtree collapsed
    /// away at lift.)
    private func folderZonesAllowed(_ folderID: UUID) -> Bool {
        guard let payload else { return false }
        if payload.isNote { return true }
        if payload.id == folderID { return false }
        let depths = isCrossTier ? targetFolderDepths : sourceFolderDepths
        let depth = depths[folderID] ?? 0
        return depth + 1 + payloadSubtreeHeight <= Folder.maxDepth
    }

    /// Half the pitch the dragged row occupies in the current scope — added
    /// to each static midY so boundaries land between landing centers.
    private var slotBias: CGFloat {
        let spacing = isCrossTier ? targetSpacing : sourceSpacing
        let height = isCrossTier ? (ghost?.size.height ?? sourceRowHeight) : sourceRowHeight
        return (spacing + height) / 2
    }

    /// The current scope's blocks in STATIC space: the resting layout with the
    /// dragged block removed (same-tier rows below the source shift up by one
    /// source gap; a cross-tier target is its resting layout as-is). Insertion
    /// index i in this list == walking-hole slot i, both regimes.
    private struct ZoneEntry {
        let id: UUID
        let frame: CGRect        // static union frame (header ∪ children)
        let headerFrame: CGRect  // static header frame (== frame for notes)
        let isFolder: Bool
        let isExpanded: Bool
        let children: [UUID]
        let shift: CGFloat
    }

    /// Resting union of a block and all its rendered descendants. The dragged
    /// block's own descendants are excluded everywhere — they collapsed away
    /// at lift, so their frames are stale. The dragged row ITSELF stays: its
    /// resting frame is the hole, and scopes model its removal explicitly.
    private func staticUnionRect(
        of id: UUID, base: CGRect, descendants: [UUID: [UUID]]
    ) -> CGRect {
        var union = base
        for kid in descendants[id] ?? [] {
            if payloadDescendants.contains(kid) { continue }
            if let frame = rowFrames[kid] { union = union.union(frame) }
        }
        return union
    }

    private func zoneEntries() -> [ZoneEntry] {
        // A child source resolves its whole tier, not just its siblings: its
        // top-level ANCESTOR block is one zone among the others, and the
        // recursive childZone walk reaches the source's own sibling slots any
        // depth down. (Sibling fallback only if the ancestor lookup failed.)
        if !isCrossTier, sourceParentFolderID != nil, parentTopIndex != nil {
            return outerZoneEntries()
        }
        let blocks: [UUID]
        let children: [UUID: [UUID]]
        let descendants: [UUID: [UUID]]
        if isCrossTier {
            blocks = targetBlocks
            children = targetChildren
            descendants = targetDescendants
        } else {
            blocks = sourceBlocks
            children = sourceChildren
            descendants = sourceDescendants
        }
        let folderDepths = isCrossTier ? targetFolderDepths : sourceFolderDepths

        let sourceGap = sourceRowHeight + sourceSpacing
        var entries: [ZoneEntry] = []
        for (idx, id) in blocks.enumerated() {
            if !isCrossTier, idx == sourceIndex { continue }
            guard let header = rowFrames[id] else { continue }
            let shift: CGFloat = (!isCrossTier && idx > sourceIndex) ? -sourceGap : 0
            let union = staticUnionRect(of: id, base: header, descendants: descendants)
            entries.append(ZoneEntry(
                id: id,
                frame: union.offsetBy(dx: 0, dy: shift),
                headerFrame: header.offsetBy(dx: 0, dy: shift),
                isFolder: folderDepths[id] != nil,
                isExpanded: children[id] != nil,
                children: children[id] ?? [],
                shift: shift
            ))
        }
        return entries
    }

    /// Child source (any depth): the source tier's TOP-LEVEL layout in static
    /// space — the dragged row removed means its top-level ANCESTOR block's
    /// union shrinks by one source gap and every block below it shifts up to
    /// match. Folder zones stay live (the ancestor's body recurses down to
    /// the source's own sibling slots; other folders = nest targets), so
    /// depth is decided purely by where the ghost is.
    private func outerZoneEntries() -> [ZoneEntry] {
        guard let parentIdx = parentTopIndex else { return [] }
        let sourceGap = sourceRowHeight + sourceSpacing
        var entries: [ZoneEntry] = []
        for (idx, id) in sourceOuterBlocks.enumerated() {
            guard let header = rowFrames[id] else { continue }
            let shift: CGFloat = idx > parentIdx ? -sourceGap : 0
            // The union keeps the dragged row's own resting frame (its hole)
            // — the explicit shrink below models its removal. Only stale
            // collapsed-away descendants are skipped (staticUnionRect).
            var union = staticUnionRect(of: id, base: header, descendants: sourceDescendants)
            if idx == parentIdx {
                union.size.height -= sourceGap
            }
            entries.append(ZoneEntry(
                id: id,
                frame: union.offsetBy(dx: 0, dy: shift),
                headerFrame: header.offsetBy(dx: 0, dy: shift),
                isFolder: sourceFolderDepths[id] != nil,
                isExpanded: sourceOuterChildren[id] != nil,
                children: sourceOuterChildren[id] ?? [],
                shift: shift
            ))
        }
        return entries
    }

    /// Zone resolution INSIDE an expanded folder's body, walking its direct
    /// children in static space. A closed subfolder presents the same absorb
    /// band as a top-level closed folder; an EXPANDED subfolder presents the
    /// same split as a top-level one — thin strip above its header inserts
    /// before it, its body RECURSES so the ghost can aim at a child slot any
    /// depth down. Illegal nest targets read as plain slot boundaries.
    private func childZone(in entry: ZoneEntry, centerY: CGFloat) -> Zone {
        let bias = slotBias
        let sourceGap = sourceRowHeight + sourceSpacing
        let children = isCrossTier ? targetChildren : sourceChildren
        let descendants = isCrossTier ? targetDescendants : sourceDescendants
        let folderDepths = isCrossTier ? targetFolderDepths : sourceFolderDepths
        let payloadID = payload?.id
        var slot = 0
        var belowSource = false
        for kid in entry.children {
            if kid == payloadID { belowSource = true; continue }
            guard let header = rowFrames[kid] else { continue }
            let isExpandedKid = children[kid] != nil
            // The kid whose subtree holds the dragged row: its union still
            // contains the hole, so its static height is one source gap
            // shorter — and everything after it has closed up, same as after
            // the hole itself.
            let holdsSource = !isCrossTier && payloadID != nil
                && descendants[kid]?.contains(payloadID!) == true
            var frame = header
            if isExpandedKid {
                frame = staticUnionRect(of: kid, base: header, descendants: descendants)
                if holdsSource { frame.size.height -= sourceGap }
            }
            // Static space has everything below the source's hole (a direct
            // kid here, or buried in a `holdsSource` subtree) closed up.
            var shift = entry.shift
            if belowSource { shift -= sourceGap }
            if holdsSource { belowSource = true }

            if folderDepths[kid] != nil, folderZonesAllowed(kid) {
                if isExpandedKid {
                    let headerBand = header.minY + header.height * 0.4 + shift
                    if centerY < headerBand {
                        return .childInsert(folderID: entry.id, slot: slot)
                    }
                    if centerY <= frame.maxY + shift {
                        return childZone(in: ZoneEntry(
                            id: kid,
                            frame: frame.offsetBy(dx: 0, dy: shift),
                            headerFrame: header.offsetBy(dx: 0, dy: shift),
                            isFolder: true,
                            isExpanded: true,
                            children: children[kid] ?? [],
                            shift: shift
                        ), centerY: centerY)
                    }
                    slot += 1
                } else {
                    let top = frame.minY + frame.height * 0.22 + shift
                    let bottom = frame.maxY - frame.height * 0.22 + shift
                    if centerY >= top, centerY <= bottom {
                        return .hover(folderID: kid)
                    }
                    if centerY > bottom { slot += 1 }
                }
            } else if centerY > frame.midY + shift + bias {
                slot += 1
            }
        }
        return .childInsert(folderID: entry.id, slot: slot)
    }

    private func nearestGridSlot(_ grid: GridGeometry, center: CGPoint, slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for slot in 0..<slots {
            let cell = grid.cellCenter(slot)
            let distance = hypot(center.x - cell.x, center.y - cell.y)
            if distance < bestDistance {
                bestDistance = distance
                best = slot
            }
        }
        return best
    }

    // MARK: - Folder hover

    /// Hovering a closed folder highlights it; release absorbs the note. The
    /// folder does NOT spring open mid-drag — placing at a specific child
    /// slot is for folders the user already opened.
    private func setHoverFolder(_ folderID: UUID?) {
        guard folderID != hoverFolderID else { return }
        hoverFolderID = folderID
        if nestTargetFolderID != folderID { nestTargetFolderID = folderID }
    }

    // MARK: - Landing resolution (release glide destinations, global coords)

    private func sourceBlockFrame(_ index: Int) -> CGRect? {
        guard sourceBlocks.indices.contains(index) else { return nil }
        // The dragged block is just its row: an expanded folder collapses at
        // lift (its stale descendants are excluded by staticUnionRect).
        guard let base = rowFrames[sourceBlocks[index]] else { return nil }
        if index == sourceIndex { return base }
        return staticUnionRect(of: sourceBlocks[index], base: base, descendants: sourceDescendants)
    }

    private func targetBlockFrame(_ index: Int) -> CGRect? {
        guard targetBlocks.indices.contains(index),
              let base = rowFrames[targetBlocks[index]]
        else { return nil }
        return staticUnionRect(of: targetBlocks[index], base: base, descendants: targetDescendants)
    }

    private func reorderLandingGlobal(for slot: Int) -> CGPoint? {
        guard let ghost, let payload else { return nil }
        if let grid = sourceGrid {
            let origin = grid.cellOrigin(slot)
            return CGPoint(x: origin.x + contentOriginGlobal.x, y: origin.y + contentOriginGlobal.y)
        }
        // No sibling blocks: glide home to the row's own frame.
        guard !sourceBlocks.isEmpty else {
            return rowFrames[payload.id].map {
                CGPoint(x: $0.minX + contentOriginGlobal.x, y: $0.minY + contentOriginGlobal.y)
            }
        }
        guard let sourceFrame = sourceBlockFrame(sourceIndex) else { return nil }

        let topContent: CGFloat
        if slot == sourceIndex {
            topContent = sourceFrame.minY
        } else if let slotFrame = sourceBlockFrame(slot) {
            topContent = slot > sourceIndex
                ? slotFrame.maxY - ghost.size.height
                : slotFrame.minY
        } else {
            return nil
        }

        return CGPoint(
            x: sourceFrame.minX + contentOriginGlobal.x,
            y: topContent + contentOriginGlobal.y
        )
    }

    private func insertLandingGlobal(tier: NoteTier, index: Int) -> CGPoint? {
        if let grid = targetGrid {
            let origin = grid.cellOrigin(index)
            return CGPoint(x: origin.x + contentOriginGlobal.x, y: origin.y + contentOriginGlobal.y)
        }
        guard targetBlocks.isEmpty == false else {
            // Empty tier: glide to the drop band at the section top.
            return tierFrames[tier].map {
                CGPoint(x: $0.minX + contentOriginGlobal.x, y: $0.minY + contentOriginGlobal.y)
            }
        }

        let xContent = targetBlockFrame(0)?.minX ?? tierFrames[tier]?.minX ?? 0
        let yContent: CGFloat
        if index < targetBlocks.count, let frame = targetBlockFrame(index) {
            yContent = frame.minY
        } else if let last = targetBlockFrame(targetBlocks.count - 1) {
            yContent = last.maxY + targetSpacing
        } else {
            return nil
        }

        return CGPoint(x: xContent + contentOriginGlobal.x, y: yContent + contentOriginGlobal.y)
    }

    /// Where an un-nesting child settles: the top-level slot's static position
    /// in the outer scope (parent folder shrunk, blocks below shifted up).
    private func unnestLandingGlobal(index: Int) -> CGPoint? {
        let entries = outerZoneEntries()
        guard let first = entries.first else { return nil }
        let yContent: CGFloat
        if index < entries.count {
            yContent = entries[index].frame.minY
        } else if let last = entries.last {
            yContent = last.frame.maxY + sourceSpacing
        } else {
            return nil
        }
        return CGPoint(
            x: first.headerFrame.minX + contentOriginGlobal.x,
            y: yContent + contentOriginGlobal.y
        )
    }

    /// Where the ghost settles when nesting at a child slot: the slot's static
    /// position inside the (grown) folder, child-inset from the folder's own
    /// header (which is already depth-inset for nested targets).
    private func childInsertLandingGlobal(folderID: UUID, slot: Int) -> CGPoint? {
        let blocks: [UUID]
        let children: [UUID: [UUID]]
        let descendants: [UUID: [UUID]]
        let spacing: CGFloat
        let holeIndex: Int?
        if isCrossTier {
            blocks = targetBlocks
            children = targetChildren
            descendants = targetDescendants
            spacing = targetSpacing
            holeIndex = nil
        } else if sourceParentFolderID != nil, parentTopIndex != nil {
            blocks = sourceOuterBlocks
            children = sourceOuterChildren
            descendants = sourceDescendants
            spacing = sourceSpacing
            holeIndex = parentTopIndex
        } else {
            // Top-level source (child sources of any depth resolve the outer
            // scope; this is also the defensive fallback if the ancestor
            // lookup failed and parentTopIndex is nil).
            blocks = sourceBlocks
            children = sourceChildren
            descendants = sourceDescendants
            spacing = sourceSpacing
            holeIndex = sourceIndex
        }
        // The target may be nested: locate the scope block whose subtree
        // holds it, then walk the containment chain accumulating the static
        // shift (scope hole above the block; source hole — direct kid or
        // buried subtree — above the chain at any level).
        guard let blockIdx = blocks.firstIndex(where: {
            $0 == folderID || descendants[$0]?.contains(folderID) == true
        }), let header = rowFrames[folderID]
        else { return nil }
        let payloadID = payload?.id
        let sourceGap = sourceRowHeight + sourceSpacing
        var shift: CGFloat = (holeIndex.map { blockIdx > $0 } ?? false) ? -sourceGap : 0
        var container = blocks[blockIdx]
        while container != folderID {
            guard let kids = children[container],
                  let chainIdx = kids.firstIndex(where: {
                      $0 == folderID || descendants[$0]?.contains(folderID) == true
                  })
            else { return nil }
            if !isCrossTier, let payloadID,
               let holeIdx = kids.firstIndex(where: {
                   $0 == payloadID || descendants[$0]?.contains(payloadID) == true
               }), chainIdx > holeIdx {
                shift -= sourceGap
            }
            container = kids[chainIdx]
        }
        let kids = (children[folderID] ?? []).filter { $0 != payloadID }
        // The final container may hold the hole too (target = an ancestor of
        // the source's parent): reference rows past the hole's chain rest one
        // gap lower than their static position.
        var slotShift = shift
        if !isCrossTier, let payloadID,
           let holeIdx = kids.firstIndex(where: {
               descendants[$0]?.contains(payloadID) == true
           }), slot >= kids.count || slot > holeIdx {
            slotShift -= sourceGap
        }

        let yContent: CGFloat
        if slot < kids.count, let slotFrame = rowFrames[kids[slot]] {
            yContent = slotFrame.minY + slotShift
        } else if let lastID = kids.last, let lastFrame = rowFrames[lastID] {
            // The last kid may be an expanded subfolder — land below its
            // whole block, not just its header.
            let lastUnion = staticUnionRect(of: lastID, base: lastFrame, descendants: descendants)
            yContent = lastUnion.maxY + spacing + slotShift
        } else {
            yContent = header.maxY + spacing + slotShift
        }
        return CGPoint(
            x: header.minX + Self.childInset + contentOriginGlobal.x,
            y: yContent + contentOriginGlobal.y
        )
    }

    // MARK: - Cross-space switching (P4)

    /// Holding the finger in a screen-edge band pages the pager to the
    /// adjacent space after a short dwell — and keeps paging, one space per
    /// interval, while held. ARM and DISARM use different widths
    /// (hysteresis): finger wobble of a few points at the edge must not
    /// leave the band, because re-entering restarts the dwell from zero —
    /// that read as "it randomly stops and I have to re-arm".
    private func updateEdgeSwitch() {
        guard viewportGlobal.width > 0 else { return }
        let armBand: CGFloat = 32
        let disarmBand: CGFloat = 54
        let x = lastFingerGlobal.x
        var direction = edgeDirection
        if x < viewportGlobal.minX + armBand {
            direction = -1
        } else if x > viewportGlobal.maxX - armBand {
            direction = 1
        } else if edgeDirection == -1, x >= viewportGlobal.minX + disarmBand {
            direction = 0
        } else if edgeDirection == 1, x <= viewportGlobal.maxX - disarmBand {
            direction = 0
        }
        guard direction != edgeDirection else { return }
        edgeDirection = direction
        if direction != 0 {
            scheduleEdgeFire(after: 0.35)
        } else {
            edgeFireToken = UUID()   // kill the pending fire
        }
    }

    private func scheduleEdgeFire(after delay: TimeInterval) {
        let gen = dragGeneration
        let token = UUID()
        edgeFireToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.dragGeneration == gen, self.edgeFireToken == token,
                  self.isActive, !self.isSettling, self.edgeDirection != 0
            else { return }
            self.switchSpace(by: self.edgeDirection)
            // Still held at the edge → keep walking the pager.
            self.scheduleEdgeFire(after: 0.6)
        }
    }

    /// Page the pager `delta` spaces from the current one (edge hold and the
    /// second-finger swipe both land here).
    func switchSpace(by delta: Int) {
        guard isActive, let active = activeSpaceID,
              let idx = orderedSpaceIDs.firstIndex(of: active),
              orderedSpaceIDs.indices.contains(idx + delta)
        else { return }
        requestSpaceSwitch?(orderedSpaceIDs[idx + delta])
    }

    // MARK: - Auto-scroll

    private func updateAutoScroll() {
        guard viewportGlobal.height > 0 else { return }
        let band: CGFloat = 90
        let maxSpeed: CGFloat = 14   // pt per 1/60s tick
        let y = lastFingerGlobal.y
        let topEdge = viewportGlobal.minY + band
        let bottomEdge = viewportGlobal.maxY - band

        var velocity: CGFloat = 0
        if y < topEdge {
            velocity = -maxSpeed * min(1, (topEdge - y) / band)
        } else if y > bottomEdge {
            velocity = maxSpeed * min(1, (y - bottomEdge) / band)
        }
        // Quantize so the observed property (and its reader leaf) doesn't
        // churn on every sub-point change.
        velocity = (velocity * 2).rounded() / 2
        if velocity != autoScrollVelocity { autoScrollVelocity = velocity }
    }
}

// MARK: - Active-page gating

/// `true` only on the space page the pager is currently settled on. Rows use
/// it to gate frame reporting — Essentials render on EVERY page, so without
/// gating their frames would collide across pages.
private struct IsActiveSpacePageKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isActiveSpacePage: Bool {
        get { self[IsActiveSpacePageKey.self] }
        set { self[IsActiveSpacePageKey.self] = newValue }
    }
}
