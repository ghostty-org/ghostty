import Foundation

/// Pure logic used by the tab sidebar. This is kept free of AppKit state so it
/// can be unit tested.
enum TabSidebarLogic {
    /// The minimum width the user can resize the sidebar to.
    static let minWidth: CGFloat = 150

    /// The maximum width the user can resize the sidebar to.
    static let maxWidth: CGFloat = 480

    /// The width of the sidebar if the user never resized it.
    static let defaultWidth: CGFloat = 220

    /// The minimum width we try to leave for the terminal when the window is narrow.
    static let minTerminalWidth: CGFloat = 200

    /// Clamps a stored (user-chosen) width into the valid range.
    static func clampStoredWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultWidth }
        return min(max(width, minWidth), maxWidth)
    }

    /// The width actually laid out for a container of the given width. If the window
    /// is too narrow to fit both the stored sidebar width and the minimum terminal
    /// width, the sidebar shrinks down to (but never below) its minimum width.
    static func effectiveWidth(stored: CGFloat, containerWidth: CGFloat, visible: Bool) -> CGFloat {
        guard visible else { return 0 }
        let width = clampStoredWidth(stored)
        let room = containerWidth - minTerminalWidth
        return max(0, min(width, max(minWidth, room)))
    }

    /// Abbreviates a path by replacing the home directory prefix with "~".
    /// Returns nil for a nil or empty path.
    static func abbreviatePath(_ path: String?, home: String = NSHomeDirectory()) -> String? {
        guard var path, !path.isEmpty else { return nil }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }

        var home = home
        if home.count > 1, home.hasSuffix("/") { home.removeLast() }
        guard !home.isEmpty, home != "/" else { return path }

        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The prefix added to the window title when the bell rang.
    static let bellTitlePrefix = "🔔 "

    /// Returns the title and subtitle displayed in a tab row.
    ///
    /// Shells usually set the title to the working directory, which would make the
    /// subtitle repeat the title. In that case the title becomes the directory name
    /// (like Warp) and the subtitle shows the full abbreviated path.
    static func rowText(
        title: String,
        isOverride: Bool,
        pwd: String?,
        home: String = NSHomeDirectory()
    ) -> (title: String, subtitle: String?) {
        guard let path = abbreviatePath(pwd, home: home), let pwd else { return (title, nil) }
        guard !isOverride else { return (title, path == title ? nil : path) }

        var prefix = ""
        var rest = title
        if rest.hasPrefix(bellTitlePrefix) {
            prefix = bellTitlePrefix
            rest.removeFirst(bellTitlePrefix.count)
        }

        if rest.isEmpty || isPathTitle(rest, pwd: pwd, abbreviatedPath: path) {
            let name = directoryName(path)
            return (prefix + name, name == path ? nil : path)
        }

        return (title, path == title ? nil : path)
    }

    /// Returns true if the title is a (possibly shortened) form of the working directory,
    /// e.g. "/Users/me/src/app", "~/src/app", "…/src/app" or fish's "~/s/app".
    static func isPathTitle(_ title: String, pwd: String, abbreviatedPath: String) -> Bool {
        var title = title.trimmingCharacters(in: .whitespaces)
        guard let first = title.first, first == "~" || first == "/" || first == "…" else { return false }
        if title.count > 1, title.hasSuffix("/") { title.removeLast() }
        if title == pwd || title == abbreviatedPath { return true }
        guard title != "~", title != "/", abbreviatedPath != "~", abbreviatedPath != "/" else { return false }
        return (title as NSString).lastPathComponent == (abbreviatedPath as NSString).lastPathComponent
    }

    /// The name of the directory of an abbreviated path ("~" and "/" are kept as is).
    static func directoryName(_ path: String) -> String {
        guard path != "~", path != "/" else { return path }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Converts an NSTableView drop row (using "above" semantics, so in the range
    /// `0...count`) for a row dragged from `source` into the final index of that
    /// row after the move. Returns nil if the move is invalid or a no-op.
    static func destinationIndex(from source: Int, dropRow: Int, count: Int) -> Int? {
        guard (0..<count).contains(source), (0...count).contains(dropRow) else { return nil }
        let dest = dropRow > source ? dropRow - 1 : dropRow
        return dest == source ? nil : dest
    }

    /// The final index of a tab at `selected` moved by `amount` positions, clamped
    /// to the bounds of a tab list with `count` tabs.
    static func moveIndex(selected: Int, amount: Int, count: Int) -> Int {
        if amount < 0 {
            return selected - min(selected, -amount)
        } else {
            let remaining = count - 1 - selected
            return selected + min(remaining, amount)
        }
    }
}
