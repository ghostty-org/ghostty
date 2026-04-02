import AppKit
import Combine

/// Horizontal tab bar for the browser panel's internal tabs.
/// Hidden when only one tab exists. Shows tab titles with close buttons.
@MainActor
final class BrowserTabBar: NSView {
    // MARK: - Properties

    weak var tabManager: BrowserTabManager? {
        didSet { subscribeToManager() }
    }

    private var tabButtons: [UUID: NSButton] = [:]
    private var closeButtons: [UUID: NSButton] = [:]
    private var hoverTrackingAreas: [UUID: NSTrackingArea] = [:]
    private let stackView = NSStackView()
    private let addTabButton = NSButton()
    private var cancellables = Set<AnyCancellable>()

    /// Tab bar height.
    private static let barHeight: CGFloat = 24
    /// Maximum width for each tab.
    private static let maxTabWidth: CGFloat = 120

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.barHeight)
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true

        // Stack view for tab buttons
        stackView.orientation = .horizontal
        stackView.spacing = 1
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        // Add-tab button
        configureAddButton()
        stackView.addArrangedSubview(addTabButton)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Height constraint
        let heightConstraint = heightAnchor.constraint(equalToConstant: Self.barHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true
    }

    private func configureAddButton() {
        addTabButton.bezelStyle = .inline
        addTabButton.isBordered = false
        addTabButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New tab"
        )
        addTabButton.imageScaling = .scaleProportionallyDown
        addTabButton.target = self
        addTabButton.action = #selector(addTabClicked)
        addTabButton.setContentHuggingPriority(.required, for: .horizontal)

        let widthConstraint = addTabButton.widthAnchor.constraint(equalToConstant: 20)
        widthConstraint.isActive = true
    }

    // MARK: - Manager Subscription

    private func subscribeToManager() {
        cancellables.removeAll()

        guard let manager = tabManager else {
            rebuildTabs(tabs: [], activeId: nil)
            return
        }

        // Both BrowserTabBar and BrowserTabManager are @MainActor, so the
        // publishers already fire on the main actor — no .receive(on:) needed.
        // (Using RunLoop.main here caused a crash in debug builds due to a
        // Combine/@MainActor isolation conflict.)
        manager.$tabs
            .combineLatest(manager.$activeTabId)
            .sink { [weak self] tabs, activeId in
                self?.rebuildTabs(tabs: tabs, activeId: activeId)
            }
            .store(in: &cancellables)
    }

    // MARK: - Rebuild

    private func rebuildTabs(tabs: [BrowserTabManager.Tab], activeId: UUID?) {
        // Remove existing tab buttons (keep the add button)
        for (_, button) in tabButtons {
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        for (_, button) in closeButtons {
            button.removeFromSuperview()
        }
        tabButtons.removeAll()
        closeButtons.removeAll()

        // Remove old tracking areas
        for (_, area) in hoverTrackingAreas {
            removeTrackingArea(area)
        }
        hoverTrackingAreas.removeAll()

        // Create a button for each tab
        for (i, tab) in tabs.enumerated() {
            let button = makeTabButton(tab: tab, isActive: tab.id == activeId)
            tabButtons[tab.id] = button

            let closeBtn = makeCloseButton(tabId: tab.id)
            closeButtons[tab.id] = closeBtn

            // Insert before the add button
            stackView.insertArrangedSubview(button, at: i)

            // Add close button as subview of the tab button
            button.addSubview(closeBtn)
            closeBtn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                closeBtn.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                closeBtn.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                closeBtn.widthAnchor.constraint(equalToConstant: 12),
                closeBtn.heightAnchor.constraint(equalToConstant: 12),
            ])

            // Close button hidden by default, shown on hover
            closeBtn.isHidden = true
        }

        // Visibility: hidden when 0 or 1 tab
        alphaValue = tabs.count > 1 ? 1 : 0
    }

    // MARK: - Tab Button Factory

    private func makeTabButton(tab: BrowserTabManager.Tab, isActive: Bool) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.title = tab.title
        button.font = NSFont.systemFont(ofSize: 11)
        button.alignment = .left
        button.tag = tab.id.hashValue
        button.target = self
        button.action = #selector(tabClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)

        // Width constraint
        let widthConstraint = button.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxTabWidth)
        widthConstraint.isActive = true

        // Active tab highlight
        if isActive {
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            button.layer?.cornerRadius = 4
        }

        // Tracking area for hover (to show/hide close button)
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: ["tabId": tab.id.uuidString]
        )
        button.addTrackingArea(trackingArea)
        hoverTrackingAreas[tab.id] = trackingArea

        return button
    }

    private func makeCloseButton(tabId: UUID) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close tab"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        )
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(closeTabClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier("close-\(tabId.uuidString)")
        return button
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let idString = userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: idString)
        else { return }
        closeButtons[tabId]?.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        guard let userInfo = event.trackingArea?.userInfo,
              let idString = userInfo["tabId"] as? String,
              let tabId = UUID(uuidString: idString)
        else { return }
        closeButtons[tabId]?.isHidden = true
    }

    // MARK: - Actions

    @objc private func tabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              let tabId = UUID(uuidString: idString)
        else { return }
        tabManager?.switchTab(id: tabId)
    }

    @objc private func closeTabClicked(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue,
              idString.hasPrefix("close-")
        else { return }
        let uuidString = String(idString.dropFirst("close-".count))
        guard let tabId = UUID(uuidString: uuidString) else { return }
        tabManager?.closeTab(id: tabId)
    }

    @objc private func addTabClicked() {
        tabManager?.createTab()
    }

}
