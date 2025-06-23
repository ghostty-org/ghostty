import GhosttyKit

extension Ghostty {
    /// `ghostty_command_s`
    struct Command: Sendable {
        private let cValue: ghostty_command_s

        /// The title of the command.
        var title: String {
            String(cString: cValue.title)
        }

        /// Human-friendly description of what this command will do.
        var description: String {
            String(cString: cValue.description)
        }

        /// The full action that must be performed to invoke this command.
        var action: String {
            String(cString: cValue.action)
        }

        /// Only the key portion of the action so you can compare action types, e.g. `goto_split`
        /// instead of `goto_split:left`.
        var actionKey: String {
            String(cString: cValue.action_key)
        }

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
            self.cValue = cValue
        }
    }
}
