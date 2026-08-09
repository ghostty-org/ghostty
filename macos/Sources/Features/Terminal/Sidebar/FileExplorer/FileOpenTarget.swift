import Darwin
import Foundation

/// Where a file picked in a panel gets opened.
enum FileOpenTarget: String, CaseIterable, Identifiable {
    /// Reuse the selected terminal when it is sitting at a prompt, and
    /// only then.
    case reuseIdleTerminal

    /// Always somewhere new.
    case alwaysNewTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reuseIdleTerminal: return "Reuse the Current Terminal"
        case .alwaysNewTerminal: return "Always Open a New Terminal"
        }
    }

    static let defaultsKey = "FileExplorerOpenTarget"

    /// New terminal by default: it is the option that can't go wrong, and
    /// reuse is a preference about *your* habits, not a safe assumption
    /// about them.
    static var current: FileOpenTarget {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(FileOpenTarget.init(rawValue:)) ?? .alwaysNewTerminal
    }
}

/// Whether a terminal is idle — sitting at a shell prompt with nothing
/// running on top of it.
///
/// This is what makes reuse safe. A terminal's foreground process group is
/// the shell itself when nothing is running; anything else means a program
/// owns the keyboard, and text typed into it reaches *that program*. That
/// is the exact failure reuse has to avoid: an editor already open there
/// would swallow the next command into its buffer instead of running it.
/// It also answers "did the previous file get closed" without having to
/// ask — if it didn't, the terminal isn't idle and a new one is used.
enum TerminalIdleCheck {
    /// Matched on the executable name, which is what `proc_name` reports —
    /// so no leading dash to strip, unlike `ps`'s login-shell `argv[0]`.
    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh",
        "nu", "elvish", "xonsh",
    ]

    /// Unknown means "not idle": every caller uses this to decide whether
    /// it is safe to type, and the cost of being wrong in that direction is
    /// only an extra terminal.
    static func isIdle(foregroundPID pid: Int?) -> Bool {
        guard let pid, let name = processName(pid) else { return false }
        return shells.contains(name)
    }

    /// The seam the tests use — the naming rule, without a live process.
    static func isShell(_ name: String) -> Bool {
        shells.contains(name)
    }

    /// The executable name behind a pid. Shared with the sidebar, which
    /// uses it to say *what* a terminal is running.
    ///
    /// The buffer has to hold `2 * MAXCOMLEN`, not `MAXCOMLEN`: `proc_name`
    /// copies out of `proc_bsdinfo.pbi_name`, which is that size, and it
    /// refuses outright — returning 0, not a truncated name — when handed
    /// anything smaller. Sized at `MAXCOMLEN` this never returned a name at
    /// all, which made every terminal look busy and quietly disabled the
    /// reuse setting.
    static func processName(_ pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let written = proc_name(Int32(pid), &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }
}
