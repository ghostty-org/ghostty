import Foundation

/// Whether a file is something the editor can usefully show.
///
/// Two ways it isn't. A **binary** — you can watch this happen today by
/// sending a `.class` to `vim`: the screen fills with control codes and
/// there is nothing to read or edit. And a file **large enough** that
/// loading it would stall the app; the editor is for working on source,
/// not for opening a log dump.
///
/// Both answers name the file's escape hatch rather than just refusing, so
/// the caller can offer to hand it to an external app instead.
enum FileOpenGuard {
    /// `Error` so a refusal can travel in a `Result` — the reason a file
    /// didn't open is the same shape as any other failure the caller
    /// handles.
    enum Verdict: Error, Equatable {
        case open

        /// Bytes that don't form text. Carries nothing extra: there is one
        /// reason and one remedy.
        case binary

        /// Too big to load, with the size that decided it.
        case tooLarge(bytes: Int)

        var canOpen: Bool { self == .open }

        /// What to tell the user, in one sentence.
        var reason: String? {
            switch self {
            case .open:
                return nil
            case .binary:
                return "This looks like a binary file, so there's nothing readable to show."
            case .tooLarge(let bytes):
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "This file is \(size), past the size the editor will open."
            }
        }
    }

    /// Past this the editor declines. Generous for source — the largest
    /// files in a normal repository are lockfiles and bundles, well under
    /// it — and small enough that loading never blocks noticeably.
    static let maxBytes = 10 * 1024 * 1024

    /// How much of the file to inspect when deciding whether it is text.
    ///
    /// A prefix rather than the whole file: this runs before opening, and
    /// reading megabytes to answer "is this text" would cost exactly what
    /// the guard exists to avoid. Real binaries put a NUL in the first few
    /// bytes — every format with a magic number does.
    static let sniffBytes = 8 * 1024

    /// - Parameters:
    ///   - size: the file's size in bytes.
    ///   - prefix: its first bytes, up to `sniffBytes`.
    static func verdict(size: Int, prefix: Data) -> Verdict {
        if size > maxBytes { return .tooLarge(bytes: size) }
        if prefix.contains(0) { return .binary }
        return .open
    }

    /// Reads just enough of `url` to decide.
    ///
    /// Returns `.binary` when the file can't be read at all: the caller's
    /// only sensible move is the same either way, and inventing a third
    /// state for "unreadable" would spread that everywhere.
    static func verdict(for url: URL) -> Verdict {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .binary }
        defer { try? handle.close() }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes { return .tooLarge(bytes: size) }

        let prefix = (try? handle.read(upToCount: sniffBytes)) ?? Data()
        return verdict(size: size, prefix: prefix)
    }
}
