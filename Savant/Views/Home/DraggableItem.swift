import SwiftUI

/// Hooks the system drag preview lifecycle so sibling views can react.
/// IMPORTANT: SwiftUI renders the `.draggable` preview in a separate UIWindow, which
/// does NOT inherit the parent view's environment. Pass the `InteractionMode` reference
/// directly so this modifier doesn't rely on `@Environment` lookup at preview time.
struct DragLifecycleHook: ViewModifier {
    let interaction: InteractionMode

    func body(content: Content) -> some View {
        content
            .onAppear { interaction.beginDragging() }
            .onDisappear { interaction.endDragging() }
    }
}

extension View {
    func dragLifecycleHook(_ interaction: InteractionMode) -> some View {
        modifier(DragLifecycleHook(interaction: interaction))
    }
}
