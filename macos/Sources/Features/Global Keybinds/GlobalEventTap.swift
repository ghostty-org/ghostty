import Cocoa
import ApplicationServices
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
    fileprivate var eventTap: CFMachPort?

    // Polls Accessibility permission before enabling the global event tap.
    private var enableTimer: Timer?

    // Private init so it can't be constructed outside of our singleton
    private init() {}

    deinit {
        disable()
    }

    // Enable the global event tap. This is safe to call if it is already enabled or
    // waiting for Accessibility permission.
    func enable() {
        // If we already have a tap or we're already checking on a timer, do nothing.
        guard eventTap == nil, enableTimer == nil else { return }

        // Creating a CGEventTap without Accessibility permission leaks a Mach port
        // inside CoreGraphics on each failed attempt. Request permission once and
        // poll the non-leaking trust check instead of retrying tap creation.
        if AXIsProcessTrusted() {
            _ = tryEnable()
            return
        }

        // Ask macOS to prompt for Accessibility access. Approval happens
        // asynchronously, so ignore the current result and poll below.
        Self.logger.info("No accessibility permission detected, prompting...")
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // Check in a timer
        enableTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }

            // Stop polling before attempting creation. If creation fails for a
            // reason other than permissions, we must not retry it indefinitely.
            self.enableTimer?.invalidate()
            self.enableTimer = nil
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
            Self.logger.warning("creating global event tap failed despite Accessibility permission")
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

private func cgEventFlagsChangedHandler(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let result = Unmanaged.passUnretained(cgEvent)

    // macOS disables the event tap if the callback is too slow or for other
    // internal reasons. When that happens it sends this event type. We need
    // to re-enable the tap or it stays dead forever.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        GlobalEventTap.logger.warning("global event tap was disabled by the system, re-enabling")
        if let machPort = GlobalEventTap.shared.eventTap {
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
        return result
    }

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
    if ghostty_app_key(ghostty, key_ev) {
        GlobalEventTap.logger.info("global key event handled event=\(event, privacy: .public)")
        return nil
    }

    return result
}
