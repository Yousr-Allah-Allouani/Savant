import Foundation
import SwiftData

enum PersistenceController {
    static let cloudContainerIdentifier = "iCloud.app.savant"

    static var schema: Schema {
        Schema([
            Space.self,
            SpaceProfile.self,
            Note.self,
            Folder.self,
            Attachment.self,
            TidyRun.self,
            TidyAction.self
        ])
    }

    static func makeModelContainer(inMemory: Bool = false, cloudKitEnabled: Bool = true) throws -> ModelContainer {
        let cloudKitDatabase: ModelConfiguration.CloudKitDatabase = cloudKitEnabled ? .private(cloudContainerIdentifier) : .none
        let configuration = ModelConfiguration(
            "Savant",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: cloudKitDatabase
        )

        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

enum SpacePresetLibrary {
    static let presets: [SpacePreset] = [
        SpacePreset(
            id: "personal",
            name: "Personal",
            emoji: "☀️",
            lightHex: "#E3D5BA",
            darkHex: "#3B3122",
            profile: SpaceProfileDraft(
                summary: "Personal errands, household reminders, relationships, health, and everyday life.",
                includeCriteria: ["personal errands", "home notes", "health reminders", "relationship notes", "life admin"],
                excludeCriteria: ["work meetings", "school assignments", "business deadlines"],
                keywords: ["home", "errand", "call", "appointment", "family", "health"],
                exampleSnippets: ["Book dentist appointment", "Gift idea for Maya", "Renew passport"]
            )
        ),
        SpacePreset(
            id: "work",
            name: "Work",
            emoji: "💼",
            lightHex: "#C5CDD3",
            darkHex: "#293138",
            profile: SpaceProfileDraft(
                summary: "Work tasks, meetings, projects, and professional communication.",
                includeCriteria: ["meeting notes", "project updates", "work tasks", "professional contacts", "deadlines"],
                excludeCriteria: ["personal errands", "hobbies", "recreational reading"],
                keywords: ["meeting", "project", "deadline", "team", "client", "deliverable"],
                exampleSnippets: ["Q3 roadmap review notes", "Call Sarah re: contract", "Standup blockers"]
            )
        ),
        SpacePreset(
            id: "college",
            name: "College",
            emoji: "🎓",
            lightHex: "#D5CCE0",
            darkHex: "#2E2A38",
            profile: SpaceProfileDraft(
                summary: "Classes, assignments, exam prep, campus logistics, and research notes.",
                includeCriteria: ["lecture notes", "assignments", "exam prep", "research ideas", "campus errands"],
                excludeCriteria: ["unrelated work tasks", "recipes", "travel logistics"],
                keywords: ["class", "paper", "exam", "lecture", "professor", "reading"],
                exampleSnippets: ["Anthro midterm chapters", "Ask TA about lab report", "Essay thesis ideas"]
            )
        ),
        SpacePreset(
            id: "recipes",
            name: "Recipes",
            emoji: "🍳",
            lightHex: "#D9B5A0",
            darkHex: "#3D2820",
            profile: SpaceProfileDraft(
                summary: "Recipes, groceries, meal prep, restaurant inspiration, and cooking notes.",
                includeCriteria: ["ingredients", "cooking steps", "meal ideas", "grocery lists", "restaurant inspiration"],
                excludeCriteria: ["work deadlines", "class notes", "finance tasks"],
                keywords: ["recipe", "salt", "oven", "sauce", "grocery", "dinner"],
                exampleSnippets: ["Miso butter salmon", "Buy basil and lemons", "Try crisp rice technique"]
            )
        ),
        SpacePreset(
            id: "reading",
            name: "Reading",
            emoji: "📚",
            lightHex: "#B8C5A8",
            darkHex: "#2B3322",
            profile: SpaceProfileDraft(
                summary: "Books, articles, references, quotes, and reading-list material.",
                includeCriteria: ["book notes", "article links", "quotes", "research references", "reading lists"],
                excludeCriteria: ["urgent tasks", "shopping lists", "calendar logistics"],
                keywords: ["book", "essay", "quote", "paper", "article", "read"],
                exampleSnippets: ["Read Ursula Le Guin essay", "Quote about attention", "Paper on spatial memory"]
            )
        ),
        SpacePreset(
            id: "travel",
            name: "Travel",
            emoji: "✈️",
            lightHex: "#D7DCE0",
            darkHex: "#2C3035",
            profile: SpaceProfileDraft(
                summary: "Trips, places to visit, lodging, packing, transit, and itinerary notes.",
                includeCriteria: ["itinerary", "places to visit", "packing lists", "lodging", "travel logistics"],
                excludeCriteria: ["work project notes", "daily household tasks", "class assignments"],
                keywords: ["flight", "hotel", "train", "museum", "packing", "trip"],
                exampleSnippets: ["Lisbon cafe list", "Passport expires in October", "Pack USB-C adapter"]
            )
        ),
        SpacePreset(
            id: "ideas",
            name: "Ideas",
            emoji: "💡",
            lightHex: "#C8D5C0",
            darkHex: "#2A3328",
            profile: SpaceProfileDraft(
                summary: "Creative fragments, startup ideas, writing sparks, design references, and experiments.",
                includeCriteria: ["creative ideas", "product concepts", "writing prompts", "design notes", "experiments"],
                excludeCriteria: ["routine errands", "fixed appointments", "finance records"],
                keywords: ["idea", "concept", "prototype", "sketch", "draft", "experiment"],
                exampleSnippets: ["Ambient notebook concept", "Opening line for story", "Tiny habit tracker widget"]
            )
        ),
        SpacePreset(
            id: "finance",
            name: "Finance",
            emoji: "💳",
            lightHex: "#C3C19A",
            darkHex: "#33321F",
            profile: SpaceProfileDraft(
                summary: "Budgeting, bills, purchase research, subscriptions, and money decisions.",
                includeCriteria: ["budget notes", "bill reminders", "subscription tracking", "purchase comparisons", "tax prep"],
                excludeCriteria: ["recipes", "travel inspiration", "school notes"],
                keywords: ["invoice", "budget", "bill", "subscription", "tax", "price"],
                exampleSnippets: ["Cancel trial before June", "Compare camera prices", "Set aside quarterly tax"]
            )
        )
    ]

    static var defaultFirstLaunchIDs: Set<String> {
        ["personal", "work"]
    }
}

@MainActor
enum SpaceFactory {
    static func makeSpace(from preset: SpacePreset, sortIndex: Int) -> Space {
        Space(
            name: preset.name,
            emoji: preset.emoji,
            colorHex: preset.lightHex,
            darkColorHex: preset.darkHex,
            sortIndex: sortIndex,
            profile: preset.profile.makeModel(),
            isPreset: true
        )
    }

    static func makeCustomSpace(
        name: String,
        emoji: String,
        colorHex: String,
        darkColorHex: String,
        sortIndex: Int,
        profile: SpaceProfileDraft
    ) -> Space {
        Space(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "✦" : emoji,
            colorHex: colorHex,
            darkColorHex: darkColorHex,
            sortIndex: sortIndex,
            profile: profile.makeModel(),
            isPreset: false
        )
    }
}

@MainActor
enum SampleDataSeeder {
    static func ensureInitialSpaces(in context: ModelContext, selectedPresetIDs: Set<String>? = nil) throws {
        let descriptor = FetchDescriptor<Space>()
        let existingCount = try context.fetchCount(descriptor)
        guard existingCount == 0 else { return }

        let selectedIDs = selectedPresetIDs ?? SpacePresetLibrary.defaultFirstLaunchIDs
        let presets = SpacePresetLibrary.presets.filter { selectedIDs.contains($0.id) }
        for (index, preset) in presets.enumerated() {
            context.insert(SpaceFactory.makeSpace(from: preset, sortIndex: index))
        }

        try context.save()
    }

    static func ensureScreenshotContent(in context: ModelContext) throws {
        let noteCount = try context.fetchCount(FetchDescriptor<Note>())
        guard noteCount == 0 else { return }

        let spaces = try context.fetch(FetchDescriptor<Space>(sortBy: [SortDescriptor(\.sortIndex)]))
        guard
            let personal = spaces.first(where: { $0.name == "Personal" }),
            let work = spaces.first(where: { $0.name == "Work" })
        else { return }

        let now = Date()
        let health = Folder(name: "Health", createdByTidy: true, sortIndex: 0, space: personal, tier: .random)
        context.insert(health)

        let notes = [
            Note(
                title: "North star list",
                bodyMarkdown: "Keep mornings quiet, ship one meaningful thing, call home twice a week.",
                createdAt: now.addingTimeInterval(-7200),
                updatedAt: now.addingTimeInterval(-900),
                tier: .favorite
            ),
            Note(
                title: "Renew passport before July",
                bodyMarkdown: "Bring photo, current passport, and proof of travel window.",
                createdAt: now.addingTimeInterval(-10_000),
                updatedAt: now.addingTimeInterval(-1800),
                tier: .pinned,
                manualSortIndex: 0,
                space: personal
            ),
            Note(
                title: "Dentist appointment questions",
                bodyMarkdown: "Ask about night guard fit and whether the sensitivity on the left side needs an x-ray.",
                createdAt: now.addingTimeInterval(-18_000),
                updatedAt: now.addingTimeInterval(-2400),
                tier: .random,
                space: personal,
                folder: health
            ),
            Note(
                title: "Gift idea for Maya",
                bodyMarkdown: "Small ceramic lamp, linen notebook, or tickets to the architecture tour.",
                createdAt: now.addingTimeInterval(-15_000),
                updatedAt: now.addingTimeInterval(-3200),
                tier: .random,
                space: personal
            ),
            Note(
                title: "Q3 roadmap review",
                bodyMarkdown: "Open with activation metrics, then discuss the billing experiment and migration timeline.",
                createdAt: now.addingTimeInterval(-12_000),
                updatedAt: now.addingTimeInterval(-1200),
                tier: .pinned,
                manualSortIndex: 0,
                space: work
            ),
            Note(
                title: "Client follow-up draft",
                bodyMarkdown: "Summarize the integration risks, ask for staging access, and propose Friday for the walkthrough.",
                createdAt: now.addingTimeInterval(-9000),
                updatedAt: now.addingTimeInterval(-3600),
                tier: .random,
                space: work
            ),
            Note(
                title: "Old parking receipt",
                bodyMarkdown: "meter 4b",
                createdAt: now.addingTimeInterval(-200_000),
                updatedAt: now.addingTimeInterval(-160_000),
                tier: .archived,
                space: personal
            )
        ]

        for note in notes {
            context.insert(note)
        }

        let run = TidyRun(
            startedAt: now.addingTimeInterval(-600),
            completedAt: now.addingTimeInterval(-540),
            notesProcessed: 6,
            notesArchived: 1,
            foldersCreated: 1,
            trigger: .manual
        )
        context.insert(run)

        try context.save()
    }
}

@MainActor
struct NoteService {
    let context: ModelContext

    @discardableResult
    func createQuickNote(
        text: String,
        in space: Space,
        attachments: [AttachmentDraft] = []
    ) throws -> Note? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }

        let note = Note(
            title: NoteService.title(from: trimmed, attachments: attachments),
            bodyMarkdown: trimmed,
            tier: .random,
            space: space
        )
        context.insert(note)

        for draft in attachments {
            let attachment = Attachment(
                kind: draft.kind,
                url: draft.url,
                imageData: draft.imageData,
                voiceTranscript: draft.voiceTranscript,
                linkTitle: draft.displayTitle,
                linkSiteName: draft.linkSiteName,
                note: note
            )
            context.insert(attachment)
        }

        try context.save()
        return note
    }

