import SwiftData
import SwiftUI

#if os(macOS)

/// One value that captures everything affecting the vertical layout of
/// the Essentials area at the top of the sidebar. Used as the `value:`
/// for the spring that drives banner expansion, banner collapse, and
/// grid appear/disappear transitions so they share one continuous curve.
private struct EssentialsLayoutKey: Hashable {
    let showsBanner: Bool
    let hasEssentials: Bool
    let count: Int
}

struct MacNotesSidebar: View {
    let spaces: [Space]
    let notes: [Note]
    let folders: [Folder]
    @Binding var selectedSpaceID: UUID?
    @Binding var selectedNoteIDsBySpace: [UUID: UUID]
    let spacePageOffset: CGFloat // fractional page index, animated by the parent
    let width: CGFloat
    let selectNote: (Note, Space) -> Void
    let createNote: () -> Void
    let createSpace: () -> Void
    let toggleSidebar: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var searchText: String = ""
    @State private var session = CrossTierDragSession()
    @State private var isDragging: Bool = false
    @State private var dragTarget: NoteDropTarget?

    private var selectedSpace: Space? {
        if let selectedSpaceID, let match = spaces.first(where: { $0.id == selectedSpaceID }) {
            return match
        }
        return spaces.first
    }

    private var spaceColor: Color {
        guard let s = selectedSpace else { return .accentColor }
        return Color.spaceColor(lightHex: s.colorHex, darkHex: s.darkColorHex, scheme: colorScheme)
    }

    /// Show the promo banner only when (a) a non-favorite is being dragged,
    /// (b) there are no Essentials yet, AND (c) the cursor has crossed
    /// above the active column's space-name label. The fact that
    /// `spaceNameMaxY` moves down once the banner is open creates natural
    /// hysteresis — the banner stays open while the cursor lingers in the
    /// top zone instead of flickering away.
    private var shouldShowAddToEssentialsBanner: Bool {
        guard session.isActive,
              session.sourceTier != .favorite,
              favoriteNotes.isEmpty,
              let cursorY = session.cursorY else { return false }
        return cursorY < session.spaceNameMaxY
    }

    /// Cross-space — favorites are global. Lives at sidebar level so its
    /// view doesn't slide with per-space swipes (Zen does the same with
    /// `#zen-essentials`).
    private var favoriteNotes: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return notes
            .filter { $0.tier == .favorite }
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.bodyMarkdown.lowercased().contains(q) }
            .sorted {
                switch ($0.manualSortIndex, $1.manualSortIndex) {
                case let (.some(l), .some(r)): return l == r ? $0.createdAt < $1.createdAt : l < r
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): return $0.createdAt < $1.createdAt
                }
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacSidebarCommandField(
                searchText: $searchText,
                createNote: createNote,
                toggleSidebar: toggleSidebar
            )
            .padding(.top, 10)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            // Anchored Essentials grid — rendered once at sidebar level so
            // it doesn't move during a per-space swipe. Cross-space.
            if !favoriteNotes.isEmpty, let activeSpace = selectedSpace {
                MacEssentialsRow(
                    notes: favoriteNotes,
                    space: activeSpace,
                    allNotes: notes,
                    selectedNoteID: selectedSpace.flatMap { selectedNoteIDsBySpace[$0.id] },
                    dragTarget: $dragTarget,
                    isDragging: $isDragging,
                    selectNote: { note in
                        if let sp = selectedSpace { selectNote(note, sp) }
                    },
                    session: session
                )
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if shouldShowAddToEssentialsBanner {
                // No favorites yet — render the Zen-style "Add to Essentials"
                // promo banner during a non-favorite drag. Pushes the
                // sidebar down via the .animation(value:) below.
                addToEssentialsBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Horizontal track of all space columns, offset by the animated
            // page index. Per Zen: only Pinned + Notes (per-space content)
            // slides with the workspace.
            HStack(spacing: 0) {
                ForEach(spaces) { space in
                    MacSpaceNotesColumn(
                        space: space,
                        notes: notes,
                        folders: folders,
                        selectedNoteID: selectedNoteIDsBySpace[space.id],
                        searchText: searchText,
                        selectNote: { selectNote($0, space) },
                        createNote: createNote,
                        session: session,
                        isDragging: $isDragging,
                        dragTarget: $dragTarget,
                        isActiveSpace: space.id == selectedSpaceID
                    )
                    .frame(width: width)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(x: -spacePageOffset * width)
            .frame(maxHeight: .infinity)
            .clipped()

            MacSpaceStrip(
                spaces: spaces,
                selectedSpaceID: selectedSpace?.id,
                selectSpace: selectSpace,
                createSpace: createSpace
            )
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 6)
        }
        // Drives the sidebar's vertical reflow whenever the Essentials
        // section transitions: banner showing/hiding, grid appearing or
        // disappearing on a count change. Single tight spring keeps the
        // banner expansion, banner collapse, grid appearance, and last-
        // essential-removed grid collapse all using the same curve.
        .animation(.spring(response: 0.18, dampingFraction: 0.82),
                   value: EssentialsLayoutKey(
                       showsBanner: shouldShowAddToEssentialsBanner,
                       hasEssentials: !favoriteNotes.isEmpty,
                       count: favoriteNotes.count
                   ))
        .frame(width: width)
        .background {
            ZStack {
                if let space = selectedSpace {
                    Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
                        .opacity(colorScheme == .dark ? 0.34 : 0.22)
                }
                Rectangle().fill(.ultraThinMaterial).opacity(colorScheme == .dark ? 0.40 : 0.30)
            }
        }
        // Floating ghost lives at sidebar level so its `.position(...)` uses
        // the same "notes-column" coords that `tierFrames` / `cursorY` /
        // `sourceRowCenter` are written in. Anchoring it to the sidebar
        // also means it doesn't get clipped by the HStack's `.clipped()`.
        .overlay(alignment: .topLeading) {
            if let id = session.draggedNoteID,
               let note = notes.first(where: { $0.id == id }) {
                floatingGhost(note: note)
            }
        }
        // Shared coord space across the anchored Essentials and the per-
        // space columns, so tier frames + cursor Y are measured in one
        // consistent frame of reference.
        .coordinateSpace(name: "notes-column")
    }

    @ViewBuilder
    private var addToEssentialsBanner: some View {
        let isTargeted = session.currentTier == .favorite
        VStack(spacing: 6) {
            Image(systemName: "heart.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.78))
            Text("Add to Essentials")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.88))
            Text("Keep your favorite notes just a click away")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(spaceColor.opacity(isTargeted ? 0.32 : 0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    spaceColor.opacity(isTargeted ? 0.95 : 0.55),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [5, 4])
                )
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            session.tierFrames[.favorite] = newFrame
        }
        .animation(.easeInOut(duration: 0.15), value: isTargeted)
    }

    @ViewBuilder
    private func floatingGhost(note: Note) -> some View {
        let asTile = (session.currentTier ?? session.sourceTier) == .favorite
        let rowWidth = session.tierFrames[session.sourceTier ?? .random]?.width
            ?? session.tierFrames[.random]?.width
            ?? session.tierFrames[.pinned]?.width
            ?? 240
        Group {
            if asTile {
                // Identical layout to the dropped tile in MacEssentialsRow:
                // VStack(icon + title), 8pt padding, 66pt minHeight,
                // primary.opacity(0.06) fill + matching stroke. The width
                // matches a typical grid cell (~88pt for 3 columns at
                // sidebar width 280).
                VStack(alignment: .leading, spacing: 8) {
                    MacNoteMiniIcon(note: note, size: 24)
                    Text(note.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(Color.primary.opacity(0.82))
                }
                .frame(width: 88, alignment: .topLeading)
                .frame(minHeight: 66, alignment: .topLeading)
                .padding(8)
                .background(
                    Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
            } else if let activeSpace = selectedSpace {
                MacNoteRow(
                    note: note,
                    space: activeSpace,
                    isSelected: false,
                    showDropIndicator: false,
                    indicatorColor: .clear,
                    selectNote: { _ in }
                )
                .frame(width: rowWidth)
                .background(
                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.78),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
            }
        }
        .position(
            x: session.sourceRowCenter.x,
            y: session.sourceRowCenter.y + session.translation.height
        )
        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)
        .opacity(0.95)
        .allowsHitTesting(false)
        .animation(.smooth(duration: 0.14), value: asTile)
    }

    private func selectSpace(_ space: Space) {
        guard selectedSpaceID != space.id else { return }
        withAnimation(.smooth(duration: 0.18)) {
            selectedSpaceID = space.id
        }
    }
}


