import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
extension View {
    /// AppKit-backed hover detection. SwiftUI's built-in `.onHover` drops
    /// events in some nested contexts (offset-based layouts, custom gesture
    /// stacks, etc.); this routes through an `NSTrackingArea` instead, which
    /// is the same primitive AppKit's own controls use, so it fires reliably.
    /// Use the same way as `.onHover`: `.onHoverTracked { hovering in ... }`.
    func onHoverTracked(_ change: @escaping (Bool) -> Void) -> some View {
        background(HoverTrackingView(onChange: change))
    }

    /// AppKit-backed press + click detection. Same reason as `.onHoverTracked` —
    /// SwiftUI gestures (`DragGesture`, `.onTapGesture`, `Button`) drop events
    /// in some nested contexts; this uses `mouseDown` / `mouseUp` directly on
    /// an `NSView` overlay. `onPress(true)` fires on mouse-down (for instant
    /// press feedback), `onPress(false)` on release, and `onTap` fires once
    /// when released INSIDE the view's bounds.
    func onPressTracked(
        onPress: @escaping (Bool) -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        overlay(PressTrackingView(onPress: onPress, onTap: onTap))
    }

}

/// Shared "what cursor should show right now" for a surface that must forcibly
/// own the cursor over views BEHIND it — e.g. the full-window Manage Spaces
/// overlay covering the note editor's `NSTextView`, whose I-beam otherwise
/// leaks through any frontmost view (a plain ScrollView, empty regions) that
/// doesn't itself claim a cursor. Hover handlers set `desired`; the `CursorPump`
/// applies it on every mouse move. Single source of truth, so a pointing-hand
/// control and the surrounding arrow surface never fight each other.
final class OverlayCursor {
    static let shared = OverlayCursor()
    var desired: NSCursor = .arrow
}

/// Full-surface cursor enforcer for an overlay. While present it installs a
/// local event monitor that OWNS the cursor for the window:
///
/// - On every `.mouseMoved` / drag it applies `OverlayCursor.shared.desired`
///   synchronously (no async frame where a stale cursor can show).
/// - It CONSUMES `.cursorUpdate` events (returns nil) so the note editor's
///   `NSTextView` behind the overlay never gets to set its I-beam in the first
///   place — the actual source of the right-side flicker. Earlier attempts
///   (cursor rects, an async tracking pump) only *corrected* the I-beam after
///   the editor set it, which always left a one-frame flicker.
///
/// Nested controls (drag handle, ⋯) just set `desired` from their SwiftUI hover
/// handlers; their hover tracking is independent of cursor events, so it keeps
/// working even though this owns the cursor.
struct CursorPump: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorPumpNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class CursorPumpNSView: NSView {
    private var monitor: Any?
    private weak var managedWindow: NSWindow?
    // Underlying text views whose selectable/editable state we flipped, with
    // their original values to restore on dismiss.
    private var suppressedTextViews: [(view: NSTextView, selectable: Bool, editable: Bool)] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let w = window {
            managedWindow = w
            OverlayCursor.shared.desired = .arrow
            w.acceptsMouseMovedEvents = true
            w.disableCursorRects()
            suppressUnderlyingIBeam(in: w)
            installMonitor()
        } else if let w = managedWindow {
            // Removed from the hierarchy (board dismissed) — restore everything.
            w.enableCursorRects()
            w.resetCursorRects()
            restoreUnderlyingIBeam()
            managedWindow = nil
            removeMonitor()
        }
    }

    /// A non-selectable, non-editable NSTextView shows the ARROW cursor instead
    /// of an I-beam. The note editor behind this full-window overlay drives its
    /// I-beam via tracking (not cursor rects, so `disableCursorRects` can't stop
    /// it), and `.cursorUpdate` isn't reliably deliverable to event monitors —
    /// so we neutralize it at the source: flip every underlying text view's
    /// selectable/editable off while the board is up, restore on dismiss.
    private func suppressUnderlyingIBeam(in window: NSWindow) {
        guard let content = window.contentView else { return }
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let tv = sub as? NSTextView {
                    suppressedTextViews.append((tv, tv.isSelectable, tv.isEditable))
                    tv.isSelectable = false
                    tv.isEditable = false
                }
                walk(sub)
            }
        }
        walk(content)
    }

    private func restoreUnderlyingIBeam() {
        for entry in suppressedTextViews {
            entry.view.isSelectable = entry.selectable
            entry.view.isEditable = entry.editable
        }
        suppressedTextViews.removeAll()
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        // Apply the desired cursor on every move so the board's arrow / the
        // handle's open-hand are asserted; text-cursor leakage is already gone.
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { event in
            OverlayCursor.shared.desired.set()
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        restoreUnderlyingIBeam()
        removeMonitor()
    }
}

