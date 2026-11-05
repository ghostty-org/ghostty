import AppKit
import Carbon
import GhosttyKit
import OSLog

/// Uses native registrations only when the entire configuration is representable.
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    private static let signature: OSType = 0x47684B79
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: GlobalHotkeys.self))

    struct Key: Hashable {
        let keyCode: UInt32
        let mods: UInt32

        init?(_ binding: ghostty_input_binding_s) {
            let flags = Ghostty.Input.BindingFlags(cFlags: binding.flags)
            guard flags.contains([.global, .consumed]), !flags.contains(.performable),
                  binding.trigger.tag == GHOSTTY_TRIGGER_PHYSICAL,
                  binding.trigger.mods.rawValue & ~UInt32(0xF) == 0,
                  let key = Ghostty.Input.Key(cKey: binding.trigger.key.physical),
                  let keyCode = key.keyCode else { return nil }
            self.keyCode = UInt32(keyCode)
            self.mods = binding.trigger.mods.rawValue
        }

        var carbonModifiers: UInt32 {
            var result: UInt32 = 0
            if mods & GHOSTTY_MODS_SHIFT.rawValue != 0 { result |= UInt32(shiftKey) }
            if mods & GHOSTTY_MODS_CTRL.rawValue != 0 { result |= UInt32(controlKey) }
            if mods & GHOSTTY_MODS_ALT.rawValue != 0 { result |= UInt32(optionKey) }
            if mods & GHOSTTY_MODS_SUPER.rawValue != 0 { result |= UInt32(cmdKey) }
            return result
        }

        var event: ghostty_input_key_s {
            var result = ghostty_input_key_s()
            result.action = GHOSTTY_ACTION_PRESS
            result.keycode = keyCode
            result.mods = ghostty_input_mods_e(mods)
            return result
        }
    }

    static func nativeKeys(for bindings: [ghostty_input_binding_s]) -> [Key]? {
        let keys = bindings.compactMap(Key.init)
        guard keys.count == bindings.count, Set(keys).count == keys.count else { return nil }
        return keys
    }

    private var keys: [Key]? = []
    private var registrations: [UInt32: (key: Key, ref: EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0
    private var fallback: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private let enableFallback: () -> Void

    init(enableFallback: @escaping () -> Void = { GlobalEventTap.shared.enable() }) {
        self.enableFallback = enableFallback
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: NSApp, queue: .main
            ) { [weak self] _ in
                guard let self, let keys = self.keys, !keys.isEmpty else { return }
                self.updateActivity(active: NSApp.isActive)
            })
        }
    }

    deinit {
        fallback?.cancel()
        unregister()
        if let handler { RemoveEventHandler(handler) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func update(config: Ghostty.Config, permissionDelay: TimeInterval = 0) {
        fallback?.cancel()
        unregister()
        keys = Self.nativeKeys(for: config.globalKeybinds)
        updateActivity(active: NSApp.isActive, permissionDelay: permissionDelay)
    }

    func updateActivity(active: Bool, permissionDelay: TimeInterval = 0) {
        fallback?.cancel()
        unregister()
        if let keys {
            if keys.isEmpty || active || register(keys) {
                GlobalEventTap.shared.disable()
                return
            }
            // Retry an OS-rejected registration only after a configuration reload.
            self.keys = nil
        }

        let work = DispatchWorkItem(block: enableFallback)
        fallback = work
        if permissionDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + permissionDelay, execute: work)
        } else {
            work.perform()
        }
    }

    private func register(_ keys: [Key]) -> Bool {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue().handle(id.id)
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else {
                Self.logger.warning("installing native hotkey handler failed: \(status)")
                return false
            }
        }

        for key in keys {
            guard nextID < UInt32.max else {
                unregister()
                return false
            }
            // Never reuse an ID: a queued event may outlive a config or focus change.
            nextID += 1
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.keyCode, key.carbonModifiers,
                                            EventHotKeyID(signature: Self.signature, id: nextID),
                                            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
            guard status == noErr, let ref else {
                Self.logger.info("native global hotkey unavailable (\(status)); using event tap")
                unregister()
                return false
            }
            registrations[nextID] = (key, ref)
        }
        Self.logger.info("native global keybindings enabled count=\(keys.count)")
        return true
    }

    private func unregister() {
        for registration in registrations.values {
            let status = UnregisterEventHotKey(registration.ref)
            if status != noErr { Self.logger.warning("unregistering native hotkey failed: \(status)") }
        }
        registrations.removeAll()
    }

    private func handle(_ id: UInt32) {
        guard !NSApp.isActive, let key = registrations[id]?.key,
              let delegate = NSApp.delegate as? AppDelegate,
              let app = delegate.ghostty.app else { return }
        _ = ghostty_app_key(app, key.event)
    }
}
