import Foundation
import SwiftUI
import Sparkle

class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
    
    /// The text to display for the current update state.
    /// Returns an empty string for idle state, progress percentages for downloading/extracting,
    /// or descriptive text for other states.
    var text: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Enable Automatic Updates?"
        case .checking:
            return "Checking for Updates…"
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            if !version.isEmpty {
                return "Update Available: \(version)"
            }
            return "Update Available"
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let progress = Double(download.progress) / Double(expectedLength)
                return String(format: "Downloading: %.0f%%", progress * 100)
            }
            return "Downloading…"
        case .extracting(let extracting):
            return String(format: "Preparing: %.0f%%", extracting.progress * 100)
        case .installing(let install):
            return install.isAutoUpdate ? "Restart to Complete Update" : "Installing…"
        case .notFound:
            return "No Updates Available"
        case .error(let err):
            return err.error.localizedDescription
        }
    }
    
    /// The maximum width text for states that show progress.
    /// Used to prevent the pill from resizing as percentages change.
    var maxWidthText: String {
        switch state {
        case .downloading:
            return "Downloading: 100%"
        case .extracting:
            return "Preparing: 100%"
        default:
            return text
        }
    }
    
    /// The SF Symbol icon name for the current update state.
    var iconName: String? {
        switch state {
        case .idle:
            return nil
        case .permissionRequest:
            return "questionmark.circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .updateAvailable:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle"
        case .extracting:
            return "shippingbox"
        case .installing:
            return "power.circle"
        case .notFound:
            return "info.circle"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
    
    /// A longer description for the current update state.
    /// Used in contexts like the command palette where more detail is helpful.
    var description: String {
        switch state {
        case .idle:
            return ""
        case .permissionRequest:
            return "Configure automatic update preferences"
        case .checking:
            return "Please wait while we check for available updates"
        case .updateAvailable(let update):
            return update.releaseNotes?.label ?? "Download and install the latest version"
        case .downloading:
            return "Downloading the update package"
        case .extracting:
            return "Extracting and preparing the update"
        case let .installing(install):
            return install.isAutoUpdate ? "Restart to Complete Update" : "Installing update and preparing to restart"
        case .notFound:
            return "You are running the latest version"
        case .error:
            return "An error occurred during the update process"
        }
    }
    
    /// A badge to display for the current update state.
    /// Returns version numbers, progress percentages, or nil.
    var badge: String? {
        switch state {
        case .updateAvailable(let update):
            let version = update.appcastItem.displayVersionString
            return version.isEmpty ? nil : version
        case .downloading(let download):
            if let expectedLength = download.expectedLength, expectedLength > 0 {
                let percentage = Double(download.progress) / Double(expectedLength) * 100
                return String(format: "%.0f%%", percentage)
            }
            return nil
        case .extracting(let extracting):
            return String(format: "%.0f%%", extracting.progress * 100)
        default:
            return nil
        }
    }
    
    /// The color to apply to the icon for the current update state.
    var iconColor: Color {
        switch state {
        case .idle:
            return .secondary
        case .permissionRequest:
            return .white
        case .checking:
            return .secondary
        case .updateAvailable:
            return .accentColor
        case .downloading, .extracting, .installing:
            return .secondary
        case .notFound:
            return .secondary
        case .error:
            return .orange
        }
    }
    
    /// The background color for the update pill.
    var backgroundColor: Color {
        switch state {
        case .permissionRequest:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue)
        case .updateAvailable:
            return .accentColor
        case .notFound:
            return Color(nsColor: NSColor.systemBlue.blended(withFraction: 0.5, of: .black) ?? .systemBlue)
        case .error:
            return .orange.opacity(0.2)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }
    
    /// The foreground (text) color for the update pill.
    var foregroundColor: Color {
        switch state {
        case .permissionRequest:
            return .white
        case .updateAvailable:
            return .white
        case .notFound:
            return .white
        case .error:
            return .orange
        default:
            return .primary
        }
    }
}

enum UpdateState: Equatable {
    case idle
    case permissionRequest(PermissionRequest)
    case checking(Checking)
    case updateAvailable(UpdateAvailable)
    case notFound(NotFound)
    case error(Error)
    case downloading(Downloading)
    case extracting(Extracting)
    case installing(Installing)
    
    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
    
    /// This is true if we're in a state that can be force installed. 
    var isInstallable: Bool {
        switch (self) {
        case .checking,
                .updateAvailable,
                .downloading,
                .extracting,
                .installing:
            return true
            
        default:
            return false
        }
    }
    
    func cancel() {
        switch self {
        case .checking(let checking):
            checking.cancel()
        case .updateAvailable(let available):
            available.reply(.dismiss)
        case .downloading(let downloading):
            downloading.cancel()
        case .notFound(let notFound):
            notFound.acknowledgement()
        case .error(let err):
            err.dismiss()
        default:
            break
        }
    }
    
    /// Confirms or accepts the current update state.
    /// - For available updates: begins installation
    /// - For ready-to-install: proceeds with installation
    func confirm() {
        switch self {
        case .updateAvailable(let available):
            available.reply(.install)
        default:
            break
        }
    }
    
    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case (.permissionRequest, .permissionRequest):
            return true
        case (.checking, .checking):
            return true
        case (.updateAvailable(let lUpdate), .updateAvailable(let rUpdate)):
            return lUpdate.appcastItem.displayVersionString == rUpdate.appcastItem.displayVersionString
        case (.notFound, .notFound):
            return true
        case (.error(let lErr), .error(let rErr)):
            return lErr.error.localizedDescription == rErr.error.localizedDescription
        case (.downloading(let lDown), .downloading(let rDown)):
            return lDown.progress == rDown.progress && lDown.expectedLength == rDown.expectedLength
        case (.extracting(let lExt), .extracting(let rExt)):
            return lExt.progress == rExt.progress
        case (.installing(let lInstall), .installing(let rInstall)):
            return lInstall.isAutoUpdate == rInstall.isAutoUpdate
        default:
            return false
        }
    }
    
    struct NotFound {
        let acknowledgement: () -> Void
    }
    
    struct PermissionRequest {
        let request: SPUUpdatePermissionRequest
        let reply: @Sendable (SUUpdatePermissionResponse) -> Void
    }
    
    struct Checking {
        let cancel: () -> Void
    }
    
    struct UpdateAvailable {
        let appcastItem: SUAppcastItem
        let reply: @Sendable (SPUUserUpdateChoice) -> Void
        
        var releaseNotes: ReleaseNotes? {
            let currentCommit = Bundle.main.infoDictionary?["GhosttyCommit"] as? String
            return ReleaseNotes(displayVersionString: appcastItem.displayVersionString, currentCommit: currentCommit)
        }
    }
    
    enum ReleaseNotes {
        case commit(URL)
        case compareTip(URL)
        case tagged(URL)
        
        init?(displayVersionString: String, currentCommit: String?) {
            let version = displayVersionString
            
            // Check for semantic version (x.y.z)
            if let semver = Self.extractSemanticVersion(from: version) {
                let slug = semver.replacingOccurrences(of: ".", with: "-")
                if let url = URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)") {
                    self = .tagged(url)
                    return
                }
            }
            
            // Fall back to git hash detection
            guard let newHash = Self.extractGitHash(from: version) else {
                return nil
            }
            
            if let currentHash = currentCommit, !currentHash.isEmpty,
               let url = URL(string: "https://github.com/ghostty-org/ghostty/compare/\(currentHash)...\(newHash)") {
                self = .compareTip(url)
            } else if let url = URL(string: "https://github.com/ghostty-org/ghostty/commit/\(newHash)") {
                self = .commit(url)
            } else {
                return nil
            }
        }
        
        private static func extractSemanticVersion(from version: String) -> String? {
            let pattern = #"^\d+\.\d+\.\d+$"#
            if version.range(of: pattern, options: .regularExpression) != nil {
                return version
            }
            return nil
        }
        
        private static func extractGitHash(from version: String) -> String? {
            let pattern = #"[0-9a-f]{7,40}"#
            if let range = version.range(of: pattern, options: .regularExpression) {
                return String(version[range])
            }
            return nil
        }
        
        var url: URL {
            switch self {
            case .commit(let url): return url
            case .compareTip(let url): return url
            case .tagged(let url): return url
            }
        }
        
        var label: String {
            switch (self) {
            case .commit: return "View GitHub Commit"
            case .compareTip: return "Changes Since This Tip Release"
            case .tagged: return "View Release Notes"
            }
        }
    }
    
    struct Error {
        let error: any Swift.Error
        let retry: () -> Void
        let dismiss: () -> Void
    }
    
    struct Downloading {
        let cancel: () -> Void
        let expectedLength: UInt64?
        let progress: UInt64
    }
    
    struct Extracting {
        let progress: Double
    }
    
    struct Installing {
        /// True if this state is triggered by ``Ghostty/UpdateDriver/updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)``
        var isAutoUpdate = false
        let retryTerminatingApplication: () -> Void
        let dismiss: () -> Void
    }
}
