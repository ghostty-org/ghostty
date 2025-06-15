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

        // Our unshifted codepoint is the codepoint with no modifiers. We
        // ignore multi-codepoint values. We have to use `byApplyingModifiers`
        // instead of `charactersIgnoringModifiers` because the latter changes
        // behavior with ctrl pressed and we don't want any of that.
        key_ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                key_ev.unshifted_codepoint = codepoint.value
            }
        }

        return key_ev
    }

    /// Returns the text to set for a key event for Ghostty.
    ///
    /// This namely contains logic to avoid control characters, since we handle control character
    /// mapping manually within Ghostty.
    var ghosttyCharacters: String? {
        // If we have no characters associated with this event we do nothing.
        guard let characters else { return nil }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first {
            // If we have a single control character, then we return the characters
            // without control pressed. We do this because we handle control character
            // encoding directly within Ghostty's KeyEncoder.
            if scalar.value < 0x20 {
                return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control))
            }

            // If we have a single value in the PUA, then it's a function key and
            // we don't want to send PUA ranges down to Ghostty.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
