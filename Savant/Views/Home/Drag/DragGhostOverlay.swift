import SwiftUI

/// Floating drag ghost, rendered once at the pager root so it survives
/// auto-scroll (and, later, mid-drag space switches). This leaf is the ONLY
/// view that reads `session.ghostOrigin` — per-finger-frame updates
/// invalidate just this body.
///
/// The ghost MORPHS: its style follows `session.currentTier` (and the open
/// folder it's being placed into), so a kept note dragged into the stream
/// reshapes into a stream row mid-flight, an essential card melts into a list
/// row, and a row entering an open folder narrows to child width — by release
/// it already looks exactly like the row it's about to become. Note ghosts
/// render through ONE view identity (`MorphingNoteGhost`) so the card↔row
/// change animates as a frame morph, not a crossfade. The rendered size is
/// reported back so gaps, hit-tests, and the grab point track the morph.
struct DragGhostOverlay: View {
    let session: TouchDragSession

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let ghost = session.ghost {
                ghostContent(ghost)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        proxy.size
                    } action: { size in
                        session.ghostSizeChanged(size)
                    }
                    .scaleEffect(ghostScale, anchor: .center)
                    .opacity(session.settleFades ? 0 : 1)
                    .shadow(
                        color: .black.opacity(session.isSettling ? 0.10 : 0.18),
                        radius: session.isSettling ? 6 : 14,
                        y: session.isSettling ? 3 : 8
                    )
                    .offset(
                        x: session.ghostOrigin.x - session.overlayOriginGlobal.x,
                        y: session.ghostOrigin.y - session.overlayOriginGlobal.y
                    )
                    .animation(TouchDragSession.ghostMorph, value: noteStyle)
                    .animation(TouchDragSession.ghostMorph, value: styleTier)
                    .animation(TouchDragSession.commitGlide, value: session.isSettling)
                    .animation(TouchDragSession.commitGlide, value: session.settleFades)
            }
        }
        .allowsHitTesting(false)
        .onGeometryChange(for: CGPoint.self) { proxy in
            proxy.frame(in: .global).origin
        } action: { origin in
            session.overlayOriginGlobal = origin
        }
    }

    /// The tier whose row style the ghost wears right now.
    private var styleTier: NoteTier {
        session.currentTier ?? session.sourceTier ?? .random
    }

    private var ghostScale: CGFloat {
        if session.settleFades { return 0.82 }   // absorbed (closed folder)
        return session.isSettling ? 1.0 : 1.03
    }

    @ViewBuilder
    private func ghostContent(_ ghost: TouchDragSession.GhostSpec) -> some View {
        switch ghost.content {
        case .note(let note):
            MorphingNoteGhost(note: note, style: noteStyle)
        case .folder(let folder, let count):
            FolderRowCard(folder: folder, count: count, isExpanded: false, tier: styleTier)
                .frame(width: rowWidth)
        }
    }

    private var noteStyle: MorphingNoteGhost.Style {
        if styleTier == .favorite {
            return .card(essentialCardSize)
        }
        return .row(width: rowWidth, showsPreview: styleTier == .pinned)
    }

    /// Inside an open folder the ghost narrows to child width; in the source
    /// tier it keeps the lifted row's own width (child rows are narrower than
    /// the section); carried out of its folder it widens to the tier's full
    /// row width (the drag-out preview); crossing tiers it takes the target's.
    private var rowWidth: CGFloat {
        let tierWidth = session.tierFrames[styleTier]?.width ?? 0
        if session.targetParentFolderID != nil, tierWidth > 0 {
            // Nested targets sit deeper — one inset per level.
            return tierWidth - CGFloat(session.targetParentDepth + 1) * TouchDragSession.childInset
        }
        if session.isUnnesting, tierWidth > 0 { return tierWidth }
        if !session.isCrossTier { return session.sourceRowWidth }
        return tierWidth > 0 ? tierWidth : session.sourceRowWidth
    }

    /// One grid cell of the Essentials 3-column layout (12pt gutters).
    private var essentialCardSize: CGSize {
        let gridWidth = session.tierFrames[.favorite]?.width
            ?? session.ghost?.size.width
            ?? 120
        let width = max(80, (gridWidth - 24) / 3)
        return CGSize(width: width, height: width / 0.78)
    }
}

/// One view identity for every shape a dragged NOTE can wear — essential card,
/// kept row, stream row — so style changes animate as a single frame/layout
/// morph instead of a view swap. Mirrors `EssentialCardFace` and `NoteRowCard`
/// styling; keep them visually in sync.
struct MorphingNoteGhost: View {
    enum Style: Equatable {
        case card(CGSize)
        case row(width: CGFloat, showsPreview: Bool)
    }

    let note: Note
    let style: Style

    private var isCard: Bool {
        if case .card = style { return true }
        return false
    }

    private var showsPreview: Bool {
        if case .row(_, let preview) = style { return preview }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(
                        isCard
                            ? .system(.subheadline, design: .rounded).weight(.medium)
                            : .system(size: 17, design: .rounded)
                    )
                    .foregroundStyle(.savantInk)
                    .lineLimit(isCard ? 3 : 1)
                    .multilineTextAlignment(.leading)
                if !isCard, let moveSuggestionTitle = note.moveSuggestionTitle {
                    Text("→ \(moveSuggestionTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.08), in: .capsule)
                }
                Spacer(minLength: 0)
            }

            if showsPreview, !note.bodyMarkdown.isEmpty {
                Text(note.bodyMarkdown)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if isCard { Spacer(minLength: 0) }
        }
        .padding(.horizontal, isCard ? 14 : 18)
        .padding(.vertical, isCard ? 14 : (showsPreview ? 13 : 12))
        .frame(width: frameWidth, height: frameHeight, alignment: .topLeading)
        .frame(minHeight: isCard ? nil : (showsPreview ? 62 : 48))
        .savantCard(
            radius: isCard ? SavantTheme.cardRadius : SavantTheme.rowRadius,
            soft: !isCard && !showsPreview
        )
    }

    private var frameWidth: CGFloat? {
        switch style {
        case .card(let size): size.width
        case .row(let width, _): width > 0 ? width : nil
        }
    }

    private var frameHeight: CGFloat? {
        switch style {
        case .card(let size): size.height
        case .row: nil
        }
    }
}
