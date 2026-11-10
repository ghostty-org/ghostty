import AppKit

final class GitHistoryCell: NSTableCellView {
    private let subject = InspectorCopyableTextField(labelWithString: "")
    private let authorAndEmail = GitMetadataLine()
    private let timeAndHash = GitMetadataLine()
    private let badges = GitRefBadgesView()
    private let graph = GitGraphCellView()
    private let disclosure = NSButton()
    private var graphWidth: CGFloat = 10
    private var contentX: CGFloat = 13
    private var toggle: () -> Void = {}

    static func height(commit: GitHistoryCommit, refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        let badges = GitRefBadgesView.height(for: refs, width: width)
        return 56 + (badges > 0 ? badges + 5 : 0)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        subject.cell = GitHistorySubjectCell(textCell: "")
        subject.font = .systemFont(ofSize: 12, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail
        subject.maximumNumberOfLines = 1
        subject.isSelectable = false
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.imageScaling = .scaleNone
        disclosure.controlSize = .small
        disclosure.focusRingType = .none
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.setButtonType(.momentaryChange)
        disclosure.target = self
        disclosure.action = #selector(toggleCommit)
        [graph, disclosure, subject, authorAndEmail, timeAndHash, badges].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @objc private func toggleCommit() { toggle() }

    func configure(commit: GitHistoryCommit, graph: GitGraphRow, graphLayout: GitGraphColumnLayout,
                   summary: (date: String, refs: [GitRefDecoration]), state: (head: Bool, expanded: Bool),
                   query: GitHistorySearchQuery = .init(""),
                   toggle: @escaping () -> Void, contextMenu: (() -> NSMenu?)? = nil,
                   colors: GitCollectionColors = .init()) {
        self.toggle = toggle
        graphWidth = graphLayout.width
        contentX = graphLayout.contentX
        self.graph.configure(row: graph, isHead: state.head, layout: graphLayout,
                             section: state.expanded ? .expandedCommit : .commit)
        let title = commit.subject.isEmpty ? GitL10n.text("(no subject)") : commit.subject
        let subjectText = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        if let snippet = query.bodySnippet(for: commit) {
            subjectText.append(NSAttributedString(string: " · " + snippet, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        GitSearchHighlight.apply(terms: query.subjectHighlightTerms, to: subjectText)
        subject.attributedStringValue = subjectText
        let doubleClick = toggle
        authorAndEmail.configure(
            .init(text: commit.authorName, value: commit.authorName, label: GitL10n.text("Author"),
                  highlights: query.authorTerms),
            second: commit.authorEmail.isEmpty ? nil : .init(
                text: commit.authorEmail, value: commit.authorEmail, label: GitL10n.text("Email"),
                highlights: query.emailTerms
            ),
            onDoubleClick: doubleClick
        )
        timeAndHash.configure(
            .init(text: summary.date, value: commit.authoredAt.description, label: GitL10n.text("Time")),
            second: .init(text: commit.id.shortSHA, value: commit.id.rawValue, label: GitL10n.text("Commit SHA"),
                          highlights: query.hashTerms(for: commit.id)),
            onDoubleClick: doubleClick
        )
        subject.copyItems = [(GitL10n.text("Copy subject"), commit.subject)]
        subject.contextMenuProvider = contextMenu
        authorAndEmail.contextMenuProvider = contextMenu
        timeAndHash.contextMenuProvider = contextMenu
        badges.colors = colors
        badges.configure(summary.refs)
        disclosure.image = NSImage(systemSymbolName: state.expanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: state.expanded ? GitL10n.text("Collapse commit") : GitL10n.text("Expand commit"))?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .medium))
        toolTip = "\(commit.subject)\n\(commit.authorName) <\(commit.authorEmail)>\n\(commit.authoredAt)\n\(commit.id.rawValue)"
        needsLayout = true
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        disclosure.frame = NSRect(x: bounds.width - 24, y: GitHistoryRowMetrics.contentAxisY - 9, width: 18, height: 18)
        let x = contentX
        let width = max(1, bounds.width - x - 8)
        subject.frame = NSRect(x: x, y: 4, width: max(1, width - 22), height: 17)
        authorAndEmail.frame = NSRect(x: x, y: 23, width: width, height: 14)
        timeAndHash.frame = NSRect(x: x, y: 39, width: width, height: 13)
        let badgeY: CGFloat = 56
        badges.frame = NSRect(x: x, y: badgeY, width: width, height: max(0, bounds.height - badgeY - 5))
    }
}

/// Child rows share the commit's graph gutter; they have no card background or
/// repeated summary. Files precede the optional, independently folded body.
final class GitHistoryDetailCell: NSTableCellView {
    enum Content {
        case files(Int, GitDiffStatistics?, Bool)
        case file(GitDiffFile, Int = 0, Bool = false)
        case folder(String, Int, Bool)
        case message(String, Bool?)
        case notice(String, Bool)
    }
    private let graph = GitGraphCellView()
    private let label = InspectorCopyableTextField(wrappingLabelWithString: "")
    private let button = NSButton()
    private let openIcon = NSImageView()
    private var graphWidth: CGFloat = 10
    private var contentX: CGFloat = 13
    private var content = Content.notice("", false)
    private var query = GitHistorySearchQuery("")
    private var action: () -> Void = {}

    private struct Measurement: Hashable { let text: String; let width: CGFloat }
    private static var measurements: [Measurement: CGFloat] = [:]
    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let key = Measurement(text: text, width: width)
        if let height = measurements[key] { return height }
        let cell = NSTextFieldCell(textCell: text)
        cell.font = .systemFont(ofSize: 11)
        cell.wraps = true
        cell.isScrollable = false
        cell.usesSingleLineMode = false
        let height = ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width),
                                                   height: .greatestFiniteMagnitude)).height)
        if measurements.count >= 32 { measurements.removeAll(keepingCapacity: true) }
        measurements[key] = height
        return height
    }
    static func height(for content: Content, width: CGFloat, query: GitHistorySearchQuery = .init("")) -> CGFloat {
        switch content {
        case .files: return 28
        case .file, .folder: return 22
        case .notice(let text, _): return max(26, textHeight(text, width: width) + 12)
        case .message(let text, let expanded):
            return messageIsExpanded(text, preference: expanded, width: width, query: query)
                ? textHeight(text, width: width - 12) + 36 : 28
        }
    }
    static func messageIsExpanded(
        _ text: String,
        preference: Bool?,
        width: CGFloat,
        query: GitHistorySearchQuery = .init("")
    ) -> Bool {
        if let preference { return preference }
        if query.messageTerms.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return true }
        guard text.utf16.count <= max(320, Int(width) * 2) else { return false }
        return textHeight(text, width: width - 12) <= 56
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [graph, label, button, openIcon].forEach(addSubview)
        label.font = .systemFont(ofSize: 11)
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeft
        button.imageScaling = .scaleNone
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.target = self
        button.action = #selector(activate)
        button.cell?.lineBreakMode = .byTruncatingTail
        openIcon.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        openIcon.contentTintColor = .tertiaryLabelColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    @objc private func activate() { action() }

    func configure(graph: GitGraphRow, graphLayout: GitGraphColumnLayout, isLast: Bool,
                   content: Content, query: GitHistorySearchQuery = .init(""),
                   action: @escaping () -> Void) {
        graphWidth = graphLayout.width
        contentX = graphLayout.contentX
        self.graph.configure(row: graph, layout: graphLayout, section: isLast ? .expansionEnd : .continuation)
        self.content = content
        self.query = query
        self.action = action
        toolTip = nil
        if case .file(let file, _, _) = content {
            toolTip = GitL10n.text("Open diff · ") + file.kind.label + " · " + file.displayPath
            setAccessibilityRole(.button)
        } else { setAccessibilityRole(.group) }
        setAccessibilityLabel(toolTip)
        needsLayout = true
    }
    override func accessibilityPerformPress() -> Bool {
        guard case .file = content else { return false }
        action()
        return true
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if case .file = content { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func layout() {
        super.layout()
        graph.frame = NSRect(x: 0, y: 0, width: graphWidth, height: bounds.height)
        let x = contentX
        let width = max(1, bounds.width - x - 8)
        label.frame = NSRect(x: x, y: 6, width: width, height: max(1, bounds.height - 12))
        label.isHidden = false
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.usesSingleLineMode = false
        label.cell?.wraps = true
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        button.toolTip = nil
        button.isHidden = true
        openIcon.isHidden = true
        switch content {
        case .folder(let title, let depth, let expanded):
            label.isHidden = true
            button.isHidden = false
            let folderTitle = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
            GitSearchHighlight.apply(terms: query.fileTerms, to: folderTitle)
            button.attributedTitle = folderTitle
            button.image = NSImage(systemSymbolName: expanded ? "folder.fill" : "folder", accessibilityDescription: nil)
            button.frame = NSRect(x: x + 12 + CGFloat(depth) * 14, y: 1,
                                  width: max(1, width - 12 - CGFloat(depth) * 14), height: 20)
        case .files(let count, let stats, let collapsed):
            label.isHidden = true
            button.isHidden = false
            button.attributedTitle = Self.filesTitle(count: count, statistics: stats)
            button.image = Self.chevron(collapsed ? "right" : "down")
            button.frame = NSRect(x: x, y: 4, width: width, height: 20)
            button.toolTip = button.attributedTitle.string
        case .file(let file, let depth, let tree):
            label.isSelectable = false
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.cell?.wraps = false
            label.cell?.isScrollable = false
            label.cell?.usesSingleLineMode = true
            let text = NSMutableAttributedString(string: file.kind.rawValue + "  ", attributes: [
                .foregroundColor: file.kind.color, .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            ])
            let pathOffset = text.length
            let display = tree ? (file.path as NSString).lastPathComponent : file.displayPath
            text.append(NSAttributedString(string: display, attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11),
            ]))
            GitSearchHighlight.apply(terms: query.fileTerms, to: text,
                                     range: NSRange(location: pathOffset, length: text.length - pathOffset))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            label.attributedStringValue = text
            label.frame = NSRect(x: x + 12 + CGFloat(depth) * 14, y: 3,
                                 width: max(1, width - 26 - CGFloat(depth) * 14), height: 15)
            openIcon.isHidden = false
            openIcon.frame = NSRect(x: x + width - 10, y: 6, width: 8, height: 8)
        case .notice(let text, let isError):
            label.isSelectable = true
            if label.stringValue != text { label.stringValue = text }
            label.textColor = isError ? .systemRed : .secondaryLabelColor
        case .message(let text, let preference):
            let expanded = Self.messageIsExpanded(text, preference: preference, width: width, query: query)
            let messageText = NSMutableAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            GitSearchHighlight.apply(terms: query.messageTerms, to: messageText)
            label.attributedStringValue = messageText
            label.isHidden = !expanded
            button.isHidden = false
            let lines = text.components(separatedBy: "\n").count
            button.title = GitL10n.format(lines == 1 ? "Commit message · {0} line" : "Commit message · {0} lines", String(lines))
            button.image = Self.chevron(expanded ? "down" : "right")
            button.frame = NSRect(x: x, y: 4, width: width, height: 20)
            label.frame = NSRect(x: x + 12, y: 30, width: max(1, width - 12), height: max(1, bounds.height - 36))
        }
    }
    private static func chevron(_ direction: String) -> NSImage? {
        NSImage(systemSymbolName: "chevron." + direction, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
    }
    private static func filesTitle(count: Int, statistics: GitDiffStatistics?) -> NSAttributedString {
        let value = NSMutableAttributedString(string: GitL10n.format(count == 1 ? "{0} file changed" : "{0} files changed", String(count)), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor,
        ])
        if let statistics {
            value.append(NSAttributedString(string: " · +\(statistics.additions)", attributes: [.foregroundColor: NSColor.systemGreen]))
            value.append(NSAttributedString(string: " −\(statistics.deletions)", attributes: [.foregroundColor: NSColor.systemRed]))
            if statistics.binaryFiles > 0 {
                value.append(NSAttributedString(string: GitL10n.format(" · {0} binary", String(describing: statistics.binaryFiles)), attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        value.addAttribute(.font, value: NSFont.systemFont(ofSize: 10, weight: .medium), range: NSRange(location: 0, length: value.length))
        return value
    }
}

enum GitSearchHighlight {
    static let fillColor = NSColor.systemYellow.withAlphaComponent(0.45)

    static func apply(terms: [String], to attributed: NSMutableAttributedString, range: NSRange? = nil) {
        let bounds = range ?? NSRange(location: 0, length: attributed.length)
        guard bounds.length > 0 else { return }
        let source = attributed.string as NSString
        for term in terms where !term.isEmpty {
            var remaining = bounds
            while remaining.length > 0 {
                let match = source.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                guard match.location != NSNotFound, match.length > 0 else { break }
                attributed.addAttributes([
                    .backgroundColor: fillColor,
                    .foregroundColor: NSColor.labelColor,
                ], range: match)
                let end = NSMaxRange(match)
                let maxEnd = NSMaxRange(bounds)
                guard end < maxEnd else { break }
                remaining = NSRange(location: end, length: maxEnd - end)
            }
        }
    }
}

/// Draw at the row's content origin without NSTextField's internal text inset.
/// Subject selection/copy remains owned by the history table.
private final class GitHistorySubjectCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        let text: NSMutableAttributedString
        if attributedStringValue.length > 0 {
            text = NSMutableAttributedString(attributedString: attributedStringValue)
        } else {
            text = NSMutableAttributedString(string: stringValue, attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: textColor ?? NSColor.labelColor,
            ])
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        text.draw(in: cellFrame)
    }
}
