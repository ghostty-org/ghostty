import AppKit

/// Reused native cells keep file identity and checkbox state explicit.
final class GitCollectionCell: NSTableCellView {
    let checkbox = GitStageCheckbox()
    private let progress = NativeProgressIndicator()
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let rule = NSView()
    private var row: GitCollectionRow?
    private var toggle: () -> Void = {}
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for field in [name, subtitle, status, badge] {
            field.lineBreakMode = .byTruncatingMiddle
            field.maximumNumberOfLines = 1
        }
        name.font = .systemFont(ofSize: 11)
        subtitle.font = .systemFont(ofSize: 10)
        status.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
        badge.font = .systemFont(ofSize: 9)
        badge.alignment = .right
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.target = self
        disclosure.action = #selector(toggleFolder)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        rule.wantsLayer = true
        [checkbox, progress, disclosure, icon, name, subtitle, status, badge, rule].forEach(addSubview)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ row: GitCollectionRow, colors: GitCollectionColors, toggle: @escaping () -> Void,
                   stage: @escaping () -> Void) {
        self.row = row
        self.toggle = toggle
        let item = row.item
        [checkbox, progress, disclosure, icon, subtitle, status, badge, rule].forEach { $0.isHidden = true }
        progress.setAnimating(false)
        name.stringValue = item.title
        name.font = .systemFont(ofSize: 11, weight: item.isCategory ? .medium : .regular)
        name.textColor = item.isCategory ? colors.secondary : colors.text
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle?.isEmpty != false
        subtitle.textColor = colors.secondary
        status.textColor = colors.secondary
        badge.textColor = colors.secondary
        icon.contentTintColor = colors.secondary
        disclosure.contentTintColor = colors.secondary
        rule.layer?.backgroundColor = colors.separator.cgColor
        alphaValue = item.enabled || item.pending ? 1 : 0.55
        toolTip = item.tooltip
        setAccessibilityIdentifier(item.id)
        setAccessibilityLabel(item.tooltip)
        checkbox.actionSymbol = nil
        checkbox.setAccessibilityRole(.checkBox)
        if let batch = item.stageBatch {
            if item.isCategory {
                checkbox.actionSymbol = batch.shouldStage ? "plus" : "minus"
                checkbox.setAccessibilityRole(.button)
            }
            checkbox.configure(state: batch.isMixed ? .mixed : batch.allStaged ? .on : .off, enabled: item.enabled, colors: colors)
            checkbox.activate = stage
            checkbox.setAccessibilityIdentifier(item.id + "/checkbox")
            let actionTitle = item.isCategory ? (batch.shouldStage ? GitL10n.text("Stage All") : GitL10n.text("Unstage All"))
                : item.isFolder ? (batch.shouldStage ? GitL10n.text("Stage folder") : GitL10n.text("Unstage folder"))
                : batch.shouldStage ? GitL10n.text("Stage files") : GitL10n.text("Unstage files")
            checkbox.setAccessibilityLabel(actionTitle)
            checkbox.toolTip = item.pending ? GitL10n.text("Updating index…") : actionTitle
            checkbox.isHidden = item.pending
            if item.pending { progress.isHidden = false; progress.setAnimating(true) }
        }
        switch item.kind {
        case .ref(let ref):
            setIcon(GitRefBadgesView.symbol(for: ref.kind) ?? "arrow.triangle.branch")
            icon.contentTintColor = ref.kind == .tag ? colors.modified : colors.accent
        case .category(let count):
            badge.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            badge.isHidden = false; rule.isHidden = item.stageBatch != nil
        case .folder(let count):
            disclosure.isHidden = false
            disclosure.image = NSImage(systemSymbolName: row.expanded ? "chevron.down" : "chevron.right", accessibilityDescription: row.expanded ? GitL10n.text("Collapse folder") : GitL10n.text("Expand folder"))?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            setIcon("folder")
            badge.stringValue = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            badge.isHidden = false
        case .file(let file, let section):
            checkbox.setAccessibilityIdentifier(item.id + "/checkbox")
            checkbox.setAccessibilityLabel((section == .staged ? GitL10n.text("Unstage ") : GitL10n.text("Stage ")) + file.path)
            checkbox.toolTip = item.pending ? GitL10n.text("Updating index…") : (section == .staged ? GitL10n.text("Unstage ") : GitL10n.text("Stage ")) + file.path
            checkbox.isHidden = item.pending
            if item.pending {
                progress.isHidden = false
                progress.setAccessibilityLabel(GitL10n.text("Updating index for ") + file.path)
                progress.setAnimating(true)
            }
            status.stringValue = file.isUntracked ? "?" : String(file.status.prefix(1))
            status.textColor = colors.status(file)
            status.isHidden = false
        case .branch(let branch, let paths):
            setIcon(branch.isCurrent ? "checkmark.circle" : branch.isRemote ? "network" : "arrow.triangle.branch")
            if branch.isCurrent { icon.contentTintColor = colors.accent }
            if !paths.isEmpty { badge.stringValue = "worktree"; badge.isHidden = false }
        case .worktree(let tree):
            setIcon(tree.isCurrent ? "checkmark.circle" : tree.lockedReason != nil ? "lock" : "folder")
            if tree.isCurrent { icon.contentTintColor = colors.accent }
            let states = [tree.branchRef == nil ? GitL10n.text("Detached") : nil, tree.isCurrent ? GitL10n.text("current") : nil, tree.isDirty == true ? GitL10n.text("dirty") : nil]
            badge.stringValue = states.compactMap { $0 }.joined(separator: " · ")
            badge.isHidden = badge.stringValue.isEmpty
        case .scope:
            setIcon("clock.arrow.circlepath")
        case .notice(let error):
            name.textColor = error ? colors.deleted : colors.secondary
        }
        needsLayout = true
    }

    private func setIcon(_ symbol: String) {
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }
    @objc private func toggleFolder() { toggle() }

    override func layout() {
        super.layout()
        guard let row else { return }
        let x = InspectorTreeLayout.leading + CGFloat(row.depth) * InspectorTreeLayout.indent
        var textX = x
        let center = subtitle.isHidden ? bounds.height / 2 : 12
        let categoryActionWidth: CGFloat = row.item.isCategory && row.item.stageBatch != nil ? 28 : 0
        if row.item.isCategory {
            checkbox.frame = .init(x: bounds.width - 32, y: center - 12, width: 22, height: 24)
            progress.frame = .init(x: bounds.width - 27, y: center - 6, width: 12, height: 12)
        } else if row.item.isFolder {
            disclosure.frame = .init(x: x - 5, y: 0, width: 18, height: bounds.height)
            let hasCheckbox = row.item.stageBatch != nil
            checkbox.frame = .init(x: x + 14, y: center - 12, width: 22, height: 24)
            progress.frame = .init(x: x + 18, y: center - 6, width: 12, height: 12)
            let iconX = x + (hasCheckbox ? 38 : 18)
            icon.frame = .init(x: iconX, y: center - 7, width: 14, height: 14)
            textX = iconX + 19
        } else if !checkbox.isHidden || !progress.isHidden || !status.isHidden {
            let alignedX = x + (row.isTree ? InspectorTreeLayout.disclosureWidth : 0)
            checkbox.frame = .init(x: alignedX - 4, y: center - 12, width: 22, height: 24)
            progress.frame = .init(x: alignedX + 1, y: center - 6, width: 12, height: 12)
            status.frame = .init(x: alignedX + 20, y: center - 6, width: 11, height: 13)
            textX = alignedX + (status.isHidden ? 24 : 37)
        } else if !icon.isHidden {
            let iconX = x + (row.isTree ? InspectorTreeLayout.disclosureWidth : 0)
            disclosure.frame = .init(x: x - 3, y: center - 7, width: 14, height: 14)
            icon.frame = .init(x: iconX, y: center - 7, width: 14, height: 14)
            textX = iconX + 19
        }
        let badgeWidth = badge.isHidden ? 0 : min(100, ceil(badge.intrinsicContentSize.width) + 5)
        badge.frame = .init(x: max(textX, bounds.width - badgeWidth - 10 - categoryActionWidth), y: center - 7, width: badgeWidth, height: 14)
        let textWidth = max(1, bounds.width - textX - 10 - badgeWidth - categoryActionWidth)
        if !subtitle.isHidden {
            name.frame = .init(x: textX, y: 4, width: textWidth, height: 15)
            subtitle.frame = .init(x: textX, y: 21, width: max(1, bounds.width - textX - 10), height: 13)
        } else {
            name.frame = .init(x: textX, y: center - 7, width: textWidth, height: 15)
        }
        rule.frame = .init(x: 10, y: bounds.height - 1, width: max(0, bounds.width - 20), height: 0.5)
    }
}
