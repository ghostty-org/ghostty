import Cocoa

extension NSApplication {
    private static var presentationOptionCounts: [NSApplication.PresentationOptions.Element: UInt] = [:]

    /// Add a presentation option to the application and main a reference count so that and equal
    /// number of pops is required to disable it. This is useful so that multiple classes can affect global
    /// app state without overriding others.
    func acquirePresentationOption(_ option: NSApplication.PresentationOptions.Element) {
        Self.presentationOptionCounts[option, default: 0] += 1
        presentationOptions.insert(option)
    }

    /// See acquirePresentationOption
    func releasePresentationOption(_ option: NSApplication.PresentationOptions.Element) {
        guard let value = Self.presentationOptionCounts[option] else { return }
        guard value > 0 else { return }
        if (value == 1) {
            presentationOptions.remove(option)
            Self.presentationOptionCounts.removeValue(forKey: option)
        } else {
            Self.presentationOptionCounts[option] = value - 1
        }
    }
}

extension NSApplication.PresentationOptions.Element: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawValue)
    }
}
