# Savant — Full Build Specification

> An iOS 26 and macOS notes app inspired by Arc Browser. Three-tier note hierarchy, on-device AI tidy, swipeable colored spaces.

This document is the single source of truth for building Savant. It is written to be detailed enough that a competent iOS engineer (human or AI) can implement the entire v1 without further design input.

---

## Table of Contents

1. [Product Thesis](#1-product-thesis)
2. [Platform & Stack](#2-platform--stack)
3. [Core Mental Model](#3-core-mental-model)
4. [Data Model](#4-data-model)
5. [Screen-by-Screen Specification](#5-screen-by-screen-specification)
6. [Interactions & Gestures](#6-interactions--gestures)
7. [Input Bar — Detailed Spec](#7-input-bar--detailed-spec)
8. [Tidy Feature — Detailed Spec](#8-tidy-feature--detailed-spec)
9. [Space Profile System](#9-space-profile-system)
10. [AI Architecture (Foundation Models)](#10-ai-architecture-foundation-models)
11. [Design System](#11-design-system)
12. [Animations & Transitions](#12-animations--transitions)
13. [Sync (CloudKit)](#13-sync-cloudkit)
14. [Settings](#14-settings)
15. [Empty States & Onboarding](#15-empty-states--onboarding)
16. [Dependencies](#16-dependencies)
17. [File / Module Structure](#17-file--module-structure)
18. [Build Order (Milestones)](#18-build-order-milestones)
19. [Open Decisions / TBD](#19-open-decisions--tbd)
20. [macOS Desktop Direction](#20-macos-desktop-direction)

---

## 1. Product Thesis

Savant is a notes app built around the idea that **most notes are throwaway, a few are forever, and the app should know the difference automatically.**

Inspiration: **Arc Browser**'s tab management — Favorites pinned forever across spaces, Pinned tabs scoped to a space, and ephemeral tabs that auto-archive after a window of time. Savant translates this directly to notes.

Three differentiators:

- **Three-tier hierarchy** (Favorites / Pinned / Random) per swipeable, color-themed space.
- **Overnight on-device AI tidy** that classifies junk, clusters survivors into folders, and learns from user corrections.
- **A single persistent input bar** at the bottom — "Empty your mind" — that makes capture as fast as sending a text.

Tagline (working): **Empty your mind.**

---

## 2. Platform & Stack

- **iOS:** iOS 26 exclusive. No fallback path. Requires Apple Intelligence-capable device (A17 Pro / M-series).
- **macOS:** Native macOS companion target, documented in §20. Build with SwiftUI plus AppKit where needed for titlebar/sidebar/window gesture behavior. Not a Catalyst stretch goal unless explicitly revisited.
- **Language:** 100% Swift, primarily SwiftUI. UIKit/AppKit only if a specific gesture, windowing behavior, or animation demands it (e.g. paging container — to be evaluated carefully given prior burn on Cift's UIScrollView paging experiment).
- **UI framework:** SwiftUI with **Liquid Glass** chrome on iOS 26+; native macOS material/glass treatments that preserve the same Savant visual language.
- **Persistence:** SwiftData.
- **Sync:** CloudKit (private database), day one.
- **AI:** On-device Foundation Models (`FoundationModels` framework). No backend, no API keys, no network calls for AI features.
- **Rich text:** `canopas/rich-editor-swiftui` is the canonical note editor on iOS and macOS. Store its `RichText` JSON as the source of truth, with derived plain text for search/previews/AI.
- **Keyboard toolbar:** Custom animated SwiftUI toolbar (reference: iOS 26 custom animated keyboard toolbar pattern).
- **Xcode project name:** `Savant.xcodeproj`, scheme `Savant`, bundle id `app.savant` (or per developer account).

---

## 3. Core Mental Model

The user's world is divided into **Spaces**. Each space is a horizontally-swipeable page with a distinct color, name, and emoji/symbol. The list of spaces is user-defined and reorderable.

Inside each space, notes live in three tiers, stacked vertically:

| Tier      | Persistence            | Scope        | Folders | Layout                   |
|-----------|------------------------|--------------|---------|--------------------------|
| Favorites | Across all spaces      | Global       | No      | Tiles at top             |
| Pinned    | Permanent in this space| Per-space    | Yes (unlimited nesting) | Vertical list |
| Random    | Ephemeral until tidied | Per-space    | Yes (only created by tidy, flat) | Vertical list, chronological |

**Visual signal:** the space's color is the full-screen background, so swiping between spaces is instantly perceptible. Page dots at the top reinforce position.

**Capture:** a persistent bottom input bar lives across all spaces. New notes always land in the **current space's Random tier**. Promotion (to Pinned, to Favorites, to another space) is a deliberate user action — long-press menu or drag.

**Cleanup:** overnight, an on-device AI sweep classifies junk notes (auto-archived) and clusters topical survivors into folders inside Random. The user wakes to a banner summarizing what changed, with per-item undo.

---

## 4. Data Model

SwiftData models. All synced via CloudKit.

### `Space`
```swift
@Model final class Space {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String              // single emoji or SF Symbol name
    var colorHex: String           // base color, dark-mode-adjusted at render time
    var sortIndex: Int             // user-defined order in switcher
    var createdAt: Date
    var profile: SpaceProfile?     // structured profile for AI categorization (see §9)
    var isPreset: Bool             // true if created from preset, false if custom
    @Relationship(deleteRule: .cascade) var notes: [Note]
    @Relationship(deleteRule: .cascade) var folders: [Folder]
}
```

### `SpaceProfile`
```swift
@Model final class SpaceProfile {
    @Attribute(.unique) var id: UUID
    var summary: String              // user's original description or preset summary
    var includeCriteria: [String]
    var excludeCriteria: [String]
    var keywords: [String]
    var exampleSnippets: [String]    // 2-3 example note titles/contents
    var aiInterpretation: String?    // LLM's expanded reasoning, shown to user during approval
    @Relationship(inverse: \Space.profile) var space: Space?
}
```

### `Note`
```swift
@Model final class Note {
    @Attribute(.unique) var id: UUID
    var title: String                // first line if untitled
    var bodyRichTextJSON: Data        // canonical storage: encoded RichEditorSwiftUI.RichText
    var bodyPlainText: String         // derived from rich text for preview, search, and AI prompts
    var bodyMarkdown: String?         // optional import/export bridge only, not canonical
    var createdAt: Date
    var updatedAt: Date
    var tier: NoteTier               // .favorite | .pinned | .random | .archived
    var manualSortIndex: Int?        // set when user drags to reorder; nil = use createdAt
    var folder: Folder?              // nil = top-level in its tier
    var space: Space?                // nil only if tier == .favorite (favorites are global)
    var attachments: [Attachment]    // links, images, files
    var tidyMetadata: TidyMetadata?  // last classified, suggested-move chip, etc.
}

enum NoteTier: String, Codable {
    case favorite, pinned, random, archived
}
```

### `Folder`
```swift
@Model final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var createdByTidy: Bool          // true if auto-created by tidy sweep
    var parent: Folder?              // nil = top-level
    var sortIndex: Int
    @Relationship(deleteRule: .cascade) var children: [Folder]
    @Relationship(deleteRule: .nullify) var notes: [Note]
    var space: Space?
    var tier: NoteTier               // .pinned or .random only
}
```

### `Attachment`
```swift
@Model final class Attachment {
    @Attribute(.unique) var id: UUID
    var kind: AttachmentKind         // .link | .image | .file | .voice
    var url: URL?                    // for .link, .file
    var imageData: Data?             // for .image (or CloudKit asset)
    var voiceTranscript: String?     // for .voice — raw transcription
    var linkPreview: LinkPreview?    // fetched async for .link
    var note: Note?
}
```

### `TidyRun`
```swift
@Model final class TidyRun {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var completedAt: Date?
    var notesProcessed: Int
    var notesArchived: Int
    var foldersCreated: Int
    var bannerDismissed: Bool
    @Relationship var actions: [TidyAction]  // for per-item undo
    var trigger: TidyTrigger         // .scheduled | .manual
}

@Model final class TidyAction {
    var noteId: UUID
    var actionKind: TidyActionKind   // .archived | .foldered | .leftAlone
    var folderName: String?
    var undone: Bool
}
```

---

## 5. Screen-by-Screen Specification

### 5.1 Space View (Home)

The main screen. One per space; swipe horizontally between them.

**Top to bottom:**

```
┌────────────────────────────────────────────┐
│           • • ● • •                        │  ← page dots, centered, between Dynamic Island and title
│                                            │
│  College  ▾                  [🔍] [⋯|⚙]   │  ← title (SF Pro Rounded, large) + chevron, right-side controls
│                                            │
│  ┌────┐ ┌────┐ ┌────┐                     │  ← Favorites tiles (if any)
│  │    │ │    │ │    │                     │
│  └────┘ └────┘ └────┘                     │
│  ────────────────────────────              │  ← divider (only if both above and below have content)
│                                            │
│  📁 Pinned folder                          │  ← Pinned section
│    • Pinned note title                     │     ↓ icon + title + 1-line preview
│       1-line preview text…                 │
│  • Pinned note title                       │
│  ────────────────────────────              │  ← divider
│                                            │
│  • Random note title                       │  ← Random section (icon + title only)
│  • Random note title                       │
│  • Random note title                       │
│                                            │
│                                            │
│  ┌──────────────────────────┐  ┌────┐    │  ← persistent input bar, floats above home indicator
│  │ +  Empty your mind   🎤  │  │ ✎  │    │
│  └──────────────────────────┘  └────┘    │
└────────────────────────────────────────────┘
```

**Background:** the space's color, dark-mode-adjusted. Full bleed.

**Header behaviors:**
- Tap title or `▾` → opens Space Switcher View (§5.2).
- Tap `🔍` → opens search (scoped to current space by default).
- Tap `⋯` → menu: Edit (multi-select), Filters, Sort, Tidy now, View options.
- Tap `⚙` → opens Settings (§5.7).

**Favorites tile layout:**
- 0 tiles → section hidden entirely.
- 1 tile → full-width tile, shows rendered preview of note content.
- 2 tiles → side-by-side, each shows title + 1-line preview.
- 3+ tiles → horizontal scroll row of compact tiles, each shows icon + title only.

**Section dividers:** thin horizontal line, color = on-background-at-low-contrast. Only shown between non-empty sections.

**Pinned section:**
- Folders show as `📁 Folder name` (chevron when expanded).
- Notes show as `• Note title` + `   1-line preview` (indented preview, lower opacity).
- Tap folder → expand inline; long-press → menu (Rename, Delete, Move).

**Random section:**
- Chronological by default (newest at bottom — like a chat log; oldest at top of the section).
- Notes show as `• Note title` only.
- Folders (only created by tidy) show as `📁 Folder name`, flat (tidy never nests).
- Manually-reordered notes stay where placed; new notes still append chronologically around them.

**Pull-down on Random section header:** triggers manual tidy (with haptic + visual feedback).

### 5.2 Space Switcher View

Triggered by tapping the title `▾` in any space view.

Bottom sheet, large detent (~90% of screen):

```
┌────────────────────────────────────────┐
│           Spaces                       │  ← sheet title
│                                        │
│  ≡  🎓 College            (active)    │  ← active space highlighted
│  ≡  💼 Work                            │
│  ≡  🍳 Recipes                         │
│  ≡  ✈️  Travel                          │
│                                        │
│           [ + New space ]              │  ← creates a new space (preset picker → custom)
└────────────────────────────────────────┘
```

- Rows draggable to reorder (`≡` handle visible on long-press).
- Tap row → navigate to that space (sheet dismisses, horizontal scroll animates to that page).
- Long-press row → opens edit sheet (name, emoji, color via HSL picker, delete with confirmation).
- `+ New space` → opens New Space flow (§5.3).

### 5.3 New Space Flow

Sheet, two-step:

**Step 1: Choose preset or custom.**
- Grid of preset cards: Work, Personal, College, Recipes, Reading list, Travel, Ideas, Finance — each with default emoji and color preview.
- `Custom` card at the end.

**Step 2a: Preset chosen.** Pre-fill name/emoji/color/profile. User can tweak any field. Tap "Create."

**Step 2b: Custom chosen.** Form:
- Name (text field)
- Emoji (single emoji picker, or SF Symbol picker toggle)
- Color (HSL picker from Cift, port + new palette — see §11)
- Description (multi-line text field, placeholder: "What kind of notes go in this space? e.g., 'Notes about my novel — characters, plot, dialogue ideas'")
- Tap "Continue" → LLM expands description into a full `SpaceProfile` (loading state ~1-3s).
- Sheet expands to show the LLM's draft profile: includeCriteria, excludeCriteria, keywords, example snippets, plain-English interpretation. User edits any field, then taps "Create."

### 5.4 Note Read Sheet

Triggered by tapping any note row. Partial bottom sheet (~75% height).

```
┌────────────────────────────────────────┐
│                              [ ✎ Edit ]│
│                                        │
│  # Note title                          │
│                                        │
│  Body content rendered as              │
│  rich text. Links                      │
│  show as cards. Images inline.         │
│                                        │
│  [ 🔗 link preview card ]              │
│                                        │
│  ─── created 2 days ago ───            │
└────────────────────────────────────────┘
```

- Read-only. Big type, generous spacing, rendered rich text from the note's canonical `RichText` payload.
- `✎ Edit` button top-right → sheet expands to full-screen and enters edit mode.
- Swipe down → dismiss.

### 5.5 Note Edit Page

Triggered by tapping `✎ Edit` from read sheet, or by double-tapping a row on home, or via `✎` button on input bar (for a brand-new note).

Full-screen. Keyboard up by default. Custom animated keyboard toolbar at top of keyboard with formatting controls (bold, italic, heading, list, link, attachment).

```
┌────────────────────────────────────────┐
│  [ ← Done ]              [ ⋯ ]         │
│                                        │
│  Title (large, editable)               │
│                                        │
│  Body editable via canopas             │
│  RichEditorSwiftUI. Formatting         │
│  controls live above keyboard/sidebar. │
│                                        │
├────────────────────────────────────────┤
│ [B] [I] [H] [•] [🔗] [📎]   [keyboard] │  ← custom animated toolbar
└────────────────────────────────────────┘
```

- `Done` saves and dismisses → returns to read sheet (or home if entered directly).
- `⋯` menu: Move to space, Pin, Favorite, Archive, Delete, Share, Export.

### 5.6 Search View

Triggered by `🔍` in space header. Modal sheet from top.

- Search bar with toggle: "This space" / "All spaces" / "Archive".
- Results list shows note title + 1-line preview + space pill (color + emoji).
- Tap result → opens read sheet.
- Recent searches persisted (cleared via menu).

### 5.7 Settings

Modal sheet, full-screen.

Sections:
- **iCloud Sync** — status indicator, last sync timestamp, "Sync now" button.
- **Archive** — count, "Browse archive" → opens Archive Browser with per-space filter and search.
- **Appearance** — Light / Dark / System; Note body font size slider.
- **Spaces** — Default new-note destination (dropdown); Fallback space for deletions (dropdown).
- **About** — Version, Privacy Policy, Contact.

---

## 6. Interactions & Gestures

| Gesture                                      | Effect                                                       |
|----------------------------------------------|--------------------------------------------------------------|
| Horizontal swipe left/right on space view    | Switch to adjacent space                                     |
| Tap title or `▾`                             | Open Space Switcher View                                     |
| Tap note row                                 | Open Note Read Sheet                                         |
| Double-tap note row                          | Open Note Edit Page (skip read mode)                         |
| Long-press note row                          | Context menu: Delete, Pin, Favorite, Move to space, Archive, Share, Duplicate |
| Long-press folder row                        | Context menu: Rename, Delete, Move                           |
| Long-press space title                       | Quick menu: Edit space, Move to…, Archive space              |
| Long-press space row in switcher             | Edit space sheet (name, emoji, color, delete)                |
| Drag note up into Pinned/Favorites section   | Promote (drop target highlights)                             |
| Drag note to left/right screen edge          | View swipes to adjacent space mid-drag; drop = move          |
| Drag note over the page dots                 | Dots expand into space picker, drop on one to move           |
| Two-finger swipe down on rows                | Enter multi-select mode (iOS Mail pattern)                   |
| Pull-down on Random section                  | Trigger manual tidy (with haptic + spinner)                  |
| Swipe down on any sheet                      | Dismiss                                                      |
| Pinch-out anywhere on space view             | Reserved for v2 (spaces overview grid)                       |

**Multi-select mode:**
- Rows show checkboxes on the left.
- Header right shows "Done."
- Bottom action bar appears with: Delete · Move to space · Pin · Favorite · Archive · Share.
- Tap a row to toggle selection; tap and drag to range-select.

---

## 7. Input Bar — Detailed Spec

**Anatomy:**

```
[ +  Empty your mind…               🎤/↑ ]   [ ✎ ]
```

- **Capsule** (Liquid Glass, `.regular.interactive()`, shape `.capsule`):
  - Left: `+` icon button. Opens attachment menu (popover above the bar): Photo, Camera, File, Link (paste from clipboard), Voice (long voice memo, separate from inline mic).
  - Center: multi-line text field. Placeholder: "Empty your mind…". Return key inserts newline (does NOT send).
  - Right: morphing button. Empty field = `🎤` (mic) → inline voice transcription via `Speech` framework, transcript editable before send. Non-empty field = `↑` (send arrow) → commits note to current space's Random tier and clears field.
- **Circle button** (Liquid Glass, `.regular.interactive()`, shape `.circle`):
  - `✎` icon. Opens a new blank note in full Edit Page.

**Wrapping:** capsule + circle inside a `GlassEffectContainer(spacing: 0)` so glass effects blend without visual seams.

**Position:** floats above the home indicator with safe-area padding. The space color is visible behind the glass. Does NOT extend to safe-area bottom edge.

**Behavior on swipe between spaces:** the bar stays in place (does not animate with the page), reinforcing that it operates on "wherever you are."

**Behavior on keyboard up:** capsule extends upward to grow with multi-line content; circle remains anchored.

**Attachment behaviors:**
- Pasted URL → fetch title + favicon async, render as link card inline above the text field.
- Pasted image → thumbnail strip above the text field.
- Voice (inline mic) → tap to start, tap to stop. Live transcription appears in the text field, editable before send.

---

## 8. Tidy Feature — Detailed Spec

### 8.1 Scheduling

- Runs automatically once per 24h, at a time chosen heuristically (user's typical "asleep" window, inferred from app activity).
- Default time: 3:00 AM device-local.
- User can disable in Settings? — NO, tidy is core to the product. Always on. (Decision pending — see §19.)
- Triggered by `BGTaskScheduler` background task.
- Manual trigger: pull-down on Random section OR `⋯` menu → "Tidy now."

### 8.2 Eligibility

Notes eligible for tidy:
- `tier == .random`
- `folder == nil` (top-level in Random — not already in a tidy-created folder)
- `createdAt < now - 6 hours` (don't tidy notes the user just created — they may still be using them)

Notes NEVER touched:
- `tier == .favorite` or `tier == .pinned`
- Notes inside user-created folders

### 8.3 LLM Call

Single Foundation Models call per eligible space. Input:

- The space's `SpaceProfile` (so the model knows what this space is "about").
- The eligible notes (id, title, `bodyPlainText` — body truncated to ~200 chars per note to fit context).
- Recent user corrections (last ~10 undo actions) as few-shot examples ("user un-archived this note, so it's not junk").

Output (`@Generable` struct):

```swift
@Generable
struct TidyResult {
    @Guide(description: "Topical folders to create; each contains 2+ related notes")
    let folders: [TidyFolder]

    @Guide(description: "Note IDs that don't fit any group; leave them flat in Random")
    let ungrouped: [String]

    @Guide(description: "Note IDs that look like junk (orphan numbers, dead links, contextless fragments)")
    let junk: [String]
}

@Generable
struct TidyFolder {
    @Guide(description: "Short folder name, 1-3 words")
    let name: String
    let noteIds: [String]
}
```

If eligible notes > 30, chunk into batches of ~30, run separately, then do a second merge pass to combine cross-chunk folders with overlapping themes.

### 8.4 Application

1. For each folder in `result.folders` with ≥2 notes: create `Folder` (tier = .random, createdByTidy = true), assign notes to it.
2. Notes in `result.junk`: set `tier = .archived`, log to `TidyRun.actions`.
3. Notes in `result.ungrouped`: untouched.

### 8.5 Morning Banner

On next app launch after a tidy run:

```
┌──────────────────────────────────────────┐
│  ✨ Tidied 14 notes overnight             │
│  3 archived · 11 grouped into 4 folders  │
│  [ Review ]                  [ Dismiss ] │
└──────────────────────────────────────────┘
```

Banner anchored below the space title, dismissible. Persists until reviewed or dismissed.

**Review screen:** scrollable list of every change with per-item undo button. Undone actions feed back into the next tidy's few-shot examples.

### 8.6 Cross-space Move Suggestion (Silent)

Whenever a note is created or significantly edited:
- Async, low-priority Foundation Models call: "Given this note and these N space profiles, which space does it belong to? Return space ID + confidence (0-1)."
- If confidence > 0.85 AND suggested space ≠ current space: attach a `MoveSuggestion` chip to the note's `tidyMetadata`. Renders inline on the row: `→ Looks like Work` (tap = accept move, swipe = dismiss).
- Dismissals feed into few-shot for future suggestions.

---

## 9. Space Profile System

A `SpaceProfile` is the structured rubric that tells the AI what a space "stands for." Two ways to create one:

### 9.1 Presets

Ship with hand-crafted profiles for 8 default spaces. Each preset profile lives in code as a static factory:

```swift
extension SpaceProfile {
    static let work = SpaceProfile(
        summary: "Work tasks, meetings, projects, and professional communication.",
        includeCriteria: ["meeting notes", "project updates", "work tasks", "professional contacts", "deadlines"],
        excludeCriteria: ["personal errands", "hobbies", "recreational reading"],
        keywords: ["meeting", "project", "deadline", "team", "client", "deliverable"],
        exampleSnippets: ["Q3 roadmap review notes", "Call Sarah re: contract", "Standup blockers"]
    )
    // … work, personal, college, recipes, readingList, travel, ideas, finance
}
```

### 9.2 Custom (LLM-expanded)

User flow:
1. User types a description: "Notes about my novel — characters, plot points, dialogue ideas."
2. App sends to Foundation Models with prompt: "Given this description of a notes category, generate a structured profile…" → returns a `SpaceProfile` draft.
3. User reviews in sheet, edits any field, taps "Create."

The approved profile is stored on the `Space` and used for every tidy pass and move suggestion thereafter.

### 9.3 Profile Updates

Settings → Spaces → tap a space → "Regenerate profile" if the user changes the description. Profile changes do NOT retroactively re-tidy existing notes (would be jarring) — they only affect future judgments.

---

## 10. AI Architecture (Foundation Models)

### 10.1 Session Management

A single `LanguageModelSession` per task class, reused for the lifetime of that task to amortize cold-start cost.

- `TidyService` owns one session for tidy passes.
- `SuggestionService` owns one session for move suggestions.
- `ProfileExpanderService` owns one session for SpaceProfile expansion.

### 10.2 Prompts

Stored as static strings or templates in `AI/Prompts/`. Versioned (e.g., `TidyPrompt.v1`) so changes can be tested.

### 10.3 Structured Output

All outputs use `@Generable` types to guarantee parseable responses. No JSON-via-string-parsing.

### 10.4 Error Handling

If Foundation Models is unavailable (model not downloaded, device unsupported despite our floor): show a one-time alert at first launch explaining tidy won't run, allow the app to function fully as a manual notes app.

### 10.5 Privacy

100% on-device. No data leaves the device for AI processing. Surface this prominently in Settings → About.

---

## 11. Design System

### 11.1 Typography

- **Chrome** (titles, page dots, buttons, bar text): SF Pro Rounded.
- **Note body**: SF Pro (standard, more readable for long form).
- **Sizes:** Title = 34pt rounded bold. Section labels (if any) = 13pt rounded medium. Row title = 17pt rounded regular. Row preview = 14pt regular, opacity 0.6.

### 11.2 Color Palette (Space Backgrounds)

Hand-curated ~12 desaturated tones, designed for full-bleed use without fatigue:

| Name      | Light Hex | Dark Hex   |
|-----------|-----------|------------|
| Warm Tan  | `#E5D4B7` | `#3A2F22`  |
| Sage      | `#C8D5C0` | `#2A3328`  |
| Lavender  | `#D5CCE0` | `#2E2A38`  |
| Slate     | `#C5CDD3` | `#293138`  |
| Terracotta| `#D9B5A0` | `#3D2820`  |
| Olive     | `#C3C19A` | `#33321F`  |
| Ink       | `#B0B5C0` | `#1E222B`  |
| Fog       | `#D7DCE0` | `#2C3035`  |
| Sand      | `#E3D5BA` | `#3B3122`  |
| Plum      | `#C7B0BC` | `#322028`  |
| Moss      | `#B8C5A8` | `#2B3322`  |
| Rust      | `#CC9F8A` | `#3A211A`  |

User can also pick custom colors via the HSL picker (ported from Cift's `HSLCircularPickerView`). Custom colors should snap toward desaturated zone with a warning if too saturated.

### 11.3 Liquid Glass Usage

Reference: Cift project lessons stored in memory ([liquid-glass-lessons]).

- All chrome surfaces (input bar capsule + circle, header pill, page dots area, banners) use Liquid Glass.
- Wrap related glass surfaces in `GlassEffectContainer(spacing: 0)` to prevent unwanted merging.
- Interactive surfaces: `.glassEffect(.regular.interactive(), in: .capsule)` or `.circle`.
- Non-interactive: `.glassEffect(in: .rect(...))`.
- Background extending into safe area: apply `.ignoresSafeArea(edges: .top)` AFTER `.glassEffect`.

### 11.4 Icons

- App icon: TBD design pass. Should reference the muted color palette.
- Row icons: minimal. Note = `circle.fill` at 6pt (or small `doc.text` — TBD, see §19). Folder = `folder.fill`. Expandable folder shows `chevron.right` / `chevron.down`.
- Header icons: `magnifyingglass`, `ellipsis`, `gearshape`, `chevron.down`.
- Input bar icons: `plus`, `mic.fill`, `arrow.up`, `square.and.pencil`.

### 11.5 Dark Mode

- Space color = `colorHex` luminance-adjusted via a `Color.adaptedForScheme(_:)` extension.
- High contrast: white whites, neutral grays (per Cift dark-mode-contrast preferences).
- Glass effects automatically adapt; verify visually.

---

## 12. Animations & Transitions

- **Space swipe:** `TabView` with `.tabViewStyle(.page(indexDisplayMode: .never))` or custom paging if needed. Animation matches `.spring(response: 0.4, dampingFraction: 0.85)`.
- **Page dot active state:** width animates from 6pt to 18pt with `.spring()`.
- **Background color crossfade between spaces:** during horizontal swipe, the background color interpolates linearly between the two adjacent space colors based on swipe progress (gives a beautiful "bleed" effect).
- **Read → Edit sheet expansion:** sheet detent animates from `.medium` to `.large` with `.spring(response: 0.4)` while keyboard rises in parallel.
- **Mic ↔ Send arrow morph:** symbol replacement with `.symbolEffect(.replace.byLayer)` (iOS 18+).
- **Drag-to-promote:** dragged note row scales to 1.05 with shadow; drop targets pulse with subtle highlight.
- **Tidy banner:** slides down from below the title with `.spring()` on first app launch after a run.
- **Folder expand/collapse:** `.matchedGeometryEffect` or `.transition(.move)` with spring.

---

## 13. Sync (CloudKit)

- SwiftData + CloudKit private database.
- All models conform to CloudKit-compatible SwiftData requirements (all properties optional or with defaults, no unique constraints on synced fields beyond `id`).
- Conflict resolution: last-write-wins on scalar fields; for note body, store edit timestamps and use the more recent.
- Sync status surfaced in Settings → iCloud Sync.
- Initial sync on first launch shows a brief progress indicator if device has slow connection.

---

## 14. Settings

Already detailed in §5.7. Implementation notes:

- Each section is a `Section` in a `Form`/`List`.
- Tidy preferences explicitly NOT included (decision: tidy is core, runs nightly, no user knobs).
- Archive Browser: separate view showing all `tier == .archived` notes, grouped by space, with restore action.

---

## 15. Empty States & Onboarding

### 15.1 First Launch

- Brief 3-screen onboarding:
  1. "Welcome to Savant — empty your mind." (logo + tagline)
  2. Animated demo: typing in the bar, note appears in Random.
  3. Animated demo: pull-down on Random → ✨ tidy sweep → notes fold into folders.
- "Choose your first spaces" — multi-select from presets, default selection includes Personal + Work.
- Land on Personal space, empty state shows the input bar prominently with a subtle "Try it — paste a link or type a thought" hint.

### 15.2 Section Empty States

- **No Favorites:** section hidden entirely (no tiles, no divider).
- **No Pinned:** section hidden entirely.
- **No Random:** subtle centered text "Nothing here yet. Capture below ↓" pointing at the input bar.
- **First-time pull-down-to-tidy hint:** when Random has ≥10 notes and tidy hasn't been triggered manually, show a one-time animated hint at the top of Random: "↓ Pull down to tidy."

### 15.3 New Space Empty State

- All three sections empty → centered illustration (TBD) + "Your [Space Name] space is empty. Capture below."

---

## 16. Dependencies

### Swift Package Manager

- **https://github.com/canopas/rich-editor-swiftui** — pinned to latest stable (`1.1.1` as of 2026-05-18). This is Savant's canonical note editor for iOS and macOS. Use `RichEditorState`, `RichTextEditor`, and the library's `RichText` Codable model.
  - Canonical storage: encoded `RichText` JSON in `Note.bodyRichTextJSON`.
  - Derived fields: `bodyPlainText` for rows, search, and AI prompts; optional Markdown only for import/export.
  - iOS chrome: use the editor surface but keep Savant's custom animated keyboard toolbar.
  - macOS chrome: use the editor surface with a Savant-styled toolbar/sidebar inspector.
  - Attachments: keep Savant's `Attachment` model for images/files/voice/link previews; do not rely on rich text embedded image storage for v1.
  - License note: repo metadata, `LICENSE.md`, and podspec identify MIT; README currently contains a stale/conflicting Apache footer, so verify before release.

### Reference Implementations (not packages — patterns to adapt)

- **iOS 26 Custom Animated Keyboard Toolbar (SwiftUI)** — expandable toolbar pinned above the keyboard. Used for the formatting controls (B / I / H / list / link / attachment) on `NoteEditPage`. Local reference implementation: **`/Users/yousrallouani/Downloads/CustomTFT`** (contains `CustomTFT.xcodeproj` — open and adapt). Implement as a custom SwiftUI view bound to the keyboard's safe area, with spring animation for the expand/collapse states.

- **Cift's on-device Foundation Models categorizer** — reference repo: **https://github.com/Yousr-Allah-Allouani/Cift-iOS-App** (branch `yns_dev`). Cift uses Foundation Models to categorize tasks into pre-existing categories based on their title and a structured `CategoryPromptProfile` (name + description + include criteria + exclude criteria + keywords + examples). Savant reuses this exact mental model for `SpaceProfile` (see §9) and the move-suggestion service (see §8.6). Read the Cift implementation for: session setup, prompt structure, and structured output shape — then adapt prompts for Savant's three jobs (tidy classification, profile expansion, move suggestion).

### System Frameworks

- `SwiftUI`
- `SwiftData`
- `CloudKit`
- `FoundationModels` (iOS 26+)
- `Speech` (for voice transcription)
- `LinkPresentation` (for URL preview metadata)
- `BackgroundTasks` (for scheduled tidy)
- `UniformTypeIdentifiers` (for attachments)

### Ported Code (from Cift)

- `HSLCircularPickerView` — port the structure, swap preset palette.

### Internal Patterns (no library, custom impl)

- Liquid Glass keyboard toolbar (custom animated expand/collapse).

---

## 17. File / Module Structure

```
Savant/
├── App/
│   ├── SavantApp.swift              // @main, scene setup, SwiftData container
│   └── AppState.swift               // global app state observable
├── Models/
│   ├── Space.swift
│   ├── SpaceProfile.swift
│   ├── Note.swift
│   ├── Folder.swift
│   ├── Attachment.swift
│   └── TidyRun.swift
├── Views/
│   ├── Home/
│   │   ├── SpacePagerView.swift     // horizontal pager containing SpaceView instances
│   │   ├── SpaceView.swift          // a single space's content
│   │   ├── SpaceHeaderView.swift    // page dots, title, search/menu/settings buttons
│   │   ├── FavoritesTileRow.swift
│   │   ├── PinnedSection.swift
│   │   ├── RandomSection.swift
│   │   ├── NoteRowView.swift
│   │   ├── FolderRowView.swift
│   │   └── TidyBannerView.swift
│   ├── InputBar/
│   │   ├── InputBarView.swift
│   │   ├── AttachmentMenuPopover.swift
│   │   └── VoiceTranscriptionView.swift
│   ├── Switcher/
│   │   ├── SpaceSwitcherSheet.swift
│   │   └── NewSpaceFlowView.swift
│   ├── NoteSheet/
│   │   ├── NoteReadSheet.swift
│   │   ├── NoteEditPage.swift
│   │   └── KeyboardToolbarView.swift
│   ├── Search/
│   │   └── SearchSheet.swift
│   ├── Settings/
│   │   ├── SettingsSheet.swift
│   │   ├── ArchiveBrowserView.swift
│   │   └── AboutView.swift
│   ├── Onboarding/
│   │   └── OnboardingFlow.swift
│   └── Shared/
│       ├── LiquidGlassContainer.swift   // wrapper helper
│       ├── HSLCircularPickerView.swift  // ported from Cift
│       └── ColorPalette.swift
├── AI/
│   ├── TidyService.swift
│   ├── SuggestionService.swift
│   ├── ProfileExpanderService.swift
│   ├── Prompts/
│   │   ├── TidyPrompt.swift
│   │   ├── SuggestionPrompt.swift
│   │   └── ProfilePrompt.swift
│   └── GenerableTypes.swift         // @Generable structs
├── Services/
│   ├── PersistenceController.swift  // SwiftData container + CloudKit
│   ├── BackgroundTaskScheduler.swift
│   ├── LinkPreviewService.swift
│   └── VoiceTranscriber.swift
├── Extensions/
│   ├── Color+Scheme.swift           // luminance-adjust for dark mode
│   ├── Note+Helpers.swift
│   └── View+Modifiers.swift
└── Resources/
    ├── Assets.xcassets
    └── Localizable.strings
```

---

## 18. Build Order (Milestones)

### M1 — Foundation (week 1-2)
- Xcode project setup, SwiftData + CloudKit configured.
- All models defined.
- `SpacePagerView` with horizontal swipe between 2-3 hardcoded spaces.
- Space background color rendering with crossfade during swipe.
- Page dots.
- Title with chevron (no functionality yet).

### M2 — Capture (week 2-3)
- Persistent `InputBarView` with Liquid Glass.
- Text capture → creates `Note` in current space's Random.
- `RandomSection` renders notes chronologically.
- Attachment menu (text + paste link first; images second).
- Mic → send arrow morph + Speech transcription.

### M3 — Tiers & Sections (week 3-4)
- `FavoritesTileRow` (all three densities).
- `PinnedSection` with folder support (nested).
- Long-press context menus everywhere.
- Drag-to-promote between sections.
- Empty state hiding.

### M4 — Note Sheets (week 4-5)
- `NoteReadSheet` (partial, rendered rich text).
- `NoteEditPage` (full, canopas rich editor + custom keyboard toolbar).
- Read ↔ Edit transition.

### M5 — Space Management (week 5-6)
- `SpaceSwitcherSheet` (list, reorder, navigate, edit).
- `NewSpaceFlowView` (preset + custom paths, HSL picker).
- LLM-driven `SpaceProfile` expansion for custom.

### M6 — AI Tidy (week 6-8)
- `TidyService` with Foundation Models call.
- `@Generable` types and structured output.
- Background scheduling.
- Pull-down trigger on Random.
- `TidyBannerView` with review/undo flow.
- `SuggestionService` for cross-space move chips.

### M7 — Search, Settings, Archive (week 8-9)
- `SearchSheet` (scoped + global).
- `SettingsSheet` with all sections.
- `ArchiveBrowserView`.

### M8 — Onboarding & Polish (week 9-10)
- `OnboardingFlow`.
- Animation refinement.
- Haptics pass.
- Accessibility (VoiceOver, Dynamic Type, contrast).
- TestFlight beta.

---

## 19. Open Decisions / TBD

These should be resolved before or during their respective milestones:

1. **Row icon (note):** small `circle.fill` dot (max minimal) vs. `doc.text` (visual weight). Decide during M3.
2. **Favorites tile density at 2 tiles:** show snippet text or just title?
3. **Tidy off-switch in Settings:** currently NO (tidy always on). Reconsider if beta feedback shows resistance.
4. **Tidy default time (3:00 AM):** confirm or make smart.
5. **Drag-over-page-dots to move:** implement in M3 or defer to v2?
6. **Pinch-out spaces overview:** v2 only.
7. **Sharing extension** (capture from other apps): probably v2.
8. **Widgets:** v2.
9. **Live Activities:** v2 if any feature warrants it.
10. **App name confirmation:** "Savant" is working name — verify trademark / App Store availability before launch.

---

## 20. macOS Desktop Direction

Status: macOS is a first-class desktop product direction. It should be a native SwiftUI/AppKit expression of Savant's note model, with desktop UX mapped directly from Zen Browser's open-source frontend rather than invented from scratch.

### 20.1 UX References

Canonical reference: **Zen Browser** (`https://github.com/zen-browser/desktop.git`). Zen is the source of truth for the macOS Savant shell's information architecture, interaction timing, sidebar density, workspace/space behavior, folder affordances, compact mode, and theme system.

Important Zen source paths to study before changing macOS UI:

- `src/zen/tabs/zen-tabs.css` and `src/zen/tabs/zen-tabs/vertical-tabs.css`: vertical sidebar structure, titlebar/sidebar integration, pinned separator, tab density, hover states, and collapsed/expanded behavior.
- `src/zen/spaces/zen-workspaces.css`: workspace icon strip, active workspace indicator, workspace name/icon treatment, collapsed pinned section, and workspace actions reveal.
- `src/zen/spaces/ZenSpace.mjs`: DOM structure for workspace sections, especially `zen-workspace-pinned-tabs-section`, separator behavior, and collapsed pinned tabs.
- `src/zen/spaces/ZenSpaceManager.mjs`: workspace state model, active workspace, per-workspace current tab, workspace navigation, workspace cache, and drag/switch state.
- `src/zen/spaces/ZenSpacesSwipe.mjs`: horizontal workspace swipe gesture, strip translation feedback, fast-swipe state, background opacity reset, and switch timing.
- `src/zen/tabs/ZenPinnedTabManager.mjs`: Essentials behavior, max Essentials, add/remove Essential interactions, pinned reset/replace semantics, and drag between Essentials/Pinned/normal targets.
- `src/zen/folders/ZenFolders.mjs` and `src/zen/folders/zen-folders.css`: folder hierarchy, nested folder limits, collapsed folder behavior, active folder visual state, drag/drop insertion, and folder popup/search behavior.
- `src/zen/spaces/ZenGradientGenerator.mjs` and `src/zen/spaces/zen-gradient-generator.css`: workspace theme picker, gradients, opacity, texture, dark/light adaptation, and predefined color harmonies.
- `src/zen/compact-mode/zen-compact-mode.css`: compact/focus mode, hover-revealed sidebar/toolbar, acrylic/background treatment, and timing.
- `src/zen/split-view/zen-split-view.css` and `src/zen/glance/zen-glance.css`: secondary references for future multi-note split view and quick preview, not M1.
- `prefs/zen/workspaces.yaml`, `prefs/zen/compact-mode.yaml`, and `prefs/zen/folders.yaml`: Zen defaults for workspace swipe, switch animation duration, wrap-around navigation, compact mode, hover delay, and folder constraints.

Do not use Helium or the Swift Browser repo as UX references. They may remain historical context only. If the macOS UI disagrees with Zen, Zen wins unless Savant's note-taking model makes the browser behavior nonsensical.

Implementation rule: Zen is MPL-2.0 and implemented in Firefox/XUL/CSS/JS. Savant should reimplement the same UX natively in SwiftUI/AppKit. Avoid copying source or assets verbatim. If any file is directly derived from Zen source, track the original Zen path/commit and preserve required MPL notices for that derived file.

### 20.2 Browser-to-Savant Translation

| Zen primitive | Savant macOS primitive | Required UX translation |
|---------------|------------------------|-------------------------|
| Vertical tabs sidebar | Vertical notes sidebar | The sidebar is the product surface. It must be custom, dense, hover-aware, and visually integrated with the titlebar. |
| Workspace | Space | A user-defined colored context with icon/name/theme. Spaces own Pinned/Random notes and remember the last selected note. |
| Workspace icon strip | Bottom space controls / space rail | Compact, icon-first, grayscale/desaturated when inactive, full color on active/hover/drag. In expanded mode this lives at the bottom of the sidebar, like the Zen/Arc screenshots; collapsed/focus mode may become a narrow rail. Must support click switch and later drag-over switch. |
| Current workspace indicator | Active space header | Icon + name row in the sidebar. Hover reveals actions. If Pinned exists, hover/active state reveals a collapse chevron. |
| Essentials | Favorites | Persistent top-tier notes. Zen supports separate Essentials per workspace by default; Savant starts with global Favorites but must keep the UI compatible with per-space Favorites later. |
| Pinned tabs | Pinned notes | Permanent notes scoped to the active space. Pinned section can collapse and has a separator from normal notes. |
| Normal tabs | Random notes | Fast captures, chronological/manual-sortable, tidy-eligible. |
| Tab folders | Note folders | Folders are first-class rows with disclosure state, active child indication, indentation, hover background, and drag/drop insertion. |
| Workspace themes | Space themes | Space background and sidebar tint derive from a Zen-style theme object: base colors now, gradients/opacity/texture later. |
| Compact mode | Focus mode | Hover-revealed sidebar/toolbar. Defer until the expanded shell is stable, but design measurements must not block collapse. |
| Split view / Glance | Multi-note split / quick peek | Future desktop affordance: compare two notes or peek a linked note without full navigation. |

### 20.3 Desktop Shell

Default macOS layout:

```
┌──────────────────────────────────────────────────────────────┐
│ Sidebar/titlebar/chrome surface                              │
│ ┌────────────────────────┐  ┌──────────────────────────────┐ │
│ │ traffic lights  tools  │  │                              │ │
│ │ search / capture       │  │                              │ │
│ │                        │  │                              │ │
│ │ active space           │  │                              │ │
│ │ folders / favorites    │  │      Note editor / reader    │ │
│ │ pinned                 │  │                              │ │
│ │ separator              │  │                              │ │
│ │ random                 │  │                              │ │
│ │                        │  │                              │ │
│ │ bottom space controls  │  │                              │ │
│ └────────────────────────┘  └──────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

- Use a custom sidebar rather than a stock macOS source list. The sidebar is the product.
- Sidebar expanded width target: 300-340 pt, matching Zen's dense vertical sidebar rather than macOS Finder source-list spacing. Collapsed/focus rail target: 52-64 pt.
- Left sidebar is default. Right sidebar can be a preference later, matching Zen's right-side option only if cheap.
- There is no separate horizontal app header above the sidebar. The titlebar, traffic lights, sidebar tools, search/capture field, space identity, hierarchy, and bottom space controls are one continuous sidebar/chrome entity.
- Use hidden titlebar/full-size-content window styling so the native window chrome visually belongs to the sidebar. The sidebar top area provides drag regions and tool buttons; the editor pane does not sit under a global toolbar.
- Traffic lights must live inside the sidebar's top chrome area without crowding the sidebar tools. Follow Zen's titlebar/sidebar fixes conceptually, not as copied CSS.
- Active space color must bleed through the full window background and into sidebar chrome. The note editor remains readable on a neutral surface.
- The main pane opens the selected note as a large rounded content surface inset from the window edges and visually separate from the colored sidebar background. Empty selection shows an active-space empty state, not a landing page.
- Avoid marketing layout, nested cards, hero panels, oversized rounded rectangles, and decorative gradients. Zen's chrome is dense, utilitarian, and quiet.

### 20.4 Sidebar Hierarchy

Order from top to bottom:

1. **Window/sidebar chrome row**: traffic lights, sidebar toggle, overflow/menu, refresh/sync or equivalent actions, all inside the sidebar column.
2. **Search / capture field**: Zen-style rounded command field directly below the chrome row. For Savant this can search notes, open commands, or create a quick note.
3. **Active space indicator**: icon + name, text overflow ellipsis, hover-revealed actions. Click opens the space menu. Hover also reveals the Pinned collapse affordance when applicable.
4. **Favorites / Essentials**: compact top region. Prefer small icon tiles or tight rows, not large cards. Supports drag-to-Favorite.
5. **Pinned**: active-space permanent notes and folders. The section has a Zen-style separator and can collapse. Collapse hides the pinned children but keeps the active-space header stable.
6. **Random / Notes**: active-space loose captures and tidy-created folders. Scrolling is local to the active space.
7. **Bottom space controls / space rail**: space icons and new-space button sit at the bottom of the sidebar in expanded mode, matching the screenshots' Arc/Zen feel. A collapsed/focus mode may turn this into a narrow vertical rail later.

Sidebar row rules:

- Rows are 30-36 pt high in expanded mode. Selection uses a restrained tinted row plus a small active edge/indicator, not a large pill.
- Hover actions are hidden until hover. Do not permanently display close/delete buttons in every row.
- Section separators are thin, low-contrast, and animate their height/opacity when hidden, following Zen's pinned separator behavior.
- Folder rows use disclosure state, active-child state, and indentation. Open/closed folder icon motion should be subtle.
- Favorites should remain visually stable when switching spaces. Pinned and Random belong to the active space and animate as the space changes.

### 20.5 Space Switching

- Follow `ZenSpacesSwipe.mjs`: horizontal swipe begins only when a workspace switch is valid, ignores foot buttons/popovers, translates the strip during the gesture, then commits the adjacent workspace at gesture end.
- During swipe, the note list/space column translates with resistance near the edge. The background crossfades or opacity-fades between adjacent space themes. On completion, reset temporary transform/opacity state.
- Zen defaults to workspace swipe enabled, 200 ms switch animation, wrap-around navigation, and natural scroll disabled. Savant should start with the same feel unless native trackpad behavior makes inversion necessary.
- Space icons remain reachable in the rail. Clicking switches immediately with the same 180-220 ms animation family.
- Dragging a note/folder over a space icon starts delayed switch preview. Zen uses workspace DnD padding and hover-like states; Savant should preview the target space before drop.
- Keyboard shortcuts: `Command-1...Command-9` for spaces. Add next/previous shortcuts after checking system conflicts.

### 20.6 Capture And Commands

- The command/search/capture field lives near the top of the fused sidebar chrome, directly under the window/sidebar tool row, matching Zen's address/search field placement. It must not become a separate global header or a bottom editor control.
- `Command-N`: create a new Random note in the active space and focus the editor.
- `Command-Shift-N`: create a new space.
- `Command-L` or a dedicated quick-capture shortcut is TBD; avoid stealing common system/browser muscle memory unless it clearly earns the tradeoff.
- Search should be reachable via `Command-F` for in-note search and `Command-Option-F` or toolbar search for global note search.

### 20.7 Folders And Dragging

- Dragging notes between Favorites, Pinned, and Random promotes/demotes them.
- Dragging over folders inserts into the folder; dragging between rows reorders manually.
- Nested folders are allowed in Pinned. Match Zen's max-subfolders default conceptually: impose a reasonable nesting cap rather than unbounded recursion.
- Random folders created by tidy are flat by default, but user-created Random folders may become nested if we decide that desktop users need it.
- Folder-to-space conversion from Zen is a useful reference: for Savant, "Convert folder to Space" can be a v2 command that creates a space and moves the folder's notes into its Random or Pinned tier.
- Folder search/popup behavior from Zen is a future enhancement: hovering/clicking a collapsed folder can show a compact searchable popup of child notes.

### 20.8 Styling From Zen

Use these visual rules for macOS:

- Border radii: medium sidebar/chrome radius around 10-12 pt on macOS; tab/note row radius around 6-8 pt. Avoid large 16-24 pt card radii in dense chrome.
- Colors: active space theme drives icon fills, row tints, split/peek outlines, and background. Inactive space icons are grayscale/desaturated.
- Materials: use native material/acrylic-like blur sparingly for chrome. Content/editor surfaces should remain readable and not overly glassy.
- Typography: compact system text, 10-11 pt uppercase section labels, 13-14 pt note rows, 600 weight for active space/folder labels.
- Motion: short, functional transitions. Workspace switch about 200 ms; pinned separator height/opacity under 100 ms; hover/action reveal about 100-150 ms.
- Scrollbars: hide by default where native macOS already overlays them, but show local scroll affordance when a section overflows.
- Empty states: inline and compact. No hero screens, no marketing copy.

### 20.9 Tidy On macOS

- Tidy remains core and on-device.
- Manual tidy lives in the space header and context menus.
- The morning tidy banner should appear under the active space header or as a compact sidebar callout.
- Review/undo should open as a sheet or inspector-style panel, not a blocking alert.
- Desktop should add richer review affordances: multi-select undo, reveal note, move to folder/space, and restore archived notes.

### 20.10 Implementation Plan

Mac M1 - Target and shared model:
- Add a macOS target to `project.yml`.
- Reuse SwiftData models and services.
- Keep iOS-specific views behind platform checks or split into platform folders.

Mac M2 - Desktop shell:
- Build `MacRootView` with a custom Zen-derived sidebar and main note pane.
- Add hidden/full-size titlebar behavior, fused sidebar chrome, space color background, active space state, and per-space selected note memory.
- Implement space rail, active space indicator, Favorites / Pinned / Random sections, and Zen-density rows from existing data.

Mac M3 - Capture and editing:
- Add the top sidebar command/search/capture field.
- Wire `Command-N`, quick capture focus, read/edit main pane behavior.
- Share note editing services with iOS while allowing macOS-specific chrome.

Mac M4 - Spaces:
- Add create/edit/delete/reorder for spaces.
- Implement trackpad/keyboard space switching, strip translation feedback, wrap-around behavior, and background transitions.
- Add Zen-style theme editor basics: color, dark/light variant, opacity; gradients later.

Mac M5 - Drag and hierarchy:
- Drag notes between tiers, folders, and spaces.
- Add delayed drag-over-space switching.
- Add folder management and reorder persistence.
- Add folder collapse state, nested folder cap, active-child indication, and compact folder popup/search if needed.

Mac M6 - Tidy, search, polish:
- Add tidy banner/review panel.
- Add desktop search and archive browsing.
- Add compact/focus mode only after the expanded shell is stable.
- Add split/peek note affordances inspired by Zen Split View/Glance only after core navigation is solid.

### 20.11 Open macOS Decisions

1. **Native macOS vs Catalyst:** current direction is native SwiftUI/AppKit, not Catalyst.
2. **Global vs per-space Favorites:** Zen defaults toward separate Essentials; Savant currently models Favorites globally. Decide whether to migrate to per-space Favorites.
3. **Sidebar collapsed state:** initial desktop release can ship expanded-only if collapse adds too much complexity.
4. **Right sidebar:** defer unless strongly desired.
5. **Favorites density:** choose icon-grid vs compact rows after testing real note titles.
6. **Space gradients:** start with muted two-color themes; Zen-style generated gradients/texture are polish after layout is correct.
7. **Menu bar scope:** decide which commands deserve first-class macOS menu items.
8. **Multiple windows:** likely v2; first macOS build can be single-window with CloudKit sync.

---

*End of specification.*
