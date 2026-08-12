import AppKit
import SwiftUI

/// Makes the enclosing scroll view use overlay scrollers.
///
/// `.scrollIndicators(.hidden)` is already on the lists in the sidebar and a
/// bar shows anyway, which means the modifier is not reaching the scroller
/// that is drawn. Overlay is the style that appears while scrolling and
/// fades — the behaviour a sidebar wants — and a *legacy* scroller is the
/// one that sits there permanently and takes a column of layout for itself.
/// Setting it on the `NSScrollView` reaches it whatever SwiftUI decided.
///
/// Placed inside the scroll view's content with no size of its own, so it
/// can find its way up to the scroll view and otherwise does nothing.
struct OverlayScrollers: View {
    var body: some View {
        Representable()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Representable: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView { Finder() }

        func updateNSView(_ nsView: NSView, context: Context) {
            (nsView as? Finder)?.apply()
        }
    }

    private final class Finder: NSView {
        /// Applied on arrival in a window, which is the first moment there is
        /// a scroll view above this to find.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }
}
