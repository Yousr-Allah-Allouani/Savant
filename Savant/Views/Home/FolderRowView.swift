import SwiftData
import SwiftUI

/// Folder HEADER row only — children render as separate flat rows in the
/// section's single ForEach (`TierRowsBuilder`), so the drag engine can
/// shuffle them with their header as one block.
struct FolderRowView: View {
    @Environment(TouchDragSession.self) private var session

    let folder: Folder
    let count: Int
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let tier: NoteTier
    /// Non-nil for a SUBFOLDER row — it lifts as a child of that folder, so
    /// the engine resolves it like any other child block (sibling reorder,
    /// drag-out, nest elsewhere).
    let parentFolderID: UUID?
    /// Collapses an expanded folder just before the lift so it drags as a
    /// single header row (re-expanded by `onSettled`).
    let onWillLift: () -> Void
    let onSettled: () -> Void

    var body: some View {
        let isNestTarget = session.nestTargetFolderID == folder.id

        FolderRowCard(folder: folder, count: count, isExpanded: isExpanded, tier: tier)
            .overlay {
                if isNestTarget {
                    RoundedRectangle(cornerRadius: SavantTheme.rowRadius, style: .continuous)
                        .stroke(.primary.opacity(0.4), lineWidth: 1.5)
                }
            }
            .scaleEffect(isNestTarget ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: isNestTarget)
            .contentShape(.rect(cornerRadius: SavantTheme.rowRadius))
            .onTapGesture { toggleExpanded() }
            .dragRow(
                id: folder.id,
                payload: .folder(folder.id),
                tier: tier,
                parentFolderID: parentFolderID,
                spaceID: folder.space?.id,
                ghost: { .folder(folder, count: count) },
                onWillLift: onWillLift,
                onSettled: onSettled
            )
    }
}

/// The bare header card — shared between the in-list row and the drag ghost.
/// `tier` drives the style (NOT `folder.tier`): in the kept section the
/// header carries the same presence as a kept note row, and the ghost passes
/// the tier it's currently morphing toward.
struct FolderRowCard: View {
    let folder: Folder
    let count: Int
    let isExpanded: Bool
    let tier: NoteTier

    private var isProminent: Bool { tier == .pinned }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 15))
                .foregroundStyle(.savantSubtleInk)
            Text(folder.name)
                .font(.system(size: 17, design: .rounded).weight(.medium))
                .foregroundStyle(.savantInk)
                .lineLimit(1)
            Spacer()
            Text("\(count)")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.savantSubtleInk)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, isProminent ? 13 : 12)
        .frame(minHeight: isProminent ? 62 : 48)
        .savantCard(radius: SavantTheme.rowRadius, soft: !isProminent)
    }
}

// `FolderService` lives in `Services/FolderService.swift` so it compiles into
// both the iOS and macOS targets.
