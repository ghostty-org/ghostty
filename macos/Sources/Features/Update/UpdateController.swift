import Sparkle
import Cocoa

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update triggered manually.
    var shouldTerminateWithoutWarning: Bool {
        viewModel.state.shouldTerminateWithoutWarning
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    ///
    /// Disabled for Phantom: `feedURLString(for:)` (UpdateDelegate.swift) is
    /// unmodified from upstream and points at Ghostty's own appcast, since
    /// there's no Phantom release feed to point it at instead. Automatic
    /// checks are already off via `SUEnableAutomaticChecks` in
    /// Ghostty-Info.plist, but that flag doesn't gate this manual,
    /// menu-triggered path — left uncaught, "Install and Relaunch" would
    /// download a real, unmodified Ghostty release and install it in place
    /// of Phantom.
    @objc func checkForUpdates() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Phantom Doesn't Check for Updates"
        alert.informativeText = "Phantom is a personal fork you build and install by hand — there's no Phantom release feed. This is disabled so it can't offer to install a real Ghostty release over Phantom by mistake. Rebuild from source to pick up changes."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            return updater.canCheckForUpdates
        }
        return true
    }
}
