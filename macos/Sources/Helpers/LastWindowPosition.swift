import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    fileprivate static let rectsKey = "NSWindowLastRectsByScreen"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ window: NSWindow) {
        // We don't save the window frame when the window is in native fullscreen mode,
        // since AppKit doesn't restore .fullScreen correctly.
        // We should keep the behavior like first-party apps, such as Terminal and Safari.
        guard !window.styleMask.contains(.fullScreen), let screenID = window.screen?.displayUUID?.uuidString else {
            return
        }
        savedWindowRectInfo[screenID] = window.frame
    }

    func restore(_ window: NSWindow) -> Bool {
        guard
            let screen = window.screen ?? NSScreen.main,
            let screenID = screen.displayUUID?.uuidString,
            let lastFrame = savedWindowRectInfo[screenID]
        else {
            return false
        }
        let newFrame = restore(
            windowFrame: window.frame,
            lastFrame: lastFrame,
            in: screen.visibleFrame,
        )

        window.setFrame(newFrame, display: true)
        return true
    }

    func restore(windowFrame: CGRect, lastFrame: CGRect, in visibleScreenFrame: CGRect) -> CGRect {
        let visibleFrame = visibleScreenFrame
        var newFrame = windowFrame
        newFrame.origin = lastFrame.origin

        if lastFrame.width > 0, lastFrame.height > 0 {
            newFrame.size.width = min(lastFrame.width, visibleFrame.width)
            newFrame.size.height = min(lastFrame.height, visibleFrame.height)
        }

        if !visibleFrame.contains(newFrame.origin) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }
        return newFrame
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
