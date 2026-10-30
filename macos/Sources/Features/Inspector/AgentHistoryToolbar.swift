import AppKit
import SwiftUI

struct AgentHistoryToolbar: NSViewControllerRepresentable {
    let query: String
    let isSearching: Bool
    let filter: AgentHistoryFilterState
    let sessions: [AgentHistorySession]
    let agents: [SupportedAgent]
    let strings: AgentHistoryStrings
    let currentDirectory: String?
    let searchChanged: (String) -> Void
    let filterChanged: (AgentHistoryFilterState) -> Void

    func makeNSViewController(context: Context) -> AgentHistoryToolbarController {
        AgentHistoryToolbarController()
    }

    func updateNSViewController(_ controller: AgentHistoryToolbarController, context: Context) {
        controller.update(self)
    }
}

@MainActor
final class AgentHistoryToolbarController: NSViewController, NSSearchFieldDelegate {
    private let searchField = OMGNativeSearchField()
    private let progress = NSProgressIndicator()
    private let filterButton = NativeActionControl()
    private let row = NSStackView()
    private let popover = NSPopover()
    private let popoverDelegate = AgentHistoryPopoverDelegate()
    private let filterController = AgentHistoryFilterController()
    private var snapshot: AgentHistoryToolbar?
    var searchFieldForTesting: NSSearchField { searchField }
    var filterButtonForTesting: NSButton { filterButton }
    var popoverForTesting: NSPopover { popover }

