import AppKit
import Foundation
import SwiftUI

enum DiffSyntaxHighlighter {
    private static let regexCache = RegexCache()
    struct Theme {
        let font: NSFont
        let headerFont: NSFont
        let textColor: NSColor
        let secondaryTextColor: NSColor
        let hunkColor: NSColor
        let addBackground: NSColor
        let deleteBackground: NSColor
        let addPrefix: NSColor
        let deletePrefix: NSColor
        let keywordColor: NSColor
        let stringColor: NSColor
        let commentColor: NSColor
        let numberColor: NSColor
        let typeColor: NSColor

        static var `default`: Theme {
            Theme(
                font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                headerFont: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                textColor: .labelColor,
                secondaryTextColor: .secondaryLabelColor,
                hunkColor: .systemPurple,
                addBackground: NSColor.systemGreen.withAlphaComponent(0.15),
                deleteBackground: NSColor.systemRed.withAlphaComponent(0.15),
                addPrefix: .systemGreen,
                deletePrefix: .systemRed,
                keywordColor: .systemPurple,
                stringColor: .systemGreen,
                commentColor: .systemGray,
                numberColor: .systemOrange,
                typeColor: .systemTeal
            )
        }
    }

    static func highlightedDiff(
        text: String,
        filePath: String?,
        theme: Theme = .default
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let language = Language.from(filePath: filePath)
        let prefixIndent = (NSString(string: " ").size(withAttributes: [.font: theme.font]).width)

        var currentLocation = 0
        let lines = splitLines(text)
        for line in lines {
            let lineAttr = NSMutableAttributedString(string: line)
            applyBaseAttributes(lineAttr, theme: theme)

            let isHeader = line.hasPrefix("diff --git")
                || line.hasPrefix("index ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("Binary file")
            let isHunk = line.hasPrefix("@@")
            let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++ ")
            let isDel = line.hasPrefix("-") && !line.hasPrefix("--- ")
            let isContext = line.hasPrefix(" ")

            if (isAdd || isDel || isContext) && lineAttr.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.headIndent = prefixIndent
                lineAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: lineAttr.length))
            }

