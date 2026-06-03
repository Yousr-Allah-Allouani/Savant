import SwiftData
import SwiftUI

#if os(macOS)

/// Mirrors Zen Browser's `nsZenWorkspaceCreation` (src/zen/spaces/ZenSpaceCreation.mjs)
/// — same vertical layout, same staggered entrance/exit, adapted to Savant's
/// Space model. Lives inside the sidebar column; the bottom space rail stays
/// visible underneath so the user can still see existing spaces.
struct MacCreateSpaceForm: View {
    let suggestedSortIndex: Int
    let cancelToken: Int
    /// While the form is up, this preview drives the window+sidebar
    /// tint. MacRootView owns the storage so the entire window updates
    /// in real time, matching Zen's gradient generator behavior.
    @Binding var previewGradient: ZenGradientConfig?
    let onCreate: (Space) -> Void
    let onCancel: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme

    @State private var name: String = ""
    @State private var icon: String = ""               // emoji char OR SF Symbol name; "" = none
    @State private var gradientConfig: ZenGradientConfig = .defaultConfig
    @State private var iconPickerOpen: Bool = false
    @State private var themePopoverOpen: Bool = false

    @FocusState private var nameFieldFocused: Bool

    // Per-element appear flags. Mirrors `elementsToAnimate` in
    // ZenSpaceCreation.mjs — title, subtitle, name+icon, gradient picker,
    // create, cancel.
    @State private var visible: [Bool] = Array(repeating: false, count: 6)
    @State private var isExiting: Bool = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool { !trimmedName.isEmpty }

    @State private var availableWidth: CGFloat = 280

