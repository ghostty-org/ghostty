import Foundation

/// Noise created when an image is pasted into an Agent conversation.
///
/// These paths point at temporary files that disappear with the session, so
/// they add no value once a message, transcript, or commit is read later.
enum TransientAttachmentNoise {
    /// Directory and file markers used by the paste pipeline.
    private static let markers = [
        "/omg-paste/", "/otty-paste/", "codex-clipboard", "/codex/attachments/",
    ]

    /// True when a line only reports a temporary pasted image.
    static func isNoise(line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "Image attachment: true" { return true }
        guard markers.contains(where: { trimmed.contains($0) }) else { return false }
        // A path is noise only when it leads the line; prose keeps its sentence.
        let path = trimmed.drop { $0 == "-" || $0 == "*" || $0 == "•" }
            .drop(while: \.isWhitespace)
        if path.hasPrefix("/") || path.hasPrefix("~/") {
            return !path.contains(where: \.isWhitespace)
        }
        // Codex's injected file list uses markdown headers for attachments.
        return trimmed.hasPrefix("## ")
    }

    /// Removes temporary pasted-image lines from a block of text.
    static func removingNoiseLines(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isNoise(line: String($0)) }
            .joined(separator: "\n")
    }
}