            if isHeader {
                lineAttr.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: NSRange(location: 0, length: lineAttr.length))
                lineAttr.addAttribute(.font, value: theme.headerFont, range: NSRange(location: 0, length: lineAttr.length))
            } else if isHunk {
                lineAttr.addAttribute(.foregroundColor, value: theme.hunkColor, range: NSRange(location: 0, length: lineAttr.length))
            } else if isAdd {
                lineAttr.addAttribute(.backgroundColor, value: theme.addBackground, range: NSRange(location: 0, length: lineAttr.length))
                if lineAttr.length > 0 {
                    lineAttr.addAttribute(.foregroundColor, value: theme.addPrefix, range: NSRange(location: 0, length: 1))
                }
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: language, contentRange: contentRange, theme: theme)
            } else if isDel {
                lineAttr.addAttribute(.backgroundColor, value: theme.deleteBackground, range: NSRange(location: 0, length: lineAttr.length))
                if lineAttr.length > 0 {
                    lineAttr.addAttribute(.foregroundColor, value: theme.deletePrefix, range: NSRange(location: 0, length: 1))
                }
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: language, contentRange: contentRange, theme: theme)
            } else if line.hasPrefix(" ") {
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: language, contentRange: contentRange, theme: theme)
            } else {
                applySyntax(lineAttr, language: language, contentRange: NSRange(location: 0, length: lineAttr.length), theme: theme)
            }

            output.append(lineAttr)
            currentLocation += line.count
        }

        return output
    }

    static func highlightedUnifiedDiff(
        text: String,
        theme: Theme = .default
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let prefixIndent = (NSString(string: " ").size(withAttributes: [.font: theme.font]).width)

        var currentLanguage: Language = .unknown

        let lines = splitLines(text)
        for (idx, line) in lines.enumerated() {
            let prevLine = idx > 0 ? lines[idx - 1] : nil
            let nextLine = (idx + 1) < lines.count ? lines[idx + 1] : nil
            let isFileTitle = isFileTitleLine(line, previousLine: prevLine, nextLine: nextLine)
            if isFileTitle, let path = filePathFromTitleLine(line) {
                currentLanguage = Language.from(filePath: path)
            }
            if line.hasPrefix("diff --git "), let path = bPathFromDiffGitLine(line) {
                currentLanguage = Language.from(filePath: path)
            }

            let lineAttr = NSMutableAttributedString(string: line)
            applyBaseAttributes(lineAttr, theme: theme)

            if isFileTitle {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.paragraphSpacing = 6
                lineAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: lineAttr.length))
                lineAttr.addAttribute(.backgroundColor, value: NSColor.secondaryLabelColor.withAlphaComponent(0.10), range: NSRange(location: 0, length: lineAttr.length))
                lineAttr.addAttribute(.font, value: NSFont.systemFont(ofSize: theme.headerFont.pointSize + 1, weight: .semibold), range: NSRange(location: 0, length: lineAttr.length))
                lineAttr.addAttribute(.foregroundColor, value: theme.textColor, range: NSRange(location: 0, length: lineAttr.length))
                output.append(lineAttr)
                continue
            }

            let isHeader = line.hasPrefix("diff --git")
                || line.hasPrefix("index ")
                || line.hasPrefix("+++ ")
                || line.hasPrefix("--- ")
                || line.hasPrefix("Binary file")
            let isHunk = line.hasPrefix("@@")
            let isAdd = line.hasPrefix("+") && !line.hasPrefix("+++ ")
            let isDel = line.hasPrefix("-") && !line.hasPrefix("--- ")
            let isContext = line.hasPrefix(" ")

            if (isAdd || isDel || isContext) && lineAttr.length > 0 {
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.headIndent = prefixIndent
                lineAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: lineAttr.length))
            }

            if isHeader {
                lineAttr.addAttribute(.foregroundColor, value: theme.secondaryTextColor, range: NSRange(location: 0, length: lineAttr.length))
                lineAttr.addAttribute(.font, value: theme.headerFont, range: NSRange(location: 0, length: lineAttr.length))
            } else if isHunk {
                lineAttr.addAttribute(.foregroundColor, value: theme.hunkColor, range: NSRange(location: 0, length: lineAttr.length))
            } else if isAdd {
                lineAttr.addAttribute(.backgroundColor, value: theme.addBackground, range: NSRange(location: 0, length: lineAttr.length))
                if lineAttr.length > 0 {
                    lineAttr.addAttribute(.foregroundColor, value: theme.addPrefix, range: NSRange(location: 0, length: 1))
                }
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: currentLanguage, contentRange: contentRange, theme: theme)
            } else if isDel {
                lineAttr.addAttribute(.backgroundColor, value: theme.deleteBackground, range: NSRange(location: 0, length: lineAttr.length))
                if lineAttr.length > 0 {
                    lineAttr.addAttribute(.foregroundColor, value: theme.deletePrefix, range: NSRange(location: 0, length: 1))
                }
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: currentLanguage, contentRange: contentRange, theme: theme)
            } else if isContext {
                let contentRange = NSRange(location: 1, length: max(0, lineAttr.length - 1))
                applySyntax(lineAttr, language: currentLanguage, contentRange: contentRange, theme: theme)
            } else {
                applySyntax(lineAttr, language: currentLanguage, contentRange: NSRange(location: 0, length: lineAttr.length), theme: theme)
            }

            output.append(lineAttr)
        }

        return output
    }

    static func highlightedCodeLine(
        text: String,
        language: Language,
        theme: Theme = .default
    ) -> NSAttributedString {
        let lineAttr = NSMutableAttributedString(string: text)
        applyBaseAttributes(lineAttr, theme: theme)
        applySyntax(lineAttr, language: language, contentRange: NSRange(location: 0, length: lineAttr.length), theme: theme)
        return lineAttr
    }

    static func highlightedCodeLineAttributed(
        text: String,
        language: Language
    ) -> AttributedString {
        var attr = AttributedString(text)
        guard !text.isEmpty else { return attr }

        let patterns = regexCache.patterns(for: language)
        let contentRange = NSRange(location: 0, length: (text as NSString).length)

        applyForegroundColor(.gray, regex: patterns.comment, in: text, range: contentRange, to: &attr)
        applyForegroundColor(.green, regex: patterns.string, in: text, range: contentRange, to: &attr)
        applyForegroundColor(.orange, regex: patterns.number, in: text, range: contentRange, to: &attr)
        applyForegroundColor(.teal, regex: patterns.type, in: text, range: contentRange, to: &attr)
        applyForegroundColor(.purple, regex: patterns.keyword, in: text, range: contentRange, to: &attr)
        return attr
    }

    private static func applyBaseAttributes(_ attr: NSMutableAttributedString, theme: Theme) {
        attr.addAttribute(.font, value: theme.font, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: theme.textColor, range: NSRange(location: 0, length: attr.length))
    }

    private static func applyForegroundColor(
        _ color: Color,
        regex: NSRegularExpression,
        in text: String,
        range: NSRange,
        to attr: inout AttributedString
    ) {
        let matches = regex.matches(in: text, options: [], range: range)
        for match in matches {
            guard let r = Range(match.range, in: text) else { continue }
            guard let start = AttributedString.Index(r.lowerBound, within: attr),
                  let end = AttributedString.Index(r.upperBound, within: attr)
            else { continue }
            attr[start..<end].foregroundColor = color
        }
    }

    private static func applySyntax(
        _ attr: NSMutableAttributedString,
        language: Language,
        contentRange: NSRange,
        theme: Theme
    ) {
        guard contentRange.length > 0 else { return }
        let string = attr.string as NSString
        let patterns = regexCache.patterns(for: language)

        for range in matchRanges(patterns.comment, in: string, range: contentRange) {
            attr.addAttribute(.foregroundColor, value: theme.commentColor, range: range)
        }

        for range in matchRanges(patterns.string, in: string, range: contentRange) {
            attr.addAttribute(.foregroundColor, value: theme.stringColor, range: range)
        }

        for range in matchRanges(patterns.number, in: string, range: contentRange) {
            attr.addAttribute(.foregroundColor, value: theme.numberColor, range: range)
        }

        for range in matchRanges(patterns.type, in: string, range: contentRange) {
            attr.addAttribute(.foregroundColor, value: theme.typeColor, range: range)
        }

        for range in matchRanges(patterns.keyword, in: string, range: contentRange) {
            attr.addAttribute(.foregroundColor, value: theme.keywordColor, range: range)
        }
    }

    private static func matchRanges(_ regex: NSRegularExpression, in string: NSString, range: NSRange) -> [NSRange] {
        regex.matches(in: string as String, options: [], range: range).map { $0.range }
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        var lines: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            lines.append(current)
        }
        return lines
    }

    private static func bPathFromDiffGitLine(_ line: String) -> String? {
        guard let range = line.range(of: "diff --git ") else { return nil }
        let remainder = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (_, b) = parseTwoTokens(String(remainder)) else { return nil }
        return stripGitDiffPathPrefix(b)
    }

    private static func isFileTitleLine(_ line: String, previousLine: String?, nextLine: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if line.hasPrefix("diff --") { return false }
        if line.hasPrefix("@@") { return false }
        if line.hasPrefix("+") { return false }
        if line.hasPrefix("-") { return false }
        if line.hasPrefix(" ") { return false }
        if line.hasPrefix("\\") { return false }

        if line.hasPrefix("index ") { return false }
        if line.hasPrefix("--- ") { return false }
        if line.hasPrefix("+++ ") { return false }

        if line.hasPrefix("new file mode ") { return false }
        if line.hasPrefix("deleted file mode ") { return false }
        if line.hasPrefix("old mode ") { return false }
        if line.hasPrefix("new mode ") { return false }
        if line.hasPrefix("similarity index ") { return false }
        if line.hasPrefix("dissimilarity index ") { return false }
        if line.hasPrefix("rename from ") { return false }
        if line.hasPrefix("rename to ") { return false }
        if line.hasPrefix("copy from ") { return false }
        if line.hasPrefix("copy to ") { return false }

        if line.hasPrefix("Binary files ") { return false }
        if line.hasPrefix("GIT binary patch") { return false }
        if line.hasPrefix("Binary file") { return false }

        let prevBlank = previousLine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard prevBlank else { return false }
        guard let nextLine else { return false }

        if nextLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if nextLine.hasPrefix("@@") { return true }
        if nextLine.hasPrefix("+") { return true }
        if nextLine.hasPrefix("-") { return true }
        if nextLine.hasPrefix(" ") { return true }
        if nextLine.hasPrefix("\\") { return true }
        if nextLine.hasPrefix("Binary") { return true }

        return false
    }

    private static func filePathFromTitleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = " ← "
        if let range = trimmed.range(of: separator) {
            return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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

    enum Language {
        case swift
        case js
        case ts
        case python
        case go
        case rust
        case zig
        case cpp
        case c
        case yaml
        case json
        case shell
        case unknown

        static func from(filePath: String?) -> Language {
            guard let filePath else { return .unknown }
            let ext = URL(fileURLWithPath: filePath).pathExtension.lowercased()
            switch ext {
            case "swift": return .swift
            case "js", "jsx": return .js
            case "ts", "tsx": return .ts
            case "py": return .python
            case "go": return .go
            case "rs": return .rust
            case "zig": return .zig
            case "c", "h": return .c
            case "cc", "cpp", "cxx", "hpp", "hh", "hxx": return .cpp
            case "yml", "yaml": return .yaml
            case "json": return .json
            case "sh", "bash", "zsh": return .shell
            default: return .unknown
            }
        }

    }
}

