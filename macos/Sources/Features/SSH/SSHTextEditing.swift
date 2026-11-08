import AppKit

/// Handle native field editing before Ghostty's terminal shortcut monitor.
/// This is scoped to the manager and its sheets, including secure field editors.
enum SSHTextEditing {
    static func belongs(_ window: NSWindow?, to root: NSWindow) -> Bool {
        guard let window else { return false }
        return window === root || window.sheetParent.map { belongs($0, to: root) } == true
    }

    static func handle(_ event: NSEvent, in window: NSWindow?) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.option), !modifiers.contains(.control),
              let editor = window?.firstResponder as? NSTextView else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let command: String
        if ["a", "c", "v", "x", "z"].contains(key) { command = key }
        else {
            // Korean IMEs can expose Hangul here; command keys still use these key codes.
            guard !key.unicodeScalars.allSatisfy({ $0.isASCII }),
                  let fallback = [UInt16(0): "a", 8: "c", 9: "v", 7: "x", 6: "z"][event.keyCode] else { return false }
            command = fallback
        }
        switch command {
        case "a": editor.selectAll(nil)
        case "c", "x":
            let range = editor.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (editor.string as NSString).length else { return true }
            // Secure field editors normally suppress copy/cut. Honor the user's explicit
            // clipboard command for every connection input, including password fields.
            let value = (editor.string as NSString).substring(with: range)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            if command == "x", editor.isEditable { editor.insertText("", replacementRange: range) }
        case "v":
            guard editor.isEditable else { return false }
            if let value = NSPasteboard.general.string(forType: .string) {
                editor.insertText(value, replacementRange: editor.selectedRange())
            }
        case "z":
            if modifiers.contains(.shift) { editor.undoManager?.redo() }
            else { editor.undoManager?.undo() }
        default: return false
        }
        return true
    }
}