// MARK: - Command field

private struct MacSidebarCommandField: View {
    @Binding var searchText: String
    let createNote: () -> Void
    let toggleSidebar: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Row 1: traffic lights (hosted), toggle button, overflow menu —
            // all on the same row, same vertical level. Lifted straight from
            // Nook's SidebarWindowControlsView (spacing 8, height 28).
            HStack(spacing: 8) {
                EmbeddedTrafficLights()

                Button("Toggle Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
                    .buttonStyle(NavButtonStyle())
                    .foregroundStyle(.primary)
                    .help("Hide sidebar (⌘S)")

                Spacer(minLength: 0)

                Menu {
                    Button("New Note", action: createNote)
                        .keyboardShortcut("n", modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis")
                        .imageScale(.large)
                }
                .menuStyle(.button)
                .buttonStyle(NavButtonStyle())
                .foregroundStyle(.primary)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .frame(height: 28)

            // Row 2: full-width URL-style search pill.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.55))

                TextField("Search or create note", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($isFocused)
                    .onSubmit {
                        if !searchText.isEmpty {
                            createNote()
                            searchText = ""
                        }
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            // Flat Zen-style URL pill: just a soft tinted fill, no stroke.
            .background(.primary.opacity(isFocused ? 0.09 : 0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }
}

// MARK: - Bottom space strip (mirrors Nook SidebarBottomBar + SpacesList)

private struct MacSpaceStrip: View {
    let spaces: [Space]
    let selectedSpaceID: UUID?
    let selectSpace: (Space) -> Void
    let createSpace: () -> Void

    @State private var availableWidth: CGFloat = 0

    private var layoutMode: SpaceStripMode {
        SpaceStripMode.determine(count: spaces.count, width: availableWidth)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                    MacSpaceChip(
                        space: space,
                        isSelected: selectedSpaceID == space.id,
                        compact: layoutMode == .compact,
                        action: { selectSpace(space) }
                    )
                    if index < spaces.count - 1 {
                        Spacer().frame(minWidth: 1, maxWidth: 8).layoutPriority(-1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .clipped() // safety net: never bleed past the allotted width
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { availableWidth = $0 }

            Button(action: createSpace) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(NavButtonStyle())
            .foregroundStyle(.primary)
            .layoutPriority(1) // plus button never gets squeezed out
            .help("New space")
        }
    }
}

private enum SpaceStripMode {
    case normal, compact

    static func determine(count: Int, width: CGFloat) -> SpaceStripMode {
        guard count > 0 else { return .normal }
        let buttonSize: CGFloat = 32
        let minSpacing: CGFloat = 4
        let normalMinWidth = CGFloat(count) * buttonSize + CGFloat(max(0, count - 1)) * minSpacing
        return width >= normalMinWidth ? .normal : .compact
    }
}

private struct MacSpaceChip: View {
    let space: Space
    let isSelected: Bool
    let compact: Bool
    let action: () -> Void

    private let dotSize: CGFloat = 6

    var body: some View {
        Button(action: action) {
            spaceIcon
                .opacity(isSelected ? 1.0 : 0.7)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SpaceChipButtonStyle())
        .foregroundStyle(.primary)
        .layoutPriority(isSelected ? 2 : 0) // active chip never shrinks below 32
        .help(space.name)
    }

    @ViewBuilder
    private var spaceIcon: some View {
        if compact && !isSelected {
            Circle()
                .fill(.primary.opacity(0.45))
                .frame(width: dotSize, height: dotSize)
        } else {
            Text(space.emoji.isEmpty ? "✦" : space.emoji)
                .font(.system(size: 15))
        }
    }
}

/// Port of Nook's `SpaceListItemButtonStyle`. Key detail: `frame(maxWidth: size)`
/// instead of `frame(width: size)` lets the chip shrink when the row is tight,
/// preventing overflow into the editor area.
private struct SpaceChipButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    private let size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
            configuration.label
                .foregroundStyle(.primary)
        }
        .frame(height: size)
        .frame(maxWidth: size)
        .opacity(isEnabled ? 1.0 : 0.3)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isHovering || isPressed { return colorScheme == .dark ? 0.20 : 0.10 }
        return 0
    }
}

/// Lifted straight from Nook (`NavButtonStyle`): 32pt square, 8pt radius,
/// hover/press tint, smooth scale.
struct NavButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering: Bool = false

    private let size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.primary.opacity(backgroundOpacity(isPressed: configuration.isPressed)))
                .frame(width: size, height: size)

            configuration.label
                .foregroundStyle(.primary)
        }
        .opacity(isEnabled ? 1.0 : 0.3)
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { hovering in isHovering = hovering }
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0 }
        if isHovering || isPressed { return colorScheme == .dark ? 0.20 : 0.10 }
        return 0
    }
}