private final class RegexCache {
    struct Patterns {
        let keyword: NSRegularExpression
        let type: NSRegularExpression
        let string: NSRegularExpression
        let comment: NSRegularExpression
        let number: NSRegularExpression
    }

    private var cache: [DiffSyntaxHighlighter.Language: Patterns] = [:]
    private let lock = NSLock()

    func patterns(for language: DiffSyntaxHighlighter.Language) -> Patterns {
        lock.lock()
        if let cached = cache[language] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let patterns = makePatterns(for: language)
        lock.lock()
        cache[language] = patterns
        lock.unlock()
        return patterns
    }

    private func makePatterns(for language: DiffSyntaxHighlighter.Language) -> Patterns {
        let keywordPattern: String
        switch language {
        case .swift:
            keywordPattern = "\\b(class|struct|enum|protocol|extension|func|let|var|if|else|for|while|switch|case|default|return|break|continue|import|guard|throw|throws|try|catch|public|private|fileprivate|internal|open|static|mutating|inout|where|as|is|nil|true|false)\\b"
        case .js:
            keywordPattern = "\\b(function|const|let|var|if|else|for|while|switch|case|default|return|break|continue|import|from|export|class|extends|new|try|catch|finally|throw|async|await|this|super|null|true|false)\\b"
        case .ts:
            keywordPattern = "\\b(function|const|let|var|if|else|for|while|switch|case|default|return|break|continue|import|from|export|class|extends|new|try|catch|finally|throw|async|await|this|super|null|true|false|interface|type|implements|enum)\\b"
        case .python:
            keywordPattern = "\\b(def|class|import|from|as|if|elif|else|for|while|return|try|except|finally|with|yield|lambda|pass|break|continue|None|True|False)\\b"
        case .go:
            keywordPattern = "\\b(func|package|import|if|else|for|range|switch|case|default|return|break|continue|type|struct|interface|map|chan|go|defer|select|const|var)\\b"
        case .rust:
            keywordPattern = "\\b(fn|let|mut|pub|struct|enum|impl|trait|use|mod|crate|if|else|match|while|for|in|loop|return|break|continue|self|super|crate|const|static|ref)\\b"
        case .zig:
            keywordPattern = "\\b(const|var|fn|struct|enum|union|if|else|switch|while|for|break|continue|return|try|catch|async|await|comptime|anytype)\\b"
        case .cpp, .c:
            keywordPattern = "\\b(auto|bool|break|case|catch|class|const|constexpr|continue|default|delete|do|else|enum|explicit|extern|false|for|friend|goto|if|inline|namespace|new|nullptr|operator|private|protected|public|return|sizeof|static|struct|switch|template|this|throw|true|try|typedef|typename|union|using|virtual|void|volatile|while)\\b"
        case .yaml:
            keywordPattern = "^(\\s*)([\\w\\-]+)(?=\\:)"
        case .json:
            keywordPattern = "\"(\\\\.|[^\"])*\"(?=\\s*\\:)"
        case .shell:
            keywordPattern = "\\b(if|then|else|fi|for|in|do|done|case|esac|while|until|function|select|time|return|break|continue)\\b"
        case .unknown:
            keywordPattern = "$^"
        }

        let typePattern: String = switch language {
        case .swift, .ts, .js: "\\b[A-Z][A-Za-z0-9_]*\\b"
        default: "$^"
        }

        let stringPattern: String = switch language {
        case .python: "(\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\"(\\\\.|[^\"])*\"|'(\\\\.|[^'])*')"
        default: "(\"(\\\\.|[^\"])*\"|'(\\\\.|[^'])*')"
        }

        let commentPattern: String = switch language {
        case .python, .yaml, .shell: "#.*$"
        case .json: "$^"
        default: "(//.*$|/\\*[\\s\\S]*?\\*/)"
        }

        let numberPattern = "\\b\\d+(\\.\\d+)?\\b"

        let keyword = (try? NSRegularExpression(pattern: keywordPattern, options: [.anchorsMatchLines])) ?? NSRegularExpression()
        let type = (try? NSRegularExpression(pattern: typePattern, options: [])) ?? NSRegularExpression()
        let string = (try? NSRegularExpression(pattern: stringPattern, options: [])) ?? NSRegularExpression()
        let comment = (try? NSRegularExpression(pattern: commentPattern, options: [.anchorsMatchLines])) ?? NSRegularExpression()
        let number = (try? NSRegularExpression(pattern: numberPattern, options: [])) ?? NSRegularExpression()

        return Patterns(keyword: keyword, type: type, string: string, comment: comment, number: number)
    }
}
