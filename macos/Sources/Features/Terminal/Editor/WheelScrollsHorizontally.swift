import AppKit
import SwiftUI

/// Makes a vertical wheel gesture scroll the enclosing scroll view sideways.
///
/// A horizontal-only `NSScrollView` ignores a vertical wheel: the wheel has no
/// horizontal axis to give it, so the tabs off the right edge are reachable
/// only by a trackpad swipe. Every editor with a scrolling tab strip answers
/// the plain wheel there, because it is the fast way to get to a tab.
///
/// **Scoped on purpose.** The monitor is process-wide — that is the only place
/// AppKit lets a view see a wheel event it is not the target of — so it
/// answers only when all four of these hold: the scroll view is in the event's
/// own window, the pointer is inside its bounds, the gesture is vertical, and
/// the content is actually wider than the viewport. Anything else is returned
/// untouched and reaches whatever scroll view it was meant for. Without those
/// guards this would quietly turn every vertical scroll in the app sideways.
struct WheelScrollsHorizontally: View {
    var body: some View {
        Representable()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Representable: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Translator() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }

    private final class Translator: NSView {
        private var monitor: Any?

        /// Installed on arrival in a window — the first moment there is a
        /// scroll view above this to translate for — and removed on the way
        /// out, because a monitor that outlives its view keeps a dead scroll
        /// view alive and answers for a bar nobody can see.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window == nil {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                return
            }

            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.translate(event) ?? event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Returns nil to consume the event, or the event to pass it on.
        private func translate(_ event: NSEvent) -> NSEvent? {
            guard let scrollView = enclosingScrollView,
                  event.window === scrollView.window
            else { return event }
            let clipView = scrollView.contentView

            // Vertical only. A trackpad swipe already carries a horizontal
            // delta and the scroll view handles it; taking that one over would
            // scroll the row twice as far as the finger moved.
            guard event.scrollingDeltaX == 0, event.scrollingDeltaY != 0 else { return event }

            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return event }

            let overflow = (scrollView.documentView?.frame.width ?? 0) - clipView.bounds.width
            guard overflow > 0 else { return event }

            // Lines rather than pixels when the event is a wheel click, which
            // reports a delta of 1 per notch and would otherwise move the row
            // by a single point.
            let step = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 16

            let target = min(max(clipView.bounds.origin.x - step, 0), overflow)
            clipView.scroll(to: NSPoint(x: target, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            return nil
        }
    }
}
