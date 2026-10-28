import Sparkle
import Cocoa
import Combine
import SwiftUI

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
    func checkForUpdates() {
        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }

        if case let .installing(installing) = viewModel.state {
            // If the update is already installed, we can't actually
            // cancel it, and SPUUpdater.checkForUpdates will simply fail,
            // so we just show an alert to remind the user to restart.
            let alert = NSAlert()
            alert.alertStyle = .informational
            let accessoryView = NSHostingView(
                rootView: InstallingAccessoryView(installing: installing)
                    .frame(width: 228, alignment: .leading)
            )
            accessoryView.frame = .init(origin: .zero, size: accessoryView.fittingSize)
            alert.accessoryView = accessoryView
            alert.addButton(withTitle: "Restart Now")
            alert.addButton(withTitle: "Restart Later")
                .keyEquivalent = .init([KeyboardShortcut(.escape).key.character])
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                viewModel.state.confirm()
            default:
                break
            }
            return
        }

        // If we're not idle then we need to cancel any prior state.
        viewModel.state.cancel()

        // The above will take time to settle, so we delay the check for some time.
        // The 100ms is arbitrary and I'd rather not, but we have to wait more than
        // one loop tick it seems.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.updater.checkForUpdates()
        }
    }
}

private struct InstallingAccessoryView: View {
    let installing: UpdateState.Installing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restart Required")
                    .font(.system(size: 13, weight: .semibold))

                Text("The update is ready. Please restart the application to complete the installation.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let item = installing.appcastItem, let releaseNotesURL = installing.releaseNotes?.url {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(destination: releaseNotesURL) {
                            HStack(spacing: 6) {
                                Text("Version:")
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(item.displayVersionString)
                            }
                            .font(.system(size: 11))
                        }

                        if let date = item.date {
                            HStack(spacing: 6) {
                                Text("Released:")
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }
}
