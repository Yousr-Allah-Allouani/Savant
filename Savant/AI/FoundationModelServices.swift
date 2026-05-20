#if canImport(FoundationModels) && !os(macOS)
import Foundation
import FoundationModels

// MARK: - Generable types

@Generable
struct GeneratedTidyFolder {
    @Guide(description: "Short folder name, one to three words")
    let name: String

    @Guide(description: "UUID strings (exact, lower-cased with hyphens) for notes that belong in this folder")
    let noteIds: [String]
}

@Generable
struct GeneratedTidyResult {
    @Guide(description: "Topical folders to create; each must contain two or more related notes")
    let folders: [GeneratedTidyFolder]

    @Guide(description: "UUID strings for notes that don't fit any group; leave them flat in Random")
    let ungrouped: [String]

    @Guide(description: "UUID strings for junk notes: orphan numbers, dead links, contextless fragments")
    let junk: [String]
}

@Generable
struct GeneratedProfile {
    @Guide(description: "One sentence category summary")
    let summary: String

    @Guide(description: "Criteria that belong in this space")
    let includeCriteria: [String]

    @Guide(description: "Criteria that do not belong in this space")
    let excludeCriteria: [String]

    @Guide(description: "Useful categorization keywords")
    let keywords: [String]

    @Guide(description: "Two to three example snippets")
    let exampleSnippets: [String]

    @Guide(description: "Plain English explanation of how the model interpreted the user's description")
    let aiInterpretation: String
}

// MARK: - Profile expansion (already wired)

struct ProfileExpanderService {
    private let session = LanguageModelSession(
        model: SystemLanguageModel(useCase: .contentTagging),
        instructions: "Generate concise, editable note-space profiles for an iOS notes app. Do not invent sensitive personal facts."
    )

    func expand(description: String) async -> SpaceProfileDraft {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.fallback(description: "General notes and ideas.")
        }

        guard SystemLanguageModel.default.isAvailable else {
            return Self.fallback(description: trimmed)
        }

        do {
            let response = try await session.respond(
                to: "Create a structured SpaceProfile for this note category: \(trimmed)",
                generating: GeneratedProfile.self
            )
            let generated = response.content
            return SpaceProfileDraft(
                summary: generated.summary,
                includeCriteria: generated.includeCriteria,
                excludeCriteria: generated.excludeCriteria,
                keywords: generated.keywords,
                exampleSnippets: generated.exampleSnippets,
                aiInterpretation: generated.aiInterpretation
            )
        } catch {
            return Self.fallback(description: trimmed)
        }
    }

    static func fallback(description: String) -> SpaceProfileDraft {
        let words = description
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 3 }
            .prefix(6)
            .map { $0.lowercased() }

        return SpaceProfileDraft(
            summary: description,
            includeCriteria: ["notes matching this description", "related follow-ups", "useful references"],
            excludeCriteria: ["unrelated errands", "unlabeled fragments", "dead links without context"],
            keywords: Array(words.isEmpty ? ["notes", "ideas", "reference"] : words),
            exampleSnippets: ["Reference worth saving", "Follow-up thought", "Useful link"],
            aiInterpretation: "Generated locally from the description because the on-device model was unavailable."
        )
    }
}

// MARK: - Tidy classification

/// A single user correction from a previous tidy run, used as a few-shot example.
struct TidyExample: Sendable {
    enum Kind: Sendable { case unarchived, removedFromFolder }
    let kind: Kind
    let noteTitle: String
    let folderName: String?
}

/// Snapshot of a note that gets sent to the model. Keep small to fit context.
struct TidyNoteSnapshot: Sendable {
    let id: UUID
    let title: String
    let snippet: String  // first ~200 chars of body

    init(note: Note) {
        self.id = note.id
        self.title = note.title
        let body = note.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count <= 200 {
            self.snippet = body
        } else {
            self.snippet = String(body.prefix(200)) + "…"
        }
    }
}

/// Inputs needed by the model for a tidy pass.
struct TidyClassificationInput: Sendable {
    let spaceName: String
    let spaceEmoji: String
    let profileSummary: String?
    let includeCriteria: [String]
    let excludeCriteria: [String]
    let keywords: [String]
    let notes: [TidyNoteSnapshot]
    let recentCorrections: [TidyExample]
}