// MARK: - Notes column (sections only)

private struct MacSpaceNotesColumn: View {
    @Environment(\.colorScheme) private var colorScheme

    let space: Space
    let notes: [Note]
    let folders: [Folder]
    let selectedNoteID: UUID?
    let searchText: String
    let selectNote: (Note) -> Void
    let createNote: () -> Void
    let session: CrossTierDragSession
    @Binding var isDragging: Bool
    @Binding var dragTarget: NoteDropTarget?
    let isActiveSpace: Bool

    private var hasRandomItems: Bool {
        !randomNotes.isEmpty || !randomFolders.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(space.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named("notes-column")).maxY
                } action: { newValue in
                    if isActiveSpace { session.spaceNameMaxY = newValue }
                }

            scrollContent
        }
    }

    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                MacSidebarGroup(
                    space: space,
                    allNotes: notes,
                    notes: pinnedNotes,
                    folders: pinnedFolders,
                    selectedNoteID: selectedNoteID,
                    dragTarget: $dragTarget,
                    isDragging: $isDragging,
                    selectNote: selectNote,
                    tier: .pinned,
                    session: session,
                    isActiveSpace: isActiveSpace
                )

                // Hairline separator between the Pinned area and the loose
                // Notes section. Always visible, regardless of whether either
                // tier has items — keeps the layout anchored.
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                NewNoteRow(action: createNote)
                    .padding(.horizontal, 0)
                    .padding(.top, 2)
                    .padding(.bottom, 4)

                MacSidebarGroup(
                    space: space,
                    allNotes: notes,
                    notes: randomNotes,
                    folders: randomFolders,
                    selectedNoteID: selectedNoteID,
                    dragTarget: $dragTarget,
                    isDragging: $isDragging,
                    selectNote: selectNote,
                    tier: .random,
                    session: session,
                    isActiveSpace: isActiveSpace
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 12)
            // Single animation source for the outer column layout: animates
            // the separator's vertical position (and every sibling's), so
            // when a tier grows or shrinks during/after a drag, the
            // separator slides smoothly instead of teleporting.
            .animation(.spring(response: 0.18, dampingFraction: 0.82),
                       value: columnLayoutKey)
        }
        .scrollIndicators(.hidden)
    }

    private var columnLayoutKey: String {
        let dragID = session.draggedNoteID?.uuidString ?? ""
        let srcTier = session.sourceTier?.rawValue ?? ""
        let curTier = session.currentTier?.rawValue ?? ""
        return "\(dragID)|\(srcTier)|\(curTier)|\(pinnedNotes.count)|\(randomNotes.count)"
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func matches(_ note: Note) -> Bool {
        guard !query.isEmpty else { return true }
        return note.title.lowercased().contains(query)
            || note.bodyMarkdown.lowercased().contains(query)
    }

    private var favoriteNotes: [Note] {
        notes
            .filter { $0.tier == .favorite && matches($0) }
            .sorted(by: noteSort)
    }

    private var pinnedNotes: [Note] { notesFor(tier: .pinned) }
    private var randomNotes: [Note] { notesFor(tier: .random) }
    private var pinnedFolders: [Folder] { foldersFor(tier: .pinned) }
    private var randomFolders: [Folder] { foldersFor(tier: .random) }

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private func notesFor(tier: NoteTier) -> [Note] {
        notes
            .filter { $0.tier == tier && $0.space?.id == space.id && $0.folder == nil && matches($0) }
            .sorted(by: noteSort)
    }

    private func foldersFor(tier: NoteTier) -> [Folder] {
        folders
            .filter { $0.tier == tier && $0.space?.id == space.id && $0.parent == nil }
            .sorted { $0.sortIndex == $1.sortIndex ? $0.createdAt < $1.createdAt : $0.sortIndex < $1.sortIndex }
    }
}

