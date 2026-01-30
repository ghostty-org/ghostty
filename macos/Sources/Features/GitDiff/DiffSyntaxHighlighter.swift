import AppKit
import Foundation

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

    private static func applyBaseAttributes(_ attr: NSMutableAttributedString, theme: Theme) {
        attr.addAttribute(.font, value: theme.font, range: NSRange(location: 0, length: attr.length))
        attr.addAttribute(.foregroundColor, value: theme.textColor, range: NSRange(location: 0, length: attr.length))
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

    func patterns(for language: DiffSyntaxHighlighter.Language) -> Patterns {
        if let cached = cache[language] { return cached }
        let patterns = makePatterns(for: language)
        cache[language] = patterns
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