/// Output of classification, in domain types (UUIDs already parsed).
struct TidyClassification {
    struct FolderProposal {
        let name: String
        let noteIDs: [UUID]
    }
    let folders: [FolderProposal]
    let ungroupedNoteIDs: [UUID]
    let junkNoteIDs: [UUID]
}

struct TidyAIService {
    static let maxNotesPerCall = 30

    private let session: LanguageModelSession

    init() {
        // Use the default general-purpose model — `.contentTagging` is for tag assignment
        // and doesn't reliably produce the structured grouping we need.
        self.session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: """
            You organize notes for an iOS notes app. The user has dumped some quick captures \
            into one space; you decide how to cluster them.

            Sort EVERY note into ONE bucket:
              • folders — 2+ notes that share a concrete theme. Group aggressively whenever \
                2+ notes plausibly belong together (same project, same person, same trip, \
                same recurring topic, same kind of errand…).
              • ungrouped — truly isolated singletons with no relative in the set.
              • junk — orphan numbers with no label, dead URLs, contextless one-word fragments.
                Be conservative. When unsure, prefer ungrouped over junk.
                A phone number WITH a name attached ("Mom 555-0102") is NOT junk.

            FOLDER NAMING — read carefully:
              • Names MUST describe what the grouped notes actually contain, derived from the \
                note titles/bodies themselves.
              • DO NOT reuse the space's name, description, or any phrasing from this prompt \
                as a folder name. The folder name must read like a label someone would write \
                AFTER looking at the notes.
              • Short and specific: 1–3 words. Examples of GOOD names: "Groceries", \
                "Lisbon Trip", "Mom's Birthday", "Q3 Roadmap". BAD names: "Health Reminders", \
                "Home Errands", "Personal Notes", "Misc", "Other".

            STRICT:
              - Use only the exact UUID strings provided. Never invent or alter an ID.
              - Each UUID appears in exactly ONE bucket.
            """
        )
    }

    /// Classify notes for a single space. Batches at `maxNotesPerCall`.
    func classify(_ input: TidyClassificationInput) async -> TidyClassification {
        guard SystemLanguageModel.default.isAvailable else {
            #if DEBUG
            print("[Tidy] SystemLanguageModel unavailable — using heuristic fallback. Notes: \(input.notes.count)")
            #endif
            return Self.heuristicFallback(input)
        }

        // Single batch.
        if input.notes.count <= Self.maxNotesPerCall {
            return await classifyBatch(input)
        }

        // Chunked: run each batch, then merge folders with matching (case-insensitive) names.
        var allFolders: [TidyClassification.FolderProposal] = []
        var allUngrouped: [UUID] = []
        var allJunk: [UUID] = []
        let chunks = input.notes.chunked(into: Self.maxNotesPerCall)
        for chunk in chunks {
            let chunkInput = TidyClassificationInput(
                spaceName: input.spaceName,
                spaceEmoji: input.spaceEmoji,
                profileSummary: input.profileSummary,
                includeCriteria: input.includeCriteria,
                excludeCriteria: input.excludeCriteria,
                keywords: input.keywords,
                notes: chunk,
                recentCorrections: input.recentCorrections
            )
            let result = await classifyBatch(chunkInput)
            allFolders.append(contentsOf: result.folders)
            allUngrouped.append(contentsOf: result.ungroupedNoteIDs)
            allJunk.append(contentsOf: result.junkNoteIDs)
        }
        return Self.mergeFolders(folders: allFolders, ungrouped: allUngrouped, junk: allJunk)
    }

    private func classifyBatch(_ input: TidyClassificationInput) async -> TidyClassification {
        let prompt = Self.buildPrompt(input)
        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedTidyResult.self
            )
            let parsed = Self.parse(response.content, allowed: Set(input.notes.map(\.id)))
            #if DEBUG
            print("[Tidy] AI returned: folders=\(parsed.folders.count), ungrouped=\(parsed.ungroupedNoteIDs.count), junk=\(parsed.junkNoteIDs.count) (raw folders=\(response.content.folders.count))")
            #endif
            return parsed
        } catch {
            #if DEBUG
            print("[Tidy] AI call failed: \(error.localizedDescription) — falling back to heuristic")
            #endif
            return Self.heuristicFallback(input)
        }
    }

    // MARK: - Prompt

    static func buildPrompt(_ input: TidyClassificationInput) -> String {
        var lines: [String] = []
        // Minimal space context — just the name so the model has a frame of reference.
        // We deliberately omit includeCriteria / excludeCriteria / keywords here because
        // the model was using them as folder names, which is wrong: folder names must
        // be derived from the note content, not from the space's metadata.
        lines.append("Space the user is currently in: \(input.spaceEmoji) \(input.spaceName)")

        if !input.recentCorrections.isEmpty {
            lines.append("")
            lines.append("Past user corrections (learn from these):")
            for ex in input.recentCorrections.prefix(10) {
                switch ex.kind {
                case .unarchived:
                    lines.append("- User UN-archived: \"\(ex.noteTitle)\" — so this kind of note is NOT junk.")
                case .removedFromFolder:
                    let f = ex.folderName ?? "a folder"
                    lines.append("- User REMOVED from \(f): \"\(ex.noteTitle)\" — don't re-group it the same way.")
                }
            }
        }

        lines.append("")
        lines.append("Notes to classify (use these exact UUID strings):")
        for snap in input.notes {
            let title = snap.title.isEmpty ? "(no title)" : snap.title
            let snip = snap.snippet.isEmpty ? "" : " — \(snap.snippet.replacingOccurrences(of: "\n", with: " "))"
            lines.append("[\(snap.id.uuidString)] \"\(title)\"\(snip)")
        }

        lines.append("")
        lines.append("Return folders (each ≥2 notes; name DERIVED from the notes themselves), plus ungrouped and junk. Every UUID appears in exactly one bucket.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parse + validate

    static func parse(_ generated: GeneratedTidyResult, allowed: Set<UUID>) -> TidyClassification {
        var seen: Set<UUID> = []

        var folders: [TidyClassification.FolderProposal] = []
        for f in generated.folders {
            let ids = f.noteIds.compactMap { UUID(uuidString: $0) }.filter { allowed.contains($0) && !seen.contains($0) }
            guard ids.count >= 2 else { continue }
            let cleanName = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { continue }
            folders.append(.init(name: cleanName, noteIDs: ids))
            ids.forEach { seen.insert($0) }
        }

        let junk = generated.junk.compactMap { UUID(uuidString: $0) }.filter { allowed.contains($0) && !seen.contains($0) }
        junk.forEach { seen.insert($0) }

        let ungroupedFromModel = generated.ungrouped.compactMap { UUID(uuidString: $0) }.filter { allowed.contains($0) && !seen.contains($0) }
        ungroupedFromModel.forEach { seen.insert($0) }

        // Any IDs the model missed → treat as ungrouped (safe default).
        let leftovers = allowed.subtracting(seen)
        let ungrouped = ungroupedFromModel + Array(leftovers)

        return TidyClassification(folders: folders, ungroupedNoteIDs: ungrouped, junkNoteIDs: junk)
    }

    // MARK: - Cross-chunk merge

    static func mergeFolders(
        folders: [TidyClassification.FolderProposal],
        ungrouped: [UUID],
        junk: [UUID]
    ) -> TidyClassification {
        var byKey: [String: TidyClassification.FolderProposal] = [:]
        for f in folders {
            let key = f.name.lowercased()
            if let existing = byKey[key] {
                let combined = Array(Set(existing.noteIDs + f.noteIDs))
                byKey[key] = .init(name: existing.name, noteIDs: combined)
            } else {
                byKey[key] = f
            }
        }
        return TidyClassification(
            folders: Array(byKey.values),
            ungroupedNoteIDs: ungrouped,
            junkNoteIDs: junk
        )
    }

    // MARK: - Fallback heuristic

    static func heuristicFallback(_ input: TidyClassificationInput) -> TidyClassification {
        var folders: [String: [UUID]] = [:]
        var junk: [UUID] = []
        var ungrouped: [UUID] = []

        for snap in input.notes {
            let text = "\(snap.title) \(snap.snippet)".trimmingCharacters(in: .whitespacesAndNewlines)
            let alphanumeric = text.filter { $0.isLetter || $0.isNumber }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            let isBareNumber = Double(text) != nil
            let isTinyFragment = words.count <= 2 && alphanumeric.count < 8
            if isBareNumber || isTinyFragment || text.lowercased() == "todo" {
                junk.append(snap.id)
                continue
            }

            let lower = text.lowercased()
            if let keyword = input.keywords.first(where: { lower.contains($0.lowercased()) }) {
                folders[keyword.capitalized, default: []].append(snap.id)
            } else {
                ungrouped.append(snap.id)
            }
        }

        let folderProposals = folders.compactMap { name, ids -> TidyClassification.FolderProposal? in
            guard ids.count >= 2 else {
                // Notes that didn't reach 2 get demoted to ungrouped.
                ungrouped.append(contentsOf: ids)
                return nil
            }
            return .init(name: name, noteIDs: ids)
        }
        return TidyClassification(folders: folderProposals, ungroupedNoteIDs: ungrouped, junkNoteIDs: junk)
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

#else
import Foundation

// Stub for environments without FoundationModels.

struct ProfileExpanderService {
    func expand(description: String) async -> SpaceProfileDraft {
        Self.fallback(description: description)
    }

    static func fallback(description: String) -> SpaceProfileDraft {
        SpaceProfileDraft(
            summary: description.isEmpty ? "General notes and ideas." : description,
            includeCriteria: ["notes matching this description", "related follow-ups", "useful references"],
            excludeCriteria: ["unrelated errands", "unlabeled fragments", "dead links without context"],
            keywords: ["notes", "ideas", "reference"],
            exampleSnippets: ["Reference worth saving", "Follow-up thought", "Useful link"],
            aiInterpretation: "Generated locally from the description."
        )
    }
}

struct TidyExample {
    enum Kind { case unarchived, removedFromFolder }
    let kind: Kind
    let noteTitle: String
    let folderName: String?
}

struct TidyNoteSnapshot {
    let id: UUID
    let title: String
    let snippet: String

    init(note: Note) {
        self.id = note.id
        self.title = note.title
        let body = note.bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        self.snippet = body.count <= 200 ? body : String(body.prefix(200)) + "…"
    }
}

struct TidyClassificationInput {
    let spaceName: String
    let spaceEmoji: String
    let profileSummary: String?
    let includeCriteria: [String]
    let excludeCriteria: [String]
    let keywords: [String]
    let notes: [TidyNoteSnapshot]
    let recentCorrections: [TidyExample]
}

struct TidyClassification {
    struct FolderProposal {
        let name: String
        let noteIDs: [UUID]
    }
    let folders: [FolderProposal]
    let ungroupedNoteIDs: [UUID]
    let junkNoteIDs: [UUID]
}

struct TidyAIService {
    func classify(_ input: TidyClassificationInput) async -> TidyClassification {
        // No on-device model available → pure heuristic fallback.
        var folders: [String: [UUID]] = [:]
        var junk: [UUID] = []
        var ungrouped: [UUID] = []
        for snap in input.notes {
            let text = "\(snap.title) \(snap.snippet)".trimmingCharacters(in: .whitespacesAndNewlines)
            let alphanumeric = text.filter { $0.isLetter || $0.isNumber }
            let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            if Double(text) != nil || (words.count <= 2 && alphanumeric.count < 8) || text.lowercased() == "todo" {
                junk.append(snap.id)
                continue
            }
            let lower = text.lowercased()
            if let keyword = input.keywords.first(where: { lower.contains($0.lowercased()) }) {
                folders[keyword.capitalized, default: []].append(snap.id)
            } else {
                ungrouped.append(snap.id)
            }
        }
        let proposals = folders.compactMap { name, ids -> TidyClassification.FolderProposal? in
            guard ids.count >= 2 else { ungrouped.append(contentsOf: ids); return nil }
            return .init(name: name, noteIDs: ids)
        }
        return TidyClassification(folders: proposals, ungroupedNoteIDs: ungrouped, junkNoteIDs: junk)
    }
}
#endif