private struct MacSidebarSectionLabel: View {
    let title: String
    let count: Int
    var isExpanded: Bool?
    var toggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            if let isExpanded, let toggle {
                Button(action: toggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
    }
}

private struct NewNoteRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .foregroundStyle(.primary.opacity(0.78))

            Text("New Note")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary.opacity(isHovering ? (colorScheme == .dark ? 0.12 : 0.06) : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }
}

private struct MacEssentialsRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.modelContext) private var modelContext
    let notes: [Note]
    let space: Space
    let allNotes: [Note]
    let selectedNoteID: UUID?
    @Binding var dragTarget: NoteDropTarget?
    @Binding var isDragging: Bool
    let selectNote: (Note) -> Void
    let session: CrossTierDragSession

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private var isCrossTierTarget: Bool {
        session.isActive
            && session.sourceTier != .favorite
            && session.currentTier == .favorite
    }

    private let rowHeight: CGFloat = 35

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 7)], spacing: 7) {
            ForEach(Array(notes.prefix(8).enumerated()), id: \.element.id) { index, note in
                let isSelected = selectedNoteID == note.id
                let isSource = session.draggedNoteID == note.id && session.sourceTier == .favorite

                VStack(alignment: .leading, spacing: 8) {
                    MacNoteMiniIcon(note: note, size: 24)
                    Text(note.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                }
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                .padding(8)
                .background(isSelected ? spaceColor.opacity(0.85) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.white.opacity(0.30) : Color.primary.opacity(0.06), lineWidth: 1)
                }
                .opacity(isSource ? 0 : 1)
                .contentShape(Rectangle())
                .onTapGesture { selectNote(note) }
                .gesture(tileDragGesture(for: note, at: index))
            }
        }
        .padding(2)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(spaceColor.opacity(isCrossTierTarget ? 0.65 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.15), value: isCrossTierTarget)
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            session.tierFrames[.favorite] = newFrame
        }
        .onAppear { session.noteCountsByTier[.favorite] = notes.count }
        .onChange(of: notes.count) { _, newValue in
            session.noteCountsByTier[.favorite] = newValue
        }
    }

    /// Essentials grid is a 2D layout, so we don't run any within-grid
    /// reorder — the tile just follows the cursor while dragging. On release,
    /// if the cursor sits in another tier, perform a demote.
    private func tileDragGesture(for note: Note, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedNoteID == nil {
                    session.draggedNoteID = note.id
                    session.sourceTier = .favorite
                    session.sourceIndex = index
                    session.currentTier = .favorite
                    session.currentIndex = index
                    // Anchor the floating ghost to a row tier's horizontal
                    // center so that, once it morphs into a row, it sits in
                    // exactly the same X column as a normal Pinned/Notes
                    // drag — not pushed against the left edge by wherever
                    // the cursor happened to grab inside the grid tile.
                    let rowMidX = session.tierFrames[.random]?.midX
                        ?? session.tierFrames[.pinned]?.midX
                        ?? value.startLocation.x
                    session.sourceRowCenter = CGPoint(x: rowMidX, y: value.startLocation.y)
                    session.noteCountsByTier[.favorite] = notes.count
                    isDragging = true
                }
                session.cursorY = value.location.y
                session.translation = CGSize(width: 0, height: value.translation.height)
                session.updateTarget(rowHeight: rowHeight)
            }
            .onEnded { _ in commitTileDrag() }
    }

    private func commitTileDrag() {
        guard let id = session.draggedNoteID,
              let source = allNotes.first(where: { $0.id == id }),
              let dest = session.currentTier else {
            wipe()
            return
        }
        let destIndex = session.currentIndex
        let crossTier = dest != .favorite

        let destFrame = session.tierFrames[dest] ?? .zero
        let targetCenterY = destFrame.minY + CGFloat(destIndex) * rowHeight + rowHeight / 2
        let targetTranslationY = targetCenterY - session.sourceRowCenter.y

        withAnimation(.spring(response: 0.16, dampingFraction: 0.88)) {
            session.translation = CGSize(width: 0, height: targetTranslationY)
        } completion: {
            if crossTier {
                withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                    performDemote(to: dest, destIndex: destIndex, noteID: id)
                }
            }
            // Defer session.reset so `@Query` has a chance to refresh
            // `favoriteNotes` first. Otherwise `isSource` flips to false
            // (because session.draggedNoteID becomes nil) while the
            // source tile is still in `notes`, causing the tile to flash
            // visible at opacity 1 before the grid is removed.
            DispatchQueue.main.async {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.reset()
                }
                isDragging = false
            }
        }
    }

    private func performDemote(to dest: NoteTier, destIndex: Int, noteID: UUID) {
        guard let source = allNotes.first(where: { $0.id == noteID }) else { return }
        source.tier = dest
        source.space = space
        source.folder = nil

        let destExisting = allNotes
            .filter { $0.tier == dest && $0.space?.id == space.id && $0.folder == nil && $0.id != noteID }
            .sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        var destReordered = destExisting
        let insertIdx = min(destIndex, destReordered.count)
        destReordered.insert(source, at: insertIdx)
        for (i, n) in destReordered.enumerated() { n.manualSortIndex = i }
        source.updatedAt = Date()
        try? modelContext.save()
    }

    private func wipe() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            session.reset()
        }
        isDragging = false
    }
}

