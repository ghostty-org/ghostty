import Carbon
import Cocoa
import OSLog

// Manages the secure keyboard input state. Secure keyboard input is an old Carbon
// API still in use by applications such as Webkit. From the old Carbon docs:
// "When secure event input mode is enabled, keyboard input goes only to the
// application with keyboard focus and is not echoed to other applications that
// might be using the event monitor target to watch keyboard input."
//
// Secure input is global and stateful so you need a singleton class to manage
// it. You have to yield secure input on application deactivation (because
// it'll affect other apps) and reacquire on reactivation, and every enable
// needs to be balanced with a disable.
class SecureInput: ObservableObject {
    static let shared = SecureInput()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: SecureInput.self)
    )

    // True if you want to enable secure input globally.
    var global: Bool = false {
        didSet {
            apply()
        }
    }

    // The scoped objects and whether they're currently in focus.
    private var scoped: [ObjectIdentifier: Bool] = [:]

    // This is set to true when we've successfully called EnableSecureInput.
    @Published private(set) var enabled: Bool = false

    // This is true if we want to enable secure input. We want to enable
    // secure input if its enabled globally or any of the scoped objects are
    // in focus.
    private var desired: Bool {
        global || scoped.contains(where: { $0.value })
    }

    private init() {
        // Add notifications for application active/resign so we can disable
        // secure input. This is only useful for global enabling of secure
        // input.
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onDidResignActive(notification:)),
            name: NSApplication.didResignActiveNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(onDidBecomeActive(notification:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        // Reset our state so that we can ensure we set the proper secure input
        // system state
        scoped.removeAll()
        global = false
        apply()
    }

    // Add a scoped object that has secure input enabled. The focused value will
    // determine if the object currently has focus. This is used so that secure
    // input is only enabled while the object is focused.
    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    // Remove a scoped object completely.
    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        apply()
    }

    private func apply() {
        // If we aren't active then we don't do anything. The become/resign
        // active notifications will handle applying for us.
        guard NSApp.isActive else { return }

        // We only need to apply if we're not in our desired state
        guard enabled != desired else { return }

        let err: OSStatus
        if enabled {
            err = DisableSecureEventInput()
        } else {
            err = EnableSecureEventInput()
        }
        if err == noErr {
            enabled = desired
            Self.logger.debug("secure input state=\(self.enabled)")
            return
        }

        Self.logger.warning("secure input apply failed err=\(err)")
    }

    // MARK: Notifications

    @objc private func onDidBecomeActive(notification: NSNotification) {
        // We only want to re-enable if we're not already enabled and we
        // desire to be enabled.
        guard !enabled && desired else { return }
        let err = EnableSecureEventInput()
        if err == noErr {
            enabled = true
            Self.logger.debug("secure input enabled on activation")
            return
        }

        Self.logger.warning("secure input apply failed err=\(err)")
    }

    @objc private func onDidResignActive(notification: NSNotification) {
        // We only want to disable if we're enabled.
        guard enabled else { return }
        let err = DisableSecureEventInput()
        if err == noErr {
            enabled = false
            Self.logger.debug("secure input disabled on deactivation")
            return
        }

        Self.logger.warning("secure input apply failed err=\(err)")
    }
}
