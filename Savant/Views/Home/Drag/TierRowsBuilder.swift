import Foundation

/// Flat row model for one tier — mirrors the macOS `flatRows` semantics: a
/// single ordered list of folder headers and note rows (children indented
/// under expanded folders, recursively — subfolders render like the macOS
/// sidebar), built once per body pass. Sections render ONE ForEach over
/// `rows` and feed the scope maps to the drag engine.
struct TierLayout {
    enum RowKind {
        case note(Note)
        case folder(Folder)
    }

    struct Row: Identifiable {
        let kind: RowKind
        let depth: Int
        let parentFolderID: UUID?

        var id: UUID {
            switch kind {
            case .note(let note): note.id
            case .folder(let folder): folder.id
            }
        }
    }

    var rows: [Row] = []
    /// Top-level sibling order (folder headers + loose notes, interleaved).
    var topLevelIDs: [UUID] = []
    /// Folder id → ordered DIRECT children (subfolder headers + note rows,
    /// interleaved by the shared per-container order). Expanded folders only —
    /// these are the rows actually rendered, which the drag engine shuffles.
    var childIDs: [UUID: [UUID]] = [:]
    /// Folder id → ALL rendered descendant row ids (any depth, render order).
    /// The engine uses these for block unions and whole-block shifts.
    var descendantIDs: [UUID: [UUID]] = [:]
    /// Every rendered folder id → its depth (0 = top level). Doubles as the
    /// engine's "is this row a folder" lookup and gates the nesting cap.
    var folderDepths: [UUID: Int] = [:]
}

enum TierRowsBuilder {
    /// Container interleave (top level AND inside each folder): folders sort
    /// by `sortIndex`, notes by `manualSortIndex` — one shared 0..n counter
    /// per container (see `FolderService.normalizeContainer`). Unindexed notes
    /// fall back to `createdAt` after all indexed items. A reorder commit
    /// writes one unified sequence across both, so after the first manual
    /// drag the interleave is exact.
    static func build(
        folders: [Folder],
        notes: [Note],
        expandedFolderIDs: Set<UUID>,
        childFolders: (Folder) -> [Folder],
        childNotes: (Folder) -> [Note]
    ) -> TierLayout {
        var layout = TierLayout()
        for item in sortedChildren(folders: folders, notes: notes) {
            switch item {
            case .note(let note):
                layout.rows.append(.init(kind: .note(note), depth: 0, parentFolderID: nil))
                layout.topLevelIDs.append(note.id)
            case .folder(let folder):
                layout.rows.append(.init(kind: .folder(folder), depth: 0, parentFolderID: nil))
                layout.topLevelIDs.append(folder.id)
                layout.folderDepths[folder.id] = 0
                if expandedFolderIDs.contains(folder.id) {
                    _ = appendChildren(
                        of: folder, depth: 1, into: &layout,
                        expandedFolderIDs: expandedFolderIDs,
                        childFolders: childFolders, childNotes: childNotes
                    )
                }
            }
        }
        return layout
    }

    /// One container's direct children in their unified order — the commit
    /// helpers splice into this (same comparator the renderer uses).
    static func orderedChildIDs(folders: [Folder], notes: [Note]) -> [UUID] {
        sortedChildren(folders: folders, notes: notes).map(\.id)
    }

    /// Manual order first, then capture order — the one note comparator for
    /// every tier list (matches `SpaceView.noteSort`).
    static func noteSort(_ lhs: Note, _ rhs: Note) -> Bool {
        switch (lhs.manualSortIndex, rhs.manualSortIndex) {
        case let (l?, r?): l < r
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): lhs.createdAt < rhs.createdAt
        }
    }

    // MARK: - Internals

    private enum Child {
        case folder(Folder)
        case note(Note)

        var id: UUID {
            switch self {
            case .folder(let folder): folder.id
            case .note(let note): note.id
            }
        }
    }

    /// Recursively renders one expanded folder's children; returns ALL
    /// descendant row ids appended (any depth) for `descendantIDs`.
    private static func appendChildren(
        of folder: Folder,
        depth: Int,
        into layout: inout TierLayout,
        expandedFolderIDs: Set<UUID>,
        childFolders: (Folder) -> [Folder],
        childNotes: (Folder) -> [Note]
    ) -> [UUID] {
        let items = sortedChildren(folders: childFolders(folder), notes: childNotes(folder))
        var direct: [UUID] = []
        var descendants: [UUID] = []
        for item in items {
            direct.append(item.id)
            descendants.append(item.id)
            switch item {
            case .note(let note):
                layout.rows.append(.init(kind: .note(note), depth: depth, parentFolderID: folder.id))
            case .folder(let sub):
                layout.rows.append(.init(kind: .folder(sub), depth: depth, parentFolderID: folder.id))
                layout.folderDepths[sub.id] = depth
                // Recursion bounded by the model's nesting cap, defensively.
                if expandedFolderIDs.contains(sub.id), depth < Folder.maxDepth + 1 {
                    descendants += appendChildren(
                        of: sub, depth: depth + 1, into: &layout,
                        expandedFolderIDs: expandedFolderIDs,
                        childFolders: childFolders, childNotes: childNotes
                    )
                }
            }
        }
        layout.childIDs[folder.id] = direct
        layout.descendantIDs[folder.id] = descendants
        return descendants
    }

    private static func sortedChildren(folders: [Folder], notes: [Note]) -> [Child] {
        struct Keyed {
            let sortKey: Int?
            let isFolder: Bool
            let createdAt: Date
            let item: Child
        }

        var keyed: [Keyed] = folders.map {
            Keyed(sortKey: $0.sortIndex, isFolder: true, createdAt: $0.createdAt, item: .folder($0))
        }
        keyed += notes.map {
            Keyed(sortKey: $0.manualSortIndex, isFolder: false, createdAt: $0.createdAt, item: .note($0))
        }

        keyed.sort { lhs, rhs in
            switch (lhs.sortKey, rhs.sortKey) {
            case let (l?, r?):
                if l != r { return l < r }
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt < rhs.createdAt
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.createdAt < rhs.createdAt
            }
        }
        return keyed.map(\.item)
    }
}
