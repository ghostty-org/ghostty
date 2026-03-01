import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    private let positionKey = "NSWindowLastPosition"

    func save(_ window: NSWindow) {
        let frame = window.frame
        let rect = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        UserDefaults.standard.set(rect, forKey: positionKey)
    }

    func restore(_ window: NSWindow) -> Bool {
        guard let values = UserDefaults.standard.array(forKey: positionKey) as? [Double],
              values.count >= 2 else { return false }

        let lastPosition = CGPoint(x: values[0], y: values[1])

        guard let screen = window.screen ?? NSScreen.main else { return false }
        let visibleFrame = screen.visibleFrame

        var newFrame = window.frame
        newFrame.origin = lastPosition

        if values.count >= 4 {
            newFrame.size.width = min(values[2], visibleFrame.width)
            newFrame.size.height = min(values[3], visibleFrame.height)
        }

        if !visibleFrame.contains(newFrame.origin) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }

        window.setFrame(newFrame, display: true)
        return true
    }
}
