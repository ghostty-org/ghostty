import AppKit

extension Notification.Name {
    /// Distributed Notification for DockTilePlugin to update icon
    ///
    /// Ghostty -> DockTilePlugin
    static let ghosttyIconDidChange = Notification.Name("com.scottmcpherson.mosttly-ghostty.iconDidChange")
}
