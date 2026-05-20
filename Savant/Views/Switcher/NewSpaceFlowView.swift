import SwiftData
import SwiftUI

struct NewSpaceFlowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Space.sortIndex) private var spaces: [Space]

    @State private var selectedPreset: SpacePreset?
    @State private var step: Step = .choose
    @State private var name = ""
    @State private var emoji = "✦"
    @State private var lightHex = "#C8D5C0"
    @State private var darkHex = "#2A3328"
    @State private var description = ""
    @State private var draftProfile = ProfileExpanderService.fallback(description: "General notes and ideas.")
    @State private var isExpandingProfile = false

    enum Step {
        case choose
        case edit
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .choose:
                    presetGrid
                case .edit:
                    editForm
                }
            }
            .navigationTitle(step == .choose ? "New space" : "Space profile")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                if step == .edit {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Create", action: createSpace)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private var presetGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 142), spacing: 12)], spacing: 12) {
                ForEach(SpacePresetLibrary.presets) { preset in
                    Button {
                        load(preset)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(preset.emoji)
                                    .font(.largeTitle)
                                Spacer()
                                Circle()
                                    .fill(Color(hex: preset.lightHex))
                                    .frame(width: 28, height: 28)
                            }
                            Text(preset.name)
                                .font(.system(.headline, design: .rounded))
                            Text(preset.profile.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                }

                Button {
                    loadCustom()
                } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.largeTitle)
                        Text("Custom")
                            .font(.system(.headline, design: .rounded))
                        Text("Describe the notes this space should understand.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                    .padding(14)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .padding(20)
        }
    }

    private var editForm: some View {
        Form {
            Section("Basics") {
                TextField("Name", text: $name)
                TextField("Emoji", text: $emoji)
                HSLCircularPickerView(selectedLightHex: $lightHex, selectedDarkHex: $darkHex)
                    .padding(.vertical, 8)
            }

            Section("Description") {
                TextField(
                    "What kind of notes go in this space?",
                    text: $description,
                    axis: .vertical
                )
                .lineLimit(3...7)

                if selectedPreset == nil {
                    Button {
                        expandProfile()
                    } label: {
                        Label(isExpandingProfile ? "Expanding…" : "Continue", systemImage: "apple.intelligence")
                    }
                    .disabled(isExpandingProfile || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("AI Profile") {
                TextField("Summary", text: $draftProfile.summary, axis: .vertical)
                EditableStringList(title: "Include", items: $draftProfile.includeCriteria)
                EditableStringList(title: "Exclude", items: $draftProfile.excludeCriteria)
                EditableStringList(title: "Keywords", items: $draftProfile.keywords)
                EditableStringList(title: "Examples", items: $draftProfile.exampleSnippets)
                if let interpretation = draftProfile.aiInterpretation {
                    Text(interpretation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load(_ preset: SpacePreset) {
        selectedPreset = preset
        name = preset.name
        emoji = preset.emoji
        lightHex = preset.lightHex
        darkHex = preset.darkHex
        description = preset.profile.summary
        draftProfile = preset.profile
        step = .edit
    }

    private func loadCustom() {
        selectedPreset = nil
        name = ""
        emoji = "✦"
        lightHex = "#C8D5C0"
        darkHex = "#2A3328"
        description = ""
        draftProfile = ProfileExpanderService.fallback(description: "General notes and ideas.")
        step = .edit
    }

    private func expandProfile() {
        let description = description
        isExpandingProfile = true
        Task {
            let profile = await ProfileExpanderService().expand(description: description)
            draftProfile = profile
            isExpandingProfile = false
        }
    }

    private func createSpace() {
        let space = SpaceFactory.makeCustomSpace(
            name: name,
            emoji: emoji,
            colorHex: lightHex,
            darkColorHex: darkHex,
            sortIndex: spaces.count,
            profile: draftProfile
        )
        contextInsert(space)
    }

    private func contextInsert(_ space: Space) {
        modelContext.insert(space)
        try? modelContext.save()
        appState.selectedSpaceID = space.id
        dismiss()
    }
}

private struct EditableStringList: View {
    let title: String
    @Binding var items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { index, _ in
                TextField(title, text: binding(for: index))
            }
            Button("Add \(title.lowercased())", systemImage: "plus") {
                items.append("")
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index] : "" },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index] = newValue
            }
        )
    }
}
