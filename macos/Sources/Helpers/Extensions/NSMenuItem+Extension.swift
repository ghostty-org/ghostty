import AppKit

extension NSMenuItem {
    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        // We only set on macOS 26 when icons on menu items became the norm.
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }
}
