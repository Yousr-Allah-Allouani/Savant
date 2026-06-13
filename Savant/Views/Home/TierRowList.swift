import SwiftData
import SwiftUI

/// One tier's flat row list (Kept and Stream): a single ForEach over the
/// interleaved folder/note rows, owning expansion state and ALL of the tier's
/// drag commits. Every body pass it publishes a fresh `TierDragContext` into
/// the session (active page only), so the engine always sees current layout +
/// handlers. Rendered even when empty — during a drag the empty tier shows an
/// insertion band the ghost can target.
struct TierRowList: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TouchDragSession.self) private var session
    @Environment(\.isActiveSpacePage) private var isActivePage

    let tier: NoteTier
    /// This tier's top-level folders / loose notes (current space).
    let folders: [Folder]
    let notes: [Note]
    /// Full query results — cross-tier arrivals are looked up here.
    let allFolders: [Folder]
    let allNotes: [Note]
    let currentSpace: Space
    let showsPreview: Bool
    /// Stream shows the capture hint when empty; Kept just collapses.
    var showsEmptyHint = false

    @State private var expandedFolderIDs: Set<UUID> = []
    /// Folder collapsed by a lift (not by the user) — re-expanded on settle.
    @State private var liftCollapsedFolderID: UUID?

    var body: some View {
        let layout = TierRowsBuilder.build(
            folders: folders,
            notes: notes,
            expandedFolderIDs: expandedFolderIDs,
            childFolders: childFolders,
            childNotes: childNotes
        )
        let _ = publishContext(layout)

        VStack(alignment: .leading, spacing: SavantTheme.rowSpacing) {
            if layout.rows.isEmpty {
                if session.isActive {
                    TierDropBand(tier: tier)
                } else if showsEmptyHint {
                    emptyHint
                }
            } else {
                ForEach(layout.rows) { row in
                    rowView(row)
                        .padding(.leading, CGFloat(row.depth) * TouchDragSession.childInset)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Visual offsets can't make room past the last row or move the
        // dividers between sections — the section itself grows by one gap
        // when it's the cross-tier target (and shrinks once its row leaves).
        .padding(.bottom, bottomAdjustment)
        .animation(session.isActive ? TouchDragSession.rowShuffle : nil, value: bottomAdjustment)
        .onGeometryChange(for: ActiveFrame.self) { proxy in
            ActiveFrame(frame: proxy.frame(in: .named("spaceContent")), active: isActivePage)
        } action: { report in
            if report.active { session.tierFrames[tier] = report.frame }
        }
    }

    private var bottomAdjustment: CGFloat {
        session.bottomAdjustment(for: tier)
    }

    @ViewBuilder
    private func rowView(_ row: TierLayout.Row) -> some View {
        switch row.kind {
        case .note(let note):
            NoteRowView(
                note: note,
                currentSpace: currentSpace,
                showsPreview: showsPreview,
                tier: tier,
                parentFolderID: row.parentFolderID
            )
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                count: childFolders(folder).count + childNotes(folder).count,
                isExpanded: expandedFolderIDs.contains(folder.id),
                toggleExpanded: { toggle(folder.id) },
                tier: tier,
                parentFolderID: row.parentFolderID,
                onWillLift: { collapseForLift(folder.id) },
                onSettled: { restoreLiftCollapse(folder.id) }
            )
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.message.fill")
                .font(.system(size: 26))
                .foregroundStyle(.savantSubtleInk)
            Text("Nothing here yet. Capture below ↓")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .multilineTextAlignment(.center)
    }

    // MARK: - Drag context

    private func publishContext(_ layout: TierLayout) {
        guard isActivePage else { return }
        let folderRowIDs = layout.rows.compactMap { row -> UUID? in
            if case .folder(let folder) = row.kind { return folder.id }
            return nil
        }
        session.publishTier(.init(
            tier: tier,
            blocks: layout.topLevelIDs,
            children: layout.childIDs,
            descendants: layout.descendantIDs,
            folderBlocks: folderRowIDs,
            folderDepths: layout.folderDepths,
            spacing: SavantTheme.rowSpacing,
            commitReorder: { applyUnifiedOrder($0); save() },
            commitChildReorder: commitChildOrder,
            commitInsert: { payload, index in
                commitInsert(payload, at: index, layout: layout)
            },
            commitNest: { commitNest($0, into: $1, at: $2) }
        ))
    }

    // MARK: - Expansion

    private func toggle(_ id: UUID) {
        withAnimation(TouchDragSession.folderToggle) {
            if expandedFolderIDs.contains(id) {
                expandedFolderIDs.remove(id)
            } else {
                expandedFolderIDs.insert(id)
            }
        }
    }

    private func collapseForLift(_ id: UUID) {
        guard expandedFolderIDs.contains(id) else { return }
        liftCollapsedFolderID = id
        withAnimation(TouchDragSession.folderToggle) {
            _ = expandedFolderIDs.remove(id)
        }
    }

    private func restoreLiftCollapse(_ id: UUID) {
        guard liftCollapsedFolderID == id else { return }
        liftCollapsedFolderID = nil
        withAnimation(TouchDragSession.folderToggle) {
            _ = expandedFolderIDs.insert(id)
        }
    }

    // MARK: - Commits (run inside a disablesAnimations transaction)

    /// Writes one unified 0..n sequence across folder `sortIndex` and note
    /// `manualSortIndex` so the top-level interleave is fully manual from the
    /// first reorder on. Looks items up in the FULL query results — a
    /// cross-tier arrival isn't in this tier's filtered lists yet.
    private func applyUnifiedOrder(_ ordered: [UUID]) {
        for (index, id) in ordered.enumerated() {
            if let folder = allFolders.first(where: { $0.id == id }) {
                folder.sortIndex = index
            } else if let note = allNotes.first(where: { $0.id == id }) {
                note.manualSortIndex = index
            }
        }
    }

    /// Children share one unified order counter per container (subfolder
    /// `sortIndex` + note `manualSortIndex`), same as the top level.
    private func commitChildOrder(parentID: UUID, _ ordered: [UUID]) {
        applyUnifiedOrder(ordered)
        _ = parentID
        save()
    }

    /// Cross-tier arrival: retier the payload, then splice it into this
    /// tier's unified order at the drop slot.
    private func commitInsert(
        _ payload: TouchDragSession.Payload, at index: Int, layout: TierLayout
    ) {
        do {
            switch payload {
            case .note(let id):
                guard let note = allNotes.first(where: { $0.id == id }) else { return }
                // Clears note.folder and re-homes the space if needed.
                try NoteService(context: modelContext).promote(note, to: tier, currentSpace: currentSpace)
                // Cross-space arrival: promote only homes space-LESS notes —
                // a note carried from another space must be claimed here.
                if tier != .favorite, note.space?.id != currentSpace.id {
                    note.space = currentSpace
                }
            case .folder(let id):
                guard let folder = allFolders.first(where: { $0.id == id }) else { return }
                let service = FolderService(context: modelContext)
                // A dragged-out subfolder arrives at the TOP level — un-nest
                // before splicing into the top-level order below.
                try service.reparent(folder, under: nil)
                // Recursive: the folder's notes (and subfolders) follow —
                // tier AND space, so cross-space arrivals re-home wholesale.
                try service.move(folder, toTier: tier, toSpace: currentSpace)
            }
        } catch {
            assertionFailure("Cross-tier insert failed: \(error)")
            return
        }

        var ordered = layout.topLevelIDs
        ordered.removeAll { $0 == payload.id }
        ordered.insert(payload.id, at: min(max(0, index), ordered.count))
        applyUnifiedOrder(ordered)
        save()
    }

    /// `index` nil = absorbed by a closed folder (lands last); set = the
    /// child slot chosen by dragging inside the open folder. The payload may
    /// be a note OR a folder (folder-into-folder nesting, capped by
    /// `Folder.maxDepth` — `reparent` no-ops illegal moves).
    private func commitNest(_ payloadID: UUID, into folderID: UUID, at index: Int?) {
        guard let target = allFolders.first(where: { $0.id == folderID }) else { return }
        let service = FolderService(context: modelContext)
        if let note = allNotes.first(where: { $0.id == payloadID }) {
            do {
                // Inherits the folder's tier + space.
                try service.moveNote(note, into: target)
            } catch {
                assertionFailure("Nest failed: \(error)")
                return
            }
        } else if let folder = allFolders.first(where: { $0.id == payloadID }) {
            do {
                try service.reparent(folder, under: target)
            } catch {
                assertionFailure("Folder nest failed: \(error)")
                return
            }
            // Illegal move (cycle/depth) was silently refused — don't splice.
            guard folder.parent?.id == target.id else { return }
        } else {
            return
        }
        var ordered = TierRowsBuilder.orderedChildIDs(
            folders: childFolders(target), notes: childNotes(target)
        ).filter { $0 != payloadID }
        let slot = index.map { min(max(0, $0), ordered.count) } ?? ordered.count
        ordered.insert(payloadID, at: slot)
        applyUnifiedOrder(ordered)
        save()
    }

    private func save() {
        try? modelContext.save()
    }

    private func childNotes(_ folder: Folder) -> [Note] {
        allNotes.filter { $0.folder?.id == folder.id && $0.tier == tier }
    }

    private func childFolders(_ folder: Folder) -> [Folder] {
        allFolders.filter { $0.parent?.id == folder.id }
    }
}

/// Insertion band an empty tier exposes mid-drag — the ghost targets it like
/// a one-row landing strip.
struct TierDropBand: View {
    @Environment(TouchDragSession.self) private var session

    let tier: NoteTier

    var body: some View {
        let isTargeted = session.currentTier == tier
        RoundedRectangle(cornerRadius: SavantTheme.rowRadius, style: .continuous)
            .fill(.primary.opacity(isTargeted ? 0.06 : 0.02))
            .strokeBorder(
                .primary.opacity(isTargeted ? 0.28 : 0.12),
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}
