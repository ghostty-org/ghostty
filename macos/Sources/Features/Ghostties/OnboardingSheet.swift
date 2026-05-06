import AppKit
import SwiftUI

/// First-launch welcome sheet. Presented once, on fresh install, over the
/// project-first sidebar. Dismissed via the "Get started" button, after which
/// `ghostties.hasSeenOnboarding` is set so it never appears again.
@MainActor
struct OnboardingSheet: View {
    let onDismiss: () -> Void

    private let buildVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }()

    private let buildNumber: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }()

    private let buildDate: String = {
        guard let execPath = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: execPath),
              let modDate = attrs[.modificationDate] as? Date else {
            return "Unknown"
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        fmt.locale = Locale(identifier: "en_US")
        return fmt.string(from: modDate)
    }()

    /// Whether `gt` is available on PATH. nil = not yet checked.
    @State private var gtInstalled: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Use the sidebar to manage multiple repos, agent threads, and terminals — all in one window.")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)

                    Text("Built on top of Ghostty.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)

                    // gt CLI install row
                    gtInstallRow

                    Text("Ghostties is in active development. Features may change.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Text("Feedback:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Link("sean@seansmithdesign.com", destination: URL(string: "mailto:sean@seansmithdesign.com?subject=Ghostties%20Feedback")!)
                                .font(.system(size: 12))
                        }

                        HStack(spacing: 4) {
                            Text("GitHub:")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Link("github.com/SeanSmithDesign/ghostties", destination: URL(string: "https://github.com/SeanSmithDesign/ghostties")!)
                                .font(.system(size: 12))
                        }
                    }

                    Text("Version \(buildVersion) (build \(buildNumber)) · Updated \(buildDate)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                .padding(20)
            }
            .onAppear {
                checkGtInstalled()
            }

            Divider()

            footer
        }
        .frame(width: 420, height: 480)
    }

    // MARK: - gt install row

    private var gtInstallRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("gt CLI")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)

                if let installed = gtInstalled {
                    if installed {
                        Text("gt installed")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("gt not found — install to use the CLI")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Checking…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if let installed = gtInstalled {
                if installed {
                    Text("installed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Install gt") {
                        openInstallInTerminal()
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - gt PATH check

    private func checkGtInstalled() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["gt"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            gtInstalled = task.terminationStatus == 0
        } catch {
            gtInstalled = false
        }
    }

    // MARK: - Open Terminal with install command

    private func openInstallInTerminal() {
        // Open Terminal.app and run the install script from the repo root.
        // Detects repo location from the app bundle path; falls back to a
        // manual instruction if the path can't be resolved.
        let script = installAppleScript()
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(nil)
        }
    }

    private func installAppleScript() -> String {
        // Best-effort: derive the repo root from the running app bundle.
        // In development, the app is typically inside the repo's build output.
        // In release (/Applications), fall back to a generic message.
        let command = "bash \"$(git -C ~ rev-parse --show-toplevel 2>/dev/null)/scripts/install-gt.sh\" 2>/dev/null || echo 'Open a terminal in your ghostties repo and run: bash scripts/install-gt.sh'"
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Ghostties")
                .font(.system(size: 14, weight: .semibold))

            Text("Ghostty + workspace + agents")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Get started") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
