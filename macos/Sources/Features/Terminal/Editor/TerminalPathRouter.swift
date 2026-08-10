import AppKit

/// Sends a path clicked in the terminal to whichever opener the reader chose.
///
/// The seam between the C action that Ghostty raises for a clicked link and
/// the window that has an editor in it. Static because the action arrives
/// with no context at all — not even which window — so the key window is the
/// only honest answer to "who was clicked in".
@MainActor
enum TerminalPathRouter {
    /// Handles `text` if it names a local file. Returns whether it did.
    ///
    /// Returning `false` is the important half: everything this declines —
    /// a URL with a scheme, a directory, a path that doesn't exist — has to
    /// reach the behaviour that was there before, or clicking a link in the
    /// terminal would silently stop working.
    static func open(_ text: String) -> Bool {
        guard let controller = NSApp.keyWindow?.windowController as? TerminalController
        else { return false }

        let target = TerminalPathTarget.parse(text)
        guard let url = target.resolvedFile(relativeTo: controller.workingDirectoryForPaths)
        else { return false }

        controller.openClickedPath(url, line: target.line, column: target.column)
        return true
    }
}
