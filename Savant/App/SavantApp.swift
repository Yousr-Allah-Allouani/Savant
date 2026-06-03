import SwiftData
import SwiftUI

@main
struct SavantApp: App {
    @State private var appState = AppState()

    private let modelContainer: ModelContainer = {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        // CloudKit syncs the iCloud.app.savant private database across the iOS and
        // macOS targets (both declare that container in their entitlements).
        // Enabled on device; kept off in the simulator (no reliable silent push,
        // flaky iCloud account state) and during UI tests.
        let cloudKitEnabled = !isUITesting && !Self.isSimulator
        do {
            return try PersistenceController.makeModelContainer(
                inMemory: isUITesting,
                cloudKitEnabled: cloudKitEnabled
            )
        } catch {
            fatalError("Unable to create SwiftData container: \(error)")
        }
    }()

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    init() {
        #if os(iOS)
        BackgroundTaskScheduler.register(modelContainer: modelContainer)
        BackgroundTaskScheduler.schedule()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MacRootView()
                .environment(appState)
            #else
            RootView()
                .environment(appState)
            #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
    }
}

#if os(macOS)
import AppKit

/// Configures the hosting NSWindow for full-size content with transparent titlebar.
/// Toggles traffic-light visibility based on whether the sidebar is shown — when
/// the sidebar is hidden, the lights hide too (Nook-style).
///
/// Window dragging by background is disabled because it conflicts with the
/// sidebar resizer hit area when the app isn't fullscreen.
struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.styleMask.insert(.fullSizeContentView)
        // The actual window-attached buttons are always hidden. The sidebar
        // hosts a separate set of standard buttons (created with
        // standardWindowButton(_, for: .titled)) inside its header, so the
        // lights live with the sidebar and disappear when it collapses.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.minSize = NSSize(width: 720, height: 520)
        window.contentMinSize = NSSize(width: 720, height: 520)
    }
}

/// Custom traffic-light buttons drawn in SwiftUI. Lifted from Nook's
/// `MacButtonsView`/`MacButtonsViewModel`: idle = gray dots, hover = colored
/// red/yellow/green with icons. Forwards close/miniaturize/zoom to the key
/// window directly. Because they're SwiftUI views inside the sidebar, they
/// disappear with the sidebar.
struct EmbeddedTrafficLights: View {
    @State private var isGroupHovered = false

    // Layout values lifted verbatim from Nook's MacButtonsView /
    // MacButtonsViewModel: 12.5pt circles, 7.5pt spacing, 70pt-wide
    // container, leading padding = height/3 - 2.
    var body: some View {
        GeometryReader { geo in
            HStack {
                HStack(alignment: .center, spacing: 7.5) {
                    TrafficLightButton(kind: .close, groupHovered: isGroupHovered)
                    TrafficLightButton(kind: .minimize, groupHovered: isGroupHovered)
                    TrafficLightButton(kind: .fullscreen, groupHovered: isGroupHovered)
                }
                .onHover { isGroupHovered = $0 }
                Spacer(minLength: 0)
            }
            .frame(height: geo.size.height)
            .padding(.leading, 12)
        }
        .frame(width: 76)
    }
}

private struct TrafficLightButton: View {
    enum Kind { case close, minimize, fullscreen }
    let kind: Kind
    let groupHovered: Bool

    var body: some View {
        Button(action: perform) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .frame(width: 12.5, height: 12.5)
                if groupHovered {
                    Image(systemName: iconName)
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(.black.opacity(0.55))
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var fillColor: Color {
        if !groupHovered { return Color.primary.opacity(0.22) }
        switch kind {
        case .close:      return Color(red: 236/255, green: 106/255, blue: 94/255)
        case .minimize:   return Color(red: 254/255, green: 188/255, blue: 46/255)
        case .fullscreen: return Color(red: 40/255, green: 200/255, blue: 65/255)
        }
    }

    private var iconName: String {
        switch kind {
        case .close:      return "xmark"
        case .minimize:   return "minus"
        case .fullscreen: return "arrow.up.left.and.arrow.down.right"
        }
    }

    private func perform() {
        guard let window = NSApp.keyWindow else { return }
        switch kind {
        case .close:      window.performClose(nil)
        case .minimize:   window.miniaturize(nil)
        case .fullscreen: window.toggleFullScreen(nil)
        }
    }
}
#endif

#if os(iOS)
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        @Bindable var appState = appState

        Group {
            if hasCompletedOnboarding || ProcessInfo.processInfo.arguments.contains("--skip-onboarding") {
                SpacePagerView()
                    .task {
                        try? SampleDataSeeder.ensureInitialSpaces(in: modelContext)
                        if ProcessInfo.processInfo.arguments.contains("--screenshot-data") {
                            try? SampleDataSeeder.ensureScreenshotContent(in: modelContext)
                        }
                    }
            } else {
                OnboardingFlow { selectedPresetIDs in
                    try? SampleDataSeeder.ensureInitialSpaces(in: modelContext, selectedPresetIDs: selectedPresetIDs)
                    hasCompletedOnboarding = true
                }
            }
        }
        .sheet(item: $appState.presentedSheet) { sheet in
            switch sheet {
            case .switcher:
                SpaceSwitcherSheet()
                    .presentationDetents([.large])
            case .newSpace:
                NewSpaceFlowView()
                    .presentationDetents([.large])
            case .search(let space):
                SearchSheet(initialSpace: space)
                    .presentationDetents([.large])
            case .settings:
                SettingsSheet()
            case .noteRead(let note):
                NoteReadSheet(note: note)
                    .presentationDetents([.fraction(0.75), .large])
            case .tidyReview(let run):
                TidyReviewSheet(run: run)
                    .presentationDetents([.large])
            }
        }
        .fullScreenCover(item: $appState.presentedFullScreen) { fullScreen in
            switch fullScreen {
            case .noteEdit(let note):
                NoteEditPage(note: note)
            }
        }
    }
}
#endif
