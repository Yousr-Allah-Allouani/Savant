import SwiftData
import XCTest
@testable import Savant

@MainActor
final class SavantModelTests: XCTestCase {
    func testQuickCaptureCreatesRandomNoteInCurrentSpace() throws {
        let harness = try makeHarness()
        let space = SpaceFactory.makeSpace(from: SpacePresetLibrary.presets[0], sortIndex: 0)
        harness.context.insert(space)

        let note = try XCTUnwrap(
            NoteService(context: harness.context).createQuickNote(text: "# Buy coffee\nBeans and filters", in: space)
        )

        XCTAssertEqual(note.title, "Buy coffee")
        XCTAssertEqual(note.tier, .random)
        XCTAssertEqual(note.space?.id, space.id)
    }

    func testQuickCaptureCanSaveAttachmentOnlyNote() throws {
        let harness = try makeHarness()
        let space = SpaceFactory.makeSpace(from: SpacePresetLibrary.presets[0], sortIndex: 0)
        harness.context.insert(space)

        let note = try XCTUnwrap(
            NoteService(context: harness.context).createQuickNote(
                text: "",
                in: space,
                attachments: [
                    AttachmentDraft(
                        kind: .link,
                        displayTitle: "example.com",
                        url: try XCTUnwrap(URL(string: "https://example.com")),
                        linkSiteName: "https://example.com"
                    )
                ]
            )
        )

        XCTAssertEqual(note.title, "example.com")
        XCTAssertEqual(note.tier, .random)
        XCTAssertEqual(note.attachments?.count, 1)
        XCTAssertEqual(note.attachments?.first?.kind, .link)
    }

    func testPromotingFavoriteClearsSpaceScope() throws {
        let harness = try makeHarness()
        let space = SpaceFactory.makeSpace(from: SpacePresetLibrary.presets[1], sortIndex: 0)
        harness.context.insert(space)
        let note = try XCTUnwrap(NoteService(context: harness.context).createQuickNote(text: "Client agenda", in: space))

        try NoteService(context: harness.context).promote(note, to: .favorite, currentSpace: space)

        XCTAssertEqual(note.tier, .favorite)
        XCTAssertNil(note.space)
    }

    func testTidyArchivesJunkAndCreatesFoldersForRelatedNotes() throws {
        let harness = try makeHarness()
        let preset = SpacePresetLibrary.presets.first { $0.id == "work" }!
        let space = SpaceFactory.makeSpace(from: preset, sortIndex: 0)
        harness.context.insert(space)

        let oldDate = Date().addingTimeInterval(-60 * 60 * 8)
        let noteA = Note(title: "meeting roadmap", bodyMarkdown: "meeting roadmap notes", createdAt: oldDate, tier: .random, space: space)
        let noteB = Note(title: "meeting blockers", bodyMarkdown: "meeting follow up", createdAt: oldDate, tier: .random, space: space)
        let junk = Note(title: "42", bodyMarkdown: "42", createdAt: oldDate, tier: .random, space: space)
        harness.context.insert(noteA)
        harness.context.insert(noteB)
        harness.context.insert(junk)

        let run = try TidyService(context: harness.context, now: Date()).tidy(
            space: space,
            notes: [noteA, noteB, junk],
            trigger: .manual
        )

        XCTAssertEqual(run.notesProcessed, 3)
        XCTAssertEqual(run.notesArchived, 1)
        XCTAssertEqual(run.foldersCreated, 1)
        XCTAssertEqual(junk.tier, .archived)
        XCTAssertNotNil(noteA.folder)
        XCTAssertEqual(noteA.folder?.id, noteB.folder?.id)
    }

    func testManualTidyIncludesFreshNotesButScheduledTidyWaits() throws {
        let harness = try makeHarness()
        let preset = SpacePresetLibrary.presets.first { $0.id == "personal" }!
        let space = SpaceFactory.makeSpace(from: preset, sortIndex: 0)
        harness.context.insert(space)

        let now = Date()
        let noteA = Note(title: "home paint samples", bodyMarkdown: "home paint samples", createdAt: now, tier: .random, space: space)
        let noteB = Note(title: "home repair quote", bodyMarkdown: "home repair quote", createdAt: now, tier: .random, space: space)
        harness.context.insert(noteA)
        harness.context.insert(noteB)

        let scheduledRun = try TidyService(context: harness.context, now: now).tidy(
            space: space,
            notes: [noteA, noteB],
            trigger: .scheduled
        )
        XCTAssertEqual(scheduledRun.notesProcessed, 0)
        XCTAssertNil(noteA.folder)
        scheduledRun.bannerDismissed = true

        let manualRun = try TidyService(context: harness.context, now: now).tidy(
            space: space,
            notes: [noteA, noteB],
            trigger: .manual
        )

        XCTAssertEqual(manualRun.notesProcessed, 2)
        XCTAssertEqual(manualRun.foldersCreated, 1)
        XCTAssertEqual(noteA.folder?.id, noteB.folder?.id)
    }

    func testPromotingBackToRandomRestoresCurrentSpace() throws {
        let harness = try makeHarness()
        let space = SpaceFactory.makeSpace(from: SpacePresetLibrary.presets[0], sortIndex: 0)
        harness.context.insert(space)
        let note = try XCTUnwrap(NoteService(context: harness.context).createQuickNote(text: "Keep this", in: space))

        try NoteService(context: harness.context).promote(note, to: .favorite, currentSpace: space)
        try NoteService(context: harness.context).promote(note, to: .random, currentSpace: space)

        XCTAssertEqual(note.tier, .random)
        XCTAssertEqual(note.space?.id, space.id)
    }

    private func makeHarness() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try PersistenceController.makeModelContainer(inMemory: true, cloudKitEnabled: false)
        return (container, container.mainContext)
    }
}
