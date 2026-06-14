import Cocoa
import GhosttyKit

extension NSEvent {
    /// Create a Ghostty key event for a given keyboard action.
    ///
    /// This will not set the "text" or "composing" fields since these can't safely be set
    /// with the information or lifetimes given.
    ///
    /// The translationMods should be set to the modifiers used for actual character
    /// translation if available.
    func ghosttyKeyEvent(
        _ action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var key_ev: ghostty_input_key_s = .init()
        key_ev.action = action
        key_ev.keycode = UInt32(keyCode)

        // We can't infer or set these safely from this method. Since text is
        // a cString, we can't use self.characters because of garbage collection.
        // We have to let the caller handle this.
        key_ev.text = nil
        key_ev.composing = false

        // macOS provides no easy way to determine the consumed modifiers for
        // producing text. We apply a simple heuristic here that has worked for years
        // so far: control and command never contribute to the translation of text,
        // assume everything else did.
        key_ev.mods = Ghostty.ghosttyMods(modifierFlags)
        key_ev.consumed_mods = Ghostty.ghosttyMods(
            (translationMods ?? modifierFlags)
                .subtracting([.control, .command]))

        // `charactersIgnoringModifiers` returns a control character when Ctrl is
        // held (e.g. Ctrl+A yields U+0001, not "a"), so it does not give the true
        // unmodified character. `characters(byApplyingModifiers: [])` does. Ignore
        // multi-codepoint results.
        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        return key_ev
    }

    /// Returns the text to send to Ghostty for this key event.
    ///
    /// macOS returns "" for `characters` while Command is held and produces
    /// control characters while Control is held, so under either we re-derive the
    /// produced character via `characters(byApplyingModifiers:)` with the
    /// translation modifiers (Shift, Option, Caps).
    var ghosttyCharacters: String? {
        if modifierFlags.contains(.command) || modifierFlags.contains(.control) {
            return self.characters(byApplyingModifiers: modifierFlags.intersection([.shift, .option, .capsLock]))
        }

        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // C0 control characters come from keys like Enter and Tab, which
            // Ghostty's KeyEncoder maps from the keycode rather than from text.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags)
            }

            // Drop function keys that are encoded in the Private Use Area
            // U+F700–U+F8FF so they don't reach Ghostty as text.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
