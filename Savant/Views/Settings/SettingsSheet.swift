import SwiftData
import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("noteBodyFontSize") private var noteBodyFontSize = 17.0

    @Query private var notes: [Note]
    @Query(sort: \Space.sortIndex) private var spaces: [Space]

    var body: some View {
        NavigationStack {
            Form {
                Section("iCloud Sync") {
                    Label("Private CloudKit database enabled", systemImage: "icloud")
                    Text("Last local save: \(Date().formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                    Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { }
                }

                Section("Archive") {
                    NavigationLink {
                        ArchiveBrowserView()
                    } label: {
                        HStack {
                            Label("Browse archive", systemImage: "archivebox")
                            Spacer()
                            Text("\(archivedCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Slider(value: $noteBodyFontSize, in: 14...24, step: 1) {
                        Text("Note body size")
                    } minimumValueLabel: {
                        Text("A")
                            .font(.caption)
                    } maximumValueLabel: {
                        Text("A")
                            .font(.title3)
                    }
                }

                Section("Spaces") {
                    Picker("Default destination", selection: .constant(spaces.first?.id)) {
                        ForEach(spaces) { space in
                            Text("\(space.emoji) \(space.name)").tag(Optional(space.id))
                        }
                    }
                    Picker("Deletion fallback", selection: .constant(spaces.first?.id)) {
                        ForEach(spaces) { space in
                            Text("\(space.emoji) \(space.name)").tag(Optional(space.id))
                        }
                    }
                }

                Section("About") {
                    NavigationLink("Privacy") {
                        AboutView()
                    }
                    Text("Savant 1.0 (1)")
                    Text("AI tidy uses Foundation Models on device when available. Notes are not sent to a backend for AI processing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var archivedCount: Int {
        notes.filter { $0.tier == .archived }.count
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section("Privacy") {
                Text("Savant is designed around on-device processing. Foundation Models tidy and profile expansion run locally when the model is available. iCloud sync uses your private CloudKit database.")
            }
            Section("Contact") {
                Link("App support", destination: URL(string: "mailto:support@app.savant")!)
            }
        }
        .navigationTitle("About")
    }
}
