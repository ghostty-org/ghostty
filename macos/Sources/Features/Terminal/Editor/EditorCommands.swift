import AppKit

/// The editor's keyboard shortcuts.
///
/// ⌘S, ⌘W and ⌘F all already mean something in this app: ⌘W closes the
/// terminal tab and ⌘F opens the terminal's own search. Taking them
/// outright would break the thing people actually use this app for, so
/// each is claimed **only while the editor holds focus** and handed
/// straight back otherwise.
///
/// Focus is decided by asking the window who its first responder is,
/// rather than by tracking a flag: a flag has to be updated from every
/// path that moves focus, and the one that gets forgotten is the one that
/// leaves ⌘W closing the wrong thing.
@MainActor
enum EditorCommands {
    /// Whether the editor should handle a key event in this window.
    ///
    /// True when the first responder is the code view or something inside
    /// it — a find bar's field is a subview, and typing ⌘S with the cursor
    /// in it should still save.
    static func isEditorFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        if responder is CodeNSTextView { return true }

        var view: NSView? = responder
        while let current = view {
            if current is CodeNSTextView { return true }
            view = current.superview
        }
        return false
    }

    /// Which command a key event means, or nil to let it through.
    ///
    /// Pure so the mapping is testable — the part worth being sure about
    /// is not that ⌘S saves, but that nothing here fires when the editor
    /// isn't focused.
    ///
    /// ⚠️ **Nothing in the app calls this.** The keys it describes are handled
    /// by `CodeNSTextView.performKeyEquivalent`, which is only in the responder
    /// chain while the editor has focus — a stronger guarantee than the
    /// `editorFocused` argument here, and the reason this went unused. It is
    /// kept because its tests document the intended mapping, but it is not the
    /// code that runs: change the text view, not this.
    static func command(
        for characters: String,
        modifiers: NSEvent.ModifierFlags,
        editorFocused: Bool,
        hasOpenFiles: Bool
    ) -> Command? {
        guard hasOpenFiles, editorFocused else { return nil }

        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        guard command else { return nil }

        switch characters.lowercased() {
        case "s": return shift ? .saveAll : .save
        case "w": return .closeTab
        default: return nil
        }
    }

    enum Command: Equatable {
        case save
        case saveAll
        case closeTab
    }

    /// What the pane should do with a key, or nil to let it through.
    ///
    /// **⌥⌘ and not ⌘ alone.** `⌘1`–`⌘9` and `⌃⇥` already belong to Ghostty's
    /// window tabs (`goto_tab`/`next_tab`), and `⌃\`` sends a control
    /// character to the shell. Taking any of those would break the terminal,
    /// which is the app — the same mistake that `⌘W` invited. There is no
    /// `alt+cmd+*` in the upstream defaults, so this claims nothing anybody
    /// else answers for.
    ///
    /// Pure so the one part worth being sure about is testable: that nothing
    /// here fires when no file is open, because then the pane has a single
    /// surface and switching is meaningless.
    nonisolated static func paneCommand(
        for characters: String,
        modifiers: NSEvent.ModifierFlags,
        hasOpenFiles: Bool
    ) -> PaneCommand? {
        guard hasOpenFiles else { return nil }

        let required: NSEvent.ModifierFlags = [.command, .option]
        let relevant = modifiers.intersection([.command, .option, .shift, .control])
        guard relevant == required else { return nil }

        if characters == "\\" { return .toggleTerminal }
        if let number = Int(characters), number >= 1, number <= 9 {
            return .selectFile(number)
        }
        return nil
    }

    enum PaneCommand: Equatable {
        /// ⌥⌘\ — the terminal, or back to the file you were on.
        case toggleTerminal

        /// ⌥⌘1–9 — the nth open file.
        case selectFile(Int)
    }
}
