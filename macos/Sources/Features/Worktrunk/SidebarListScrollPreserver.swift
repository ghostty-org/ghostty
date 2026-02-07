import AppKit
import SwiftUI

@MainActor
final class SidebarListScrollPreserver: ObservableObject {
    weak var scrollView: NSScrollView?

    func captureScrollY() -> CGFloat? {
        scrollView?.contentView.bounds.origin.y
    }

    func restoreScrollY(_ y: CGFloat) {
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Finds the NSScrollView hosting the SwiftUI List used for the sidebar so we can
/// preserve/restore scroll position when AppKit tries to "help" after row moves.
struct SidebarListScrollFinder: NSViewRepresentable {
    @ObservedObject var preserver: SidebarListScrollPreserver

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The hosting view hierarchy can change; keep trying to locate the scroll view.
        guard preserver.scrollView == nil else { return }

        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            guard preserver.scrollView == nil else { return }

            // Look upward first: SwiftUI usually embeds the representable inside the scroll view.
            var v: NSView? = nsView
            while let cur = v {
                if let sv = cur as? NSScrollView {
                    preserver.scrollView = sv
                    return
                }
                v = cur.superview
            }

            // Fallback: search downward a bit.
            if let sv = nsView.firstDescendant(withClassName: "NSScrollView") as? NSScrollView {
                preserver.scrollView = sv
            }
        }
    }
}

