import Foundation
import Observation

@MainActor
@Observable
final class InteractionMode {
    enum Mode: Equatable {
        case idle
        case dragging
        case editing(spaceID: UUID, selection: Set<UUID>)
    }

    var mode: Mode = .idle

    var isDragging: Bool {
        if case .dragging = mode { return true }
        return false
    }

    var isEditing: Bool {
        if case .editing = mode { return true }
        return false
    }

    var editingSelection: Set<UUID> {
        if case .editing(_, let sel) = mode { return sel }
        return []
    }

    func isEditing(spaceID: UUID) -> Bool {
        if case .editing(let id, _) = mode { return id == spaceID }
        return false
    }

    func beginDragging() {
        if !isEditing { mode = .dragging }
    }

    func endDragging() {
        if case .dragging = mode { mode = .idle }
    }

    func enterEditMode(spaceID: UUID) {
        mode = .editing(spaceID: spaceID, selection: [])
    }

    func exitEditMode() {
        mode = .idle
    }

    func toggleSelection(_ id: UUID) {
        guard case .editing(let spaceID, var sel) = mode else { return }
        if sel.contains(id) { sel.remove(id) } else { sel.insert(id) }
        mode = .editing(spaceID: spaceID, selection: sel)
    }

    func clearSelection() {
        guard case .editing(let spaceID, _) = mode else { return }
        mode = .editing(spaceID: spaceID, selection: [])
    }
}
