#if canImport(AppKit)

/// Normalizes the interface between NSPasteboard and UIPasteboard for working with pasteboard
/// strings.
extension OSPasteboard {
    @MainActor static let find = OSPasteboard(name: .find)

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

#elseif canImport(UIKit)

extension OSPasteboard {
    static let find = OSPasteboard.withUniqueName()
}

#endif
