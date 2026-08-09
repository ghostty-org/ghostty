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

    nonisolated static var editorCommand: String {
        let stored = UserDefaults.standard.string(forKey: editorKey) ?? ""
        return stored.isEmpty ? defaultEditor : stored
    }

    static var preferredApp: URL? {
        guard let path = UserDefaults.standard.string(forKey: preferredAppKey),
              FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// How long to give a freshly spawned shell before typing into it.
    /// Text sent before the prompt is ready is swallowed.
    private static let shellStartupDelay: TimeInterval = 1.2

    /// Asks what to do with `url`, then does it.
    ///
    /// `spawnTerminal` must create a *new* terminal and hand back its
    /// surface. `currentTerminal` is the selected one, offered only so the
    /// reuse setting has something to reuse — see `openInTerminal`.
    static func prompt(
        for url: URL,
        in window: NSWindow?,
        currentTerminal: Ghostty.SurfaceView? = nil,
        spawnTerminal: @escaping () -> Ghostty.SurfaceView?,
        openInEditor: ((URL) -> Void)? = nil
    ) {
        switch FileOpenAction.current {
        case .builtInEditor where openInEditor != nil:
            openInEditor?(url)
            return
        case .terminalEditor:
            openInTerminal(url, current: currentTerminal, spawn: spawnTerminal)
            return
        case .externalApp:
            openInApp(url, window: window)
            return
        case .builtInEditor, .ask:
            break
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = url.lastPathComponent
        alert.informativeText = "Open this file in the terminal, or hand it to an app?"

        alert.addButton(withTitle: "Open in Terminal")
        alert.addButton(withTitle: appButtonTitle)
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openInTerminal(url, current: currentTerminal, spawn: spawnTerminal)
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

    /// Opens `url` in a terminal.
    ///
    /// Which terminal is a setting, but the *unsafe* case is never on the
    /// table either way: the panels show the files of whichever terminal
    /// is selected, so the selected terminal is exactly the one most
    /// likely to be busy — and typing an editor command into a shell that
    /// is already running an editor doesn't reach a shell at all, it
    /// reaches the editor. Opening a second file used to do precisely
    /// that, landing the command inside the first `vim`'s buffer.
    ///
    /// So reuse applies only to a terminal sitting at a prompt. That test
    /// doubles as the "is the previous file closed" one: if it isn't, the
    /// terminal isn't idle, and this opens a new one instead.
    ///
    /// The command text and the Enter go through two different APIs on
    /// purpose. `sendText` is documented upstream as being "treated like a
    /// paste", and a paste into a shell with bracketed paste on — which
    /// zsh with `zle` active turns on, so: any normal interactive shell —
    /// carries a trailing `\r` through as literal text. The command lands
    /// at the prompt looking correct and simply never runs, which is
    /// exactly what this did before being tested against a real shell.
    /// A key event isn't paste content, so it submits.
    static func openInTerminal(
        _ url: URL,
        current: Ghostty.SurfaceView?,
        spawn: () -> Ghostty.SurfaceView?
    ) {
        let reused = reusableTerminal(current)
        guard let surface = reused ?? spawn() else { return }
        let command = terminalCommand(for: url)
        nameTab(surface, after: url)

        // A terminal that was already at a prompt takes the command right
        // away; a just-spawned shell has no prompt up yet and drops
        // anything sent before it does.
        let delay = reused == nil ? shellStartupDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak surface] in
            guard let model = surface?.surfaceModel else { return }
            model.sendText(command)
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .press))
            model.sendKeyEvent(Ghostty.Input.KeyEvent(key: .enter, action: .release))
        }
    }

    /// Names the tab after the file it was opened for, so the sidebar says
    /// what the terminal is showing rather than repeating a directory every
    /// one of its neighbours also shows.
    ///
    /// Merged into any override already on the tab instead of replacing it,
    /// so an icon or color the user set by hand survives being renamed.
    private static func nameTab(_ surface: Ghostty.SurfaceView, after url: URL) {
        let store = SidebarGroupStore.shared
        var override = store.tabOverrides[surface.id] ?? SidebarGroupStore.TabOverride()
        override.name = tabName(for: url)
        override.fileName = tabName(for: url)
        store.setTabOverride(surfaceId: surface.id, override)
    }

    /// The file's name and extension, and nothing else.
    ///
    /// A path long enough to be worth reading is also long enough to push
    /// the name out of a 240pt sidebar column — which would truncate away
    /// the one part that identifies the tab and leave a row of near-
    /// identical prefixes.
    nonisolated static func tabName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    /// The selected terminal, when the setting asks for reuse *and* it is
    /// actually free to take a command.
    private static func reusableTerminal(
        _ current: Ghostty.SurfaceView?
    ) -> Ghostty.SurfaceView? {
        guard FileOpenTarget.current == .reuseIdleTerminal,
              let current,
              TerminalIdleCheck.isIdle(foregroundPID: current.surfaceModel?.foregroundPID)
        else { return nil }
        return current
    }

    /// `nonisolated` so the composition — which is where a quoting bug
    /// would hide — is testable without a surface.
    nonisolated static func terminalCommand(for url: URL) -> String {
        "\(editorCommand) \(shellQuoted(url.path))"
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