/// Shared drag-over state for the entire notes column. Identifies which row
/// (or tier-end slot) the dragged item is currently hovering, so we can show
/// a precise drop indicator before commit. Used by the cross-tier
/// `.draggable`-based system.
struct NoteDropTarget: Equatable {
    enum Anchor: Equatable {
        case beforeRow(UUID)
        case tierEnd(NoteTier)
    }
    let tier: NoteTier
    let anchor: Anchor
}

/// Per-tier drag state for the live in-place reorder system. Each
/// `MacSidebarGroup` owns one; while non-nil the dragged row follows the
/// cursor via `translation.height` and sibling rows in the same tier shift
/// by ±rowHeight to reveal where the drop will land.
struct WithinTierDrag: Equatable {
    let noteID: UUID
    let startIndex: Int
    var currentIndex: Int
    var translation: CGSize
}

/// Lightweight shared session for detecting cross-tier drag intent. The
/// within-tier reorder still runs inside `MacSidebarGroup` as before; this
/// session is only consulted to (a) suppress the local reshuffle when the
/// cursor has left the source tier, (b) highlight the destination tier, and
/// (c) decide on release whether to commit a cross-tier move. No phantom
/// slots, no floating overlay — keeps the visual model identical to the
/// within-tier system you signed off on.
@Observable
@MainActor
final class CrossTierDragSession {
    // Source identity
    var draggedNoteID: UUID? = nil
    var sourceTier: NoteTier? = nil
    var sourceIndex: Int = 0
    var sourceRowCenter: CGPoint = .zero

    // Live cursor state
    var cursorY: CGFloat? = nil
    var translation: CGSize = .zero

    // Live target (where the row would land if released right now)
    var currentTier: NoteTier? = nil
    var currentIndex: Int = 0

    // Tier geometry / counts, populated by each MacSidebarGroup.
    var tierFrames: [NoteTier: CGRect] = [:]
    var noteCountsByTier: [NoteTier: Int] = [:]

    // Bottom edge of the active column's space-name label, in
    // "notes-column" coords. Used as the threshold for showing the
    // "Add to Essentials" banner — cursor must rise above it to trigger.
    var spaceNameMaxY: CGFloat = 0

    var isActive: Bool { draggedNoteID != nil }

    var isCrossTier: Bool {
        guard let s = sourceTier, let c = currentTier else { return false }
        return s != c
    }

    /// Recomputes `currentTier` and `currentIndex` from the live cursor.
    /// The actual sibling-row animation is provided by `.animation(value:)`
    /// on the consuming views — no `withAnimation` here would just double
    /// up and make things feel laggy.
    func updateTarget(rowHeight: CGFloat) {
        guard let y = cursorY else { return }

        // Pick the tier whose frame is *closest* to the cursor — exact
        // containment first, otherwise minimum vertical distance. Avoids
        // the dragged note staying classified as its source tier when the
        // cursor lands in a gap between sections (e.g., separator + New
        // Note row, which belong to no tier).
        var bestTier: NoteTier? = nil
        var bestDistance: CGFloat = .greatestFiniteMagnitude
        for tier in [NoteTier.favorite, .pinned, .random] {
            guard let frame = tierFrames[tier] else { continue }
            let distance: CGFloat
            if y >= frame.minY, y <= frame.maxY {
                distance = 0
            } else if y < frame.minY {
                distance = frame.minY - y
            } else {
                distance = y - frame.maxY
            }
            if distance < bestDistance {
                bestDistance = distance
                bestTier = tier
            }
        }
        let newTier = bestTier ?? sourceTier
        guard let target = newTier else { return }

        let frame = tierFrames[target] ?? .zero
        let yInTier = max(0, y - frame.minY)
        let baseCount = noteCountsByTier[target] ?? 0
        let effective = target == sourceTier ? max(1, baseCount) : (baseCount + 1)
        let raw = Int((yInTier / rowHeight).rounded(.down))
        let newIndex = min(max(0, raw), max(0, effective - 1))

        if currentTier != target || currentIndex != newIndex {
            currentTier = target
            currentIndex = newIndex
        }
    }

    func reset() {
        draggedNoteID = nil
        sourceTier = nil
        sourceIndex = 0
        sourceRowCenter = .zero
        cursorY = nil
        translation = .zero
        currentTier = nil
        currentIndex = 0
    }
}

/// Tier-filtered note arrays so the drag committer can rebuild any
/// destination tier's ordering without re-filtering inside `MacSidebarGroup`.
struct AllNotesByTier {
    let favorite: [Note]
    let pinned: [Note]
    let random: [Note]

    func notes(for tier: NoteTier) -> [Note] {
        switch tier {
        case .favorite: return favorite
        case .pinned: return pinned
        case .random: return random
        case .archived: return []
        }
    }
}

/// Shared cross-tier drag state. The dragged row's offset follows the cursor;
/// every other row in any tier computes its own offset from the same formula
/// (see `MacSidebarGroup.offset(forIndex:)`). Switching tiers happens by
/// hit-testing the cursor against each tier's frame.
struct NoteDragState: Equatable {
    let noteID: UUID
    let originalTier: NoteTier
    let originalIndex: Int
    var currentTier: NoteTier
    var currentIndex: Int
    var translation: CGSize
    var pointer: CGPoint           // in "notes-column" coords
    let startPointer: CGPoint
    /// Offset from the cursor to the source row's center at the moment the
    /// drag began. Used to anchor the floating overlay so it doesn't jump
    /// to the cursor on the first frame.
    let pointerDeltaFromRowCenter: CGSize
}

@Observable
@MainActor
final class NoteDragController {
    var state: NoteDragState? = nil
    var tierFrames: [NoteTier: CGRect] = [:]
    var noteCountsByTier: [NoteTier: Int] = [:]

