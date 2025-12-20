import AppKit

/// This class lives as long as the app is in the Dock.
/// If the user pins the app to the Dock, it will not be deallocated.
/// Be careful when storing state in this class.
class DockTilePlugin: NSObject, NSDockTilePlugIn {
    private let pluginBundle = Bundle(for: DockTilePlugin.self)
    #if DEBUG
    private let ghosttyUserDefaults = UserDefaults(suiteName: "com.mitchellh.ghostty.debug")
    #else
    private let ghosttyUserDefaults = UserDefaults(suiteName: "com.mitchellh.ghostty")
    #endif

    private var iconChangeObserver: Any?

    func setDockTile(_ dockTile: NSDockTile?) {
        guard let dockTile, let ghosttyUserDefaults else {
            iconChangeObserver = nil
            return
        }
        // Try to restore the previous icon on launch.
        iconDidChange(ghosttyUserDefaults.appIcon, dockTile: dockTile)

        iconChangeObserver = DistributedNotificationCenter.default().publisher(for: Ghostty.Notification.ghosttyIconDidChange)
            .map { [weak self] _ in
                self?.ghosttyUserDefaults?.appIcon
            }
            .receive(on: DispatchQueue.global())
            .sink { [weak self] newIcon in
                guard let self else { return }
                iconDidChange(newIcon, dockTile: dockTile)
            }
    }

    func getGhosttyAppPath() -> String {
        var url = pluginBundle.bundleURL
        // Remove "/Contents/PlugIns/DockTilePlugIn.bundle" from the bundle URL to reach Ghostty.app.
        while url.lastPathComponent != "Ghostty.app", !url.lastPathComponent.isEmpty {
            url.deleteLastPathComponent()
        }
        return url.path
    }

    func iconDidChange(_ newIcon: Ghostty.CustomAppIcon?, dockTile: NSDockTile) {
        guard let appIcon = newIcon?.image(in: pluginBundle) else {
            resetIcon(dockTile: dockTile)
            return
        }
        let appBundlePath = getGhosttyAppPath()
        NSWorkspace.shared.setIcon(appIcon, forFile: appBundlePath)
        NSWorkspace.shared.noteFileSystemChanged(appBundlePath)

        dockTile.setIcon(appIcon)
    }

    func resetIcon(dockTile: NSDockTile) {
        let appBundlePath = getGhosttyAppPath()
        let appIcon: NSImage
        if #available(macOS 26.0, *) {
            // Reset to the default (glassy) icon.
            NSWorkspace.shared.setIcon(nil, forFile: appBundlePath)
            #if DEBUG
            // Use the `Blueprint` icon to
            // distinguish Debug from Release builds.
            appIcon = pluginBundle.image(forResource: "BlueprintImage")!
            #else
            // Get the composed icon from the app bundle.
            if let iconRep = NSWorkspace.shared.icon(forFile: appBundlePath).bestRepresentation(for: CGRect(origin: .zero, size: dockTile.size), context: nil, hints: nil) {
                appIcon = NSImage(size: dockTile.size)
                appIcon.addRepresentation(iconRep)
            } else {
                // If something unexpected happens on macOS 26,
                // fall back to a bundled icon.
                appIcon = pluginBundle.image(forResource: "AppIconImage")!
            }
            #endif
        } else {
            // Use the bundled icon to keep the corner radius
            // consistent with other apps.
            appIcon = pluginBundle.image(forResource: "AppIconImage")!
            NSWorkspace.shared.setIcon(appIcon, forFile: appBundlePath)
        }
        NSWorkspace.shared.noteFileSystemChanged(appBundlePath)
        dockTile.setIcon(appIcon)
    }
}

private extension NSDockTile {
    func setIcon(_ newIcon: NSImage) {
        // Update the Dock tile on the main thread.
        DispatchQueue.main.async {
            let iconView = NSImageView(frame: CGRect(origin: .zero, size: self.size))
            iconView.wantsLayer = true
            iconView.image = newIcon
            self.contentView = iconView
            self.display()
        }
    }
}

extension NSDockTile: @unchecked @retroactive Sendable {}

#if DEBUG
private extension NSAlert {
    static func notify(_ message: String, image: NSImage?) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = message
            alert.icon = image
            _ = alert.runModal()
        }
    }
}
#endif

