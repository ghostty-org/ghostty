import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    private let positionKey = "NSWindowLastPosition"

    @discardableResult
    func save(_ window: NSWindow?) -> Bool {
        // We should only save the frame if the window is visible.
        // This avoids overriding the previously saved one
        // with the wrong one when window decorations change while creating,
        // e.g. adding a toolbar affects the window's frame.
        guard let window, window.isVisible else { return false }
        let frame = window.frame
        let rect = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        UserDefaults.ghostty.set(rect, forKey: positionKey)
        return true
    }

    /// Restores a previously saved window frame (or parts of it) onto the given window.
    ///
    /// - Parameters:
    ///   - window: The window whose frame should be updated.
    ///   - restoreOrigin: Whether to restore the saved position. Pass `false` when the
    ///     config specifies an explicit `window-position-x`/`window-position-y`.
    ///   - restoreSize: Whether to restore the saved size. Pass `false` when the config
    ///     specifies an explicit `window-width`/`window-height`.
    /// - Returns: `true` if the frame was modified, `false` if there was nothing to restore.
    @discardableResult
    func restore(_ window: NSWindow, origin restoreOrigin: Bool = true, size restoreSize: Bool = true) -> Bool {
        guard restoreOrigin || restoreSize else { return false }

        guard let values = UserDefaults.ghostty.array(forKey: positionKey) as? [Double],
              values.count >= 2 else { return false }

        let lastPosition = CGPoint(x: values[0], y: values[1])

        guard let screen = window.screen ?? NSScreen.main else { return false }
        let visibleFrame = screen.visibleFrame

        var newFrame = window.frame
        if restoreOrigin {
            newFrame.origin = lastPosition
        }

        if restoreSize, values.count >= 4 {
            newFrame.size.width = min(values[2], visibleFrame.width)
            newFrame.size.height = min(values[3], visibleFrame.height)
        }

        // If the new frame is not constrained to the visible screen,
        // we need to shift it a little bit before AppKit does this for us,
        // so that we can save the correct size beforehand.
        // This fixes restoration while running UI tests,
        // where config is modified without switching apps,
        // which will not trigger `windowDidBecomeMain`.
        if restoreOrigin, !visibleFrame.contains(newFrame) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }

        window.setFrame(newFrame, display: true)
        return true
    }
}
