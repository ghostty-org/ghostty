import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    fileprivate static let rectsKey = "NSWindowLastRectsByScreen"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    @discardableResult
    func save(_ window: NSWindow?) -> Bool {
        // We should only save the frame if the window is visible.
        // This avoids overriding the previously saved one
        // with the wrong one when window decorations change while creating,
        // e.g. adding a toolbar affects the window's frame.
        guard let window, window.isVisible else { return false }
        // We don't save the window frame when the window is in native fullscreen mode,
        // since AppKit doesn't restore .fullScreen correctly.
        // We should keep the behavior like first-party apps, such as Terminal and Safari.
        guard !window.styleMask.contains(.fullScreen), let screenID = window.screen?.displayUUID?.uuidString else {
            return false
        }
        savedWindowRectInfo[screenID] = window.frame
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

        guard
            let screen = window.screen ?? NSScreen.main,
            let screenID = screen.displayUUID?.uuidString,
            let lastFrame = savedWindowRectInfo[screenID]
        else {
            return false
        }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame
        if restoreOrigin {
            newFrame.origin = lastFrame.origin
        }

        if restoreSize {
            newFrame.size.width = min(lastFrame.width, visibleFrame.width)
            newFrame.size.height = min(lastFrame.height, visibleFrame.height)
        }

        if restoreOrigin, !visibleFrame.contains(newFrame.origin) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }

        window.setFrame(newFrame, display: true)
        return true
    }
}

extension LastWindowPosition {
    var savedWindowRectInfo: [String: CGRect] {
        get {
            guard
                let dict = defaults.dictionary(forKey: LastWindowPosition.rectsKey) as? [String: CFDictionary]
            else {
                // Restore previously saved rect on main screen
                if
                    let rect = CGRect(valueArray: defaults.array(forKey: "NSWindowLastPosition")),
                    let screenID = NSScreen.main?.displayUUID?.uuidString {
                    return [screenID: rect]
                } else {
                    return [:]
                }
            }
            return dict.compactMapValues(CGRect.init(dictionaryRepresentation:))
        }
        set {
            defaults.set(newValue.mapValues(\.dictionaryRepresentation), forKey: LastWindowPosition.rectsKey)
        }
    }
}

private extension CGRect {
    init?(valueArray: [Any]?) {
        guard let values = valueArray as? [Double], values.count >= 2 else {
            return nil
        }
        self.init(x: values[0], y: values[1], width: values[safe: 2] ?? 0, height: values[safe: 3] ?? 0)
    }
}