    override func loadView() {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        searchField.placeholderString = AgentHistoryStrings.current.searchPlaceholder
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        filterButton.bezelStyle = .rounded
        filterButton.setButtonType(.momentaryPushIn)
        filterButton.target = self
        filterButton.action = #selector(togglePopover)
        row.addArrangedSubview(searchField)
        row.addArrangedSubview(progress)
        row.addArrangedSubview(filterButton)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            searchField.heightAnchor.constraint(equalToConstant: 28),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14),
            filterButton.widthAnchor.constraint(equalToConstant: 30),
            filterButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        let surface = OMGNativeSurfaceView()
        row.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            row.topAnchor.constraint(equalTo: surface.topAnchor),
            row.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
        ])
        view = surface
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = popoverDelegate
        popoverDelegate.onClose = { [weak self] in self?.filterButton.setPresentationActive(false) }
        popover.contentViewController = filterController
        filterController.onChange = { [weak self] filter in
            self?.snapshot?.filterChanged(filter)
        }
        filterController.onPreferredContentSizeChange = { [weak self] size in
            guard let self, self.popover.isShown, self.popover.contentSize != size else { return }
            self.popover.contentSize = size
        }
    }

    func update(_ next: AgentHistoryToolbar) {
        _ = view
        snapshot = next
        searchField.placeholderString = next.strings.searchPlaceholder
        searchField.sendsSearchStringImmediately = true
        if searchField.stringValue != next.query, !hasMarkedText {
            searchField.stringValue = next.query
        }
        progress.isHidden = !next.isSearching
        if next.isSearching { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let active = !next.filter.isDefault
        filterButton.configure(title: "", symbol: "line.3.horizontal.decrease",
                               help: next.strings.organize, enabled: true, style: active ? .bordered : .plain,
                               identifier: "history.filter")
        filterButton.toolTip = next.strings.organize
        filterButton.setAccessibilityLabel(next.strings.organize)
        filterButton.setAccessibilityValue(active ? next.strings.filterActive : "")
        filterController.update(sessions: next.sessions, agents: next.agents,
                                filter: next.filter, strings: next.strings,
                                currentDirectory: next.currentDirectory)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        snapshot?.searchChanged(sender.stringValue)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        snapshot?.searchChanged(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !hasMarkedText, let snapshot, searchField.stringValue != snapshot.query else { return }
        searchField.stringValue = snapshot.query
    }

    private var hasMarkedText: Bool {
        (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true
    }

    @objc func togglePopover() {
        guard let snapshot else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popoverDelegate.parentWindow = view.window
            popoverDelegate.previousResponder = view.window?.firstResponder as? NSView
            filterController.update(sessions: snapshot.sessions, agents: snapshot.agents,
                                    filter: snapshot.filter, strings: snapshot.strings,
                                    currentDirectory: snapshot.currentDirectory)
            let window = view.window
            filterController.bindTheme(to: window)
            popover.contentSize = filterController.preferredContentSize
            popover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .maxY)
            filterButton.setPresentationActive(popover.isShown)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if popover.isShown { popover.performClose(nil) }
    }

}

private final class AgentHistoryPopoverDelegate: NSObject, NSPopoverDelegate {
    var onClose: (() -> Void)?
    weak var parentWindow: NSWindow?
    weak var previousResponder: NSView?

    func popoverDidClose(_ notification: Notification) {
        guard notification.object is NSPopover else { return }
        onClose?()
        if let window = parentWindow, let previousResponder,
           previousResponder.window === window {
            window.makeFirstResponder(previousResponder)
        }
        self.previousResponder = nil
        self.parentWindow = nil
    }
}

@MainActor
final class AgentHistoryFilterController: NSViewController {
    private let root = OMGNativeSurfaceView()
    private let stack = NSStackView()
    private let agentScroll = NSScrollView()
    private let agentRows = AgentHistoryFilterAgentRows()
    private let allAgentsButton = AgentHistoryFilterOptionButton()
    private let directoryChips = NSStackView()
    private let timeChips = NSStackView()
    private var groupingGrid = NSGridView()
    private let resetButton = NativeActionControl()
    private let directoryHint = NSTextField(labelWithString: "")
    private var directoryButtons: [String: AgentHistoryFilterOptionButton] = [:]
    private var timeButtons: [String: AgentHistoryFilterOptionButton] = [:]
    private var groupingButtons: [String: AgentHistoryFilterOptionButton] = [:]
    private var orderingButtons: [String: AgentHistoryFilterOptionButton] = [:]
    private var agentButtons: [String: AgentHistoryFilterOptionButton] = [:]
    private var sectionLabels: [AgentHistoryFilterField: NSTextField] = [:]
    private var agentCounts: [AgentHistoryAgentCount] = []
    private var agentScrollHeight: NSLayoutConstraint?
    private var filter = AgentHistoryFilterState()
    private var strings = AgentHistoryStrings.current
    private var currentDirectory: String?
    var onChange: ((AgentHistoryFilterState) -> Void)?
    var onPreferredContentSizeChange: ((NSSize) -> Void)?

    func configurePopoverAppearance(_ appearance: NSAppearance, background: NSColor) {
        root.applyTheme(.init(background: background, foreground: background.isLightColor ? .black : .white))
    }

    func bindTheme(to window: NSWindow?) { root.bindTheme(to: window) }

    override func loadView() {
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 9, right: 10)

        let agentHeader = sectionLabel(AgentHistoryStrings.current.filterSection)
        allAgentsButton.target = self
        allAgentsButton.action = #selector(selectAgent(_:))
        allAgentsButton.identifier = NSUserInterfaceItemIdentifier("agent-history-filter.all")
        configureVertical(agentRows)
        agentRows.spacing = 0

        agentScroll.documentView = agentRows
        agentScroll.drawsBackground = false
        agentScroll.borderType = .noBorder
        agentScroll.hasVerticalScroller = true
        agentScroll.hasHorizontalScroller = false
        agentScroll.autohidesScrollers = true
        agentScroll.scrollerStyle = .overlay
        agentScroll.translatesAutoresizingMaskIntoConstraints = false
        agentScrollHeight = agentScroll.heightAnchor.constraint(equalToConstant: 0)
        agentScrollHeight?.isActive = true
        configureHorizontal(directoryChips)
        configureHorizontal(timeChips)
        directoryHint.font = .systemFont(ofSize: 10)
        directoryHint.textColor = .secondaryLabelColor
        directoryHint.lineBreakMode = .byTruncatingMiddle
        directoryHint.isHidden = true

        groupingGrid.xPlacement = .fill
        groupingGrid.yPlacement = .center
        groupingGrid.rowSpacing = 1
        groupingGrid.columnSpacing = 8
        resetButton.title = ""
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.isBordered = false
        resetButton.font = .systemFont(ofSize: 11)
        resetButton.imagePosition = .imageLeading
        resetButton.target = self
        resetButton.action = #selector(reset)
        resetButton.setAccessibilityIdentifier("agent-history-filter.reset")

        let directoryHeader = sectionLabel(AgentHistoryStrings.current.directorySection)
        let timeHeader = sectionLabel(AgentHistoryStrings.current.timeSection)
        let groupLabel = sectionLabel(AgentHistoryStrings.current.groupSection)
        let orderLabel = sectionLabel(AgentHistoryStrings.current.orderSection)
        let groupHeader = NSStackView(views: [groupLabel, orderLabel])
        groupHeader.orientation = .horizontal
        groupHeader.alignment = .centerY
        groupHeader.spacing = 8
        groupLabel.widthAnchor.constraint(equalToConstant: 146).isActive = true
        orderLabel.widthAnchor.constraint(equalToConstant: 146).isActive = true
        sectionLabels = [.agent: agentHeader, .directory: directoryHeader, .time: timeHeader,
                         .grouping: groupLabel, .ordering: orderLabel]

        rebuildStaticOptions()
        func separator() -> NSBox {
            let value = NSBox()
            value.boxType = .separator
            value.translatesAutoresizingMaskIntoConstraints = false
            value.widthAnchor.constraint(equalToConstant: 300).isActive = true
            return value
        }
        for view in [agentHeader, allAgentsButton, agentScroll, separator(),
                     directoryHeader, directoryChips, directoryHint, separator(),
                     timeHeader, timeChips, separator(), groupHeader, groupingGrid, resetButton] {
            stack.addArrangedSubview(view)
        }
        stack.setCustomSpacing(1, after: directoryChips)
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            directoryChips.widthAnchor.constraint(equalToConstant: 300),
            timeChips.widthAnchor.constraint(equalToConstant: 300),
            groupingGrid.widthAnchor.constraint(equalToConstant: 300),
            agentScroll.widthAnchor.constraint(equalToConstant: 300),
            allAgentsButton.widthAnchor.constraint(equalToConstant: 300),
        ])
        view = root
    }

    func update(sessions: [AgentHistorySession], agents: [SupportedAgent],
                filter: AgentHistoryFilterState, strings: AgentHistoryStrings,
                currentDirectory: String?) {
        _ = view
        self.filter = filter
        self.strings = strings
        self.currentDirectory = currentDirectory
        sectionLabels[.agent]?.stringValue = strings.filterSection
        sectionLabels[.directory]?.stringValue = strings.directorySection
        sectionLabels[.time]?.stringValue = strings.timeSection
        sectionLabels[.grouping]?.stringValue = strings.groupSection
        sectionLabels[.ordering]?.stringValue = strings.orderSection
        allAgentsButton.update(title: strings.allAgents,
                               symbol: "square.grid.2x2", selected: filter.agent == nil,
                               accessibilityValue: selectionValue(filter.agent == nil), count: sessions.count)
        let nextCounts = agents.map { agent in
            AgentHistoryAgentCount(agent: agent, count: sessions.count { $0.agent == agent })
        }
        if nextCounts != agentCounts {
            agentCounts = nextCounts
            agentRows.arrangedSubviews.forEach { agentRows.removeArrangedSubview($0); $0.removeFromSuperview() }
            agentButtons.removeAll()
            for item in agentCounts {
                let row = AgentHistoryFilterOptionButton()
                row.identifier = NSUserInterfaceItemIdentifier("agent-history-filter.\(item.agent.rawValue)")
                row.target = self
                row.action = #selector(selectAgent(_:))
                row.cell?.representedObject = item.agent.rawValue
                agentRows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 300).isActive = true
                agentButtons[item.agent.rawValue] = row
            }
        }
        for item in agentCounts {
            agentButtons[item.agent.rawValue]?.update(
                title: item.agent.displayName,
                icon: item.agent.assetName,
                selected: filter.agent == item.agent,
                accessibilityValue: selectionValue(filter.agent == item.agent),
                count: item.count
            )
        }
        agentScroll.hasVerticalScroller = agentCounts.count > 6
        agentScrollHeight?.constant = CGFloat(min(agentCounts.count, 6)) * 24
        agentRows.frame = NSRect(x: 0, y: 0, width: 300,
                                 height: CGFloat(max(1, agentCounts.count)) * 24)
        agentScroll.layoutSubtreeIfNeeded()

        update(directoryButtons, values: AgentHistoryDirectoryFilter.allCases.map { ($0.rawValue, directoryTitle($0)) },
               selected: filter.directory.rawValue,
               enabledValues: AgentHistoryFilterState.normalizedPath(currentDirectory) == nil
                    ? [AgentHistoryDirectoryFilter.any.rawValue] : nil)
        update(timeButtons, values: AgentHistoryTimeFilter.allCases.map { ($0.rawValue, timeTitle($0)) },
               selected: filter.time.rawValue)
        update(groupingButtons, values: AgentHistoryGroupingMode.allCases.map { ($0.rawValue, groupingTitle($0)) },
               selected: filter.grouping.rawValue)
        update(orderingButtons, values: AgentHistoryOrderingMode.allCases.map { ($0.rawValue, orderingTitle($0)) },
               selected: filter.ordering.rawValue)
        directoryHint.stringValue = AgentHistoryFilterState.normalizedPath(currentDirectory)
            .map { $0 == "/" ? "/" : WorkspacePathPresentation.folderName($0) }
            ?? strings.directoryUnavailable
        directoryHint.toolTip = currentDirectory
        directoryHint.isHidden = true
        resetButton.configure(title: strings.reset, symbol: "arrow.counterclockwise", help: strings.reset,
                              enabled: !filter.isDefault, style: .plain, identifier: "agent-history-filter.reset")
        resetButton.setAccessibilityValue(filter.isDefault ? "" : strings.filterActive)
        agentRows.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: 320, height: ceil(stack.fittingSize.height))
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        onPreferredContentSizeChange?(size)
    }

    var filterControlsForTesting: [AgentHistoryFilterField: NSView] {
        [.agent: agentScroll, .directory: directoryChips, .time: timeChips,
         .grouping: groupingGrid, .ordering: groupingGrid]
    }
    var resetControlForTesting: NSButton { resetButton }
    var directoryHintForTesting: NSTextField { directoryHint }
    func agentButtonForTesting(_ agent: SupportedAgent) -> NSButton? { agentButtons[agent.rawValue] }
    func choiceButtonForTesting(_ field: AgentHistoryFilterField, _ value: String) -> NSButton? { button(field, value) }

    private func rebuildStaticOptions() {
        for item in AgentHistoryDirectoryFilter.allCases {
            directoryButtons[item.rawValue] = makeChip(field: .directory, value: item.rawValue)
            directoryChips.addArrangedSubview(directoryButtons[item.rawValue]!)
        }
        for item in AgentHistoryTimeFilter.allCases {
            timeButtons[item.rawValue] = makeChip(field: .time, value: item.rawValue)
            timeChips.addArrangedSubview(timeButtons[item.rawValue]!)
        }
        for item in AgentHistoryGroupingMode.allCases {
            groupingButtons[item.rawValue] = makeOption(field: .grouping, value: item.rawValue)
        }
        for item in AgentHistoryOrderingMode.allCases {
            orderingButtons[item.rawValue] = makeOption(field: .ordering, value: item.rawValue)
        }
        groupingGrid = NSGridView(views: [
            [groupingButtons[AgentHistoryGroupingMode.none.rawValue]!, orderingButtons[AgentHistoryOrderingMode.recentlyUpdated.rawValue]!],
            [groupingButtons[AgentHistoryGroupingMode.project.rawValue]!, orderingButtons[AgentHistoryOrderingMode.title.rawValue]!],
            [groupingButtons[AgentHistoryGroupingMode.agent.rawValue]!, NSView()],
            [groupingButtons[AgentHistoryGroupingMode.date.rawValue]!, NSView()],
        ])
        groupingGrid.columnSpacing = 8
        groupingGrid.rowSpacing = 1
        groupingGrid.xPlacement = .fill
        groupingGrid.yPlacement = .center
        for index in 0..<groupingGrid.numberOfColumns { groupingGrid.column(at: index).width = 146 }
    }

    private func update(_ buttons: [String: AgentHistoryFilterOptionButton],
                        values: [(String, String)], selected: String, enabledValues: [String]? = nil) {
        for (key, title) in values {
            buttons[key]?.update(title: title, selected: key == selected,
                                 accessibilityValue: selectionValue(key == selected),
                                 enabled: enabledValues == nil || enabledValues!.contains(key), count: nil)
        }
    }

    private func makeChip(field: AgentHistoryFilterField, value: String) -> AgentHistoryFilterOptionButton {
        let result = AgentHistoryFilterOptionButton(compact: true)
        result.target = self
        result.action = #selector(selectOption(_:))
        result.cell?.representedObject = AgentHistoryFilterSelection(field, value)
        return result
    }

    private func makeOption(field: AgentHistoryFilterField, value: String) -> AgentHistoryFilterOptionButton {
        let result = AgentHistoryFilterOptionButton()
        result.font = .systemFont(ofSize: 11)
        switch field {
        case .grouping:
            result.optionSymbol = ["none": "list.bullet", "project": "folder",
                                   "agent": "person.2", "date": "calendar"][value]
        case .ordering:
            result.optionSymbol = value == AgentHistoryOrderingMode.title.rawValue ? "textformat" : "clock"
        default: break
        }
        result.target = self
        result.action = #selector(selectOption(_:))
        result.cell?.representedObject = AgentHistoryFilterSelection(field, value)
        return result
    }

    private func button(_ field: AgentHistoryFilterField, _ value: String) -> NSButton? {
        switch field {
        case .agent: value.isEmpty ? allAgentsButton : agentButtons[value]
        case .directory: directoryButtons[value]
        case .time: timeButtons[value]
        case .grouping: groupingButtons[value]
        case .ordering: orderingButtons[value]
        }
    }

    @objc private func selectAgent(_ sender: NSButton) {
        if let rawValue = sender.cell?.representedObject as? String {
            apply(rawValue, to: .agent)
        } else {
            apply("", to: .agent)
        }
    }

    @objc private func selectOption(_ sender: NSButton) {
        guard let selection = sender.cell?.representedObject as? AgentHistoryFilterSelection else { return }
        apply(selection.value, to: selection.field)
    }

    func apply(_ value: String, to field: AgentHistoryFilterField) {
        switch field {
        case .agent: filter.agent = value.isEmpty ? nil : SupportedAgent(rawValue: value)
        case .directory:
            if let next = AgentHistoryDirectoryFilter(rawValue: value) { filter.directory = next }
        case .time:
            if let next = AgentHistoryTimeFilter(rawValue: value) { filter.time = next }
        case .grouping:
            if let next = AgentHistoryGroupingMode(rawValue: value) { filter.grouping = next }
        case .ordering:
            if let next = AgentHistoryOrderingMode(rawValue: value) { filter.ordering = next }
        }
        onChange?(filter)
    }

    @objc private func reset() {
        filter.reset()
        onChange?(filter)
    }

    private func selectionValue(_ isSelected: Bool) -> String { isSelected ? strings.filterActive : "" }
    private func directoryTitle(_ value: AgentHistoryDirectoryFilter) -> String {
        switch value {
        case .any: strings.anyOption
        case .currentTree: strings.directoryCurrent
        }
    }
    private func timeTitle(_ value: AgentHistoryTimeFilter) -> String {
        switch value {
        case .any: strings.anyOption
        case .day: strings.timeDay
        case .week: strings.timeWeek
        case .month: strings.timeMonth
        case .quarter: strings.timeQuarter
        case .year: strings.timeYear
        }
    }
    private func groupingTitle(_ value: AgentHistoryGroupingMode) -> String {
        switch value {
        case .none: strings.groupNone
        case .project: strings.groupProject
        case .agent: strings.groupAgent
        case .date: strings.groupDate
        }
    }
    private func orderingTitle(_ value: AgentHistoryOrderingMode) -> String {
        switch value {
        case .recentlyUpdated: strings.orderRecentlyUpdated
        case .title: strings.orderTitle
        }
    }
    private func sectionLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }
    private func configureHorizontal(_ row: NSStackView) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    private func configureVertical(_ column: NSStackView) {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
    }
}

