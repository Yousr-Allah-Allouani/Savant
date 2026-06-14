import SwiftUI
import UIKit

/// Long-press-then-drag lift, built on a UIKit recognizer so arbitration with
/// the scroll view is native: finger moving early → the scroll pan wins;
/// finger held ~0.25s → the long press recognizes, UIKit's default
/// exclusivity prevents the pan, and the recognizer owns the touch for the
/// whole drag. SwiftUI sequenced gestures inside ScrollViews can't do this
/// reliably — don't swap this back.
///
/// ONE recognizer lives at the pager root (not per row): the pager's
/// `LazyHStack` tears pages down mid-drag during cross-space switches, and a
/// recognizer dying with its view would cancel the drag. Rows instead
/// REGISTER themselves as liftable (`.dragRow`), and the delegate only lets
/// a touch through when it lands on a registered row of the active page — so
/// holding empty space, buttons, or the input bar never steals the touch.
/// Touches after the first are declined entirely, which leaves a second
/// finger free to swipe the pager between spaces mid-drag.
struct DragLiftGesture: UIGestureRecognizerRepresentable {
    let session: TouchDragSession

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.25
        recognizer.allowableMovement = 12
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer, context: Context
    ) {
        // Window coordinates == SwiftUI's .global space (full-screen window).
        let fingerGlobal = recognizer.location(in: nil)
        switch recognizer.state {
        case .began:
            session.recognizerStillTracking = { [weak recognizer] in
                recognizer.map { $0.state == .began || $0.state == .changed } ?? false
            }
            session.lift(atGlobal: fingerGlobal)
        case .changed:
            session.updateDrag(fingerGlobal: fingerGlobal)
        case .ended:
            print("🧭 DRAG-PROBE lift .ended (finger released)")
            session.endDrag()
        case .cancelled, .failed:
            // UIKit killed the touch (not a user release) — glide the row
            // home instead of committing wherever the ghost happened to be.
            print("🧭 DRAG-PROBE lift KILLED state=\(recognizer.state.rawValue) view=\(String(describing: type(of: recognizer.view))) window=\(recognizer.view?.window != nil)")
            session.endDrag(cancelled: true)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let session: TouchDragSession

        init(session: TouchDragSession) {
            self.session = session
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            // One finger only: extra touches stay with the scroll views, so
            // a second finger can page the pager mid-drag.
            guard gestureRecognizer.numberOfTouches == 0 else { return false }
            // Self-heal a drag that died without a clean end (orphaned the
            // recognizer) — otherwise every lift after it is silently blocked.
            session.clearIfOrphaned()
            return session.canLift(atGlobal: touch.location(in: nil))
        }
    }
}

/// Second-finger space steering: while a drag is active, another finger can
/// swipe horizontally anywhere to page the pager — the primary way to carry
/// a row to a different space. The pager's own pan never gets that touch
/// (the long press owns the gesture arbitration), so this dedicated pan
/// receives it and pages one space per ~70pt of travel. It only ever accepts
/// touches that BEGIN mid-drag, so normal pager swiping stays native.
struct DragSpaceSwipeGesture: UIGestureRecognizerRepresentable {
    let session: TouchDragSession

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer, context: Context
    ) {
        switch recognizer.state {
        case .changed:
            // Stream the raw translation; the pager drives the inner pager 1:1.
            session.steerChanged?(recognizer.translation(in: nil).x)
        case .ended, .cancelled, .failed:
            // Hand over a predicted endpoint (translation + a slice of velocity)
            // so a quick flick still pages and a slow half-swipe snaps back.
            let tx = recognizer.translation(in: nil).x
            let vx = recognizer.velocity(in: nil).x
            session.steerEnded?(tx + vx * 0.12)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let session: TouchDragSession

        init(session: TouchDragSession) {
            self.session = session
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
        ) -> Bool {
            // The drag finger touched down BEFORE the session went active, so
            // it can never reach this pan — only a finger added mid-drag can.
            session.isActive
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Must run WHILE the lift recognizer owns the drag touch.
            true
        }
    }
}

/// Everything a row needs to participate in the drag engine: frame reporting
/// (active page only), drag-hidden state, shuffle offset, and registration
/// with the root lift recognizer. The row declares WHERE it lives (tier +
/// parent folder + space); the session resolves the layout/commit handlers
/// from the tier's published `TierDragContext` at lift time.
struct DragRowModifier: ViewModifier {
    @Environment(TouchDragSession.self) private var session
    @Environment(\.isActiveSpacePage) private var isActivePage

