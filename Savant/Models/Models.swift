import CoreTransferable
import Foundation
import SwiftData

struct DraggedItemTransfer: Codable, Transferable {
    enum Kind: String, Codable { case note, folder }
    let kind: Kind
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }

    static func note(_ id: UUID) -> DraggedItemTransfer { .init(kind: .note, id: id) }
    static func folder(_ id: UUID) -> DraggedItemTransfer { .init(kind: .folder, id: id) }
}

enum NoteTier: String, Codable, CaseIterable, Identifiable {
    case favorite
    case pinned
    case random
    case archived

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .favorite: "Favorites"
        case .pinned: "Pinned"
        case .random: "Random"
        case .archived: "Archive"
        }
    }
}

enum AttachmentKind: String, Codable, CaseIterable, Identifiable {
    case link
    case image
    case file
    case voice

    var id: String { rawValue }
}

enum TidyTrigger: String, Codable, CaseIterable, Identifiable {
    case scheduled
    case manual

    var id: String { rawValue }
}

enum TidyActionKind: String, Codable, CaseIterable, Identifiable {
    case archived
    case foldered
    case leftAlone

    var id: String { rawValue }
}

@Model
final class Space {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = ""
    var colorHex: String = "#C8D5C0"
    var darkColorHex: String = "#2A3328"
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    var isPreset: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \SpaceProfile.space) var profile: SpaceProfile?
    @Relationship(deleteRule: .cascade, inverse: \Note.space) var notes: [Note]? = []
    @Relationship(deleteRule: .cascade, inverse: \Folder.space) var folders: [Folder]? = []

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        colorHex: String,
        darkColorHex: String,
        sortIndex: Int,
        createdAt: Date = Date(),
        profile: SpaceProfile? = nil,
        isPreset: Bool
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.darkColorHex = darkColorHex
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.profile = profile
        self.isPreset = isPreset
    }
}

@Model
final class SpaceProfile {
    var id: UUID = UUID()
    var summary: String = ""
    var includeCriteria: [String] = []
    var excludeCriteria: [String] = []
    var keywords: [String] = []
    var exampleSnippets: [String] = []
    var aiInterpretation: String?
    var space: Space?

    init(
        id: UUID = UUID(),
        summary: String,
        includeCriteria: [String],
        excludeCriteria: [String],
        keywords: [String],
        exampleSnippets: [String],
        aiInterpretation: String? = nil
    ) {
        self.id = id
        self.summary = summary
        self.includeCriteria = includeCriteria
        self.excludeCriteria = excludeCriteria
        self.keywords = keywords
        self.exampleSnippets = exampleSnippets
        self.aiInterpretation = aiInterpretation
    }
}

@Model
final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var bodyMarkdown: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var tier: NoteTier = NoteTier.random
    var manualSortIndex: Int?
    var space: Space?
    var folder: Folder?
    var moveSuggestionSpaceID: UUID?
    var moveSuggestionTitle: String?
    var moveSuggestionConfidence: Double?

    @Relationship(deleteRule: .cascade, inverse: \Attachment.note) var attachments: [Attachment]? = []

    init(
        id: UUID = UUID(),
        title: String,
        bodyMarkdown: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        tier: NoteTier,
        manualSortIndex: Int? = nil,
        space: Space? = nil,
        folder: Folder? = nil
    ) {
        self.id = id
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tier = tier
        self.manualSortIndex = manualSortIndex
        self.space = space
        self.folder = folder
    }
}

@Model
final class Folder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var createdByTidy: Bool = false
    var sortIndex: Int = 0
    var tier: NoteTier = NoteTier.random
    var space: Space?
    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent) var children: [Folder]? = []
    @Relationship(deleteRule: .nullify, inverse: \Note.folder) var notes: [Note]? = []

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        createdByTidy: Bool,
        parent: Folder? = nil,
        sortIndex: Int,
        space: Space? = nil,
        tier: NoteTier
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.createdByTidy = createdByTidy
        self.parent = parent
        self.sortIndex = sortIndex
        self.space = space
        self.tier = tier
    }
}

@Model
final class Attachment {
    var id: UUID = UUID()
    var kind: AttachmentKind = AttachmentKind.link
    var url: URL?
    var imageData: Data?
    var voiceTranscript: String?
    var linkTitle: String?
    var linkSiteName: String?
    var note: Note?

    init(
        id: UUID = UUID(),
        kind: AttachmentKind,
        url: URL? = nil,
        imageData: Data? = nil,
        voiceTranscript: String? = nil,
        linkTitle: String? = nil,
        linkSiteName: String? = nil,
        note: Note? = nil
    ) {
        self.id = id
        self.kind = kind
        self.url = url
        self.imageData = imageData
        self.voiceTranscript = voiceTranscript
        self.linkTitle = linkTitle
        self.linkSiteName = linkSiteName
        self.note = note
    }
}

@Model
final class TidyRun {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var completedAt: Date?
    var notesProcessed: Int = 0
    var notesArchived: Int = 0
    var foldersCreated: Int = 0
    var bannerDismissed: Bool = false
    var trigger: TidyTrigger = TidyTrigger.manual

    @Relationship(deleteRule: .cascade, inverse: \TidyAction.run) var actions: [TidyAction]? = []

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        notesProcessed: Int = 0,
        notesArchived: Int = 0,
        foldersCreated: Int = 0,
        bannerDismissed: Bool = false,
        trigger: TidyTrigger
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.notesProcessed = notesProcessed
        self.notesArchived = notesArchived
        self.foldersCreated = foldersCreated
        self.bannerDismissed = bannerDismissed
        self.trigger = trigger
    }
}

@Model
final class TidyAction {
    var id: UUID = UUID()
    var noteId: UUID = UUID()
    var actionKind: TidyActionKind = TidyActionKind.leftAlone
    var folderName: String?
    var previousTier: NoteTier = NoteTier.random
    var undone: Bool = false
    var run: TidyRun?

    init(
        id: UUID = UUID(),
        noteId: UUID,
        actionKind: TidyActionKind,
        folderName: String? = nil,
        previousTier: NoteTier = .random,
        undone: Bool = false
    ) {
        self.id = id
        self.noteId = noteId
        self.actionKind = actionKind
        self.folderName = folderName
        self.previousTier = previousTier
        self.undone = undone
    }
}

struct SpacePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let lightHex: String
    let darkHex: String
    let profile: SpaceProfileDraft
}

struct SpaceProfileDraft: Equatable, Hashable {
    var summary: String
    var includeCriteria: [String]
    var excludeCriteria: [String]
    var keywords: [String]
    var exampleSnippets: [String]
    var aiInterpretation: String?

    func makeModel() -> SpaceProfile {
        SpaceProfile(
            summary: summary,
            includeCriteria: includeCriteria,
            excludeCriteria: excludeCriteria,
            keywords: keywords,
            exampleSnippets: exampleSnippets,
            aiInterpretation: aiInterpretation
        )
    }
}

struct AttachmentDraft: Equatable {
    var kind: AttachmentKind
    var displayTitle: String
    var url: URL?
    var imageData: Data?
    var voiceTranscript: String?
    var linkSiteName: String?
}
