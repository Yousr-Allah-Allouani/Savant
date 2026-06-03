import AppKit
import SwiftUI

#if os(macOS)

/// Native-feel icon picker for Space identity. Tabbed: SF Symbols vs
/// Emoji. Searchable, scrollable, with a "None" / clear option and a
/// "Show System Emoji…" escape hatch that opens macOS's character
/// palette. Replaces the toy 24-emoji grid that was previously here.
///
/// Storage convention: a `Space.emoji` string is either a single emoji
/// scalar (e.g. "🪴") OR an SF Symbol name (e.g. "leaf.fill"). The
/// helper `MacSpaceIcon` resolves which is which and renders correctly.
struct MacIconPicker: View {
    @Binding var selection: String      // empty = None
    let onSelect: () -> Void

    @State private var tab: Tab = .symbol
    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    enum Tab: String, CaseIterable { case symbol, emoji }

    var body: some View {
        VStack(spacing: 8) {
            // Tabs
            Picker("", selection: $tab) {
                Text("Symbols").tag(Tab.symbol)
                Text("Emoji").tag(Tab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.55))
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            // Grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 4), count: 8), spacing: 4) {
                    noneCell
                    ForEach(filteredItems, id: \.self) { item in
                        cell(item)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 304, height: 248)

            if tab == .emoji {
                Button {
                    NSApp.orderFrontCharacterPalette(nil)
                } label: {
                    Label("More from System…", systemImage: "ellipsis.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.65))
            }
        }
        .padding(10)
        .frame(width: 324)
        // Set the whole popover surface (incl. the arrow/beak) to one material
        // so the beak matches the picker rather than the default system tint.
        .presentationBackground(.regularMaterial)
        .onAppear {
            // Auto-derive starting tab from current selection so the user
            // doesn't have to flip if they previously chose a symbol.
            if MacSpaceIcon.isSFSymbolName(selection) { tab = .symbol }
            else if !selection.isEmpty { tab = .emoji }
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var noneCell: some View {
        Button {
            selection = ""
            onSelect()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                Image(systemName: "nosign")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.5))
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("None")
    }

    @ViewBuilder
    private func cell(_ item: String) -> some View {
        Button {
            selection = item
            onSelect()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selection == item ? Color.accentColor.opacity(0.85) : Color.clear)
                if tab == .symbol {
                    Image(systemName: item)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(selection == item ? .white : Color.primary)
                } else {
                    Text(item).font(.system(size: 17))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab == .symbol ? item : item)
    }

    private var filteredItems: [String] {
        let pool = tab == .symbol ? MacIconCatalog.symbols : MacIconCatalog.emojis
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return pool }
        if tab == .symbol {
            return pool.filter { $0.lowercased().contains(q) }
        }
        // Emoji search: match against the name we keep alongside (zip).
        return MacIconCatalog.emojiSearchPairs
            .filter { $0.1.contains(q) }
            .map { $0.0 }
    }
}

// MARK: - Icon resolution

enum MacSpaceIcon {
    /// Heuristic: SF Symbol names are ASCII + dots/underscores. Emoji
    /// contains at least one non-ASCII scalar.
    static func isSFSymbolName(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        // Emoji: any extended grapheme cluster with non-ASCII content.
        if s.unicodeScalars.contains(where: { !$0.isASCII }) { return false }
        // SF Symbol convention: lowercased, dots between words.
        return s.contains(".") || s.allSatisfy { $0.isLetter || $0 == "." }
    }

    @ViewBuilder
    static func view(_ value: String, size: CGFloat, fallback: String = "✦") -> some View {
        if value.isEmpty {
            Text(fallback).font(.system(size: size))
        } else if isSFSymbolName(value) {
            Image(systemName: value)
                .font(.system(size: size * 0.9, weight: .regular))
        } else {
            Text(value).font(.system(size: size))
        }
    }
}

// MARK: - Catalog

enum MacIconCatalog {
    /// Curated SF Symbols suited to space identity. Common categories:
    /// work, study, hobbies, organization, ideas, places, etc.
    static let symbols: [String] = [
        // Notes / ideas
        "lightbulb.fill", "sparkles", "brain.head.profile", "text.bubble.fill",
        "book.fill", "book.closed.fill", "books.vertical.fill", "graduationcap.fill",
        // Work
        "briefcase.fill", "case.fill", "building.2.fill", "person.2.fill",
        "calendar", "clock.fill", "timer", "checkmark.seal.fill",
        // Tasks
        "list.bullet", "list.bullet.rectangle.fill", "checklist", "checkmark.circle.fill",
        "flag.fill", "tag.fill", "bookmark.fill", "star.fill",
        // Home / life
        "house.fill", "fork.knife", "cup.and.saucer.fill", "wineglass.fill",
        "cart.fill", "bag.fill", "creditcard.fill", "dollarsign.circle.fill",
        // Health / fitness
        "heart.fill", "figure.run", "dumbbell.fill", "leaf.fill",
        // Travel / places
        "airplane", "car.fill", "tram.fill", "map.fill",
        "location.fill", "globe.americas.fill", "mountain.2.fill", "tent.fill",
        // Hobbies / creative
        "paintpalette.fill", "paintbrush.fill", "camera.fill", "music.note",
        "headphones", "guitars.fill", "gamecontroller.fill", "die.face.5.fill",
        // Nature
        "sun.max.fill", "moon.fill", "cloud.fill", "snowflake",
        "flame.fill", "drop.fill", "tree.fill", "pawprint.fill",
        // Tech / dev
        "terminal.fill", "chevron.left.forwardslash.chevron.right",
        "cpu.fill", "memorychip.fill", "server.rack", "antenna.radiowaves.left.and.right",
        // Communication
        "envelope.fill", "phone.fill", "bubble.left.fill", "video.fill",
        // Storage / org
        "folder.fill", "tray.full.fill", "archivebox.fill", "shippingbox.fill",
        // Symbols
        "circle.fill", "square.fill", "diamond.fill", "hexagon.fill",
        "infinity", "asterisk", "number", "questionmark.circle.fill",
        // Misc
        "gift.fill", "balloon.fill", "graduationcap", "trophy.fill",
        "globe", "newspaper.fill", "key.fill", "lock.fill"
    ]

    /// Emoji set: ~150 curated, organized for a notes-app context.
    static let emojis: [String] = MacIconCatalog.emojiSearchPairs.map { $0.0 }

    /// Pairs of (emoji, search-keywords) so search works.
    static let emojiSearchPairs: [(String, String)] = [
        // Smileys / mood
        ("😀", "smile happy face"), ("🙂", "smile face"), ("😉", "wink"),
        ("😎", "cool sunglasses"), ("🤔", "think thinking"), ("😴", "sleep tired"),
        ("😅", "sweat"), ("🥳", "party"), ("😇", "angel"),
        // Hands / body
        ("👋", "wave hi hello"), ("👍", "thumbs up"), ("👏", "clap"),
        ("🙏", "pray thanks"), ("💪", "muscle strong"), ("✌️", "peace"),
        // Hearts / love
        ("❤️", "heart love red"), ("🧡", "orange heart"), ("💛", "yellow heart"),
        ("💚", "green heart"), ("💙", "blue heart"), ("💜", "purple heart"),
        ("🖤", "black heart"), ("🤍", "white heart"), ("💖", "sparkling heart"),
        // Nature
        ("🌱", "seedling plant grow"), ("🌳", "tree"), ("🌲", "evergreen tree"),
        ("🌿", "leaf herb"), ("🍀", "clover luck"), ("🌷", "tulip flower"),
        ("🌸", "cherry blossom flower"), ("🌻", "sunflower"), ("🌺", "hibiscus flower"),
        // Sun / sky
        ("☀️", "sun sunny"), ("🌙", "moon night"), ("⭐️", "star"),
        ("✨", "sparkles"), ("🌟", "glowing star"), ("⚡️", "lightning bolt"),
        ("🔥", "fire flame"), ("❄️", "snow snowflake"), ("🌈", "rainbow"),
        // Food
        ("🍎", "apple fruit"), ("🍌", "banana"), ("🍓", "strawberry"),
        ("🍕", "pizza"), ("🍔", "burger"), ("🍣", "sushi"),
        ("🍜", "noodle ramen"), ("🍰", "cake"), ("🍫", "chocolate"),
        ("☕️", "coffee"), ("🍵", "tea"), ("🍷", "wine"),
        // Travel
        ("✈️", "airplane travel"), ("🚗", "car"), ("🚲", "bike bicycle"),
        ("🏔", "mountain"), ("🏖", "beach"), ("🗺", "map travel"),
        ("🌍", "earth globe world"), ("🚀", "rocket"), ("⛵️", "sailboat"),
        // Objects / activities
        ("📚", "books study"), ("📖", "book reading"), ("✏️", "pencil write"),
        ("📝", "note memo write"), ("📒", "notebook"), ("📅", "calendar"),
        ("🗓", "calendar spiral"), ("🎯", "target goal"), ("🎨", "art paint"),
        ("🎸", "guitar music"), ("🎵", "music note"), ("🎮", "gamepad"),
        ("📷", "camera"), ("💡", "idea bulb"), ("🔑", "key"),
        // Tech
        ("💻", "laptop computer"), ("🖥", "desktop computer"), ("⌨️", "keyboard"),
        ("🖱", "mouse"), ("📱", "phone mobile"), ("⚙️", "gear settings"),
        // Work
        ("💼", "briefcase work"), ("📊", "chart graph"), ("📈", "trend up"),
        ("📉", "trend down"), ("💰", "money bag"), ("🪙", "coin"),
        // Animals
        ("🐶", "dog puppy"), ("🐱", "cat"), ("🐰", "rabbit bunny"),
        ("🦊", "fox"), ("🐻", "bear"), ("🐼", "panda"),
        ("🐧", "penguin"), ("🦉", "owl"), ("🦋", "butterfly"),
        // Misc
        ("🎉", "party celebration"), ("🎁", "gift present"), ("🏆", "trophy winner"),
        ("🏠", "home house"), ("🏥", "hospital"), ("🏫", "school"),
        ("🚪", "door"), ("🛒", "cart shop"), ("🛁", "bath"),
        ("🧘", "yoga meditation"), ("🏃", "run"), ("🛏", "bed sleep")
    ]
}

#endif
