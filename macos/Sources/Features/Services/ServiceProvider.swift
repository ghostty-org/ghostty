import Foundation
import AppKit

class ServiceProvider: NSObject {
    static private let errorNoString = NSString(string: "Could not load any text from the clipboard.")

    /// The target for an open operation
    private enum OpenTarget {
        case tab
        case window
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminal(from: pasteboard, target: .tab, error: error)
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminal(from: pasteboard, target: .window, error: error)
    }

    private func openTerminal(
        from pasteboard: NSPasteboard,
        target: OpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        guard let pathURLs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            error.pointee = Self.errorNoString
            return
        }

        // Build a set of unique directory URLs to open. File paths are truncated
        // to their directories because that's the only thing we can open.
        let directoryURLs = Set(
            pathURLs.map { url -> URL in
                url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            }
        )

        for url in directoryURLs {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = url.path(percentEncoded: false)

            switch (target) {
            case .window:
                _ = TerminalController.newWindow(delegate.ghostty, withBaseConfig: config)

            case .tab:
                _ = TerminalController.newTab(delegate.ghostty, withBaseConfig: config)
            }
        }

    }
}
