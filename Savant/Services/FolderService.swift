import Foundation
import SwiftData

/// Shared folder mutations for both iOS and macOS. Lives in `Services/` so it
/// compiles into the macOS target (which doesn't include `Views/Home/`).
@MainActor
struct FolderService {
    let context: ModelContext

    /// Create a folder in `space` at `tier`, optionally nested under `parent`.
    /// `sortIndex` is placed after existing siblings at the same level so new
    /// folders append rather than jump to the top. Returns the new folder.
    @discardableResult
    func create(
        name: String = "New Folder",
        in space: Space,
        tier: NoteTier,
        parent: Folder? = nil
    ) throws -> Folder {
        let spaceID = space.id
        let parentID = parent?.id
        let siblings = try context.fetch(
            FetchDescriptor<Folder>(predicate: #Predicate {
                $0.space?.id == spaceID && $0.parent?.id == parentID
            })
        )
        let nextIndex = (siblings.map(\.sortIndex).max() ?? -1) + 1
        let folder = Folder(
            name: name,
            createdByTidy: false,
            parent: parent,
            sortIndex: nextIndex,
            space: space,
            tier: tier
        )
        context.insert(folder)
        try context.save()
        return folder
    }

    func rename(_ folder: Folder, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled Folder" : trimmed
        try context.save()
    }

    /// Whether `folder` can legally become a child of `newParent` without
    /// creating a cycle or exceeding `Folder.maxDepth`. Passing `nil` (move to
    /// top level) is always allowed.
    func canNest(_ folder: Folder, under newParent: Folder?) -> Bool {
        guard let newParent else { return true }
        if newParent.id == folder.id { return false }
        // Reject if newParent is a descendant of folder (would form a cycle).
        var node: Folder? = newParent
        var hops = 0
        while let current = node, hops <= Folder.maxDepth + 3 {
            if current.id == folder.id { return false }
            node = current.parent
            hops += 1
        }
        // Reject if the deepest leaf under `folder` would exceed maxDepth once
        // re-rooted at newParent.depth + 1.
        let baseDepth = newParent.depth + 1
        return baseDepth + subtreeHeight(of: folder) <= Folder.maxDepth
    }

    /// Height of the subtree rooted at `folder` (a leaf has height 0).
    private func subtreeHeight(of folder: Folder) -> Int {
        let kids = folder.children ?? []
        guard !kids.isEmpty else { return 0 }
        return 1 + (kids.map { subtreeHeight(of: $0) }.max() ?? 0)
    }

    /// Re-parent `folder` under `newParent` (or to top level when nil),
    /// inheriting the destination's tier/space. No-op if the move is illegal.
    func reparent(_ folder: Folder, under newParent: Folder?) throws {
        guard canNest(folder, under: newParent) else { return }
        folder.parent = newParent
        if let newParent {
            folder.tier = newParent.tier
            folder.space = newParent.space
        }
        try context.save()
    }

    func setCollapsed(_ folder: Folder, _ collapsed: Bool) throws {
        folder.isCollapsed = collapsed
        try context.save()
    }

    func delete(_ folder: Folder) throws {
        let folderID = folder.id
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.folder?.id == folderID })
        let notes = try context.fetch(descriptor)
        for note in notes {
            note.folder = nil
        }
        context.delete(folder)
        try context.save()
    }

    func moveNote(_ note: Note, into folder: Folder) throws {
        note.folder = folder
        if let space = folder.space {
            note.space = space
        }
        note.tier = folder.tier
        note.updatedAt = Date()
        try context.save()
    }

    /// Unify a tier's top-level ordering so standalone notes (`manualSortIndex`)
    /// and top-level folders (`sortIndex`) share ONE 0..n counter — letting them
    /// interleave in the flat sidebar list. Detects the legacy dual-index state
    /// (value collisions or nil note indices) and migrates it folders-first;
    /// once unified it preserves the existing order. Also renumbers each folder's
    /// child folders + member notes into their own per-container counters.
    func normalizeTierOrder(tier: NoteTier, in space: Space) throws {
        let spaceID = space.id
        let folders = (try context.fetch(FetchDescriptor<Folder>(predicate: #Predicate {
            $0.space?.id == spaceID
        }))).filter { $0.tier == tier && $0.parent == nil }
        let notes = (try context.fetch(FetchDescriptor<Note>(predicate: #Predicate {
            $0.space?.id == spaceID
        }))).filter { $0.tier == tier && $0.folder == nil }

        var changed = false
        normalizeContainer(folders: folders, notes: notes, changed: &changed)
        if changed { try context.save() }
    }

    /// Assign ONE shared 0..n order counter across a container's child folders
    /// (`sortIndex`) AND member notes (`manualSortIndex`) so they interleave —
    /// e.g. a note can sit above a sub-folder. Migrates the legacy dual-index
    /// state folders-first; once unified, preserves order. Recurses into each
    /// child folder.
    private func normalizeContainer(folders: [Folder], notes: [Note], changed: inout Bool) {
        enum Item { case folder(Folder); case note(Note) }
        func key(_ i: Item) -> Int {
            switch i {
            case .folder(let f): return f.sortIndex
            case .note(let n): return n.manualSortIndex ?? Int.max
            }
        }
        func created(_ i: Item) -> Date {
            switch i {
            case .folder(let f): return f.createdAt
            case .note(let n): return n.createdAt
            }
        }
        let vals = folders.map { $0.sortIndex } + notes.map { $0.manualSortIndex ?? Int.max }
        let unified = Set(vals).count == vals.count && !notes.contains { $0.manualSortIndex == nil }

        let ordered: [Item]
        if unified {
            ordered = (folders.map { Item.folder($0) } + notes.map { Item.note($0) })
                .sorted { key($0) != key($1) ? key($0) < key($1) : created($0) < created($1) }
        } else {
            // Legacy dual-index → migrate folders-first within the container.
            let f = folders.sorted { $0.sortIndex != $1.sortIndex ? $0.sortIndex < $1.sortIndex : $0.createdAt < $1.createdAt }
            let n = notes.sorted {
                let a = $0.manualSortIndex ?? Int.max, b = $1.manualSortIndex ?? Int.max
                return a != b ? a < b : $0.createdAt < $1.createdAt
            }
            ordered = f.map { Item.folder($0) } + n.map { Item.note($0) }
        }

        for (i, item) in ordered.enumerated() {
            switch item {
            case .folder(let f): if f.sortIndex != i { f.sortIndex = i; changed = true }
            case .note(let n): if n.manualSortIndex != i { n.manualSortIndex = i; changed = true }
            }
        }
        for f in folders {
            normalizeContainer(folders: f.children ?? [], notes: f.notes ?? [], changed: &changed)
        }
    }

    /// Move a folder's whole subtree (the folder, its member notes, and every
    /// descendant folder + their notes) to `tier`.
    func changeTier(_ folder: Folder, to tier: NoteTier) throws {
        applyTier(folder, tier)
        try context.save()
    }

    private func applyTier(_ folder: Folder, _ tier: NoteTier) {
        folder.tier = tier
        for n in (folder.notes ?? []) { n.tier = tier }
        for c in (folder.children ?? []) { applyTier(c, tier) }
    }

    /// Move a folder's whole subtree to a new tier AND space (cross-space drag).
    func move(_ folder: Folder, toTier tier: NoteTier, toSpace space: Space) throws {
        applyTierSpace(folder, tier, space)
        try context.save()
    }

    private func applyTierSpace(_ folder: Folder, _ tier: NoteTier, _ space: Space) {
        folder.tier = tier
        folder.space = space
        for n in (folder.notes ?? []) { n.tier = tier; n.space = space }
        for c in (folder.children ?? []) { applyTierSpace(c, tier, space) }
    }
}
