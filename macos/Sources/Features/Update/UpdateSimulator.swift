import Foundation
import Sparkle

/// Simulates various update scenarios for testing the update UI.
///
/// The expected usage is by overriding the `checkForUpdates` function in AppDelegate and
/// calling one of these instead. This will allow us to test the update flows without having to use
/// real updates.
enum UpdateSimulator {
    /// Complete successful update flow: checking → available → download → extract → ready → install → idle
    case happyPath
    
    /// No updates available: checking (2s) → "No Updates Available" (3s) → idle
    case notFound
    
    /// Error during check: checking (2s) → error with retry callback
    case error
    
    /// Slower download for testing progress UI: checking → available → download (20 steps, ~10s) → extract → install
    case slowDownload
    
    /// Initial permission request flow: shows permission dialog → proceeds with happy path if accepted
    case permissionRequest
    
    /// User cancels during download: checking → available → download (5 steps) → cancels → idle
    case cancelDuringDownload
    
    /// User cancels while checking: checking (1s) → cancels → idle
    case cancelDuringChecking
    
    /// Shows the installing state with restart button: installing (stays until dismissed)
    case installing
    
    /// Simulates auto-update flow: goes directly to installing state without showing intermediate UI
    case autoUpdate
    
    func simulate(with viewModel: UpdateViewModel) {
        switch self {
        case .happyPath:
            simulateHappyPath(viewModel)
        case .notFound:
            simulateNotFound(viewModel)
        case .error:
            simulateError(viewModel)
        case .slowDownload:
            simulateSlowDownload(viewModel)
        case .permissionRequest:
            simulatePermissionRequest(viewModel)
        case .cancelDuringDownload:
            simulateCancelDuringDownload(viewModel)
        case .cancelDuringChecking:
            simulateCancelDuringChecking(viewModel)
        case .installing:
            simulateInstalling(viewModel)
        case .autoUpdate:
            simulateAutoUpdate(viewModel)
        }
    }
    
    private func simulateHappyPath(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: SUAppcastItem.empty(),
                reply: { choice in
                    if choice == .install {
                        simulateDownload(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }
    
    private func simulateNotFound(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .notFound(.init(acknowledgement: {
                // Acknowledgement called when dismissed
            }))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                viewModel.state = .idle
            }
        }
    }
    
    private func simulateError(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .error(.init(
                error: NSError(domain: "UpdateError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to check for updates"
                ]),
                retry: {
                    simulateHappyPath(viewModel)
                },
                dismiss: {
                    viewModel.state = .idle
                }
            ))
        }
    }
    
    private func simulateSlowDownload(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: SUAppcastItem.empty(),
                reply: { choice in
                    if choice == .install {
                        simulateSlowDownloadProgress(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }
    
    private func simulateSlowDownloadProgress(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)
        
        for i in 1...20 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 2000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)
                
                if i == 20 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateExtract(viewModel)
                    }
                }
            }
        }
    }
    
    private func simulatePermissionRequest(_ viewModel: UpdateViewModel) {
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        viewModel.state = .permissionRequest(.init(
            request: request,
            reply: { response in
                if response.automaticUpdateChecks {
                    simulateHappyPath(viewModel)
                } else {
                    viewModel.state = .idle
                }
            }
        ))
    }
    
    private func simulateCancelDuringDownload(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.state = .updateAvailable(.init(
                appcastItem: SUAppcastItem.empty(),
                reply: { choice in
                    if choice == .install {
                        simulateDownloadThenCancel(viewModel)
                    } else {
                        viewModel.state = .idle
                    }
                }
            ))
        }
    }
    
    private func simulateDownloadThenCancel(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)
        
        for i in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 1000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)
                
                if i == 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        viewModel.state = .idle
                    }
                }
            }
        }
    }
    
    private func simulateCancelDuringChecking(_ viewModel: UpdateViewModel) {
        viewModel.state = .checking(.init(cancel: {
            viewModel.state = .idle
        }))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            viewModel.state = .idle
        }
    }
    
    private func simulateDownload(_ viewModel: UpdateViewModel) {
        let download = UpdateState.Downloading(
            cancel: {
                viewModel.state = .idle
            },
            expectedLength: nil,
            progress: 0
        )
        viewModel.state = .downloading(download)
        
        for i in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.3) {
                let updatedDownload = UpdateState.Downloading(
                    cancel: download.cancel,
                    expectedLength: 1000,
                    progress: UInt64(i * 100)
                )
                viewModel.state = .downloading(updatedDownload)
                
                if i == 10 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateExtract(viewModel)
                    }
                }
            }
        }
    }
    
    private func simulateExtract(_ viewModel: UpdateViewModel) {
        viewModel.state = .extracting(.init(progress: 0.0))
        
        for j in 1...5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(j) * 0.3) {
                viewModel.state = .extracting(.init(progress: Double(j) / 5.0))
                
                if j == 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        simulateInstalling(viewModel)
                    }
                }
            }
        }
    }
    
    private func simulateInstalling(_ viewModel: UpdateViewModel) {
        viewModel.state = .installing(.init(
            retryTerminatingApplication: {
                print("Restart button clicked in simulator - resetting to idle")
                viewModel.state = .idle
            },
            dismiss: {
                viewModel.state = .idle
            }
        ))
    }
    
    private func simulateAutoUpdate(_ viewModel: UpdateViewModel) {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: {
                print("Restart button clicked in simulator - resetting to idle")
                viewModel.state = .idle
            },
            dismiss: {
                viewModel.state = .idle
            }
        ))
    }
}
