import AppKit

/// Opening a file picked in the explorer.
///
/// Two destinations, because the two habits are genuinely different: edit
/// it right here in the terminal that's already open on this project, or
/// hand it to a GUI app. Which one you want depends on the file and the
/// moment, so the explorer asks rather than guessing — a preview pane will
/// eventually make this less of a fork in the road.
@MainActor
enum FileOpener {
    /// The command run in the terminal. Left as a shell expression on
    /// purpose: `$EDITOR` is set by the user's shell config, which the GUI
    /// app doesn't inherit, so resolving it *in the shell* respects the
    /// setting instead of second-guessing it. `vim` is the fallback because
    /// macOS ships it.
    static let editorKey = "FileExplorerTerminalEditor"
    static let defaultEditor = "${EDITOR:-vim}"

    /// The app chosen the last time "Open in App" was used, remembered so
    /// it only has to be picked once.
    static let preferredAppKey = "FileExplorerPreferredApp"

    static var editorCommand: String {
        let stored = UserDefaults.standard.string(forKey: editorKey) ?? ""
        return stored.isEmpty ? defaultEditor : stored
    }

    static var preferredApp: URL? {
        guard let path = UserDefaults.standard.string(forKey: preferredAppKey),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Asks what to do with `url`, then does it.
    static func prompt(for url: URL, in window: NSWindow?, surfaceProvider: () -> Ghostty.SurfaceView?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = url.lastPathComponent
        alert.informativeText = "Open this file in the terminal, or hand it to an app?"

        alert.addButton(withTitle: "Open in Terminal")
        alert.addButton(withTitle: appButtonTitle)
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openInTerminal(url, surface: surfaceProvider())
        case .alertSecondButtonReturn:
            openInApp(url, window: window)
        default:
            break
        }
    }

    private static var appButtonTitle: String {
        guard let app = preferredApp else { return "Open in App…" }
        return "Open in \(app.deletingPathExtension().lastPathComponent)"
    }

    /// Types the editor command into the terminal this explorer belongs to
    /// and runs it.
    ///
    /// The command text and the Enter go through two different APIs on
    /// purpose. `sendText` is documented upstream as being "treated like a
    /// paste", and a paste into a shell with bracketed paste on — which
    /// zsh with `zle` active turns on, so: any normal interactive shell —
    /// carries a trailing `\r` through as literal text. The command lands
    /// at the prompt looking correct and simply never runs, which is
    /// exactly what this did before being tested against a real shell.
    /// A key event isn't paste content, so it submits.
    ///
    /// Sent immediately rather than through `ClaudeSession.run`'s startup
    /// delay: that delay exists for a shell that was just spawned, and this
    /// one has been sitting at a prompt.
    static func openInTerminal(_ url: URL, surface: Ghostty.SurfaceView?) {
        guard let surface, let model = surface.surfaceModel else { return }

        model.sendText("\(editorCommand) \(shellQuoted(url.path))")
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
        model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
    }

    static func openInApp(_ url: URL, window: NSWindow?) {
        guard let app = preferredApp else {
            chooseApp(in: window) { chosen in
                guard let chosen else { return }
                open(url, with: chosen)
            }
            return
        }
        open(url, with: app)
    }

    /// Forgets the remembered app so the next open asks again.
    static func clearPreferredApp() {
        UserDefaults.standard.removeObject(forKey: preferredAppKey)
    }

    static func chooseApp(in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.message = "Choose the app to open files with"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]

        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let chosen = panel.url else {
                completion(nil)
                return
            }
            UserDefaults.standard.set(chosen.path, forKey: preferredAppKey)
            completion(chosen)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(panel.runModal())
        }
    }

    private static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: app,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Single-quotes a path for the shell, escaping any embedded quote.
    /// Paths with spaces, `$` or quotes are ordinary on a Mac and would
    /// otherwise be re-split by the shell into a command that opens the
    /// wrong thing.
    ///
    /// `nonisolated` because it's a pure string transform and the quoting
    /// is the part worth testing directly.
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
