import Carbon
import Cocoa
import OSLog

// Implements the `macos-auto-switch-input-source` configuration: while Ghostty
// is the active application the configured keyboard input source is selected,
// and the input source that was selected before is restored when Ghostty
// resigns active.
//
// Input sources are global system state, so this is a singleton that tracks
// application activation, similar to SecureInput.
class AutoInputSource {
    static let shared = AutoInputSource()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: AutoInputSource.self)
    )

    // The ID of the input source to select while active, or nil to never
    // change the input source.
    var target: String? {
        didSet {
            // Apply right away so that a config reload doesn't require
            // reactivating the app.
            guard target != oldValue, NSApp.isActive else { return }
            selectTarget()
        }
    }

    // The ID of the input source that was selected before we switched to
    // the target. This is restored when we resign active. This is nil if we
    // haven't changed the input source.
    private var previous: String?

    private init() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onDidBecomeActive(notification:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onDidResignActive(notification:)),
            name: NSApplication.didResignActiveNotification,
            object: nil)

        // Quitting while active doesn't necessarily resign active first, so
        // restore on termination too.
        center.addObserver(
            self,
            selector: #selector(onDidResignActive(notification:)),
            name: NSApplication.willTerminateNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func selectTarget() {
        guard let target, let current = KeyboardLayout.id else { return }
        guard current != target else { return }
        guard Self.select(id: target) else { return }

        // Only remember the input source from before we first switched so
        // that a config reload while active doesn't overwrite it.
        if previous == nil { previous = current }
    }

    @discardableResult
    private static func select(id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              let sources = list as? [TISInputSource],
              let source = sources.first else {
            logger.warning("input source not found or not enabled id=\(id, privacy: .public)")
            return false
        }

        let err = TISSelectInputSource(source)
        if err != noErr {
            logger.warning("input source select failed id=\(id, privacy: .public) err=\(err, privacy: .public)")
            return false
        }

        logger.debug("input source selected id=\(id, privacy: .public)")
        return true
    }

    // MARK: Notifications

    @objc private func onDidBecomeActive(notification: NSNotification) {
        selectTarget()
    }

    @objc private func onDidResignActive(notification: NSNotification) {
        guard let previous else { return }
        self.previous = nil
        Self.select(id: previous)
    }
}
