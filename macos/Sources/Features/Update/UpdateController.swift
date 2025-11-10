import Sparkle
import Cocoa
import Combine

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?
    
    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }
    
    /// True if we're installing an update.
    var isInstalling: Bool {
        installCancellable != nil
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
    
    deinit {
        installCancellable?.cancel()
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
    
    /// Force install the current update. As long as we're in some "update available" state this will
    /// trigger all the steps necessary to complete the update.
    func installUpdate() {
        // Must be in an installable state
        guard viewModel.state.isInstallable else { return }
        
        // If we're already force installing then do nothing.
        guard installCancellable == nil else { return }
        
        // Setup a combine listener to listen for state changes and to always
        // confirm them. If we go to a non-installable state, cancel the listener.
        // The sink runs immediately with the current state, so we don't need to
        // manually confirm the first state.
        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }
            
            // If we move to a non-installable state (error, idle, etc.) then we
            // stop force installing.
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }
            
            // Continue the `yes` chain!
            state.confirm()
        }
    }
    
    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }
        
        // If we're not idle then we need to cancel any prior state.
        installCancellable?.cancel()
        viewModel.state.cancel()
        
        // The above will take time to settle, so we delay the check for some time.
        // The 100ms is arbitrary and I'd rather not, but we have to wait more than
        // one loop tick it seems.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.updater.checkForUpdates()
        }
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
