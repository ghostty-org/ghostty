import AppKit
import Darwin
import Foundation

/// Runs only in the short-lived askpass process, never inside the app UI process.
enum SSHAuthentication {
    static func respond(specURL: URL, prompt: String) -> Int32 {
        do {
            let spec = try SSHRuntime.readSpecification(specURL)
            guard spec.expiresAt > Date(), spec.launcherPID > 0,
                  kill(spec.launcherPID, 0) == 0,
                  SSHHelperTrust.validateCaller(launcherPID: spec.launcherPID),
                  let policy = spec.policy else { return 1 }
            if let kind = policy.credential(for: prompt), !spec.manual {
                let id = kind == .password ? spec.profile.passwordID : spec.profile.passphraseID
                if let id, SSHAuthenticationPolicy.claim(kind, directory: specURL.deletingLastPathComponent()) {
                    do {
                        if let value = try SSHCredentialStore.read(id, for: spec.profile) { return write(value) }
                    } catch {
                        // Keychain failures are visible and never silently treated as a missing item.
                        return manualResponse(prompt: prompt, context: spec.profile.name,
                                              explanation: error.localizedDescription, launcherPID: spec.launcherPID)
                    }
                }
            }
            return manualResponse(prompt: prompt, context: spec.profile.name, launcherPID: spec.launcherPID)
        } catch { return 1 }
    }

    private static func write(_ response: String) -> Int32 {
        guard !response.contains("\n"), !response.contains("\0") else { return 1 }
        do { try FileHandle.standardOutput.write(contentsOf: Data((response + "\n").utf8)); return 0 }
        catch { return 1 }
    }

    private static func manualResponse(prompt: String, context: String, explanation: String? = nil, launcherPID: pid_t) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "SSH — \(context)"
        alert.informativeText = [explanation, prompt].compactMap { $0 }.joined(separator: "\n\n")
        let confirmation = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] == "confirm"
            || prompt.contains("Are you sure you want to continue connecting")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if confirmation {
            alert.addButton(withTitle: "Continue")
        } else {
            alert.addButton(withTitle: "Submit")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        alert.addButton(withTitle: "Cancel")
        // A tab closing while the sheet is visible must not leave an orphan prompt.
        let sshPID = getppid()
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            if kill(launcherPID, 0) != 0 || kill(sshPID, 0) != 0 { app.abortModal(); alert.window.orderOut(nil) }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
        return write(confirmation ? "yes" : field.stringValue)
    }
}
