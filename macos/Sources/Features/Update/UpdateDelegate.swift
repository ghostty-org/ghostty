import Sparkle
import Cocoa

class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }
        
        // Sparkle supports a native concept of "channels" but it requires that
        // you share a single appcast file. We don't want to do that so we
        // do this instead.
        switch (appDelegate.ghostty.config.autoUpdateChannel) {
        case .tip: return "https://tip.files.ghostty.org/appcast.xml"
        case .stable: return "https://release.files.ghostty.org/appcast.xml"
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // When the updater is relaunching the application we want to get macOS
        // to invalidate and re-encode all of our restorable state so that when
        // we relaunch it uses it.
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}