    var isActive: Bool { state != nil }
    var isCrossTier: Bool {
        guard let s = state else { return false }
        return s.currentTier != s.originalTier
    }

    /// Recomputes `currentTier` and `currentIndex` from the live pointer.
    /// Wraps changes in a spring animation so sibling rows interpolate cleanly.
    /// Promotion *into* `.favorite` is disallowed (context-menu only) — only
    /// notes already in `.favorite` can target it.
    func updateTarget(rowHeight: CGFloat) {
        guard var s = state else { return }

        var newTier = s.currentTier
        for tier in [NoteTier.favorite, .pinned, .random] {
            if tier == .favorite && s.originalTier != .favorite { continue }
            if let frame = tierFrames[tier], frame.contains(s.pointer) {
                newTier = tier
                break
            }
        }

        let frame = tierFrames[newTier] ?? .zero
        let yInTier = max(0, s.pointer.y - frame.minY)
        let baseCount = noteCountsByTier[newTier] ?? 0
        let effective = newTier == s.originalTier ? max(1, baseCount) : (baseCount + 1)
        let raw = Int((yInTier / rowHeight).rounded(.down))
        let newIndex = min(max(0, raw), max(0, effective - 1))

        if s.currentTier != newTier || s.currentIndex != newIndex {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
                state?.currentTier = newTier
                state?.currentIndex = newIndex
            }
        }
    }
}

