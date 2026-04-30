extension Ghostty.Input.Mods {
    /// Parses a comma-separated modifier string into `Ghostty.Input.Mods`.
    ///
    /// Recognized names: `shift`, `control`, `option`, `command`.
    /// Returns `nil` if any unrecognized modifier name is encountered.
    init?(scriptModifiers string: String) {
        self = []
        for part in string.split(separator: ",") {
            switch part.trimmingCharacters(in: .whitespaces).lowercased() {
            case "shift": insert(.shift)
            case "control": insert(.ctrl)
            case "option": insert(.alt)
            case "command": insert(.super)
            default: return nil
            }
        }
    }
}
