import Foundation

/// Parsed display data for one Graveyard expansion panel.
///
/// Computed from a `TaskItem` on demand — not stored. Keeps the view layer
/// free of string-munging logic and makes the parsing testable in isolation.
///
/// D26: flat layout — lives directly under `macos/Sources/Features/Ghostties/`.
struct GraveyardExpansionContent {

    // MARK: - Chips

    /// Chip text for the source + id pill (e.g. "linear · SEA-142").
    let sourceChip: String

    /// Chip text for the project pill (e.g. "ghostties").
    let projectChip: String

    /// Chip text for the relative-time pill (e.g. "done 2d").
    let timeChip: String

    // MARK: - Body preview

    /// First ≤8 lines of the `.md` body, excluding frontmatter.
    /// Empty string when the file has no body content.
    let bodyPreview: String

    /// True when the body had no parseable content.
    let isBodyEmpty: Bool

    // MARK: - Factory

    /// Build display content from a `TaskItem`.
    static func make(from task: TaskItem) -> GraveyardExpansionContent {
        let sourceChip: String = {
            let src = task.source.displayName
            if let sid = task.sourceID, !sid.isEmpty {
                return "\(src) · \(sid)"
            }
            return src
        }()

        let timeChip: String = {
            let ref = task.completed ?? task.created
            let delta = Date().timeIntervalSince(ref)
            let label: String
            if delta < 3600 {
                let m = max(1, Int(delta / 60))
                label = "\(m)m"
            } else if delta < 86_400 {
                let h = Int(delta / 3600)
                label = "\(h)h"
            } else {
                let d = Int(delta / 86_400)
                label = "\(d)d"
            }
            return "done \(label)"
        }()

        // Body preview: trim whitespace, drop blank leading lines, cap at 8.
        let rawBody = [task.goal, task.notes]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let lines = rawBody
            .components(separatedBy: "\n")
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }   // leading blanks

        let previewLines = lines.prefix(8)
        let preview = previewLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GraveyardExpansionContent(
            sourceChip: sourceChip,
            projectChip: task.project,
            timeChip: timeChip,
            bodyPreview: preview,
            isBodyEmpty: preview.isEmpty
        )
    }
}

// MARK: - TaskSource display name

private extension TaskSource {
    var displayName: String {
        switch self {
        case .linear:  return "linear"
        case .github:  return "github"
        case .sentry:  return "sentry"
        case .shell:   return "shell"
        case .unknown: return "unknown"
        }
    }
}
