import AppKit
import Foundation
import SwiftUI

struct GitDiffMainView: View {
    @ObservedObject var state: GitDiffSidebarState

    var body: some View {
        content
        .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
    }

    @ViewBuilder
    private var content: some View {
        if state.isDiffLoading {
            VStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                Spacer()
            }
        } else if let diffError = state.diffError, !diffError.isEmpty {
            Text(diffError)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if state.diffText.isEmpty {
            Text("No diff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DiffTextViewRepresentable(
                text: state.diffText,
                filePath: state.selectedPath
            )
        }
    }
}

private struct DiffTextViewRepresentable: NSViewRepresentable {
    let text: String
    let filePath: String?

    func makeNSView(context: Context) -> DiffTextContainerView {
        DiffTextContainerView()
    }

    func updateNSView(_ nsView: DiffTextContainerView, context: Context) {
        nsView.update(text: text, filePath: filePath)
    }
}

private final class DiffTextContainerView: NSView {
    private let headerView = DiffStickyHeaderView()
    private let scrollView = NSScrollView()
    private let textView = DiffTextView()

    private var sections: [DiffFileSection] = []
    private var renderNonce: Int = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func update(text: String, filePath: String?) {
        let key = DiffTextView.RenderKey(text: text, filePath: filePath)
        if textView.lastRenderKey == key { return }
        textView.lastRenderKey = key

        renderNonce += 1
        let nonce = renderNonce

        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = DiffFileSectionParser.parse(text: text)
            let highlighted = DiffSyntaxHighlighter.highlightedDiff(text: parsed.displayText, filePath: filePath)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard nonce == self.renderNonce else { return }
                self.sections = parsed.sections
                self.textView.textStorage?.setAttributedString(highlighted)
                self.updateStickyHeaderForScroll()
            }
        }
    }

    private func setup() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc
    private func scrollBoundsDidChange() {
        updateStickyHeaderForScroll()
    }

    private func updateStickyHeaderForScroll() {
        guard !sections.isEmpty else {
            headerView.update(title: textView.lastRenderKey?.filePath ?? "Diff", headerLines: [])
            return
        }

        let charLocation = visibleCharacterLocation()
        let section = sections.section(atCharacterOffset: charLocation) ?? sections.first
        headerView.update(
            title: section?.title ?? "Diff",
            headerLines: section?.headerLines ?? []
        )
    }

    private func visibleCharacterLocation() -> Int {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return 0 }
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        return charRange.location
    }
}

private final class DiffStickyHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private var lineLabels: [NSTextField] = []
    private let stackView = NSStackView()
    private let bottomBorder = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(title: String, headerLines: [String]) {
        let display = displayTitle(from: title)
        let normalized = normalizedHeaderLines(headerLines)
        if titleLabel.stringValue == display,
           titleLabel.toolTip == title,
           zip(lineLabels, normalized + Array(repeating: "", count: max(0, lineLabels.count - normalized.count))).allSatisfy({ $0.stringValue == $1 })
        {
            return
        }

        titleLabel.stringValue = display
        titleLabel.toolTip = title

        for (idx, label) in lineLabels.enumerated() {
            let value = idx < normalized.count ? normalized[idx] : ""
            label.stringValue = value
            label.isHidden = value.isEmpty
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView.orientation = .vertical
        stackView.spacing = 2
        stackView.alignment = .leading
        stackView.distribution = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(titleLabel)

        lineLabels = (0..<8).map { _ in
            let label = NSTextField(labelWithString: "")
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = NSColor.secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            stackView.addArrangedSubview(label)
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            ])
            return label
        }

        NSLayoutConstraint.activate([
            titleLabel.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
        ])

        addSubview(stackView)

        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)

        NSLayoutConstraint.activate([
            bottomBorder.heightAnchor.constraint(equalToConstant: 1),
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: bottomBorder.topAnchor, constant: -6),
        ])
    }

    private func displayTitle(from title: String) -> String {
        let separator = " ← "
        if let range = title.range(of: separator) {
            let right = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let left = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(basename(right)) ← \(basename(left))"
        }
        return basename(title)
    }

    private func basename(_ path: String) -> String {
        let component = URL(fileURLWithPath: path).lastPathComponent
        return component.isEmpty ? path : component
    }

    private func normalizedHeaderLines(_ headerLines: [String]) -> [String] {
        let lines = headerLines
            .prefix(8)
            .map { $0.trimmingCharacters(in: .newlines) }
        return Array(lines)
    }
}

private final class DiffTextView: NSTextView {
    struct RenderKey: Equatable {
        let textHash: Int
        let filePath: String?

