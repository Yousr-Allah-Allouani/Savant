import SwiftData
import SwiftUI

struct SpacePagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Space.sortIndex) private var spaces: [Space]
    @Query(sort: \Note.createdAt) private var notes: [Note]
    @Query(sort: \Folder.sortIndex) private var folders: [Folder]
    @Query(sort: \TidyRun.startedAt, order: .reverse) private var tidyRuns: [TidyRun]

    @State private var keyboardDismissRequest = 0
    @State private var isInputFocused = false

    var body: some View {
        @Bindable var appState = appState

        ZStack(alignment: .bottom) {
            Group {
                if let currentSpace {
                    SpaceMeshBackground(space: currentSpace)
                        .id(currentSpace.id)
                        .transition(.opacity)
                } else {
                    Color(hex: "#C8D5C0").ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.4), value: appState.selectedSpaceID)

            if spaces.isEmpty {
                EmptyWorkspaceView()
            } else {
                TabView(selection: $appState.selectedSpaceID) {
                    ForEach(spaces) { space in
                        SpaceView(
                            space: space,
                            spaces: spaces,
                            notes: notes,
                            folders: folders,
                            latestTidyRun: latestVisibleRun,
                            selectedIndex: selectedIndex,
                            selectSpaceAtIndex: selectSpace(at:),
                            tidyNow: { tidy(space) }
                        )
                        .tag(Optional(space.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea(edges: .top)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if isInputFocused {
                            dismissInputKeyboard()
                        }
                    }
                )
                .onAppear(perform: ensureSelection)
                .onChange(of: spaces.map(\.id)) { _, _ in
                    ensureSelection()
                }

                InputBarView(
                    currentSpace: currentSpace,
                    keyboardDismissRequest: keyboardDismissRequest,
                    isInputFocused: $isInputFocused
                )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .zIndex(2)
            }
        }
    }

    private var currentSpace: Space? {
        guard let selectedSpaceID = appState.selectedSpaceID else { return spaces.first }
        return spaces.first { $0.id == selectedSpaceID } ?? spaces.first
    }

    private var selectedIndex: Int {
        guard let currentSpace else { return 0 }
        return spaces.firstIndex(where: { $0.id == currentSpace.id }) ?? 0
    }

    private var latestVisibleRun: TidyRun? {
        tidyRuns.first { $0.completedAt != nil && !$0.bannerDismissed && ($0.notesArchived > 0 || $0.foldersCreated > 0) }
    }

    private func ensureSelection() {
        guard appState.selectedSpaceID == nil || !spaces.contains(where: { $0.id == appState.selectedSpaceID }) else { return }
        appState.selectedSpaceID = spaces.first?.id
    }

    private func selectSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            appState.selectedSpaceID = spaces[index].id
        }
    }

    private func tidy(_ space: Space) {
        Task { @MainActor in
            do {
                let run = try await TidyService(context: modelContext).tidy(
                    space: space,
                    notes: notes,
                    trigger: .manual
                )
                if run.notesProcessed > 0 || run.notesArchived > 0 || run.foldersCreated > 0 {
                    appState.presentedSheet = .tidyReview(run)
                }
            } catch {
                assertionFailure("Manual tidy failed: \(error)")
            }
        }
    }

    private func dismissInputKeyboard() {
        keyboardDismissRequest += 1
        isInputFocused = false
        dismissKeyboard()
    }
}

private struct EmptyWorkspaceView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.square.filled.on.square")
                .font(.system(size: 44, weight: .semibold))
            Text("Create your first space")
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text("Spaces give your notes a place to land.")
                .font(.body)
                .foregroundStyle(.secondary)
            GlassCapsuleButton {
                appState.presentedSheet = .newSpace
            } content: {
                Label("New space", systemImage: "plus")
            }
        }
        .padding(28)
        .multilineTextAlignment(.center)
    }
}
