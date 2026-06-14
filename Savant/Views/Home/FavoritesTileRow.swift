import SwiftData
import SwiftUI

/// Essentials — the global top tier as a grid of soft-white cards on the space
/// accent (Figma skeleton). Three columns; extra notes wrap to new rows.
/// A FULL drag surface: cards lift out to demote, reshuffle live inside the
/// grid (manual order via `manualSortIndex`), and arrivals from the lists
/// open a real cell slot the ghost morphs into.
/// (Filename/type kept so call sites and the project file don't churn.)
struct FavoritesTileRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TouchDragSession.self) private var session
    @Environment(\.isActiveSpacePage) private var isActivePage

    /// This space's Essentials (favorites are global — space-agnostic),
    /// already in manual order.
    let notes: [Note]
    /// Full query results — promote commits look arrivals up here.
    let allNotes: [Note]
    let spaces: [Space]
    let currentSpace: Space

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        let _ = publishContext()
        let isTargeted = session.isCrossTier && session.currentTier == .favorite

        VStack(spacing: 0) {
            if notes.isEmpty {
                // PRINCIPLE: empty Essentials stays collapsed at lift — its slot
                // grows in only when the ghost actually approaches the top
                // (proximity reveal), so it never pops above the source rows.
                // The placeholder is a real grid CELL (card-sized), so the note
                // settles into it with no further growth on release.
                if session.revealsEmptyBand(.favorite) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        RoundedRectangle(cornerRadius: SavantTheme.cardRadius, style: .continuous)
                            .fill(.primary.opacity(session.currentTier == .favorite ? 0.06 : 0.02))
                            .strokeBorder(
                                .primary.opacity(session.currentTier == .favorite ? 0.28 : 0.12),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                            )
                            .aspectRatio(0.78, contentMode: .fit)
                    }
                    .padding(4)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(notes) { note in
                        EssentialCard(note: note)
                    }
                }
                .padding(4)
                .overlay {
                    if isTargeted {
                        RoundedRectangle(cornerRadius: SavantTheme.cardRadius + 4, style: .continuous)
                            .stroke(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
                }
                .padding(-4)
                .animation(.easeOut(duration: 0.15), value: isTargeted)
            }
        }
        // The grid grows a row when an arrival's slot wraps past the last
        // card, and drops one once an outbound card's hole closes.
        .padding(.bottom, bottomAdjustment)
        .animation(session.isActive ? TouchDragSession.rowShuffle : nil, value: bottomAdjustment)
        .animation(TouchDragSession.rowShuffle, value: session.revealsEmptyBand(.favorite))
        .onGeometryChange(for: ActiveFrame.self) { proxy in
            ActiveFrame(frame: proxy.frame(in: .named("spaceContent")), active: isActivePage)
        } action: { report in
            if report.active { session.tierFrames[.favorite] = report.frame }
        }
    }

    private var bottomAdjustment: CGFloat {
        session.bottomAdjustment(for: .favorite)
    }

    private func publishContext() {
        guard isActivePage else { return }
        session.publishTier(.init(
            tier: .favorite,
            blocks: notes.map(\.id),
            spacing: 12,
            gridColumns: 3,
            acceptsFolders: false,
            commitReorder: { ordered in
                applyOrder(ordered)
            },
            commitInsert: { payload, index in
                guard case .note(let id) = payload,
                      let note = allNotes.first(where: { $0.id == id })
                else { return }
                do {
                    try NoteService(context: modelContext).promote(
                        note, to: .favorite, currentSpace: currentSpace
                    )
                } catch {
                    assertionFailure("Promote to Essentials failed: \(error)")
                    return
                }
                var ordered = notes.map(\.id).filter { $0 != id }
                ordered.insert(id, at: min(max(0, index), ordered.count))
                applyOrder(ordered)
            }
        ))
    }

    private func applyOrder(_ ordered: [UUID]) {
        for (index, id) in ordered.enumerated() {
            allNotes.first(where: { $0.id == id })?.manualSortIndex = index
        }
        try? modelContext.save()
    }
}

/// One Essential: a tall soft-white card with the note title pinned to the
/// top-leading corner. Quiet by design — the card shape carries the tier.
private struct EssentialCard: View {
    @Environment(AppState.self) private var appState

    let note: Note

    var body: some View {
        EssentialCardFace(note: note)
            .aspectRatio(0.78, contentMode: .fit)
            .contentShape(.rect(cornerRadius: SavantTheme.cardRadius))
            .onTapGesture(count: 2) { appState.presentEdit(note) }
            .onTapGesture { appState.presentRead(note) }
            .dragRow(
                id: note.id,
                payload: .note(note.id),
                tier: .favorite,
                ghost: { .note(note) }
            )
    }
}

/// The bare card — shared between the in-grid card and the drag ghost.
struct EssentialCardFace: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(note.title)
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(.savantInk)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .savantCard(radius: SavantTheme.cardRadius)
    }
}
