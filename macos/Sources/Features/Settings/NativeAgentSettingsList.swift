import AppKit
import Combine

@MainActor
final class NativeAgentSettingsList: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let target: String
    private let manager: AgentIntegrationManager
    private let strings: SettingsStrings
    private let includeUnavailable: Bool
    private let table = NSTableView()
    private var items: [SupportedAgent] = []
    private var subscription: AnyCancellable?
    var onSelect: ((SupportedAgent) -> Void)?
    var onCountChange: ((Int) -> Void)?
    var displayedCount: Int { items.count }

    init(target: String, manager: AgentIntegrationManager, strings: SettingsStrings, includeUnavailable: Bool = false) {
        self.target = target
        self.manager = manager
        self.strings = strings
        self.includeUnavailable = includeUnavailable
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 48
        table.addTableColumn(NSTableColumn(identifier: .init("agent")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(openSelected)
        table.doubleAction = #selector(openSelected)
        table.setAccessibilityIdentifier("settings.agents." + target)
        scroll.documentView = table
        view = scroll
        reload()
        subscription = manager.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.reload() }
    }

    private func reload() {
        let selected = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
        let snapshot = manager.snapshot(for: target) ?? .init()
        items = SupportedAgent.allCases.filter {
            includeUnavailable || snapshot.cli[$0]?.path != nil || snapshot.hooks[$0]?.isInstalled == true
        }
        table.reloadData()
        onCountChange?(items.count)
        if let selected, let index = items.firstIndex(of: selected) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { max(1, items.count) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { items.indices.contains(row) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else {
            return NSTextField(labelWithString: strings.t("No Agents found. Select Check to discover them.", "尚未发现 Agent。请选择“检查”。"))
        }
        let agent = items[row]
        let snapshot = manager.snapshot(for: target) ?? .init()
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(named: agent.assetName) ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let title = NSTextField(labelWithString: agent.displayName)
        let detail = NSTextField(labelWithString: snapshot.cli[agent]?.version ??
            (snapshot.cli[agent]?.path == nil ? strings.t("Not installed", "未安装") : strings.t("Available", "可用")))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        labels.addArrangedSubview(title)
        labels.addArrangedSubview(detail)
        let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        let stack = NSStackView(views: [image, labels, arrow])
        stack.distribution = .fill
        stack.spacing = 12
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 24), image.heightAnchor.constraint(equalToConstant: 24),
            arrow.widthAnchor.constraint(equalToConstant: 12),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
    @objc private func openSelected() {
        guard items.indices.contains(table.selectedRow) else { return }
        onSelect?(items[table.selectedRow])
    }
}
