import SwiftUI

struct OnboardingFlow: View {
    let complete: (Set<String>) -> Void

    @State private var page = 0
    @State private var selectedPresetIDs = SpacePresetLibrary.defaultFirstLaunchIDs

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                OnboardingIntroPage(
                    symbol: "square.and.pencil.circle.fill",
                    title: "Savant",
                    subtitle: "Empty your mind. Keep the few notes that matter."
                )
                .tag(0)

                OnboardingIntroPage(
                    symbol: "bubble.left.and.text.bubble.right.fill",
                    title: "Capture like a message",
                    subtitle: "The input bar is always waiting at the bottom of every space."
                )
                .tag(1)

                OnboardingIntroPage(
                    symbol: "sparkles",
                    title: "Tidy while you sleep",
                    subtitle: "Random notes can be grouped or archived locally with Foundation Models."
                )
                .tag(2)

                chooseSpacesPage
                    .tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            HStack {
                Button(page == 0 ? "Skip" : "Back") {
                    if page == 0 {
                        complete(selectedPresetIDs)
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            page -= 1
                        }
                    }
                }
                .buttonStyle(.glass)

                Spacer()

                Button(page == 3 ? "Start" : "Next") {
                    if page == 3 {
                        complete(selectedPresetIDs)
                    } else {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            page += 1
                        }
                    }
                }
                .buttonStyle(.glassProminent)
            }
            .padding(20)
        }
        .background(Color(hex: "#C8D5C0").ignoresSafeArea())
    }

    private var chooseSpacesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Choose your first spaces")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                Text("Personal and Work are selected by default. You can add or delete spaces later.")
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(SpacePresetLibrary.presets) { preset in
                        Button {
                            toggle(preset.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(preset.emoji)
                                    .font(.title)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name)
                                        .font(.system(.headline, design: .rounded))
                                    Text(selectedPresetIDs.contains(preset.id) ? "Selected" : "Tap to add")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: selectedPresetIDs.contains(preset.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedPresetIDs.contains(preset.id) ? .primary : .secondary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                    }
                }
            }
            .padding(24)
        }
    }

    private func toggle(_ id: String) {
        if selectedPresetIDs.contains(id), selectedPresetIDs.count > 1 {
            selectedPresetIDs.remove(id)
        } else {
            selectedPresetIDs.insert(id)
        }
    }
}

private struct OnboardingIntroPage: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 74, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }
            Spacer()
        }
        .padding(24)
    }
}
