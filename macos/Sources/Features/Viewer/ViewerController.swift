import AppKit
import SwiftUI

/// A non-terminal tab that renders an HTML or Markdown file.
///
/// Unlike terminal tabs (`TerminalController` / `BaseTerminalController`), this
/// is a lean `NSWindowController` that hosts a `WKWebView` through SwiftUI. Its
/// window joins the native macOS tab group of a terminal window so it appears
/// as a regular tab alongside terminal tabs.
class ViewerController: NSWindowController, NSWindowDelegate {
    /// Strong references to open viewer controllers. AppKit does not retain a
    /// window controller for us, so we keep them alive here while their window
    /// is open and drop them in `windowWillClose`.
    private static var openControllers: [ViewerController] = []

    /// File extensions this viewer knows how to render.
    static let supportedExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "html", "htm",
    ]

    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.tabbingMode = .preferred
        window.title = fileURL.lastPathComponent
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView: ViewerView(fileURL: fileURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Open `fileURL` in a new viewer tab. If `parent` is given, the viewer
    /// joins that window's native tab group; otherwise it opens standalone.
    @discardableResult
    static func open(fileURL: URL, from parent: NSWindow? = nil) -> ViewerController {
        let controller = ViewerController(fileURL: fileURL)
        openControllers.append(controller)

        guard let window = controller.window else { return controller }

        if let parent, window.tabbingMode != .disallowed {
            // If macOS already auto-tabbed our window, remove it first so we
            // control the ordering (mirrors TerminalController.newTab).
            if let group = parent.tabGroup,
               group.windows.firstIndex(of: window) != nil {
                group.removeWindow(window)
            }
            parent.addTabbedWindowSafely(window, ordered: .above)
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        Self.openControllers.removeAll { $0 === self }
    }
}
