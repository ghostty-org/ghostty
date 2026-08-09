import Foundation

/// A failed git operation, turned into something worth reading.
///
/// Git's output is a transcript, not a message: a `pull` that fails because
/// of two dirty files prints every ref it fetched first, and the sentence
/// that matters is four lines from the bottom. Dropping all of it into the
/// sidebar was unreadable *and* stretched the window, so it gets summarized
/// here and the transcript is kept for when the summary isn't enough.
///
/// The patterns matched below are git's own stable phrasings — the ones it
/// has printed for years and that every answer on the internet quotes.
/// Anything unrecognized still gets a title and the full transcript, which
/// is no worse than before.
struct GitFailure: Equatable {
    /// What went wrong, in a few words.
    let title: String

    /// What to do about it, when git's message implies an obvious next step.
    let summary: String?

    /// The paths git named as the problem, if any.
    let files: [String]

    /// Everything git printed.
    let raw: String

    init(operation: String, output: String) {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = text
        let parsed = Self.classify(operation: operation, output: text)
        self.title = parsed.title
        self.summary = parsed.summary
        self.files = parsed.files
    }

    /// Test seam: build one directly.
    init(title: String, summary: String?, files: [String], raw: String) {
        self.title = title
        self.summary = summary
        self.files = files
        self.raw = raw
    }

    // MARK: Classification

    private static func classify(
        operation: String,
        output: String
    ) -> (title: String, summary: String?, files: [String]) {
        let lower = output.lowercased()

        if lower.contains("your local changes to the following files would be overwritten") {
            return (
                "Local changes are in the way",
                "These files differ from the incoming version. Commit or stash them, then try again.",
                filesListed(after: "would be overwritten by", in: output)
            )
        }

        if lower.contains("untracked working tree files would be overwritten") {
            return (
                "Untracked files are in the way",
                "Files that aren't tracked would be replaced. Move or delete them, then try again.",
                filesListed(after: "would be overwritten by", in: output)
            )
        }

        if lower.contains("automatic merge failed") || lower.contains("fix conflicts and then commit") {
            return (
                "Merge conflicts",
                "Resolve the conflicts, stage the results, then commit.",
                []
            )
        }

        if lower.contains("non-fast-forward") || lower.contains("updates were rejected") {
            return (
                "The remote has changes you don't",
                "Someone pushed since you last pulled. Pull first, then push.",
                []
            )
        }

        // Two phrasings for one situation: "have diverged" is the older
        // wording, "divergent branches" is what git prints since it started
        // demanding an explicit pull strategy (2.27+). Only matching the
        // first meant modern git fell through to the generic fallback.
        if lower.contains("have diverged") || lower.contains("divergent branches") {
            return (
                "Your branch and the remote have diverged",
                "Both sides have commits the other doesn't. Pull to reconcile them.",
                []
            )
        }

        if lower.contains("no upstream branch") || lower.contains("has no upstream branch") {
            return (
                "This branch isn't on the remote yet",
                "Use Publish Branch to push it and set its upstream.",
                []
            )
        }

        // Order matters through the next four branches. `Could not read from
        // remote repository` is git's generic wrapper and it prints *under*
        // the real cause — DNS failure, refused key, anything — so testing
        // for it first classified every network outage as an auth problem.
        // The specific causes get their say, and the wrapper is only
        // consulted once none of them matched.
        if lower.contains("could not resolve host")
            || lower.contains("network is unreachable")
            || lower.contains("connection timed out")
            || lower.contains("operation timed out") {
            return ("Couldn't reach the remote", "Check your connection.", [])
        }

        if lower.contains("permission denied (publickey)") {
            return (
                "The remote refused the connection",
                "Git couldn't authenticate. Check that your SSH key is loaded, or try the same command in the terminal.",
                []
            )
        }

        if lower.contains("authentication failed") || lower.contains("invalid username or password") {
            return (
                "Authentication failed",
                "The remote rejected your credentials.",
                []
            )
        }

        if lower.contains("could not read from remote repository") {
            return (
                "The remote refused the connection",
                "The repository may not exist, or your account may not have access to it.",
                []
            )
        }

        if lower.contains("nothing to commit") {
            return ("Nothing to commit", "No changes are staged.", [])
        }

        if lower.contains("please tell me who you are") {
            return (
                "Git doesn't know who you are",
                "Set user.name and user.email before committing.",
                []
            )
        }

        if lower.contains("not a git repository") {
            return ("Not a git repository", nil, [])
        }

        if lower.contains("did not match any file(s) known to git")
            || lower.contains("pathspec") && lower.contains("did not match") {
            return ("Git didn't recognize that path", nil, [])
        }

        if lower.contains("no stash entries found") {
            return ("There's no stash to pop", nil, [])
        }

        if lower.contains("already exists") && lower.contains("branch") {
            return ("That branch already exists", nil, [])
        }

        // A hook that rejects gets its own framing: the operation is fine,
        // the project's own rules said no, and the hook's output is the
        // actual message the user needs.
        //
        // `exited with code` is husky's phrasing and by far the one seen
        // most here — it says neither "declined" nor "failed", so matching
        // only git's own words missed every lint-staged rejection.
        if lower.contains("hook")
            && (lower.contains("declined")
                || lower.contains("failed")
                || lower.contains("exited with code")) {
            return (
                "A git hook rejected the \(operation.lowercased())",
                "The project's own checks didn't pass. Their output is below.",
                []
            )
        }

        if output.isEmpty {
            return ("\(operation) failed", "Git exited without explaining why.", [])
        }

        // Unrecognized: lead with git's own first meaningful line rather
        // than inventing a summary for something we don't understand.
        return ("\(operation) failed", firstMeaningfulLine(in: output), [])
    }

    /// The indented paths git lists under a "would be overwritten" notice.
    private static func filesListed(after marker: String, in output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0.lowercased().contains(marker) }) else { return [] }

        var files: [String] = []
        for line in lines[lines.index(after: start)...] {
            // Git indents the paths and un-indents for the next sentence.
            guard line.hasPrefix("\t") || line.hasPrefix("    ") else { break }
            let path = line.trimmingCharacters(in: .whitespaces)
            if path.isEmpty { break }
            files.append(path)
        }
        return files
    }

    /// Git leads with `error:` or `fatal:` when it has something specific
    /// to say; those lines are worth more than the fetch transcript above
    /// them.
    private static func firstMeaningfulLine(in output: String) -> String? {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        if let flagged = lines.first(where: {
            let l = $0.lowercased()
            return l.hasPrefix("error:") || l.hasPrefix("fatal:")
        }) {
            return flagged
                .replacingOccurrences(of: "error: ", with: "")
                .replacingOccurrences(of: "fatal: ", with: "")
        }

        return lines.last(where: { !$0.isEmpty })
    }
}
