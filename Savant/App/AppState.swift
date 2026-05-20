import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    enum PresentedSheet: Identifiable, Equatable {
        case switcher
        case newSpace
        case search(Space?)
        case settings
        case noteRead(Note)
        case tidyReview(TidyRun)

        var id: String {
            switch self {
            case .switcher: "switcher"
            case .newSpace: "newSpace"
            case .search(let space): "search-\(space?.id.uuidString ?? "all")"
            case .settings: "settings"
            case .noteRead(let note): "noteRead-\(note.id.uuidString)"
            case .tidyReview(let run): "tidyReview-\(run.id.uuidString)"
            }
        }

        static func == (lhs: PresentedSheet, rhs: PresentedSheet) -> Bool {
            lhs.id == rhs.id
        }
    }

    enum PresentedFullScreen: Identifiable, Equatable {
        case noteEdit(Note)

        var id: String {
            switch self {
            case .noteEdit(let note): "noteEdit-\(note.id.uuidString)"
            }
        }
    }

    var selectedSpaceID: UUID?
    var presentedSheet: PresentedSheet?
    var presentedFullScreen: PresentedFullScreen?
    var selectedSearchScope: SearchScope = .thisSpace

    func presentRead(_ note: Note) {
        presentedSheet = .noteRead(note)
    }

    func presentEdit(_ note: Note) {
        presentedSheet = nil
        presentedFullScreen = .noteEdit(note)
    }

    func closeFullScreen() {
        presentedFullScreen = nil
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case thisSpace = "This space"
    case allSpaces = "All spaces"
    case archive = "Archive"

    var id: String { rawValue }
}
