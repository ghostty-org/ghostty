import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // Ghostties-specific appcast feeds (not upstream Ghostty).
        // Hosted on ghostties.org (Vercel) — updated by release workflow after each tag.
        // Stable channel: only receives non-beta releases.
        // Tip/beta channel: receives all releases including betas.
        switch appDelegate.ghostty.config.autoUpdateChannel {
        case .tip: return "https://ghostties.org/appcast-beta.xml"
        case .stable: return "https://ghostties.org/appcast-stable.xml"
        }
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // When the updater is relaunching the application we want to get macOS
        // to invalidate and re-encode all of our restorable state so that when
        // we relaunch it uses it.
        NSApp.invalidateRestorableState()
        for window in NSApp.windows { window.invalidateRestorableState() }
    }
}
