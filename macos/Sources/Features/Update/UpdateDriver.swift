import Cocoa
import Sparkle

/// Implement the SPUUserDriver to modify our UpdateViewModel for custom presentation.
class UpdateDriver: NSObject, SPUUserDriver {
    let viewModel: UpdateViewModel
    let standard: SPUStandardUserDriver
    private let installChannel: InstallChannel
    private var checkSource: UpdateCheckSource = .background

    private enum UpdateCheckSource {
        case user
        case background
    }

    private static let homebrewCommand = "brew update && brew upgrade --cask ghostree"
    
    init(viewModel: UpdateViewModel, hostBundle: Bundle, installChannel: InstallChannel) {
        self.viewModel = viewModel
        self.standard = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        self.installChannel = installChannel
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
        checkSource = .user
        viewModel.state = .checking(.init(cancel: cancellation))

        if installChannel != .homebrew && !hasUnobtrusiveTarget {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }
    
    func showUpdateFound(with appcastItem: SUAppcastItem,
                         state: SPUUserUpdateState,
                         reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        if installChannel == .homebrew {
            let source = consumeCheckSource()
            let shouldPresent = source == .user || hasFocusedUnobtrusiveTarget

            if shouldPresent {
                if hasUnobtrusiveTarget {
                    viewModel.state = .homebrewAvailable(.init(
                        appcastItem: appcastItem,
                        command: Self.homebrewCommand,
                        copyCommand: { [weak self] in
                            self?.copyHomebrewCommand()
                        },
                        openInGhostree: { [weak self] in
                            self?.copyHomebrewCommand()
                            self?.openHomebrewTerminal()
                        },
                        dismiss: { [weak self] in
                            reply(.dismiss)
                            self?.viewModel.state = .idle
                        }
                    ))
                } else if source == .user {
                    showHomebrewUpdateAlert(appcastItem: appcastItem, reply: reply)
                    viewModel.state = .idle
                } else {
                    reply(.dismiss)
                }
            } else {
                reply(.dismiss)
            }
            return
        }

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
        if installChannel == .homebrew {
            let source = consumeCheckSource()
            if source == .background {
                acknowledgement()
                return
            }
            if !hasUnobtrusiveTarget {
                showHomebrewUpToDateAlert()
                viewModel.state = .idle
                acknowledgement()
                return
            }
        }

        viewModel.state = .notFound(.init(acknowledgement: acknowledgement))
        
        if installChannel != .homebrew && !hasUnobtrusiveTarget {
            standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
        }
    }
    
    func showUpdaterError(_ error: any Error,
                          acknowledgement: @escaping () -> Void) {
        _ = consumeCheckSource()
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
        _ = consumeCheckSource()
        viewModel.state = .downloading(.init(
            cancel: cancellation,
            expectedLength: nil,
            progress: 0))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadInitiated(cancellation: cancellation)
        }
    }
    
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        _ = consumeCheckSource()
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
        _ = consumeCheckSource()
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
        _ = consumeCheckSource()
        viewModel.state = .extracting(.init(progress: 0))
        
        if !hasUnobtrusiveTarget {
            standard.showDownloadDidStartExtractingUpdate()
        }
    }
    
    func showExtractionReceivedProgress(_ progress: Double) {
        _ = consumeCheckSource()
        viewModel.state = .extracting(.init(progress: progress))
        
        if !hasUnobtrusiveTarget {
            standard.showExtractionReceivedProgress(progress)
        }
    }
    
    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        _ = consumeCheckSource()
        if !hasUnobtrusiveTarget {
            standard.showReady(toInstallAndRelaunch: reply)
        } else {
            reply(.install)
        }
    }
    
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        _ = consumeCheckSource()
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
        _ = consumeCheckSource()
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
        viewModel.state = .idle
    }
    
    func showUpdateInFocus() {
        _ = consumeCheckSource()
        if !hasUnobtrusiveTarget {
            standard.showUpdateInFocus()
        }
    }
    
    func dismissUpdateInstallation() {
        _ = consumeCheckSource()
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

    private var hasFocusedUnobtrusiveTarget: Bool {
        hasUnobtrusiveTarget && NSApp.isActive
    }

    private func consumeCheckSource() -> UpdateCheckSource {
        let source = checkSource
        checkSource = .background
        return source
    }

    private func copyHomebrewCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.homebrewCommand, forType: .string)
    }

    private func openHomebrewTerminal() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        let parentWindow = TerminalController.preferredParent?.window ?? NSApp.keyWindow
        if let parentWindow {
            _ = TerminalController.newTab(appDelegate.ghostty, from: parentWindow)
        } else {
            _ = TerminalController.newWindow(appDelegate.ghostty)
        }
    }

    private func showHomebrewUpdateAlert(appcastItem: SUAppcastItem, reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        let alert = NSAlert()
        let version = appcastItem.displayVersionString
        if version.isEmpty {
            alert.messageText = "Update via Homebrew"
        } else {
            alert.messageText = "Ghostree \(version) is available"
        }
        alert.informativeText = "This copy of Ghostree was installed via Homebrew.\n\nTo update, run:\n\(Self.homebrewCommand)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Ghostree Window")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            copyHomebrewCommand()
            openHomebrewTerminal()
        case .alertSecondButtonReturn:
            copyHomebrewCommand()
        default:
            break
        }

        reply(.dismiss)
    }

    private func showHomebrewUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Ghostree is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
