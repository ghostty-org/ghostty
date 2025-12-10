import Cocoa
import Sparkle

/// Implement the SPUUserDriver to modify our UpdateViewModel for custom presentation.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    let standard: SPUStandardUserDriver
    
    init(viewModel: UpdateViewModel, hostBundle: Bundle) {
        self.viewModel = viewModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTerminalWindowWillClose),
            name: TerminalWindow.terminalWillCloseNotification,
            object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleTerminalWindowWillClose() {
        // If we lost the ability to show unobtrusive states, cancel whatever
        // update state we're in. This will allow the manual `check for updates`
        // call to initialize the standard driver.
        //
        // We have to do this after a short delay so that the window can fully
        // close.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self else { return }
            guard !hasUnobtrusiveTarget else { return }
            viewModel.state.cancel()
            viewModel.state = .idle
        }
    }
    
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
        viewModel.state = .permissionRequest(.init(request: request, reply: { [weak viewModel] response in
            viewModel?.state = .idle
            reply(response)
        }))
        if !hasUnobtrusiveTarget {
            standard.show(request, reply: reply)
        }
    }
    
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        viewModel.state = .checking(.init(cancel: cancellation))

        if !hasUnobtrusiveTarget {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }
    
    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        viewModel.state = .updateAvailable(.init(appcastItem: appcastItem, reply: reply))
        if !hasUnobtrusiveTarget {
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        }
    }
    
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // We don't do anything with the release notes here because Ghostty
        // doesn't use the release notes feature of Sparkle currently.
    }
    
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // We don't do anything with release notes. See `showUpdateReleaseNotes`
    }
    
    func showUpdateNotFoundWithError(_ error: any Error,
                                     acknowledgement: @escaping () -> Void) {
        viewModel.state = .notFound(.init(acknowledgement: acknowledgement))
        
        if !hasUnobtrusiveTarget {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }
    
    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        viewModel.state = .error(.init(
            error: error,
            retry: { [weak self, weak viewModel] in
                viewModel?.state = .idle
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard let delegate = NSApp.delegate as? AppDelegate else { return }
                    delegate.checkForUpdates(self)
                }
            },
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }))
        
        if !hasUnobtrusiveTarget {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
        } else {
            acknowledgement()
        }
    }
    
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        viewModel.state = .downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadInitiated(cancellation: cancellation)
        }
    }
    
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }
            
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: expectedContentLength,
            progress: 0))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
        }
    }
    
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard case let .downloading(downloading) = viewModel.state else {
            return
        }
        
        viewModel.state = .downloading(.init(
            cancel: downloading.cancel,
            expectedLength: downloading.expectedLength,
            progress: downloading.progress + length))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadDidReceiveData(ofLength: length)
        }
    }
    
    func showDownloadDidStartExtractingUpdate() {
        viewModel.state = .extracting(.init(progress: 0))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }
    
    func showExtractionReceivedProgress(_ progress: Double) {
        viewModel.state = .extracting(.init(progress: progress))
        
        if !hasUnobtrusiveTarget {
            standard.showExtractionReceivedProgress(progress)
        }
    }
    
    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        if !hasUnobtrusiveTarget {
            standard.showReady(toInstallAndRelaunch: reply)
        } else {
            reply(.install)
        }
    }
    
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        viewModel.state = .installing(.init(
            retryTerminatingApplication: retryTerminatingApplication,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        
        if !hasUnobtrusiveTarget {
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
        }
    }
    
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
        viewModel.state = .idle
    }
    
    func showUpdateInFocus() {
        if !hasUnobtrusiveTarget {
            standard.showUpdateInFocus()
        }
    }
    
    func dismissUpdateInstallation() {
        viewModel.state = .idle
        standard.dismissUpdateInstallation()
    }
    
    // MARK: No-Window Fallback
    
    /// True if there is a target that can render our unobtrusive update checker.
    var hasUnobtrusiveTarget: Bool {
        NSApp.windows.contains { window in
            (window is TerminalWindow || window is QuickTerminalWindow) &&
            window.isVisible
        }
    }
}
