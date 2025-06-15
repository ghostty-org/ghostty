import Cocoa
import CoreGraphics
import Carbon
import OSLog
import GhosttyKit

// Manages the event tap to monitor global events, currently only used for
// global keybindings.
class GlobalEventTap {
    static let shared = GlobalEventTap()

    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: GlobalEventTap.self)
    )

    // The event tap used for global event listening. This is non-nil if it is
    // created.
    private var eventTap: CFMachPort? = nil

    // This is the timer used to retry enabling the global event tap if we
    // don't have permissions.
    private var enableTimer: Timer? = nil

    // Private init so it can't be constructed outside of our singleton
    private init() {}

    deinit {
        disable()
    }

    // Enable the global event tap. This is safe to call if it is already enabled.
    // If enabling fails due to permissions, this will start a timer to retry since
    // accessibility permissions take affect immediately.
    func enable() {
        if (eventTap != nil) {
            // Already enabled
            return
        }

        // If we are already trying to enable, then stop the timer and restart it.
        if let enableTimer {
            enableTimer.invalidate()
        }

        // Try to enable the event tap immediately. If this succeeds then we're done!
        if (tryEnable()) {
            return
        }

        // Failed, probably due to permissions. The permissions dialog should've
        // popped up. We retry on a timer since once the permissions are granted
        // then they take affect immediately.
        enableTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            _ = self.tryEnable()
        }
    }

    // Disable the global event tap. This is safe to call if it is already disabled.
    func disable() {
        // Stop our enable timer if it is on
        if let enableTimer {
            enableTimer.invalidate()
            self.enableTimer = nil
        }

        // Stop our event tap
        if let eventTap {
            Self.logger.debug("invalidating event tap mach port")
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    // Try to enable the global event type, returns false if it fails.
    private func tryEnable() -> Bool {
        // The events we care about
        let eventMask = [
            CGEventType.keyDown
        ].reduce(CGEventMask(0), { $0 | (1 << $1.rawValue)})

        // Try to create it
        guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: cgEventFlagsChangedHandler(proxy:type:cgEvent:userInfo:),
                userInfo: nil
        ) else {
            // Return false if creation failed. This is usually because we don't have
            // Accessibility permissions but can probably be other reasons I don't
            // know about.
            Self.logger.debug("creating global event tap failed, missing permissions?")
            return false
        }

        // Store our event tap
        self.eventTap = eventTap

        // If we have an enable timer we always want to disable it
        if let enableTimer {
            enableTimer.invalidate()
            self.enableTimer = nil
        }

        // Attach our event tap to the main run loop. Note if you don't do this then
        // the event tap will block every
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            CFMachPortCreateRunLoopSource(nil, eventTap, 0),
            .commonModes
        )

        Self.logger.info("global event tap enabled for global keybinds")
        return true
    }
}

fileprivate func cgEventFlagsChangedHandler(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let result = Unmanaged.passUnretained(cgEvent)

    // We only care about keydown events
    guard type == .keyDown else { return result }

    // If our app is currently active then we don't process the key event.
    // This is because we already have a local event handler in AppDelegate
    // that processes all local events.
    guard !NSApp.isActive else { return result }

    // We need an app delegate to get the Ghostty app instance
    guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return result }
    guard let ghostty = appDelegate.ghostty.app else { return result }

    // We need an NSEvent for our logic below
    guard let event: NSEvent = .init(cgEvent: cgEvent) else { return result }

    // Build our event input and call ghostty
    let key_ev = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
    if (ghostty_app_key(ghostty, key_ev)) {
        GlobalEventTap.logger.info("global key event handled event=\(event)")
        return nil
    }

    return result
}
