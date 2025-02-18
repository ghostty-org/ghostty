import Cocoa

/// Manages the persistence and restoration of window positions across app launches.
class LastWindowPosition {
    static let shared = LastWindowPosition()

    private let positionKey = "NSWindowLastPosition"

    func save(_ window: NSWindow) {
        let origin = window.frame.origin
        let point = [origin.x, origin.y]
        UserDefaults.standard.set(point, forKey: positionKey)
    }

    func restore(_ window: NSWindow) -> Bool {
        guard let points = UserDefaults.standard.array(forKey: positionKey) as? [Double],
              points.count == 2 else { return false }

        let lastPosition = CGPoint(x: points[0], y: points[1])

        guard let screen = window.screen ?? NSScreen.main else { return false }
        let visibleFrame = screen.visibleFrame

        var newFrame = window.frame
        newFrame.origin = lastPosition
        if !visibleFrame.contains(newFrame.origin) {
            newFrame.origin.x = max(visibleFrame.minX, min(visibleFrame.maxX - newFrame.width, newFrame.origin.x))
            newFrame.origin.y = max(visibleFrame.minY, min(visibleFrame.maxY - newFrame.height, newFrame.origin.y))
        }

        window.setFrame(newFrame, display: true)
        return true
    }
}
