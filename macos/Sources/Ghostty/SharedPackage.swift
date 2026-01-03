import Foundation
import os

enum Ghostty {
    // The primary logger used by the GhosttyKit libraries.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ghostty"
    )

    // All the notifications that will be emitted will be put here.
    struct Notification {}

    // The user notification category identifier
    static let userNotificationCategory = "com.mitchellh.ghostty.userNotification"

    // The user notification "Show" action
    static let userNotificationActionShow = "com.mitchellh.ghostty.userNotification.Show"
}

extension Ghostty {
    /// macos-icon
    enum MacOSIcon: String, Sendable {
        case official
        case blueprint
        case chalkboard
        case glass
        case holographic
        case microchip
        case paper
        case retro
        case xray
        case custom
        case customStyle = "custom-style"
    }

    /// macos-icon-frame
    enum MacOSIconFrame: String, Codable {
        case aluminum
        case beige
        case plastic
        case chrome
    }
}
