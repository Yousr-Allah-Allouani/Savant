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

    func changeTier(_ folder: Folder, to tier: NoteTier) throws {
        let folderID = folder.id
        folder.tier = tier
        let descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.folder?.id == folderID })
        for note in try context.fetch(descriptor) {
            note.tier = tier
        }
        try context.save()
    }
}
