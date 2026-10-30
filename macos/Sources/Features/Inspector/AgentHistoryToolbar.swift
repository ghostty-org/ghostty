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
    private let searchField = NSSearchField()
    private let progress = NSProgressIndicator()
    private let filterButton = NSButton()
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
        view = row
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = popoverDelegate
        popover.contentViewController = filterController
        filterController.onChange = { [weak self] filter in
            self?.snapshot?.filterChanged(filter)
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
        if next.isSearching { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let active = !next.filter.isDefault
        filterButton.image = NSImage(
            systemSymbolName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
            accessibilityDescription: next.strings.organize
        )
        filterButton.contentTintColor = active ? .controlAccentColor : nil
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
            popover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .maxY)
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if popover.isShown { popover.performClose(nil) }
    }

}

private final class AgentHistoryPopoverDelegate: NSObject, NSPopoverDelegate {
    weak var parentWindow: NSWindow?
    weak var previousResponder: NSView?

    func popoverDidClose(_ notification: Notification) {
        guard notification.object is NSPopover else { return }
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
    private let stack = NSStackView()
    private let directoryHint = NSTextField(labelWithString: "")
    private var controls: [AgentHistoryFilterField: NSPopUpButton] = [:]
    private var resetButton = NSButton()
    private var filter = AgentHistoryFilterState()
    private var strings = AgentHistoryStrings.current
    private var currentDirectory: String?
    var onChange: ((AgentHistoryFilterState) -> Void)?

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for field in AgentHistoryFilterField.allCases {
            let title = NSTextField(labelWithString: "")
            title.font = .systemFont(ofSize: 11, weight: .semibold)
            title.textColor = .secondaryLabelColor
            let control = NSPopUpButton(frame: .zero, pullsDown: false)
            control.target = self
            control.action = #selector(selectionChanged(_:))
            control.tag = field.rawValue
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 288).isActive = true
            let line = NSStackView(views: [title, control])
            line.orientation = .vertical
            line.alignment = .leading
            line.spacing = 3
            stack.addArrangedSubview(line)
            title.identifier = NSUserInterfaceItemIdentifier("label.\(field.rawValue)")
            controls[field] = control
            control.menu?.autoenablesItems = false
            if field == .directory {
                directoryHint.font = .systemFont(ofSize: 10)
                directoryHint.textColor = .secondaryLabelColor
                directoryHint.lineBreakMode = .byTruncatingMiddle
                directoryHint.isHidden = true
                stack.addArrangedSubview(directoryHint)
            }
        }
        resetButton = NSButton(title: "", target: self, action: #selector(reset))
        resetButton.bezelStyle = .rounded
        stack.addArrangedSubview(resetButton)
        view = stack
    }

    func update(sessions: [AgentHistorySession], agents: [SupportedAgent],
                filter: AgentHistoryFilterState, strings: AgentHistoryStrings,
                currentDirectory: String?) {
        _ = view
        self.filter = filter
        self.strings = strings
        self.currentDirectory = currentDirectory
        let scope = sessions
        set(.agent, label: strings.filterSection, options: [
            ("", "\(strings.allAgents) (\(scope.count))")
        ] + agents.map { agent in
            (agent.rawValue, "\(agent.displayName) (\(scope.count { $0.agent == agent }))")
        }, selected: filter.agent?.rawValue ?? "")
        set(.directory, label: strings.directorySection, options: [
            ("any", strings.anyOption), ("currentTree", strings.directoryCurrent)
        ], selected: filter.directory.rawValue)
        set(.time, label: strings.timeSection, options: AgentHistoryTimeFilter.allCases.map {
            ($0.rawValue, timeTitle($0))
        }, selected: filter.time.rawValue)
        set(.grouping, label: strings.groupSection, options: AgentHistoryGroupingMode.allCases.map {
            ($0.rawValue, groupingTitle($0))
        }, selected: filter.grouping.rawValue)
        set(.ordering, label: strings.orderSection, options: AgentHistoryOrderingMode.allCases.map {
            ($0.rawValue, orderingTitle($0))
        }, selected: filter.ordering.rawValue)
        controls[.directory]?.menu?.autoenablesItems = false
        controls[.directory]?.item(at: 1)?.isEnabled = AgentHistoryFilterState.normalizedPath(currentDirectory) != nil
        directoryHint.stringValue = AgentHistoryFilterState.normalizedPath(currentDirectory)
            .map { $0 == "/" ? "/" : WorkspacePathPresentation.folderName($0) }
            ?? strings.directoryUnavailable
        directoryHint.toolTip = currentDirectory
        directoryHint.isHidden = filter.directory != .currentTree
        resetButton.title = strings.reset
        resetButton.isEnabled = !filter.isDefault
        stack.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 320, height: max(320, stack.fittingSize.height))
    }

    var filterControlsForTesting: [AgentHistoryFilterField: NSPopUpButton] { controls }
    var resetControlForTesting: NSButton { resetButton }
    var directoryHintForTesting: NSTextField { directoryHint }

    private func set(_ field: AgentHistoryFilterField, label: String,
                     options: [(String, String)], selected: String) {
        guard let control = controls[field], let line = control.superview as? NSStackView,
              let title = line.arrangedSubviews.first as? NSTextField else { return }
        title.stringValue = label
        control.removeAllItems()
        for (key, value) in options {
            control.addItem(withTitle: value)
            control.lastItem?.representedObject = key
        }
        if let index = control.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            control.selectItem(at: index)
        }
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        guard let field = AgentHistoryFilterField(rawValue: sender.tag),
              let value = sender.selectedItem?.representedObject as? String else { return }
        apply(value, to: field)
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
}

enum AgentHistoryFilterField: Int, CaseIterable {
    case agent, directory, time, grouping, ordering
}