    let id: UUID
    let payload: TouchDragSession.Payload
    let tier: NoteTier
    var parentFolderID: UUID? = nil
    /// nil = the row renders identically on every page (Essentials).
    var spaceID: UUID? = nil
    let ghost: () -> TouchDragSession.GhostSpec.Content
    var isEnabled: Bool = true
    /// Runs just before the session starts (e.g. collapse an expanded folder
    /// so it drags as a single header row).
    var onWillLift: (() -> Void)? = nil
    /// Runs after the release glide settles (e.g. re-expand that folder).
    var onSettled: (() -> Void)? = nil

    func body(content: Content) -> some View {
        let isDragged = session.isDragged(id)
        let offset = session.shuffleOffset(for: id)
        // Re-registered every body pass so the captured closures stay fresh
        // (mirrors `publishContext`); env flips re-run this body. Inactive
        // pages never touch the registry — Essentials share row ids across
        // pages, so an inactive page writing (or removing) entries would
        // clobber the active page's registration.
        if isActivePage {
            session.registerLiftable(id, .init(
                payload: payload, tier: tier, parentFolderID: parentFolderID,
                spaceID: spaceID, ghost: ghost, isEnabled: isEnabled,
                onWillLift: onWillLift, onSettled: onSettled
            ))
        }

        return content
            // The hidden row keeps its layout slot — it IS the source hole;
            // neighbors close/open it purely with visual offsets.
            .opacity(isDragged ? 0 : 1)
            .offset(offset)
            .animation(session.isActive ? TouchDragSession.rowShuffle : nil, value: offset)
            // The report value carries the activation flag: a page becoming
            // active re-fires the action even when its geometry is unchanged
            // (the bare-frame version only ever reported the FIRST active
            // page — every other space dragged blind).
            .onGeometryChange(for: ActiveFrame.self) { proxy in
                ActiveFrame(frame: proxy.frame(in: .named("spaceContent")), active: isActivePage)
            } action: { report in
                if report.active { session.rowFrames[id] = report.frame }
            }
            .onDisappear {
                if session.isDragged(id) {
                    print("🧭 DRAG-PROBE dragged row's VIEW disappeared mid-drag")
                }
                if isActivePage { session.unregisterLiftable(id) }
            }
    }
}

/// A geometry value that also changes when the page's activation flips, so
/// `onGeometryChange` re-fires on activation, not just on layout changes.
struct ActiveFrame: Equatable {
    let frame: CGRect
    let active: Bool
}

extension View {
    func dragRow(
        id: UUID,
        payload: TouchDragSession.Payload,
        tier: NoteTier,
        parentFolderID: UUID? = nil,
        spaceID: UUID? = nil,
        ghost: @escaping () -> TouchDragSession.GhostSpec.Content,
        isEnabled: Bool = true,
        onWillLift: (() -> Void)? = nil,
        onSettled: (() -> Void)? = nil
    ) -> some View {
        modifier(DragRowModifier(
            id: id, payload: payload, tier: tier, parentFolderID: parentFolderID,
            spaceID: spaceID, ghost: ghost, isEnabled: isEnabled,
            onWillLift: onWillLift, onSettled: onSettled
        ))
    }

    /// Frame reporting only — for rows that participate in shuffles (children
    /// moving with their folder) but aren't themselves liftable yet.
    func dragRowFrame(id: UUID) -> some View {
        modifier(DragRowFrameModifier(id: id))
    }
}

/// Frame + shuffle without a lift gesture (used by rows that move with the
/// layout but can't be grabbed — none today, kept for the P3 surface).
struct DragRowFrameModifier: ViewModifier {
    @Environment(TouchDragSession.self) private var session
    @Environment(\.isActiveSpacePage) private var isActivePage

    let id: UUID

    func body(content: Content) -> some View {
        let offset = session.shuffleOffset(for: id)
        content
            .offset(offset)
            .animation(session.isActive ? TouchDragSession.rowShuffle : nil, value: offset)
            .onGeometryChange(for: ActiveFrame.self) { proxy in
                ActiveFrame(frame: proxy.frame(in: .named("spaceContent")), active: isActivePage)
            } action: { report in
                if report.active { session.rowFrames[id] = report.frame }
            }
    }
}