/// Reusable circular icon button with the same soft grey hover treatment as
/// the empty-pane "New Note" button: a translucent `.primary` fill that's faint
/// at rest (`0.08`) and lifts on hover (`0.16` light / `0.20` dark), with the
/// glyph opacity tracking along. Use for close (×), back, and similar chrome
/// buttons so they all share one language.
struct SoftHoverIconButton: View {
    let systemName: String
    var diameter: CGFloat = 26
    var iconSize: CGFloat = 11
    var iconWeight: Font.Weight = .bold
    /// Optional lift-on-hover, matching the "New Note" button's `1.03` pop.
    /// Defaults to `1.0` (no scale) so existing call sites are unchanged.
    var hoverScale: CGFloat = 1.0
    var help: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: iconWeight))
                .foregroundStyle(.primary.opacity(isHovered ? 0.9 : 0.6))
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(.primary.opacity(
                        isHovered ? (colorScheme == .dark ? 0.20 : 0.16) : 0.08
                    ))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Scale BEFORE the hover tracker: scaleEffect doesn't change layout
        // size, so the NSTrackingArea (added by .onHoverTracked as a background)
        // stays at the unscaled frame and won't flicker enter/exit on hover.
        .scaleEffect(isHovered ? hoverScale : 1.0)
        .help(help ?? "")
        .onHoverTracked { if isHovered != $0 { isHovered = $0 } }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

/// Rectangular sibling of `SoftHoverIconButton`: wraps a small glyph in a
/// rounded-rect that picks up the same translucent grey hover chip as the
/// "New Note" button (invisible at rest, `0.16` light / `0.20` dark on hover).
/// For icons that live inside an already-busy surface (a split pill, a column
/// footer) where a permanent rest chip would clutter — so the chip only
/// appears on hover. The label closure receives the live hover state so the
/// glyph opacity can lift in step.
struct SoftHoverChipButton<Label: View>: View {
    var cornerRadius: CGFloat = 7
    var help: String? = nil
    let action: () -> Void
    @ViewBuilder var label: (Bool) -> Label

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label(isHovered)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.primary.opacity(
                            isHovered ? (colorScheme == .dark ? 0.20 : 0.16) : 0.0
                        ))
                )
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHoverTracked { if isHovered != $0 { isHovered = $0 } }
        .animation(.easeOut(duration: 0.10), value: isHovered)
    }
}

struct HoverTrackingView: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = HoverTrackingNSView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HoverTrackingNSView)?.onChange = onChange
    }
}

private final class HoverTrackingNSView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let newArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(newArea)
        area = newArea
    }
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

struct PressTrackingView: NSViewRepresentable {
    let onPress: (Bool) -> Void
    let onTap: () -> Void
    func makeNSView(context: Context) -> NSView {
        let view = PressTrackingNSView()
        view.onPress = onPress
        view.onTap = onTap
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let v = nsView as? PressTrackingNSView else { return }
        v.onPress = onPress
        v.onTap = onTap
    }
}

private final class PressTrackingNSView: NSView {
    var onPress: ((Bool) -> Void)?
    var onTap: (() -> Void)?
    private var mouseDownInside = false

    // Receive mouse events even when not key, and don't block hit-testing
    // (we want events to reach US since we're the click target).
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownInside = true
        onPress?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        // Cursor left the view's bounds → cancel the pressed visual; tap won't
        // fire on release (matches standard button behavior).
        let p = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(p)
        if inside != mouseDownInside {
            mouseDownInside = inside
            onPress?(inside)
        }
    }
    override func mouseUp(with event: NSEvent) {
        let wasInside = mouseDownInside
        mouseDownInside = false
        onPress?(false)
        if wasInside { onTap?() }
    }
}

struct MouseDownTrackingView: NSViewRepresentable {
    let action: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MouseDownTrackingNSView()
        view.onMouseDown = action
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MouseDownTrackingNSView else { return }
        view.onMouseDown = action
        view.onHover = onHover
    }
}

private final class MouseDownTrackingNSView: NSButton {
    var onMouseDown: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var localMouseMonitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        focusRingType = .none
        setButtonType(.momentaryChange)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoringMouseDown()
        } else {
            startMonitoringMouseDown()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown else { return }
        onMouseDown?()
    }

    private func startMonitoringMouseDown() {
        guard localMouseMonitor == nil else { return }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.onMouseDown?()
            return nil
        }
    }

    private func stopMonitoringMouseDown() {
        guard let localMouseMonitor else { return }
        NSEvent.removeMonitor(localMouseMonitor)
        self.localMouseMonitor = nil
    }

    deinit {
        stopMonitoringMouseDown()
    }
}
#endif