    @discardableResult
    func createBlankNote(in space: Space) throws -> Note {
        let note = Note(
            title: "Untitled",
            bodyMarkdown: "",
            tier: .random,
            space: space
        )
        context.insert(note)
        try context.save()
        return note
    }

    func save(note: Note, title: String, body: String) throws {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = normalizedTitle.isEmpty ? NoteService.title(from: body) : normalizedTitle
        note.bodyMarkdown = body
        note.updatedAt = Date()
        try context.save()
    }

    func promote(_ note: Note, to tier: NoteTier, currentSpace: Space?) throws {
        note.tier = tier
        note.folder = nil
        if tier == .favorite {
            note.space = nil
        } else if note.space == nil {
            note.space = currentSpace
        }
        note.updatedAt = Date()
        try context.save()
    }

    func move(_ note: Note, to space: Space) throws {
        note.space = space
        if note.tier == .favorite {
            note.tier = .pinned
        }
        note.updatedAt = Date()
        try context.save()
    }

    func archive(_ note: Note) throws {
        note.tier = .archived
        note.folder = nil
        note.updatedAt = Date()
        try context.save()
    }

    func restore(_ note: Note, to space: Space) throws {
        note.tier = .random
        note.space = space
        note.updatedAt = Date()
        try context.save()
    }

