import SwiftUI

extension View {
    /// Returns the ghostty icon to use for views.
    func ghosttyIconImage() -> Image {
        #if os(macOS)
        // Grab the icon from the running application. This is the best way
        // I've found so far to get the proper icon for our current icon
        // tinting and so on with macOS Tahoe
        if let icon = NSRunningApplication.current.icon {
            return Image(nsImage: icon)
        }

        // Get our defined application icon image.
        if let nsImage = NSApp.applicationIconImage {
            return Image(nsImage: nsImage)
        }
        #endif

        // Fall back to a static representation
        return Image("AppIconImage")
    }
}
