import Foundation
import AppKit

class ServiceProvider: NSObject {
    static private let errorNoString = NSString(string: "Could not load any text from the clipboard.")

    /// The target for an open operation
    enum OpenTarget {
        case tab
        case window
    }

    @objc func openTab(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminalFromPasteboard(pasteboard: pasteboard, target: .tab, error: error)
    }

    @objc func openWindow(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        openTerminalFromPasteboard(pasteboard: pasteboard, target: .window, error: error)
    }

    @inline(__always)
    private func openTerminalFromPasteboard(
        pasteboard: NSPasteboard,
        target: OpenTarget,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let objs = pasteboard.readObjects(forClasses: [NSURL.self]) as? [NSURL] else {
            error.pointee = Self.errorNoString
            return
        }
        let urlObjects = objs.map { $0 as URL }

        openTerminal(urlObjects, target: target)
    }

    private func openTerminal(_ urls: [URL], target: OpenTarget) {
        guard let delegateRaw = NSApp.delegate else { return }
        guard let delegate = delegateRaw as? AppDelegate else { return }
        let terminalManager = delegate.terminalManager

        let uniqueCwds: Set<URL> = Set(
            urls.map { url -> URL in
                // We only open in directories.
                url.hasDirectoryPath ? url : url.deletingLastPathComponent()
            }
        )

        for cwd in uniqueCwds {
            // Build our config
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = cwd.path(percentEncoded: false)

            switch (target) {
            case .window:
                terminalManager.newWindow(withBaseConfig: config)

            case .tab:
                terminalManager.newTab(withBaseConfig: config)
            }
        }

    }
}
