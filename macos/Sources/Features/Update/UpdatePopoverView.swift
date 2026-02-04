import SwiftUI
import Sparkle
import AppKit

/// A popover view that displays detailed update information and action buttons.
///
/// The view adapts its content based on the current update state, showing appropriate
/// UI for checking, downloading, installing, or handling errors.
struct UpdatePopoverView: View {
    /// The update view model that provides the current state and information
    @ObservedObject var model: UpdateViewModel
    
    /// Environment value for dismissing the popover
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.state {
            case .idle:
                // Shouldn't happen in a well-formed view stack. Higher levels
                // should not call the popover for idles.
                EmptyView()
                
            case .permissionRequest(let request):
                PermissionRequestView(request: request, dismiss: dismiss)
                
            case .checking(let checking):
                CheckingView(checking: checking, dismiss: dismiss)
                
            case .updateAvailable(let update):
                UpdateAvailableView(update: update, dismiss: dismiss)
                
            case .homebrewAvailable(let update):
                HomebrewUpdateView(update: update, dismiss: dismiss)
                
            case .downloading(let download):
                DownloadingView(download: download, dismiss: dismiss)
                
            case .extracting(let extracting):
                ExtractingView(extracting: extracting)
                
            case .installing(let installing):
                // This is only required when `installing.isAutoUpdate == true`,
                // but we keep it anyway, just in case something unexpected
                // happens during installing
                InstallingView(installing: installing, dismiss: dismiss)
                
            case .notFound(let notFound):
                NotFoundView(notFound: notFound, dismiss: dismiss)
                
            case .error(let error):
                UpdateErrorView(error: error, dismiss: dismiss)
            }
        }
        .frame(width: 300)
    }
}

fileprivate struct PermissionRequestView: View {
    let request: UpdateState.PermissionRequest
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable automatic updates?")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("Ghostree can automatically check for updates in the background.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 8) {
                Button("Not Now") {
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: false,
                        sendSystemProfile: false))
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Allow") {
                    request.reply(SUUpdatePermissionResponse(
                        automaticUpdateChecks: true,
                        sendSystemProfile: false))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

fileprivate struct CheckingView: View {
    let checking: UpdateState.Checking
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking for updates…")
                    .font(.system(size: 13))
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    checking.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpdateAvailableView: View {
    let update: UpdateState.UpdateAvailable
    let dismiss: DismissAction
    
    private let labelWidth: CGFloat = 60
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update Available")
                        .font(.system(size: 13, weight: .semibold))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Version:")
                                .foregroundColor(.secondary)
                                .frame(width: labelWidth, alignment: .trailing)
                            Text(update.appcastItem.displayVersionString)
                        }
                        .font(.system(size: 11))
                        
                        if update.appcastItem.contentLength > 0 {
                            HStack(spacing: 6) {
                                Text("Size:")
                                    .foregroundColor(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(update.appcastItem.contentLength), countStyle: .file))
                            }
                            .font(.system(size: 11))
                        }
                        
                        if let date = update.appcastItem.date {
                            HStack(spacing: 6) {
                                Text("Released:")
                                    .foregroundColor(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .textSelection(.enabled)
                }
                
                HStack(spacing: 8) {
                    Button("Skip") {
                        update.reply(.skip)
                        dismiss()
                    }
                    .controlSize(.small)
                    
                    Button("Later") {
                        update.reply(.dismiss)
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    
                    Spacer()
                    
                    Button("Install and Relaunch") {
                        update.reply(.install)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(16)
            
            if let notes = update.releaseNotes {
                Divider()
                
                Link(destination: notes.url) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text(notes.label)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

fileprivate struct HomebrewUpdateView: View {
    let update: UpdateState.HomebrewUpdate
    let dismiss: DismissAction
    
    private let labelWidth: CGFloat = 60
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update via Homebrew")
                        .font(.system(size: 13, weight: .semibold))
                    
                    VStack(alignment: .leading, spacing: 4) {
                        let version = update.appcastItem.displayVersionString
                        if !version.isEmpty {
                            HStack(spacing: 6) {
                                Text("Version:")
                                    .foregroundColor(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                Text(version)
                            }
                            .font(.system(size: 11))
                        }
                        
                        if update.appcastItem.contentLength > 0 {
                            HStack(spacing: 6) {
                                Text("Size:")
                                    .foregroundColor(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(update.appcastItem.contentLength), countStyle: .file))
                            }
                            .font(.system(size: 11))
                        }
                        
                        if let date = update.appcastItem.date {
                            HStack(spacing: 6) {
                                Text("Released:")
                                    .foregroundColor(.secondary)
                                    .frame(width: labelWidth, alignment: .trailing)
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .textSelection(.enabled)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Run:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(update.command)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(6)
                    }
                }
                
                HStack(spacing: 8) {
                    Button(openButtonTitle) {
                        update.openInGhostree()
                        update.dismiss()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    
                    Button("Copy Command") {
                        update.copyCommand()
                        update.dismiss()
                        dismiss()
                    }
                    .controlSize(.small)
                    
                    Spacer()
                    
                    Button("Later") {
                        update.dismiss()
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            
            if let notes = update.releaseNotes {
                Divider()
                
                Link(destination: notes.url) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text(notes.label)
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.primary)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var openButtonTitle: String {
        if let window = NSApp.keyWindow, window.windowController is TerminalController {
            return "Open New Tab"
        }
        return "Open New Window"
    }
}

fileprivate struct DownloadingView: View {
    let download: UpdateState.Downloading
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Downloading Update")
                    .font(.system(size: 13, weight: .semibold))
                
                if let expectedLength = download.expectedLength, expectedLength > 0 {
                    let progress = min(1, max(0, Double(download.progress) / Double(expectedLength)))
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text(String(format: "%.0f%%", progress * 100))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            
            HStack {
                Spacer()
                Button("Cancel") {
                    download.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct ExtractingView: View {
    let extracting: UpdateState.Extracting
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preparing Update")
                .font(.system(size: 13, weight: .semibold))
            
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, extracting.progress)), total: 1.0)
                Text(String(format: "%.0f%%", min(1, max(0, extracting.progress)) * 100))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }
}

fileprivate struct InstallingView: View {
    let installing: UpdateState.Installing
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restart Required")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("The update is ready. Please restart the application to complete the installation.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack {
                Button("Restart Later") {
                    installing.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Restart Now") {
                    installing.retryTerminatingApplication()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct NotFoundView: View {
    let notFound: UpdateState.NotFound
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("No Updates Found")
                    .font(.system(size: 13, weight: .semibold))
                
                Text("You're already running the latest version.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack {
                Spacer()
                Button("OK") {
                    notFound.acknowledgement()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}

fileprivate struct UpdateErrorView: View {
    let error: UpdateState.Error
    let dismiss: DismissAction
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 13))
                    Text("Update Failed")
                        .font(.system(size: 13, weight: .semibold))
                }
                
                Text(error.error.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 8) {
                Button("OK") {
                    error.dismiss()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
                
                Spacer()
                
                Button("Retry") {
                    error.retry()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
            }
        }
        .padding(16)
    }
}
