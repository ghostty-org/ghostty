import Foundation

enum DiffParser {
    private static let maxRenderedDiffLinesPerFile: Int = 10_000
    private static let hunkHeaderRegex: NSRegularExpression = {
        // Typical: @@ -80,3 +80,5 @@
        // Counts may be omitted: @@ -1 +1 @@
        let pattern = "^@@\\s*-(\\d+)(?:,(\\d+))?\\s*\\+(\\d+)(?:,(\\d+))?\\s*@@"
        return (try? NSRegularExpression(pattern: pattern, options: [])) ?? NSRegularExpression()
    }()

    static func parseUnified(text: String, source: DiffDocumentSource) -> DiffDocument {
        var files: [DiffFile] = []
        files.reserveCapacity(32)

        var current: FileAccumulator? = nil

        func finishCurrent() {
            guard var acc = current else { return }
            acc.finish()
            files.append(acc.build())
            current = nil
        }

        forEachLineNoNewline(text) { line in
            let line = line

            if line.hasPrefix("diff --git ") {
                finishCurrent()
                current = FileAccumulator(diffGitLine: String(line))
                return
            }

            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                finishCurrent()
                current = FileAccumulator(combinedLine: String(line))
                return
            }

            guard current != nil else { return }

            if current?.status == .combinedUnsupported {
                current?.appendFallbackLine(String(line))
                return
            }

            if line.hasPrefix("new file mode ") {
                current?.status = .added
                return
            }

            if line.hasPrefix("deleted file mode ") {
                current?.status = .deleted
                return
            }

            if line.hasPrefix("rename from ") {
                current?.status = .renamed
                current?.pathOld = String(line.dropFirst("rename from ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }

            if line.hasPrefix("rename to ") {
                current?.status = .renamed
                current?.pathNew = String(line.dropFirst("rename to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }

            if line.hasPrefix("copy from ") {
                current?.status = .copied
                current?.pathOld = String(line.dropFirst("copy from ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }

            if line.hasPrefix("copy to ") {
                current?.status = .copied
                current?.pathNew = String(line.dropFirst("copy to ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }

            if line.hasPrefix("--- ") {
                let p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if p == "/dev/null" {
                    current?.status = .added
                }
                return
            }

            if line.hasPrefix("+++ ") {
                let p = String(line.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if p == "/dev/null" {
                    current?.status = .deleted
                }
                return
            }

            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.status = .binary
                current?.appendFallbackLine(String(line))
                return
            }

            if line.hasPrefix("@@") {
                current?.startHunk(header: String(line))
                return
            }

            if line.hasPrefix("+") && !line.hasPrefix("+++ ") {
                current?.appendDiffLine(prefix: "+", fullLine: line)
                return
            }

            if line.hasPrefix("-") && !line.hasPrefix("--- ") {
                current?.appendDiffLine(prefix: "-", fullLine: line)
                return
            }

            if line.hasPrefix(" ") {
                current?.appendDiffLine(prefix: " ", fullLine: line)
                return
            }

            if line.hasPrefix("\\") {
                current?.appendMetaLine(String(line))
                return
            }

            if line.hasPrefix("# ") {
                current?.appendFallbackLine(String(line.dropFirst(2)))
                return
            }

            // Ignore remaining git headers (index, mode changes, etc) unless we're in a binary diff.
            if current?.status == .binary {
                current?.appendFallbackLine(String(line))
            }
        }

        finishCurrent()
        return DiffDocument(source: source, files: files)
    }

    // MARK: - Internal

    private struct FileAccumulator {
        var pathOld: String?
        var pathNew: String?
        var status: DiffFileStatus

        var hunks: [HunkAccumulator] = []
        var currentHunk: HunkAccumulator? = nil

        var fallbackLines: [String] = []
        var additions: Int = 0
        var deletions: Int = 0
        var totalDiffLinesSeen: Int = 0
        var isTooLargeToRender: Bool = false

        private var hunkCounter: Int = 0

        init(diffGitLine: String) {
            self.status = .modified
            let parsed = parseDiffGitLine(diffGitLine)
            self.pathOld = parsed?.a
            self.pathNew = parsed?.b
            if self.pathOld == "/dev/null" { self.pathOld = nil }
            if self.pathNew == "/dev/null" { self.pathNew = nil }
        }

        init(combinedLine: String) {
            self.status = .combinedUnsupported
            let p: String
            if combinedLine.hasPrefix("diff --cc ") {
                p = String(combinedLine.dropFirst("diff --cc ".count))
            } else {
                p = String(combinedLine.dropFirst("diff --combined ".count))
            }
            let path = p.trimmingCharacters(in: .whitespacesAndNewlines)
            self.pathOld = path.isEmpty ? nil : path
            self.pathNew = self.pathOld
            self.fallbackLines = [combinedLine]
        }

        mutating func finish() {
            if let currentHunk {
                hunks.append(currentHunk)
                self.currentHunk = nil
            }
        }

        func build() -> DiffFile {
            let builtHunks = hunks.map { $0.build() }
            let tooLarge = isTooLargeToRender
            let totalLines = max(totalDiffLinesSeen, builtHunks.reduce(0) { $0 + $1.lines.count })

            let fallback: String?
            if status == .binary {
                fallback = fallbackLines.isEmpty ? "Binary file not shown." : fallbackLines.joined(separator: "\n")
            } else if status == .combinedUnsupported {
                fallback = fallbackLines.isEmpty ? "Combined diffs are not supported." : fallbackLines.joined(separator: "\n")
            } else if tooLarge {
                fallback = "Diff too large to render (\(totalLines) lines)."
            } else if builtHunks.isEmpty, !fallbackLines.isEmpty {
                fallback = fallbackLines.joined(separator: "\n")
            } else {
                fallback = nil
            }

            return DiffFile(
                pathOld: pathOld,
                pathNew: pathNew,
                status: status,
                additions: additions,
                deletions: deletions,
                hunks: tooLarge ? [] : builtHunks,
                fallbackText: fallback,
                isTooLargeToRender: tooLarge
            )
        }

        mutating func appendFallbackLine(_ line: String) {
            fallbackLines.append(line)
        }

        mutating func appendMetaLine(_ line: String) {
            // Keep meta only if we don't have hunks yet; these lines are typically context for binaries.
            if status == .binary || status == .combinedUnsupported {
                fallbackLines.append(line)
                return
            }
            totalDiffLinesSeen += 1
            if isTooLargeToRender { return }
            if totalDiffLinesSeen > DiffParser.maxRenderedDiffLinesPerFile {
                markTooLarge()
                return
            }
            currentHunk?.appendMeta(line)
        }

        mutating func startHunk(header: String) {
            if let currentHunk {
                hunks.append(currentHunk)
                self.currentHunk = nil
            }
            hunkCounter += 1
            currentHunk = HunkAccumulator(id: "\(primaryPath)|\(hunkCounter)", header: header)
        }

        mutating func appendDiffLine(prefix: String, fullLine: Substring) {
            totalDiffLinesSeen += 1
            switch prefix {
            case "+": additions += 1
            case "-": deletions += 1
            default: break
            }

            if isTooLargeToRender { return }
            if totalDiffLinesSeen > DiffParser.maxRenderedDiffLinesPerFile {
                markTooLarge()
                return
            }

            if currentHunk == nil {
                // Some tools can emit diff bodies without explicit hunks; create a synthetic hunk.
                startHunk(header: "@@ -0,0 +0,0 @@")
            }
            currentHunk?.append(prefix: prefix, fullLine: String(fullLine))
        }

        private var primaryPath: String {
            (pathNew?.isEmpty == false ? pathNew : nil)
                ?? (pathOld?.isEmpty == false ? pathOld : nil)
                ?? "Diff"
        }

        mutating func markTooLarge() {
            isTooLargeToRender = true
            hunks.removeAll(keepingCapacity: false)
            currentHunk = nil
        }
    }

    private struct HunkAccumulator {
        let id: String
        let header: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int

        var oldCursor: Int
        var newCursor: Int

        var lines: [DiffLine] = []
        private var lineCounter: Int = 0

        init(id: String, header: String) {
            self.id = id
            self.header = header
            let parsed = parseHunkHeader(header)
            self.oldStart = parsed.oldStart
            self.oldCount = parsed.oldCount
            self.newStart = parsed.newStart
            self.newCount = parsed.newCount
            self.oldCursor = parsed.oldStart
            self.newCursor = parsed.newStart
        }

        mutating func append(prefix: String, fullLine: String) {
            guard let first = fullLine.first else { return }
            let content = String(fullLine.dropFirst())

            lineCounter += 1
            let lineID = "\(id)|l\(lineCounter)"

            switch first {
            case "+":
                lines.append(DiffLine(id: lineID, kind: .add, oldLine: nil, newLine: newCursor, text: content))
                newCursor += 1
            case "-":
                lines.append(DiffLine(id: lineID, kind: .del, oldLine: oldCursor, newLine: nil, text: content))
                oldCursor += 1
            case " ":
                lines.append(DiffLine(id: lineID, kind: .context, oldLine: oldCursor, newLine: newCursor, text: content))
                oldCursor += 1
                newCursor += 1
            default:
                lines.append(DiffLine(id: lineID, kind: .meta, oldLine: nil, newLine: nil, text: fullLine))
            }
        }

        mutating func appendMeta(_ line: String) {
            lineCounter += 1
            let lineID = "\(id)|m\(lineCounter)"
            lines.append(DiffLine(id: lineID, kind: .meta, oldLine: nil, newLine: nil, text: line))
        }

        func build() -> DiffHunk {
            DiffHunk(
                id: id,
                header: header,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: lines
            )
        }
    }

    private static func forEachLineNoNewline(_ text: String, _ body: (Substring) -> Void) {
        if text.isEmpty { return }
        var start = text.startIndex
        var idx = start
        while idx < text.endIndex {
            if text[idx] == "\n" {
                let line = text[start..<idx]
                if line.hasSuffix("\r") {
                    body(line.dropLast())
                } else {
                    body(line)
                }
                start = text.index(after: idx)
                idx = start
                continue
            }
            idx = text.index(after: idx)
        }
        if start < text.endIndex {
            let line = text[start..<text.endIndex]
            if line.hasSuffix("\r") {
                body(line.dropLast())
            } else {
                body(line)
            }
        }
    }

    private static func parseDiffGitLine(_ line: String) -> (a: String, b: String)? {
        guard let range = line.range(of: "diff --git ") else { return nil }
        let remainder = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (a, b) = parseTwoTokens(remainder) else { return nil }
        return (stripGitDiffPathPrefix(a), stripGitDiffPathPrefix(b))
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int) {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = hunkHeaderRegex.firstMatch(in: line, options: [], range: range) else {
            return (0, 0, 0, 0)
        }
        func intGroup(_ idx: Int, default defaultValue: Int) -> Int {
            guard idx < match.numberOfRanges else { return defaultValue }
            let r = match.range(at: idx)
            guard r.location != NSNotFound else { return defaultValue }
            let s = ns.substring(with: r)
            return Int(s) ?? defaultValue
        }
        let oldStart = intGroup(1, default: 0)
        let oldCount = intGroup(2, default: 1)
        let newStart = intGroup(3, default: 0)
        let newCount = intGroup(4, default: 1)
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func stripGitDiffPathPrefix(_ token: String) -> String {
        if token.hasPrefix("a/") { return String(token.dropFirst(2)) }
        if token.hasPrefix("b/") { return String(token.dropFirst(2)) }
        return token
    }

    private static func parseTwoTokens(_ input: String) -> (String, String)? {
        var tokens: [String] = []
        tokens.reserveCapacity(2)

        let quote: Character = "\""
        let backslash: Character = "\\"

        var idx = input.startIndex
        while tokens.count < 2 {
            while idx < input.endIndex, isWhitespace(input[idx]) {
                idx = input.index(after: idx)
            }
            guard idx < input.endIndex else { break }

            if input[idx] == quote {
                idx = input.index(after: idx)
                var token = ""
                while idx < input.endIndex {
                    let ch = input[idx]
                    if ch == quote {
                        idx = input.index(after: idx)
                        break
                    }
                    if ch == backslash {
                        let next = input.index(after: idx)
                        if next < input.endIndex {
                            token.append(input[next])
                            idx = input.index(after: next)
                            continue
                        }
                    }
                    token.append(ch)
                    idx = input.index(after: idx)
                }
                tokens.append(token)
            } else {
                let start = idx
                while idx < input.endIndex, !isWhitespace(input[idx]) {
                    idx = input.index(after: idx)
                }
                tokens.append(String(input[start..<idx]))
            }
        }

        guard tokens.count == 2 else { return nil }
        return (tokens[0], tokens[1])
    }

    private static func isWhitespace(_ ch: Character) -> Bool {
        ch.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