    func delete(_ note: Note) throws {
        context.delete(note)
        try context.save()
    }

    @discardableResult
    func duplicate(_ note: Note) throws -> Note {
        let copy = Note(
            title: "\(note.title) copy",
            bodyMarkdown: note.bodyMarkdown,
            tier: note.tier,
            space: note.space,
            folder: note.folder
        )
        context.insert(copy)
        try context.save()
        return copy
    }

    static func title(from body: String, attachments: [AttachmentDraft] = []) -> String {
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*` ").union(.whitespacesAndNewlines))

        if let firstLine, !firstLine.isEmpty {
            return String(firstLine.prefix(72))
        }

        if let attachment = attachments.first {
            return attachments.count == 1 ? attachment.displayTitle : "\(attachments.count) attachments"
        }

        return "Untitled"
    }
}

@MainActor
struct TidyService {
    let context: ModelContext
    var now: Date = Date()
    var aiService: TidyAIService = TidyAIService()

    /// Run a tidy pass over a space. Async because it calls the on-device LLM.
    @discardableResult
    func tidy(space: Space, notes: [Note], trigger: TidyTrigger) async throws -> TidyRun {
        let cutoff = trigger == .scheduled ? Calendar.current.date(byAdding: .hour, value: -6, to: now) : nil
        let eligible = notes
            .filter { note in
                let passesAgeGate = cutoff.map { note.createdAt < $0 } ?? true
                return note.tier == .random &&
                note.folder == nil &&
                note.space?.id == space.id &&
                passesAgeGate
            }
            .sorted { $0.createdAt < $1.createdAt }

        let run = TidyRun(startedAt: now, trigger: trigger)
        context.insert(run)

        guard !eligible.isEmpty else {
            run.completedAt = now
            try context.save()
            return run
        }

        // Build classifier input (snapshots + space profile + recent corrections).
        let snapshots = eligible.map { TidyNoteSnapshot(note: $0) }
        let input = TidyClassificationInput(
            spaceName: space.name,
            spaceEmoji: space.emoji,
            profileSummary: space.profile?.summary,
            includeCriteria: space.profile?.includeCriteria ?? [],
            excludeCriteria: space.profile?.excludeCriteria ?? [],
            keywords: space.profile?.keywords ?? [],
            notes: snapshots,
            recentCorrections: try Self.recentCorrections(in: context)
        )

        let classification = await aiService.classify(input)
        let notesByID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0) })

        // Apply: create folders, archive junk, leave ungrouped flat.
        var folderSortIndex = 0
        for proposal in classification.folders {
            let folder = Folder(
                name: proposal.name,
                createdByTidy: true,
                sortIndex: folderSortIndex,
                space: space,
                tier: .random
            )
            folderSortIndex += 1
            context.insert(folder)
            run.foldersCreated += 1

            for id in proposal.noteIDs {
                guard let note = notesByID[id] else { continue }
                note.folder = folder
                note.updatedAt = now
                let action = TidyAction(
                    noteId: note.id,
                    actionKind: .foldered,
                    folderName: folder.name,
                    previousTier: .random
                )
                context.insert(action)
                run.actions = (run.actions ?? []) + [action]
            }
        }

        for id in classification.junkNoteIDs {
            guard let note = notesByID[id] else { continue }
            let previousTier = note.tier
            note.tier = .archived
            note.folder = nil
            note.updatedAt = now
            run.notesArchived += 1
            let action = TidyAction(
                noteId: note.id,
                actionKind: .archived,
                previousTier: previousTier
            )
            context.insert(action)
            run.actions = (run.actions ?? []) + [action]
        }

        // Sweep any remaining ungrouped notes into an "Other" folder so every tidied note
        // ends up filed somewhere. Reuse an existing tidy-created "Other" folder in this
        // space if one already exists, so repeated tidies don't pile up duplicate folders.
        let ungroupedNotes = classification.ungroupedNoteIDs.compactMap { notesByID[$0] }
        if !ungroupedNotes.isEmpty {
            let otherFolder = existingTidyOtherFolder(in: space) ?? {
                let folder = Folder(
                    name: "Other",
                    createdByTidy: true,
                    sortIndex: folderSortIndex,
                    space: space,
                    tier: .random
                )
                context.insert(folder)
                run.foldersCreated += 1
                return folder
            }()

            for note in ungroupedNotes {
                note.folder = otherFolder
                note.updatedAt = now
                let action = TidyAction(
                    noteId: note.id,
                    actionKind: .foldered,
                    folderName: otherFolder.name,
                    previousTier: .random
                )
                context.insert(action)
                run.actions = (run.actions ?? []) + [action]
            }
        }

        run.notesProcessed = eligible.count
        run.completedAt = now
        try context.save()
        return run
    }

    func undo(_ action: TidyAction, notes: [Note]) throws {
        guard let note = notes.first(where: { $0.id == action.noteId }) else { return }
        switch action.actionKind {
        case .archived:
            note.tier = action.previousTier
        case .foldered:
            note.folder = nil
        case .leftAlone:
            break
        }
        action.undone = true
        note.updatedAt = Date()
        try context.save()
    }

    /// Look for an existing tidy-created "Other" folder in this space's Random tier.
    private func existingTidyOtherFolder(in space: Space) -> Folder? {
        let spaceID = space.id
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.name == "Other" && folder.space?.id == spaceID
            }
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        return matches.first { $0.createdByTidy && $0.tier == .random }
    }

    /// Pull recent undone tidy actions as few-shot examples for the next classification.
    static func recentCorrections(in context: ModelContext) throws -> [TidyExample] {
        var descriptor = FetchDescriptor<TidyAction>(
            predicate: #Predicate { $0.undone == true },
            sortBy: [SortDescriptor(\TidyAction.id, order: .reverse)]
        )
        descriptor.fetchLimit = 10
        let undoneActions = try context.fetch(descriptor)
        guard !undoneActions.isEmpty else { return [] }

        let noteIDs = undoneActions.map(\.noteId)
        let notesDescriptor = FetchDescriptor<Note>(predicate: #Predicate { noteIDs.contains($0.id) })
        let notes = try context.fetch(notesDescriptor)
        let titleByID = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, $0.title) })

        return undoneActions.compactMap { action in
            guard let title = titleByID[action.noteId], !title.isEmpty else { return nil }
            let kind: TidyExample.Kind = action.actionKind == .archived ? .unarchived : .removedFromFolder
            return TidyExample(kind: kind, noteTitle: title, folderName: action.folderName)
        }
    }
}

struct SearchService {
    static func matches(_ note: Note, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let haystack = "\(note.title) \(note.bodyMarkdown)".localizedCaseInsensitiveContains(trimmed)
        return haystack
    }
}
