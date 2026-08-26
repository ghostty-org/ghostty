import AppKit

/// Convenience interface for working with pasteboard strings.
extension NSPasteboard {
    @MainActor static let find = NSPasteboard(name: .find)

    /// The pasteboard's current string value.
    @MainActor var string: String? {
        get {
            string(forType: .string)
        }
        set {
            clearContents()
            if let newValue {
                setString(newValue, forType: .string)
            }
        }
    }
}
