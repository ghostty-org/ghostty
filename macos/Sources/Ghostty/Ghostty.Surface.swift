import GhosttyKit

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// NOTE(mitchellh): This is a work-in-progress class as part of a general refactor
    /// of our Ghostty data model. At the time of writing there's still a ton of surface
    /// functionality that is not encapsulated in this class. It is planned to migrate that
    /// all over.
    ///
    /// Wraps a `ghostty_surface_t`
    @MainActor
    final class Surface {
        private var surface: ghostty_surface_t?

        /// Read the underlying C value for this surface. This is unsafe because the value may be
        /// freed explicitly or when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t? {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        /// Free the underlying surface. This is safe to call multiple times.
        func free() {
            guard let surface else { return }
            self.surface = nil
            ghostty_surface_free(surface)
        }

        deinit {
            guard let surface else { return }
            guard !Thread.isMainThread else {
                // The surface remains registered with the app and holds unretained
                // userdata until it is freed. When already on the main thread, free
                // it synchronously so teardown completes before we disappear.
                ghostty_surface_free(surface)
                return
            }
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there
            Task.detached { @MainActor in
                ghostty_surface_free(surface)
            }
        }

        /// Send text to the terminal using paste semantics. This doesn't send key events, so keyboard
        /// shortcuts and other encodings do not take effect. Bracketed paste framing is applied when
        /// the terminal has enabled it.
        func sendText(_ text: String) {
            guard let surface else { return }
            let len = text.utf8CString.count
            if len == 0 { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Returns the modifiers that participate in text translation for key
        /// events on this surface. This honors configuration such as
        /// `macos-option-as-alt`, which may exclude option from translation.
        ///
        /// - Parameter mods: The full set of modifiers for the key event.
        /// - Returns: The subset of `mods` to use for keyboard layout translation.
        func keyTranslationMods(_ mods: Input.Mods) -> Input.Mods {
            guard let surface else { return mods }
            return Input.Mods(cMods: ghostty_surface_key_translation_mods(surface, mods.cMods))
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        func sendKeyEvent(_ event: Input.KeyEvent) {
            guard let surface else { return }
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Check if a key event matches a keybinding.
        ///
        /// This checks whether the given key event would trigger a keybinding in the terminal.
        /// If it matches, returns the binding flags indicating properties of the matched binding.
        ///
        /// - Parameter event: The key event to check
        /// - Returns: The binding flags if a binding matches, or nil if no binding matches
        func keyIsBinding(_ event: ghostty_input_key_s) -> Input.BindingFlags? {
            guard let surface else { return nil }
            var flags = ghostty_binding_flags_e(0)
            guard ghostty_surface_key_is_binding(surface, event, &flags) else { return nil }
            return Input.BindingFlags(cFlags: flags)
        }

        /// See `keyIsBinding(_ event: ghostty_input_key_s)`.
        func keyIsBinding(_ event: Input.KeyEvent) -> Input.BindingFlags? {
            event.withCValue { keyIsBinding($0) }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        var mouseCaptured: Bool {
            guard let surface else { return false }
            return ghostty_surface_mouse_captured(surface)
        }

        /// The PID of the foreground process group attached to the PTY.
        var foregroundPID: Int? {
            guard let surface else { return nil }
            let pid = ghostty_surface_foreground_pid(surface)
            guard pid != 0 else { return nil }
            return Int(exactly: pid)
        }

        /// The PTY device name for this surface.
        var ttyName: String? {
            guard let surface else { return nil }
            let ttyName = AllocatedString(ghostty_surface_tty_name(surface)).string
            return ttyName.isEmpty ? nil : ttyName
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            guard let surface else { return }
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        func sendMousePos(_ event: Input.MousePosEvent) {
            guard let surface else { return }
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            guard let surface else { return }
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        func perform(action: String) -> Bool {
            guard let surface else { return false }
            let len = action.utf8CString.count
            if len == 0 { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }
    }
}