private struct MacSidebarGroup: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let space: Space
    let allNotes: [Note] // unfiltered — needed to look up cross-tier sources
    let notes: [Note]
    let folders: [Folder]
    let selectedNoteID: UUID?
    @Binding var dragTarget: NoteDropTarget?
    @Binding var isDragging: Bool
    let selectNote: (Note) -> Void
    let tier: NoteTier
    let session: CrossTierDragSession
    var isActiveSpace: Bool = true

    private let rowHeight: CGFloat = 35 // 32pt row + 3pt spacing

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    private var isSourceTier: Bool { session.sourceTier == tier }
    private var isCurrentTier: Bool { session.currentTier == tier }

    var body: some View {
        LazyVStack(spacing: 3) {
            ForEach(folders) { folder in
                MacFolderRow(folder: folder, space: space, selectedNoteID: selectedNoteID, selectNote: selectNote)
            }

            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                let isSource = session.draggedNoteID == note.id && isSourceTier

                MacNoteRow(
                    note: note,
                    space: space,
                    isSelected: selectedNoteID == note.id,
                    showDropIndicator: false,
                    indicatorColor: spaceColor,
                    selectNote: selectNote
                )
                // Source row collapses out of layout when the cursor has
                // moved into another tier (so this tier's rows close the
                // gap). Within-tier, slot is preserved so the unified offset
                // formula can shift siblings around it.
                .opacity(isSource ? 0 : 1)
                .frame(height: (isSource && session.isCrossTier) ? 0 : nil)
                .offset(y: offset(forIndex: index))
                .gesture(liveDragGesture(for: note, at: index))
            }
            .animation(.spring(response: 0.18, dampingFraction: 0.82),
                       value: dragSignature)

            tierEndDropZone
        }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("notes-column"))
        } action: { newFrame in
            // Only the active (centered) column reports tier frames so
            // off-screen columns don't overwrite the live geometry.
            if isActiveSpace { session.tierFrames[tier] = newFrame }
        }
        .onAppear {
            if isActiveSpace { session.noteCountsByTier[tier] = notes.count }
        }
        .onChange(of: notes.count) { _, newValue in
            if isActiveSpace { session.noteCountsByTier[tier] = newValue }
        }
        .onChange(of: isActiveSpace) { _, newValue in
            // When this column becomes the active one (after a swipe),
            // refresh its frames and counts so the session is in sync.
            if newValue {
                session.noteCountsByTier[tier] = notes.count
            }
        }
    }

    /// Single value that captures any state change that should re-trigger
    /// the row-shuffle animation. Used as the `value:` for `.animation(...)`.
    private var dragSignature: String {
        let st = session.sourceTier?.rawValue ?? "_"
        let ct = session.currentTier?.rawValue ?? "_"
        return "\(st)|\(session.sourceIndex)|\(ct)|\(session.currentIndex)"
    }

    /// Unified vertical offset for the row at `index` in this tier.
    ///
    /// Source tier within-tier reorder: shift siblings to open a gap at
    /// `currentIndex` (existing within-tier behavior).
    ///
    /// Source tier cross-tier mode: source row collapses out of layout via
    /// `.frame(height: 0)`, so siblings flow up naturally. Offsets here are 0.
    ///
    /// Destination tier (different from source): push every row at
    /// `currentIndex` or later down by `rowHeight` so the dragged row has a
    /// visible landing slot — identical to the within-tier gap.
    private func offset(forIndex i: Int) -> CGFloat {
        guard session.isActive else { return 0 }

        // After the data commit but before the session is wiped, the dragged
        // note already lives in its destination tier's `notes` array at the
        // exact slot the ghost finished animating to. Once that's the case,
        // every offset should be 0 so nothing visually re-shuffles when the
        // session finally resets.
        if let id = session.draggedNoteID, notes.contains(where: { $0.id == id }), !isSourceTier {
            return 0
        }

        if isSourceTier {
            if i == session.sourceIndex { return 0 } // source row, will be hidden
            if session.isCrossTier {
                // Source row is collapsed (height 0) but its 3pt
                // LazyVStack spacing slot is still in layout. After commit
                // the row is gone entirely and that spacing collapses,
                // pulling every row below source up by 3pt — visible jitter
                // at release. Pre-shift those rows by -3 during the drag
                // so they're already at their post-commit positions.
                if let id = session.draggedNoteID,
                   notes.contains(where: { $0.id == id }),
                   i > session.sourceIndex {
                    return -3
                }
                return 0
            }
            // Within-tier reshuffle
            let s = session.sourceIndex
            let c = session.currentIndex
            if c > s, i > s, i <= c { return -rowHeight }
            if c < s, i >= c, i < s { return rowHeight }
            return 0
        }

        if isCurrentTier {
            return i >= session.currentIndex ? rowHeight : 0
        }

        return 0
    }

    private func liveDragGesture(for note: Note, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("notes-column"))
            .onChanged { value in
                if session.draggedNoteID == nil {
                    session.draggedNoteID = note.id
                    session.sourceTier = tier
                    session.sourceIndex = index
                    session.currentTier = tier
                    session.currentIndex = index
                    let tierFrame = session.tierFrames[tier] ?? .zero
                    session.sourceRowCenter = CGPoint(
                        x: tierFrame.midX,
                        y: tierFrame.minY + CGFloat(index) * rowHeight + rowHeight / 2
                    )
                    session.noteCountsByTier[tier] = notes.count
                    isDragging = true
                }
                session.cursorY = value.location.y
                session.translation = CGSize(width: 0, height: value.translation.height)
                session.updateTarget(rowHeight: rowHeight)
            }
            .onEnded { _ in commitDrag() }
    }

    /// Unified release path: animate the floating ghost (via
    /// `session.translation`) to sit exactly over the destination slot, then
    /// commit the data and clear the session non-animated. Identical for
    /// within-tier reorder and cross-tier promotion/demotion.
    private func commitDrag() {
        guard let id = session.draggedNoteID,
              let source = allNotes.first(where: { $0.id == id }),
              let dest = session.currentTier else {
            wipe()
            return
        }
        let destIndex = session.currentIndex
        let crossTier = dest != session.sourceTier

        // Where on the column should the ghost end up?
        let destFrame = session.tierFrames[dest] ?? .zero
        let targetCenterY = destFrame.minY + CGFloat(destIndex) * rowHeight + rowHeight / 2
        let targetTranslationY = targetCenterY - session.sourceRowCenter.y

        withAnimation(.spring(response: 0.16, dampingFraction: 0.88)) {
            session.translation = CGSize(width: 0, height: targetTranslationY)
        } completion: {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.82)) {
                performMove(source: source, dest: dest, destIndex: destIndex, crossTier: crossTier)
            }
            DispatchQueue.main.async {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    session.reset()
                }
                isDragging = false
            }
        }
    }

    private func performMove(source: Note, dest: NoteTier, destIndex: Int, crossTier: Bool) {
        if crossTier {
            source.tier = dest
            source.space = dest == .favorite ? nil : space
            source.folder = nil
        }

        // Rebuild destination tier
        let destOthers: [Note] = dest == .favorite
            ? allNotes.filter { $0.tier == .favorite && $0.id != source.id }
            : allNotes.filter { $0.tier == dest && $0.space?.id == space.id && $0.folder == nil && $0.id != source.id }
        var destReordered = destOthers.sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
        let insertIdx = min(destIndex, destReordered.count)
        destReordered.insert(source, at: insertIdx)
        for (i, n) in destReordered.enumerated() { n.manualSortIndex = i }

        // If we left a different tier, renumber its remaining notes too.
        if crossTier, let srcTier = session.sourceTier {
            let srcOthers: [Note] = srcTier == .favorite
                ? allNotes.filter { $0.tier == .favorite && $0.id != source.id }
                : allNotes.filter { $0.tier == srcTier && $0.space?.id == space.id && $0.folder == nil && $0.id != source.id }
            let srcSorted = srcOthers.sorted { ($0.manualSortIndex ?? Int.max) < ($1.manualSortIndex ?? Int.max) }
            for (i, n) in srcSorted.enumerated() { n.manualSortIndex = i }
        }

        source.updatedAt = Date()
        try? modelContext.save()
    }

    private func wipe() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            session.reset()
        }
        isDragging = false
    }

    /// While this tier is a cross-tier destination AND the source row is
    /// not yet in our `notes` array, the drop zone reserves `rowHeight` of
    /// extra layout space — matching the post-commit layout (one more
    /// row). Once the row is committed (notes contains it), the expansion
    /// collapses to 0 since the real row now occupies that slot.
    private var tierEndExpansion: CGFloat {
        guard session.isActive, isCurrentTier, session.isCrossTier else { return 0 }
        if let id = session.draggedNoteID, notes.contains(where: { $0.id == id }) {
            return 0
        }
        return rowHeight
    }

    /// Source tier of a cross-tier drag: compensates for the
    /// `LazyVStack(spacing: 3)` slot around the collapsed source row.
    /// The compensation only applies while the row is still in `notes`
    /// (pre-commit). After commit removes it, the spacing slot is gone
    /// too — no contraction needed.
    private var tierEndContraction: CGFloat {
        guard session.isActive, isSourceTier, session.isCrossTier else { return 0 }
        if let id = session.draggedNoteID, notes.contains(where: { $0.id == id }) {
            return 3
        }
        return 0
    }

    @ViewBuilder
    private var tierEndDropZone: some View {
        let isTarget = dragTarget == NoteDropTarget(tier: tier, anchor: .tierEnd(tier))
        Color.clear
            .frame(height: max(0, 16 + tierEndExpansion - tierEndContraction))
            .animation(.spring(response: 0.18, dampingFraction: 0.82), value: tierEndExpansion)
            .animation(.spring(response: 0.18, dampingFraction: 0.82), value: tierEndContraction)
            .overlay(alignment: .top) {
                if isTarget {
                    Capsule()
                        .fill(spaceColor.opacity(0.85))
                        .frame(height: 2)
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: DraggedItemTransfer.self) { items, _ in
                handleDrop(items: items, before: nil)
                return true
            } isTargeted: { targeted in
                if targeted {
                    dragTarget = NoteDropTarget(tier: tier, anchor: .tierEnd(tier))
                } else if dragTarget == NoteDropTarget(tier: tier, anchor: .tierEnd(tier)) {
                    dragTarget = nil
                }
            }
    }

    /// Cross-tier-aware drop handler. If `before` is nil, append to tier.
    private func handleDrop(items: [DraggedItemTransfer], before destination: Note?) {
        defer { dragTarget = nil }
        guard let item = items.first, item.kind == .note else { return }
        guard let source = allNotes.first(where: { $0.id == item.id }) else { return }
        guard source.id != destination?.id else { return }

        // Update tier / space / folder so the move sticks across sections.
        source.tier = tier
        if tier == .favorite {
            // Favorites are global — clear the space.
            source.space = nil
        } else {
            source.space = space
        }
        source.folder = nil

        // Rebuild the tier's ordered list (excluding the dragged note), then
        // insert at the target position; re-number manualSortIndex.
        var reordered = notes.filter { $0.id != source.id }
        if let destination, let destIdx = reordered.firstIndex(where: { $0.id == destination.id }) {
            reordered.insert(source, at: destIdx)
        } else {
            reordered.append(source)
        }
        for (idx, n) in reordered.enumerated() { n.manualSortIndex = idx }
        source.updatedAt = Date()
        try? modelContext.save()
    }
}

