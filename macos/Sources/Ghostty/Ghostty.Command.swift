import GhosttyKit

extension Ghostty {
    /// `ghostty_command_s`
    struct Command: Sendable {
        /// The title of the command.
        let title: String

        /// Human-friendly description of what this command will do.
        let description: String

        /// The full action that must be performed to invoke this command.
        let action: String

        /// Only the key portion of the action so you can compare action types, e.g. `goto_split`
        /// instead of `goto_split:left`.
        let actionKey: String

        /// True if this can be performed on this target.
        var isSupported: Bool {
            !Self.unsupportedActionKeys.contains(actionKey)
        }

        /// Unsupported action keys, because they either don't make sense in the context of our
        /// target platform or they just aren't implemented yet.
        static let unsupportedActionKeys: [String] = [
            "toggle_tab_overview",
            "toggle_window_decorations",
            "show_gtk_inspector",
        ]

        init(cValue: ghostty_command_s) {
            self.title = String(cString: cValue.title)
            self.description = String(cString: cValue.description)
            self.action = String(cString: cValue.action)
            self.actionKey = String(cString: cValue.action_key)
        }
    }
}