private struct AgentHistoryAgentCount: Equatable {
    let agent: SupportedAgent
    let count: Int
}

private final class AgentHistoryFilterSelection: NSObject {
    let field: AgentHistoryFilterField
    let value: String
    init(_ field: AgentHistoryFilterField, _ value: String) {
        self.field = field
        self.value = value
    }
}

private final class AgentHistoryFilterAgentRows: NSStackView {
    override var isFlipped: Bool { true }
}

private final class AgentHistoryFilterOptionButton: NSButton {
    private let checkIcon = NSImageView()
    private let leadingIcon = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private var compact: Bool
    private var selectedOption = false
    private var trailingCount: Int?
    private var hovered = false
    var optionSymbol: String?

    override var isFlipped: Bool { true }

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        buildContent()
    }

    override init(frame frameRect: NSRect) {
        compact = false
        super.init(frame: frameRect)
        buildContent()
    }

    private func buildContent() {
        setButtonType(.toggle)
        isBordered = false
        controlSize = .small
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = compact ? 0 : 5
        row.translatesAutoresizingMaskIntoConstraints = false
        checkIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkIcon.imageScaling = .scaleProportionallyUpOrDown
        checkIcon.contentTintColor = .controlAccentColor
        leadingIcon.imageScaling = .scaleProportionallyUpOrDown
        leadingIcon.contentTintColor = .labelColor
        font = .systemFont(ofSize: compact ? 10.5 : 11.5)
        titleField.font = font
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countField.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        countField.textColor = .secondaryLabelColor
        countField.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(checkIcon)
        row.addArrangedSubview(leadingIcon)
        row.addArrangedSubview(titleField)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(countField)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: compact ? 22 : 24),
            checkIcon.widthAnchor.constraint(equalToConstant: 10),
            checkIcon.heightAnchor.constraint(equalToConstant: 10),
            leadingIcon.widthAnchor.constraint(equalToConstant: 14),
            leadingIcon.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if compact {
            checkIcon.isHidden = true
            leadingIcon.isHidden = true
        }
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override var wantsUpdateLayer: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(title: String, symbol: String? = nil, icon: String? = nil,
                selected: Bool, accessibilityValue: String,
                enabled: Bool = true, count: Int?) {
        titleField.stringValue = title
        titleField.font = font
        checkIcon.isHidden = compact
        checkIcon.alphaValue = selected ? 1 : 0
        if let icon {
            leadingIcon.image = NSImage(named: icon)
            leadingIcon.contentTintColor = leadingIcon.image?.isTemplate == true ? .labelColor : nil
        } else if let symbol = symbol ?? optionSymbol {
            leadingIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            leadingIcon.contentTintColor = .secondaryLabelColor
        } else {
            leadingIcon.image = nil
        }
        countField.stringValue = count.map(String.init) ?? ""
        countField.isHidden = count == nil
        trailingCount = count
        selectedOption = selected
        state = selected ? .on : .off
        isEnabled = enabled
        titleField.textColor = enabled ? .labelColor : .tertiaryLabelColor
        setAccessibilityLabel(title + (count.map { ", \($0)" } ?? ""))
        setAccessibilityValue(accessibilityValue)
        setAccessibilityIdentifier(identifier?.rawValue)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func updateLayer() {
        let theme = OMGNativeTheme.resolve(for: self)
        let color = selectedOption
            ? theme.selectedFill
            : (hovered || isHighlighted) && isEnabled ? theme.hoverFill : .clear
        layer?.backgroundColor = color.cgColor
        titleField.textColor = isEnabled ? theme.foreground : theme.disabled
        countField.textColor = theme.secondary
        checkIcon.contentTintColor = theme.accent
        leadingIcon.contentTintColor = leadingIcon.image?.isTemplate == true ? theme.foreground : nil
        layer?.cornerRadius = compact ? 5 : 5
    }
}

enum AgentHistoryFilterField: Int, CaseIterable {
    case agent, directory, time, grouping, ordering
}