private struct MacFolderRow: View {
    let folder: Folder
    let space: Space
    let selectedNoteID: UUID?
    let selectNote: (Note) -> Void

    @State private var isExpanded = true

    private var notes: [Note] {
        (folder.notes ?? []).sorted(by: noteSort)
    }

    var body: some View {
        VStack(spacing: 2) {
            Button {
                withAnimation(.smooth(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 22)
                        .foregroundStyle(.secondary)

                    Text(folder.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text("\(notes.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(notes) { note in
                    MacNoteRow(note: note, space: space, isSelected: selectedNoteID == note.id, selectNote: selectNote)
                        .padding(.leading, 18)
                }
            }
        }
    }
}

private struct MacNoteRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    let note: Note
    let space: Space
    let isSelected: Bool
    var showDropIndicator: Bool = false
    var indicatorColor: Color = .accentColor
    let selectNote: (Note) -> Void

    @State private var isHovering = false

    private var spaceColor: Color {
        Color.spaceColor(lightHex: space.colorHex, darkHex: space.darkColorHex, scheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 9) {
            MacNoteMiniIcon(note: note, size: 20, tintedWhite: isSelected)

            Text(note.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if isHovering {
                Button(action: deleteNote) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.primary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.86))
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
        }
        .overlay {
            // A 1pt rim on the selected row gives the colored pill some
            // definition against the sidebar tint — without leaning on the
            // old left-edge capsule.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.white.opacity(0.18) : .clear,
                    lineWidth: 1
                )
        }
        .shadow(
            color: isSelected ? spaceColor.opacity(0.32) : .clear,
            radius: isSelected ? 6 : 0, x: 0, y: 2
        )
        .overlay(alignment: .top) {
            if showDropIndicator {
                Capsule()
                    .fill(indicatorColor.opacity(0.9))
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: -2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectNote(note) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", systemImage: "doc.text") { selectNote(note) }
            Divider()
            Button("Make Essential", systemImage: "star.fill") { promote(to: .favorite) }
            Button("Pin", systemImage: "pin.fill") { promote(to: .pinned) }
            Button("Move to Notes", systemImage: "tray") { promote(to: .random) }
            Divider()
            Button("Duplicate", systemImage: "plus.square.on.square") { duplicateNote() }
            Button("Archive", systemImage: "archivebox") { archiveNote() }
            Button("Delete", systemImage: "trash", role: .destructive) { deleteNote() }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            // Slightly deeper than before so the white text reads well and
            // the row reads as a solid, cohesive pill (no accent capsule
            // needed for affordance).
            return spaceColor.opacity(colorScheme == .dark ? 0.95 : 0.92)
        }
        return isHovering ? Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.07) : Color.clear
    }

    private func promote(to tier: NoteTier) {
        try? NoteService(context: modelContext).promote(note, to: tier, currentSpace: space)
    }

    private func archiveNote() {
        try? NoteService(context: modelContext).archive(note)
    }

    private func duplicateNote() {
        if let copy = try? NoteService(context: modelContext).duplicate(note) {
            selectNote(copy)
        }
    }

    private func deleteNote() {
        try? NoteService(context: modelContext).delete(note)
    }
}

private struct MacNoteMiniIcon: View {
    let note: Note
    let size: CGFloat
    var tintedWhite: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tintedWhite ? Color.white.opacity(0.22) : Color.primary.opacity(0.10))
            .overlay {
                Text(String(note.title.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "N"))
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(tintedWhite ? Color.white : Color.secondary)
            }
            .frame(width: size, height: size)
    }
}

private func noteSort(_ lhs: Note, _ rhs: Note) -> Bool {
    switch (lhs.manualSortIndex, rhs.manualSortIndex) {
    case let (.some(left), .some(right)):
        return left == right ? lhs.createdAt < rhs.createdAt : left < right
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    case (.none, .none):
        return lhs.createdAt < rhs.createdAt
    }
}
#endif