        init(text: String, filePath: String?) {
            self.textHash = text.hashValue
            self.filePath = filePath
        }
    }

    var lastRenderKey: RenderKey?

}

private struct DiffFileSection: Equatable {
    let startOffsetUtf16: Int
    let title: String
    let headerLines: [String]
}

private enum DiffFileSectionParser {
    struct ParsedDiff: Equatable {
        let displayText: String
        let sections: [DiffFileSection]
    }

    static func parse(text: String) -> ParsedDiff {
        var displayLines: [String] = []
        displayLines.reserveCapacity(512)

        var sections: [DiffFileSection] = []
        sections.reserveCapacity(32)

        var displayOffsetUtf16 = 0
        var currentSectionIndex: Int? = nil
        var inHeaderBlock = false
        var capturedFirstHunkHeader = false

        for line in splitLines(text) {
            if line.hasPrefix("diff --git ") {
                let title = titleFromDiffGitLine(line) ?? "Diff"
                sections.append(DiffFileSection(startOffsetUtf16: displayOffsetUtf16, title: title, headerLines: [line]))
                currentSectionIndex = sections.count - 1
                inHeaderBlock = true
                capturedFirstHunkHeader = false
                continue
            }

            if inHeaderBlock, let currentSectionIndex {
                if isGitHeaderLine(line) || isGitMetaLine(line) {
                    let section = sections[currentSectionIndex]
                    sections[currentSectionIndex] = DiffFileSection(
                        startOffsetUtf16: section.startOffsetUtf16,
                        title: section.title,
                        headerLines: section.headerLines + [line]
                    )
                    continue
                }

                if line.hasPrefix("@@"), !capturedFirstHunkHeader {
                    let section = sections[currentSectionIndex]
                    sections[currentSectionIndex] = DiffFileSection(
                        startOffsetUtf16: section.startOffsetUtf16,
                        title: section.title,
                        headerLines: section.headerLines + [line]
                    )
                    capturedFirstHunkHeader = true
                    inHeaderBlock = false
                    continue
                }

                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    let section = sections[currentSectionIndex]
                    sections[currentSectionIndex] = DiffFileSection(
                        startOffsetUtf16: section.startOffsetUtf16,
                        title: section.title,
                        headerLines: section.headerLines + [line]
                    )
                    inHeaderBlock = false
                    continue
                }

                inHeaderBlock = false
            }

            displayLines.append(line)
            displayOffsetUtf16 += line.utf16.count
        }

        return ParsedDiff(displayText: displayLines.joined(), sections: sections)
    }

    private static func isGitHeaderLine(_ line: String) -> Bool {
        line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
    }

    private static func isGitMetaLine(_ line: String) -> Bool {
        line.hasPrefix("new file mode ")
            || line.hasPrefix("deleted file mode ")
            || line.hasPrefix("old mode ")
            || line.hasPrefix("new mode ")
            || line.hasPrefix("similarity index ")
            || line.hasPrefix("dissimilarity index ")
            || line.hasPrefix("rename from ")
            || line.hasPrefix("rename to ")
            || line.hasPrefix("copy from ")
            || line.hasPrefix("copy to ")
    }

    private static func splitLines(_ text: String) -> [String] {
        if text.isEmpty { return [""] }
        var lines: [String] = []
        lines.reserveCapacity(256)

        var current = ""
        current.reserveCapacity(128)
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

    private static func titleFromDiffGitLine(_ line: String) -> String? {
        guard let range = line.range(of: "diff --git ") else { return nil }
        let remainder = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let (a, b) = parseTwoTokens(remainder) else { return nil }

        let aPath = stripGitDiffPathPrefix(a)
        let bPath = stripGitDiffPathPrefix(b)

        let isDevNullA = aPath == "/dev/null"
        let isDevNullB = bPath == "/dev/null"

        if isDevNullA && !isDevNullB { return bPath }
        if isDevNullB && !isDevNullA { return aPath }
        if aPath != bPath { return "\(bPath) ← \(aPath)" }
        return bPath
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

private extension Array where Element == DiffFileSection {
    func section(atCharacterOffset offset: Int) -> DiffFileSection? {
        guard !isEmpty else { return nil }
        if offset <= 0 { return first }
        if offset >= (last?.startOffsetUtf16 ?? 0) { return last }

        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let midOffset = self[mid].startOffsetUtf16
            if midOffset == offset { return self[mid] }
            if midOffset < offset {
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let index = Swift.max(0, Swift.min(high, count - 1))
        return self[index]
    }
}
