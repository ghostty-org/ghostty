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
    final class Surface: Sendable {
        private let surface: ghostty_surface_t

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t {
            surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t) {
            self.surface = cSurface
        }

        deinit {
            // deinit is not guaranteed to happen on the main actor and our API
            // calls into libghostty must happen there so we capture the surface
            // value so we don't capture `self` and then we detach it in a task.
            // We can't wait for the task to succeed so this will happen sometime
            // but that's okay.
            let surface = self.surface
            Task.detached { @MainActor in
                ghostty_surface_free(surface)
            }
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            let len = text.utf8CString.count
            if (len == 0) { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            ghostty_surface_mouse_captured(surface)
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
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
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
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
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
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
        @MainActor
        func perform(action: String) -> Bool {
            let len = action.utf8CString.count
            if (len == 0) { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }

        /// Command options for this surface.
        @MainActor
        func commands() throws -> [Command] {
            var ptr: UnsafeMutablePointer<ghostty_command_s>? = nil
            var count: Int = 0
            ghostty_surface_commands(surface, &ptr, &count)
            guard let ptr else { throw Error.apiFailed }
            let buffer = UnsafeBufferPointer(start: ptr, count: count)
            return Array(buffer).map { Command(cValue: $0) }.filter { $0.isSupported }
        }
    }
}