    var body: some View {
        // Top + bottom chrome anchored to the window edges; the middle
        // section scrolls when the window is short or the sidebar is
        // narrow. Without this, dragging the window below ~640pt tall
        // OR shrinking the sidebar below the color pad's natural width
        // clipped the form and pushed the workspace pane's bottom edge
        // out of the safe area.
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EmbeddedTrafficLights()
                Spacer(minLength: 0)
            }
            .frame(height: 28)
            .padding(.top, 10)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 6) {
                        stagger(0) {
                            Text("Create a Space")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                        }
                        stagger(1) {
                            Text("Spaces are used to organize your notes by theme.")
                                .font(.system(size: 11.5, weight: .regular))
                                .foregroundStyle(.primary.opacity(0.45))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.top, 18)

                    VStack(spacing: 10) {
                        stagger(2) { nameRow }
                        stagger(3) { chooseThemeButton }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 22)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
            }

            VStack(spacing: 6) {
                stagger(4) {
                    Button(action: handleCreate) {
                        Text("Create Space")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(CreateSpacePrimaryButtonStyle(enabled: canCreate))
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canCreate)
                }

                stagger(5) {
                    Button(action: dismiss) {
                        Text("Cancel")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.65))
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            // Subtract the form's horizontal padding (10 each side) so
            // the picker sizes its pad against the actual content width.
            availableWidth = max(160, newWidth - 20)
        }
        .onAppear(perform: runEntranceAnimation)
        .onChange(of: gradientConfig) { _, newValue in
            previewGradient = newValue
        }
        .onChange(of: cancelToken) { _, _ in dismiss() }
    }

    // MARK: - Name + icon row

    private var nameRow: some View {
        HStack(spacing: 8) {
            Button {
                iconPickerOpen.toggle()
            } label: {
                ZStack {
                    if icon.isEmpty {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                .primary.opacity(colorScheme == .dark ? 0.5 : 0.4),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.primary.opacity(colorScheme == .dark ? 0.10 : 0.08))
                        MacSpaceIcon.view(icon, size: 14)
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pick an icon")
            .popover(isPresented: $iconPickerOpen, arrowEdge: .top) {
                MacIconPicker(selection: $icon) { iconPickerOpen = false }
            }

            TextField("Space Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.primary)
                .focused($nameFieldFocused)
                .onSubmit { if canCreate { handleCreate() } }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(
            .primary.opacity(colorScheme == .dark ? 0.08 : 0.06),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - Theme button (opens popover)

    private var chooseThemeButton: some View {
        Button {
            themePopoverOpen.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "paintbrush.pointed.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.7))
                Text("Choose a Theme")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer(minLength: 0)
                themePreviewDot
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                .primary.opacity(colorScheme == .dark ? 0.10 : 0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $themePopoverOpen, arrowEdge: .trailing) {
            ZenGradientPicker(config: $gradientConfig)
        }
    }

    private var themePreviewDot: some View {
        let dark = gradientConfig.resolvedDark(osIsDark: colorScheme == .dark)
        let colors = gradientConfig.resolvedColors(forDark: dark)
        return ZStack {
            if colors.count <= 1 {
                Circle().fill(colors.first ?? Color.gray)
            } else {
                Circle().fill(AngularGradient(
                    gradient: Gradient(colors: colors + [colors[0]]),
                    center: .center,
                    angle: .degrees(-90)
                ))
            }
            Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1)
        }
        .frame(width: 18, height: 18)
    }

    // MARK: - Stagger helper

    @ViewBuilder
    private func stagger<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .opacity(visible[index] ? 1 : 0)
            .offset(y: visible[index] ? 0 : 14)
            .blur(radius: visible[index] ? 0 : 1.6)
    }

    // MARK: - Lifecycle

    private func runEntranceAnimation() {
        previewGradient = gradientConfig
        for index in 0..<visible.count {
            let delay = 0.2 + Double(index) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !isExiting else { return }
                withAnimation(.spring(response: 0.6, dampingFraction: 1.0)) {
                    visible[index] = true
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(visible.count) * 0.05 + 0.05) {
            nameFieldFocused = true
        }
    }

    private func dismiss() {
        guard !isExiting else { return }
        isExiting = true
        let total = visible.count
        for offset in 0..<total {
            let index = total - 1 - offset
            let delay = Double(offset) * 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.4, dampingFraction: 1.0)) {
                    visible[index] = false
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(total) * 0.05 + 0.32) {
            onCancel()
        }
    }

    private func handleCreate() {
        guard canCreate, !isExiting else { return }
        // Derive flat hex values directly from HSL math — no NSColor
        // round-trip, which on macOS sometimes lands in a color space
        // where `.redComponent` returns the wrong channel and the saved
        // hex drifts from what the user picked.
        let lightHex = gradientConfig.lightHex
        let darkHex = gradientConfig.darkHex
        let resolvedIcon = icon.isEmpty ? "✦" : icon
        let profile = ProfileExpanderService.fallback(
            description: trimmedName.isEmpty ? "General notes and ideas." : trimmedName
        )
        let space = SpaceFactory.makeCustomSpace(
            name: trimmedName,
            emoji: resolvedIcon,
            colorHex: lightHex,
            darkColorHex: darkHex,
            sortIndex: suggestedSortIndex,
            profile: profile
        )
        // Persist the full gradient config alongside the representative
        // color so future renders can use the gradient directly.
        space.gradientConfigJSON = ZenGradientConfig.encode(gradientConfig)
        modelContext.insert(space)
        do { try modelContext.save() } catch {
            assertionFailure("Failed to persist new space: \(error)")
        }
        isExiting = true
        let total = visible.count
        for offset in 0..<total {
            let index = total - 1 - offset
            let delay = Double(offset) * 0.04
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.spring(response: 0.35, dampingFraction: 1.0)) {
                    visible[index] = false
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(total) * 0.04 + 0.28) {
            onCreate(space)
        }
    }
}

// MARK: - Button styles

private struct CreateSpacePrimaryButtonStyle: ButtonStyle {
    let enabled: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(enabled ? 0.95 : 0.55))
            .background(
                .primary.opacity(backgroundOpacity(pressed: configuration.isPressed)),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && enabled ? 0.985 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }

    private func backgroundOpacity(pressed: Bool) -> Double {
        let base = colorScheme == .dark ? 0.20 : 0.16
        if !enabled { return base * 0.6 }
        return pressed ? base + 0.04 : base
    }
}

// MARK: - "+" popover menu (Create Space / Create Folder / New Split / New Tab)

struct MacSidebarNewElementMenu: View {
    let onCreateSpace: () -> Void
    let onCreateFolder: () -> Void
    let onNewSplit: () -> Void
    let onNewTab: () -> Void

    private let folderEnabled = true    // creates a Pinned folder + inline rename
    private let splitEnabled = false    // v2 (per SPEC §20.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row(icon: "square.on.square", label: "Create Space", enabled: true, action: onCreateSpace)
            row(icon: "folder", label: "Create Folder", enabled: folderEnabled, action: onCreateFolder)
            Divider().padding(.horizontal, 10).padding(.vertical, 5)
            row(icon: "rectangle.split.2x1", label: "New Split", enabled: splitEnabled, action: onNewSplit)
            row(icon: "plus", label: "New Tab", enabled: true, action: onNewTab)
        }
        .padding(6)
        .frame(minWidth: 196)
    }

    @ViewBuilder
    private func row(icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        MenuRow(icon: icon, label: label, enabled: enabled, action: action)
    }
}

private struct MenuRow: View {
    let icon: String
    let label: String
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    /// Concentric-corner convention: inner radius = outer radius − the
    /// inset gap. The popover's corner is ~20pt and the menu inset is
    /// 6pt, so 14pt keeps the highlight's curve parallel to the
    /// popover's rather than tighter.
    private let cornerRadius: CGFloat = 14

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(width: 18, alignment: .center)
                Text(label)
                    .font(.system(size: 13, weight: hovering ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background(
                hovering ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = enabled && $0 }
    }

    private var foreground: Color {
        if !enabled { return .primary.opacity(0.32) }
        if hovering { return .white }
        return .primary
    }
}

#endif
