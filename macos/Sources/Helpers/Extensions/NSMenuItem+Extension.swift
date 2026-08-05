import AppKit

extension NSMenuItem {
    struct KeyEquivalentConfig {
        let keyEquivalent: String
        let keyEquivalentModifierMask: NSEvent.ModifierFlags
        let allowsAutomaticKeyEquivalentLocalization: Bool
        let allowsAutomaticKeyEquivalentMirroring: Bool
    }

    var keyEquivalentConfig: KeyEquivalentConfig {
        .init(
            keyEquivalent: keyEquivalent,
            keyEquivalentModifierMask: keyEquivalentModifierMask,
            allowsAutomaticKeyEquivalentLocalization: allowsAutomaticKeyEquivalentLocalization,
            allowsAutomaticKeyEquivalentMirroring: allowsAutomaticKeyEquivalentMirroring
        )
    }

    func update(with config: KeyEquivalentConfig) {
        self.keyEquivalent = config.keyEquivalent
        self.keyEquivalentModifierMask = config.keyEquivalentModifierMask
        self.allowsAutomaticKeyEquivalentLocalization = config.allowsAutomaticKeyEquivalentLocalization
        self.allowsAutomaticKeyEquivalentMirroring = config.allowsAutomaticKeyEquivalentMirroring
    }

    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        // We only set on macOS 26 when icons on menu items became the norm.
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }
}
