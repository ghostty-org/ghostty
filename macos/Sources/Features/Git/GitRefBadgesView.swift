import AppKit

/// One fixed-height row. Every badge opens the complete, copyable ref list.
final class GitRefBadgesView: NSView, NSPopoverDelegate {
    static let maximumBadgeWidth: CGFloat = 104
    static let badgeHeight: CGFloat = 17

    struct Badge: Equatable {
        let decoration: GitRefDecoration
        let refs: [GitRefDecoration]
        let isCount: Bool
        var widthLimit: CGFloat = GitRefBadgesView.maximumBadgeWidth
    }
    private var refs: [GitRefDecoration] = []
    private var rendered: [Badge] = []
    private var layoutWidth: CGFloat?
    private var buttons: [NSButton] = []
    private(set) var popover: NSPopover?
    private var referenceController: GitReferenceListPopoverController?
    private let popoverState = GitCollectionState()
    var colors = GitCollectionColors()
    private var languageCode = GitL10n.current.languageCode
    override var isFlipped: Bool { true }

    static func attributed(_ decoration: GitRefDecoration, inset: Bool = true) -> NSAttributedString {
        let color = tint(for: decoration.kind)
        let symbol = decoration.kind == .head ? nil : symbol(for: decoration.kind)
        let text = NSMutableAttributedString(string: inset ? " " : "")
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: decoration.kind.displayName)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))?
            .withSymbolConfiguration(.init(paletteColors: [color])) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -2, width: 11, height: 11)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: (inset || symbol != nil ? " " : "") + decoration.name + " ", attributes: [
            .foregroundColor: color, .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        ]))
        return text
    }

    static func symbol(for kind: GitRefDecorationKind) -> String? {
        switch kind {
        case .currentBranch, .localBranch: "arrow.triangle.branch"
        case .remoteBranch: "network"
        case .tag: "tag.fill"
        case .head: "circle.inset.filled"
        }
    }

    static func tint(for kind: GitRefDecorationKind) -> NSColor {
        switch kind {
        case .head, .currentBranch: .systemBlue
        case .localBranch: .systemGreen
        case .remoteBranch: .systemPurple
        case .tag: .systemOrange
        }
    }

    static func badges(for refs: [GitRefDecoration], width: CGFloat) -> [Badge] {
        let ordered = GitRefDecoration.orderedForDisplay(refs)
        func named(_ ref: GitRefDecoration) -> Badge { Badge(decoration: ref, refs: [ref], isCount: false) }
        func count(_ refs: [GitRefDecoration], kind: GitRefDecorationKind) -> [Badge] {
            refs.isEmpty ? [] : [Badge(decoration: .init(name: String(refs.count), kind: kind), refs: refs, isCount: true)]
        }
        func fit(_ values: [Badge]) -> [Badge]? {
            var widths = values.map(badgeWidth)
            let minimums = zip(values, widths).map { badge, width in
                badge.isCount || badge.decoration.kind == .head ? width : min(48, width)
            }
            let gaps = CGFloat(max(0, values.count - 1)) * 4
            guard minimums.reduce(0, +) + gaps <= width else { return nil }
            var excess = max(0, widths.reduce(0, +) + gaps - width)
            // Keep a readable tag before sacrificing its name to an aggregate.
            let indices = values.indices.sorted { (values[$0].decoration.kind == .tag ? 1 : 0) < (values[$1].decoration.kind == .tag ? 1 : 0) }
            for index in indices {
                let removed = min(excess, widths[index] - minimums[index])
                widths[index] -= removed
                excess -= removed
            }
            return values.enumerated().map { index, badge in
                var badge = badge
                badge.widthLimit = widths[index]
                return badge
            }
        }
        let head = ordered.filter { $0.kind == .head }.map(named)
        let branches = ordered.filter { $0.kind == .currentBranch || $0.kind == .localBranch }
        let remotes = ordered.filter { $0.kind == .remoteBranch }
        let tags = ordered.filter { $0.kind == .tag }
        let tagBadges = tags.prefix(1).map(named) + count(Array(tags.dropFirst()), kind: .tag)
        if let all = fit(head + branches.map(named) + remotes.map(named) + tagBadges) { return all }
        let remoteBadges = branches.isEmpty ? remotes.prefix(1).map(named) + count(Array(remotes.dropFirst()), kind: .remoteBranch)
            : count(remotes, kind: .remoteBranch)
        let primary = head + branches.prefix(1).map(named) + count(Array(branches.dropFirst()), kind: .localBranch) + remoteBadges + tagBadges
        if let result = fit(primary) { return result }
        if let result = fit(head + count(branches, kind: .localBranch) + count(remotes, kind: .remoteBranch) + tagBadges) { return result }
        if let result = fit(head + count(branches, kind: .localBranch) + count(remotes, kind: .remoteBranch) + count(tags, kind: .tag)) { return result }
        let others = ordered.filter { $0.kind != .tag }
        let otherBadge = others.isEmpty ? [] : [Badge(decoration: .init(name: GitL10n.format("{0} refs", String(describing: others.count)), kind: .head), refs: others, isCount: true)]
        if let result = fit(otherBadge + tagBadges) { return result }
        return ordered.isEmpty ? [] : [Badge(decoration: .init(name: GitL10n.format("{0} refs", String(describing: ordered.count)), kind: .head), refs: ordered, isCount: true)]
    }

    private static func badgeWidth(_ badge: Badge) -> CGFloat {
        min(badge.widthLimit, ceil(attributed(badge.decoration, inset: false).size().width) + 4)
    }

    static func height(for refs: [GitRefDecoration], width: CGFloat) -> CGFloat {
        refs.isEmpty ? 0 : badgeHeight
    }

    func configure(_ refs: [GitRefDecoration]) {
        let languageChanged = languageCode != GitL10n.current.languageCode
        guard self.refs != refs || languageChanged else { return }
        languageCode = GitL10n.current.languageCode
        if languageChanged { rendered = [] }
        popover?.close()
        layoutWidth = nil
        self.refs = refs
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { popover?.close() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutWidth = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard layoutWidth != bounds.width else { return }
        layoutWidth = bounds.width
        let next = Self.badges(for: refs, width: bounds.width)
        if next != rendered {
            buttons.forEach { $0.removeFromSuperview() }
            rendered = next
            buttons = next.map { badge in
                let button = NSButton()
                button.setButtonType(.momentaryChange)
                button.isBordered = false
                button.alignment = .left
                button.controlSize = .small
                button.attributedTitle = Self.attributed(badge.decoration, inset: false)
                button.attributedAlternateTitle = button.attributedTitle
                (button.cell as? NSButtonCell)?.highlightsBy = []
                (button.cell as? NSButtonCell)?.showsStateBy = []
                button.cell?.lineBreakMode = .byTruncatingTail
                button.wantsLayer = true
                button.layer?.cornerRadius = 3
                button.target = self
                button.action = #selector(showRefs(_:))
                button.toolTip = badge.refs.map(\.name).joined(separator: "\n")
                button.setAccessibilityLabel(button.toolTip)
                button.setAccessibilityHelp(GitL10n.text("Show complete refs"))
                addSubview(button)
                return button
            }
        }
        var x: CGFloat = 0
        for (button, badge) in zip(buttons, rendered) {
            let width = min(Self.badgeWidth(badge), max(0, bounds.width - x))
            button.frame = NSRect(x: x, y: 0, width: width, height: Self.badgeHeight)
            button.layer?.backgroundColor = Self.tint(for: badge.decoration.kind).withAlphaComponent(0.10).cgColor
            x += width + 4
        }
    }

    @objc private func showRefs(_ sender: NSButton) {
        popover?.performClose(nil)
        let selected = buttons.firstIndex(where: { $0 === sender }).flatMap { rendered[$0].refs.first }
        let popover = NSPopover()
        let controller = GitReferenceListPopoverController(
            refs: refs,
            selected: selected,
            state: popoverState,
            colors: colors,
            pasteboard: .general,
            close: { [weak popover] in popover?.performClose(nil) }
        )
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = GitRefPopoverStyle.size
        referenceController = controller
        self.popover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minX)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === popover else { return }
        referenceController?.saveAnchor()
        referenceController = nil
        popover = nil
    }
}
