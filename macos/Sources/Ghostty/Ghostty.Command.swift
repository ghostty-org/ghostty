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
        let isSupported: Bool

        init(cValue: ghostty_command_s) {
            self.title = String(cString: cValue.title)
            self.description = String(cString: cValue.description)
            self.action = String(cString: cValue.action)
            self.actionKey = String(cString: cValue.action_key)
            self.isSupported = cValue.supported
        }
    }
}
