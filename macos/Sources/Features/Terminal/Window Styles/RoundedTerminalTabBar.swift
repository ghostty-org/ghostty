import AppKit
import Combine
import GhosttyKit

/// Presents native AppKit tab groups without taking ownership of terminal sessions.
/// Window references are weak so a closed tab cannot be retained by its own chrome.
/// The settings preview subclasses this with sample tabs (`PreviewTabModel`).
@MainActor
class RoundedTerminalTabModel: ObservableObject {
    struct Tab: Identifiable {
        let id: ObjectIdentifier
        let window: Weak<NSWindow>
        let title: String
        let color: TerminalTabColor
        let selected: Bool
        /// Random color slot (index into `TabBarSettings.randomPaletteIndices`).
        var autoColor: Int?
    }

    /// Picks a random color slot that differs from the given neighbours.
    static func randomColorSlot(avoiding neighbours: [Int?]) -> Int {
        let count = TabBarSettings.randomPaletteIndices.count
        let taken = Set(neighbours.compactMap { $0 })
        let choices = (0..<count).filter { !taken.contains($0) }
        return (choices.isEmpty ? Array(0..<count) : choices).randomElement() ?? 0
    }

    /// Gives every tab in every Ghostty X tab group a new random color.
    static func shuffleAllColors() {
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows.compactMap({ $0 as? TerminalWindow }) {
            let windows = window.tabGroup?.windows ?? [window]
            guard let first = windows.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            var previous: Int?
            for case let tab as TerminalWindow in windows {
                tab.autoTabColorSlot = randomColorSlot(avoiding: [previous])
                previous = tab.autoTabColorSlot
            }
        }
        NotificationCenter.default.post(name: .ghosttyXTabColorsDidShuffle, object: nil)
    }

    @Published var tabs: [Tab] = []
    weak var hostWindow: TerminalWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var refreshScheduled = false

    init(hostWindow: TerminalWindow?) {
        self.hostWindow = hostWindow
    }

    func refresh() {
        guard let hostWindow else { tabs = []; return }
        let group = hostWindow.tabGroup
        if observedGroup !== group {
            observedGroup = group
            groupObservations = []
            if let group {
                groupObservations = [
                    group.observe(\.windows) { [weak self] _, _ in self?.scheduleRefresh() },
                    group.observe(\.selectedWindow) { [weak self] _, _ in self?.scheduleRefresh() },
                ]
            }
        }
        let windows = group?.windows ?? [hostWindow]
        let ids = windows.map(ObjectIdentifier.init)
        if ids != tabs.map(\.id) {
            titleObservations = windows.map { window in
                window.observe(\.title) { [weak self] _, _ in self?.scheduleRefresh() }
            }
        }
        // New tabs pick a color unlike the tabs on either side of them.
        let terminals = windows.map { $0 as? TerminalWindow }
        for (index, terminal) in terminals.enumerated() where terminal?.autoTabColorSlot == nil {
            let before = index > 0 ? terminals[index - 1]?.autoTabColorSlot : nil
            let after = index + 1 < terminals.count ? terminals[index + 1]?.autoTabColorSlot : nil
            terminal?.autoTabColorSlot = Self.randomColorSlot(avoiding: [before, after])
        }
        tabs = windows.map { window in
            Tab(id: ObjectIdentifier(window), window: Weak(window),
                title: window.title.isEmpty ? "Terminal" : window.title,
                color: (window as? TerminalWindow)?.tabColor ?? .none,
                selected: window === (group?.selectedWindow ?? hostWindow),
                autoColor: (window as? TerminalWindow)?.autoTabColorSlot)
        }
    }

    nonisolated func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            // Rebind observations after the KVO callback has returned.
            DispatchQueue.main.async { [weak self] in
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func select(_ tab: Tab) {
        guard let window = tab.window.value else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        // Uses Ghostty's confirmation/undo path; never terminate a shell directly.
        (tab.window.value?.windowController as? TerminalController)?.closeTab(nil)
    }

    func move(_ tab: Tab, by offset: Int) {
        guard let window = tab.window.value,
              let group = window.tabGroup,
              let index = group.windows.firstIndex(of: window) else { return }
        let destination = min(max(index + offset, 0), group.windows.count - 1)
        guard destination != index else { return }
        group.insertWindow(window, at: destination)
        scheduleRefresh()
    }

    func reorder(_ identifiers: [String], before destination: Tab) -> Bool {
        guard let id = identifiers.first,
              let source = tabs.first(where: { String(describing: $0.id) == id }),
              let sourceWindow = source.window.value,
              let targetWindow = destination.window.value,
              let group = targetWindow.tabGroup,
              group.windows.contains(sourceWindow),
              let index = group.windows.firstIndex(of: targetWindow) else { return false }
        group.insertWindow(sourceWindow, at: index)
        scheduleRefresh()
        return true
    }

    func newTab() { hostWindow?.terminalController?.newTab(nil) }

    func rename(_ tab: Tab) {
        select(tab)
        (tab.window.value?.windowController as? TerminalController)?.promptTabTitle()
    }

    func detach(_ tab: Tab) { tab.window.value?.moveTabToNewWindow(nil) }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tab.window.value as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func shuffleColors() { Self.shuffleAllColors() }
}

extension Notification.Name {
    static let ghosttyXTabColorsDidShuffle = Notification.Name("com.amsynist.ghosttyx.tabColorsDidShuffle")
}

/// Colors for the tab strip, taken from the active Ghostty theme so the chrome matches
/// the terminal. The accent is a palette entry picked in the Tab Bar settings.
struct RoundedTabTheme: Equatable {
    var foreground: NSColor
    var background: NSColor
    /// `background-opacity`; edge bars paint the terminal background themselves.
    var backgroundOpacity: CGFloat = 1
    var palette: [NSColor]

    /// Tokyo Night values, used until a Ghostty config is available.
    static let fallback = RoundedTabTheme(
        foreground: NSColor(srgbRed: 0.753, green: 0.792, blue: 0.961, alpha: 1),
        background: NSColor(rgb: 0x1a1b26),
        palette: [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        ].map { NSColor(rgb: $0) })

    init(foreground: NSColor, background: NSColor, palette: [NSColor]) {
        self.foreground = foreground
        self.background = background
        self.palette = palette
    }

    init(config: Ghostty.Config) {
        let fallback = Self.fallback
        foreground = config.roundedTabColor("foreground") ?? fallback.foreground
        background = config.roundedTabColor("background") ?? fallback.background
        backgroundOpacity = CGFloat(min(max(config.backgroundOpacity, 0), 1))
        let palette = config.roundedTabPalette ?? []
        self.palette = palette.count >= 16 ? palette : fallback.palette
    }

    static var current: RoundedTabTheme {
        guard let delegate = NSApp.delegate as? AppDelegate else { return fallback }
        return RoundedTabTheme(config: delegate.ghostty.config)
    }

    func accent(_ accent: TabBarSettings.Accent) -> NSColor {
        guard let index = accent.paletteIndex, palette.indices.contains(index) else { return foreground }
        return palette[index]
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

extension Ghostty.Config {
    fileprivate func roundedTabColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: 1)
    }

    fileprivate var roundedTabPalette: [NSColor]? {
        guard let config else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map {
                NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
            }
        }
    }
}

/// The capsule tab strip. One component serves every position:
/// - `.titlebar`: inside the native titlebar accessory, shown when the position is Top.
///   For other positions it becomes an empty, draggable placeholder that shields the
///   hidden native tab bar from clicks.
/// - `.edge`: beside the terminal content (bottom bar or left/right sidebar).
/// - `.preview`: the settings window's live preview; always follows the chosen position.
///
/// Native controls are important here: this view can live inside AppKit's titlebar
/// accessory, where hosting-view drag handling can consume SwiftUI button clicks.
@MainActor
final class RoundedTerminalTabBar: NSView {
    enum Placement { case titlebar, edge, preview }

    let model: RoundedTerminalTabModel
    let placement: Placement
    private let store: TabBarSettingsStore
    private let scroll = NSScrollView()
    private let document = FlippedTabDocument()
    private let addButton = TabAddButton()
    private let header = NSTextField(labelWithString: "")
    private let headerCount = NSTextField(labelWithString: "")
    private var cells: [ObjectIdentifier: RoundedTabCell] = [:]
    private var observations: [AnyCancellable] = []
    private(set) var displayedTabs: [RoundedTerminalTabModel.Tab] = []

    private(set) var settings: TabBarSettings
    var theme = RoundedTabTheme.current {
        didSet { if theme != oldValue { applyAppearance() } }
    }

    /// Called whenever the number of tabs changes (edge bars hide with a single tab).
    var onTabCountChange: ((Int) -> Void)?

    /// True when the strip should draw as a vertical sidebar.
    var isVertical: Bool { placement != .titlebar && settings.position.isVertical }

    /// In the titlebar while tabs live elsewhere: draw nothing, move the window on drag.
    var isPlaceholder: Bool { placement == .titlebar && settings.position != .top }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    convenience init(hostWindow: TerminalWindow, placement: Placement = .titlebar,
                     store: TabBarSettingsStore = .shared) {
        self.init(model: RoundedTerminalTabModel(hostWindow: hostWindow), placement: placement, store: store)
    }

    init(model: RoundedTerminalTabModel, placement: Placement, store: TabBarSettingsStore = .shared) {
        self.model = model
        self.placement = placement
        self.store = store
        self.settings = store.settings
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        addButton.target = self
        addButton.action = #selector(newTab)
        addButton.toolTip = "New tab"
        addButton.setAccessibilityLabel("New tab")
        addButton.menuProvider = { [weak self] in self?.barMenu() }
        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.isSelectable = false
        header.lineBreakMode = .byClipping
        addSubview(scroll)
        addSubview(header)
        headerCount.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        headerCount.alignment = .right
        headerCount.isSelectable = false
        addSubview(headerCount)
        addSubview(addButton)
        setAccessibilityElement(false)
        observations = [
            model.$tabs.sink { [weak self] tabs in self?.reconcile(tabs) },
            store.$settings.sink { [weak self] settings in self?.settingsDidChange(settings) },
        ]
        applyAppearance()
        // Follow config reloads (e.g. a theme change) without reopening the window.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange(_:)), name: .ghosttyConfigDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsDidShuffle), name: .ghosttyXTabColorsDidShuffle, object: nil)
    }

    @objc private func colorsDidShuffle() { model.refresh() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func configDidChange(_ notification: Notification) {
        // Only the global config carries the theme; surface-level changes don't.
        guard notification.object == nil else { return }
        theme = RoundedTabTheme.current
    }

    func refresh() {
        theme = RoundedTabTheme.current
        model.refresh()
    }

    private func settingsDidChange(_ settings: TabBarSettings) {
        let wasVertical = isVertical
        self.settings = settings
        if wasVertical != isVertical { attachAddButton() }
        applyAppearance()
        reconcile(model.tabs)
    }

    private func applyAppearance() {
        scroll.isHidden = isPlaceholder
        addButton.isHidden = isPlaceholder
        header.isHidden = isPlaceholder || !isVertical
        headerCount.isHidden = header.isHidden
        header.textColor = theme.foreground.withAlphaComponent(0.4)
        headerCount.textColor = theme.foreground.withAlphaComponent(0.4)
        addButton.theme = theme
        addButton.settings = settings
        addButton.isRow = isVertical
        for cell in cells.values { cell.appearanceDidChange() }
        needsLayout = true
        needsDisplay = true
    }

    /// Horizontal strips keep `+` beside the scroller; sidebars scroll it with the list.
    private func attachAddButton() {
        let parent: NSView = isVertical ? document : self
        guard addButton.superview !== parent else { return }
        addButton.removeFromSuperview()
        parent.addSubview(addButton)
    }

    @objc private func newTab() { model.newTab() }

    private func reconcile(_ tabs: [RoundedTerminalTabModel.Tab]) {
        let countChanged = tabs.count != displayedTabs.count
        displayedTabs = tabs
        let keep = Set(tabs.map(\.id))
        for id in cells.keys where !keep.contains(id) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
        }
        for (index, tab) in tabs.enumerated() {
            let cell = cells[tab.id] ?? RoundedTabCell(owner: self)
            if cell.superview == nil { document.addSubview(cell); cells[tab.id] = cell }
            cell.update(tab, index: index, count: tabs.count)
        }
        attachAddButton()
        header.stringValue = "TABS"
        headerCount.stringValue = "\(tabs.count)"
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
        if let selected = tabs.first(where: \.selected), let cell = cells[selected.id] {
            document.scrollToVisible(cell.frame.insetBy(dx: -8, dy: -8))
        }
        if countChanged { onTabCountChange?(tabs.count) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        guard !isPlaceholder else { return }
        if isVertical { layoutVertical() } else { layoutHorizontal() }
    }

    private func layoutHorizontal() {
        let s = settings
        let height = bounds.height
        let tab = min(CGFloat(s.tabHeight), max(16, height - 6)).rounded()
        let gap = CGFloat(s.spacing)
        let inset: CGFloat = placement == .titlebar ? 6 : 12
        let available = max(0, bounds.width - inset * 2 - gap - tab)
        let count = displayedTabs.count
        var widths: [CGFloat]
        switch s.width {
        case .fit:
            widths = displayedTabs.enumerated().map { index, item in
                RoundedTabCell.fittedWidth(item, index: index, height: tab, settings: s)
            }
        case .equal:
            let share = count > 0 ? (available - gap * CGFloat(count - 1)) / CGFloat(count) : 0
            widths = Array(repeating: min(max(share, 72), 200).rounded(.down), count: count)
        }
        let content = widths.reduce(0, +) + gap * CGFloat(max(0, count - 1))
        let viewport = min(content, available)
        var start = inset
        if s.alignment == .center {
            start = max(inset, ((bounds.width - viewport - gap - tab) / 2).rounded())
        }
        let y = ((height - tab) / 2).rounded()
        scroll.frame = NSRect(x: start, y: 0, width: viewport, height: height)
        document.frame = NSRect(x: 0, y: 0, width: content, height: height)
        var x: CGFloat = 0
        for (index, item) in displayedTabs.enumerated() {
            guard let cell = cells[item.id] else { continue }
            cell.frame = NSRect(x: x, y: y, width: widths[index], height: tab)
            x += widths[index] + gap
        }
        header.frame = .zero
        headerCount.frame = .zero
        addButton.frame = NSRect(x: start + viewport + (count > 0 ? gap : 0), y: y, width: tab, height: tab)
    }

    private func layoutVertical() {
        let s = settings
        let pad: CGFloat = 10
        let headerHeight: CGFloat = 26
        let row = CGFloat(s.tabHeight)
        let gap = CGFloat(s.spacing)
        header.frame = NSRect(x: pad + 6, y: pad + 4, width: bounds.width - pad * 2 - 40, height: 14)
        headerCount.frame = NSRect(x: bounds.width - pad - 6 - 30, y: pad + 4, width: 30, height: 14)
        let top = pad + headerHeight
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let count = displayedTabs.count
        let listHeight = CGFloat(count) * row + CGFloat(count) * gap + row + pad
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(listHeight, scroll.frame.height))
        var y: CGFloat = 0
        let width = max(0, bounds.width - pad * 2)
        for item in displayedTabs {
            cells[item.id]?.frame = NSRect(x: pad, y: y, width: width, height: row)
            y += row + gap
        }
        addButton.frame = NSRect(x: pad, y: y, width: width, height: row)
    }

    /// Frame of the tab at `index` in this bar's coordinates.
    func tabFrame(at index: Int) -> NSRect? {
        guard displayedTabs.indices.contains(index), let cell = cells[displayedTabs[index].id] else { return nil }
        return convert(cell.bounds, from: cell)
    }

    /// Size along the cross axis that an edge placement wants.
    var preferredThickness: CGFloat { settings.edgeThickness }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let s = settings
        if isPlaceholder { drawPlaceholderTitle(); return }
        // The titlebar already has the window background; the preview mimics that for Top.
        guard placement == .edge || (placement == .preview && s.position != .top) else { return }
        if placement == .edge {
            // Only terminal surfaces paint the background, so beside them we paint it too
            // (same color and opacity) instead of showing the blurred desktop.
            theme.background.withAlphaComponent(theme.backgroundOpacity).setFill()
            bounds.fill()
        }
        if s.showBackground {
            theme.foreground.withAlphaComponent(0.035).setFill()
            bounds.fill()
        }
        theme.foreground.withAlphaComponent(0.08).setFill()
        switch s.position {
        case .top: NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        case .bottom: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        case .left: NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        case .right: NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: Placeholder (tabs shown elsewhere): behave like an empty titlebar.

    /// Draws the focused tab's title centered on the window, like a plain titlebar.
    private func drawPlaceholderTitle() {
        guard let window, let title = displayedTabs.first(where: \.selected)?.title ?? model.hostWindow?.title,
              !title.isEmpty else { return }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.titleBarFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: theme.foreground.withAlphaComponent(window.isMainWindow ? 0.75 : 0.4),
        ])
        let size = text.size()
        let center = convert(NSPoint(x: window.frame.width / 2, y: 0), from: nil).x
        let width = min(size.width, max(0, bounds.width - 24))
        var x = (center - width / 2).rounded()
        x = min(max(x, 12), max(12, bounds.width - 12 - width))
        let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: width, height: size.height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPlaceholder {
            // `point` is in the superview's coordinate space.
            guard !isHidden else { return nil }
            return frame.contains(point) ? self : nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isPlaceholder, let window else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    // MARK: Menus

    override func menu(for event: NSEvent) -> NSMenu? { isPlaceholder ? nil : barMenu() }

    func barMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.addItem(.separator())
        addTabBarItems(to: menu)
        return menu
    }

    /// Position submenu plus the settings window, shared by tab and bar menus.
    func addTabBarItems(to menu: NSMenu) {
        let positions = NSMenu()
        for position in TabBarSettings.Position.allCases {
            let item = NSMenuItem(title: position.title, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.representedObject = position.rawValue
            item.target = self
            item.state = settings.position == position ? .on : .off
            positions.addItem(item)
        }
        let positionItem = NSMenuItem(title: "Tab Bar Position", action: nil, keyEquivalent: "")
        positionItem.submenu = positions
        menu.addItem(positionItem)
        if settings.tabColors == .random {
            let shuffle = NSMenuItem(title: "Shuffle Tab Colors", action: #selector(shuffleColors), keyEquivalent: "")
            shuffle.target = self
            menu.addItem(shuffle)
        }
        let settingsItem = NSMenuItem(title: "Tab Bar Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = TabBarSettings.Position(rawValue: raw) else { return }
        store.settings.position = position
    }

    @objc private func openSettings() { TabBarSettingsController.shared.show() }
    @objc private func shuffleColors() { model.shuffleColors() }
}

private final class FlippedTabDocument: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? {
        (enclosingScrollView?.superview as? RoundedTerminalTabBar)?.barMenu()
    }
}

/// Handle selection on mouse-down, without a SwiftUI drag recognizer competing
/// with the click. Standard button action handling remains available to AX/keyboard.
private class TabMouseButton: NSButton {
    var onMouseDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        if let onMouseDown { onMouseDown(event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? superview?.menu(for: event) }
}

/// Buttons that draw their own hover state.
private class HoverTabButton: TabMouseButton {
    private var tracking: NSTrackingArea?
    var isHovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The small round close control inside a capsule.
private final class TabCloseButton: HoverTabButton {
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isHovered {
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        let r: CGFloat = 3.25
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y - r)); path.line(to: NSPoint(x: c.x + r, y: c.y + r))
        path.move(to: NSPoint(x: c.x + r, y: c.y - r)); path.line(to: NSPoint(x: c.x - r, y: c.y + r))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        tint.withAlphaComponent(isHovered ? 1 : 0.8).setStroke()
        path.stroke()
    }
}

/// `+` as a round capsule in horizontal strips, or a dashed "New tab" row in sidebars.
private final class TabAddButton: HoverTabButton {
    var theme = RoundedTabTheme.fallback { didSet { needsDisplay = true } }
    var settings = TabBarSettings() { didSet { needsDisplay = true } }
    var isRow = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let fg = theme.foreground
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(settings.cornerRadius(height: rect.height), rect.height / 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let ink = fg.withAlphaComponent(isHovered ? 0.9 : 0.5)
        if isRow {
            if isHovered { fg.withAlphaComponent(0.06).setFill(); shape.fill() }
            shape.setLineDash([3, 3], count: 2, phase: 0)
            shape.lineWidth = 1
            fg.withAlphaComponent(0.14).setStroke()
            shape.stroke()
            drawPlus(at: NSPoint(x: rect.minX + 16, y: rect.midY), color: ink)
            let text = NSAttributedString(string: "New tab", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: ink,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: rect.minX + 30, y: rect.midY - size.height / 2))
        } else {
            fg.withAlphaComponent(isHovered ? 0.11 : 0.05).setFill()
            shape.fill()
            drawPlus(at: NSPoint(x: rect.midX, y: rect.midY), color: ink)
        }
    }

    private func drawPlus(at c: NSPoint, color: NSColor) {
        let r: CGFloat = 4.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y)); path.line(to: NSPoint(x: c.x + r, y: c.y))
        path.move(to: NSPoint(x: c.x, y: c.y - r)); path.line(to: NSPoint(x: c.x, y: c.y + r))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

@MainActor
private final class RoundedTabCell: NSView, NSDraggingSource {
    private static let dragType = NSPasteboard.PasteboardType("com.amsynist.ghosttyx.tab")
    private static let minWidth: CGFloat = 84
    private static let maxWidth: CGFloat = 200
    private static let closeSize: CGFloat = 16
    private static let dotSize: CGFloat = 7

    private weak var owner: RoundedTerminalTabBar?
    private var tab: RoundedTerminalTabModel.Tab?
    private var index = 0
    private var count = 0
    private let selectButton = TabMouseButton()
    private let closeButton = TabCloseButton()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var dragging = false

    /// 0...1 progress values the drawing interpolates on, animated via the
    /// view's animator proxy so selection and hover fade instead of snapping.
    @objc dynamic var selectAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    @objc dynamic var hoverAmount: CGFloat = 0 { didSet { needsDisplay = true } }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        switch key {
        case "selectAmount", "hoverAmount": CABasicAnimation()
        default: super.defaultAnimation(forKey: key)
        }
    }

    private var theme: RoundedTabTheme { owner?.theme ?? .fallback }
    private var settings: TabBarSettings { owner?.settings ?? TabBarSettings() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(owner: RoundedTerminalTabBar) {
        self.owner = owner
        super.init(frame: .zero)
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.onMouseDown = { [weak self] event in
            guard let self else { return }
            if event.clickCount == 2 { self.renameTab() } else { self.selectTab() }
        }
        selectButton.onDrag = { [weak self] event in self?.beginTabDrag(event) }
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.onMouseDown = { [weak self] _ in self?.closeTab() }
        addSubview(selectButton)
        addSubview(closeButton)
        registerForDraggedTypes([Self.dragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Metrics

    private struct Metrics {
        var cap: NSRect?
        var dot: NSRect?
        var number: NSRect?
        var title: NSRect
        var close: NSRect?
    }

    /// Whether the tab shows a color: one picked by hand, or a random one.
    private static func hasColor(_ tab: RoundedTerminalTabModel.Tab, settings: TabBarSettings) -> Bool {
        tab.color.displayColor != nil || (settings.tabColors == .random && tab.autoColor != nil)
    }

    private static func capWidth(height: CGFloat, settings: TabBarSettings) -> CGFloat {
        (height * (settings.showNumbers ? 1.05 : 0.5)).rounded()
    }

    /// The tab's color: picked by hand first, else its random palette color.
    private var tabColor: NSColor? {
        guard let tab else { return nil }
        if let color = tab.color.displayColor { return color }
        guard settings.tabColors == .random, let slot = tab.autoColor else { return nil }
        let indices = TabBarSettings.randomPaletteIndices
        let index = indices[slot % indices.count]
        return theme.palette.indices.contains(index) ? theme.palette[index] : nil
    }

    private static func fonts(height: CGFloat) -> (title: NSFont, selected: NSFont, number: NSFont) {
        let size: CGFloat = height >= 32 ? 13 : 12
        return (.systemFont(ofSize: size, weight: .medium),
                .systemFont(ofSize: size, weight: .semibold),
                .monospacedDigitSystemFont(ofSize: size - 1.5, weight: .semibold))
    }

    private static func paddings(height: CGFloat, settings: TabBarSettings) -> (left: CGFloat, right: CGFloat) {
        let radius = settings.cornerRadius(height: height)
        return (max(10, (radius * 0.65).rounded()), max(6, (radius * 0.4).rounded()))
    }

    private static func numberWidth(_ index: Int, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: "\(index + 1)", attributes: [.font: font]).size().width)
    }

    /// Width a capsule needs to show its whole title (clamped), used by "Fit title".
    static func fittedWidth(_ tab: RoundedTerminalTabModel.Tab, index: Int, height: CGFloat,
                            settings: TabBarSettings) -> CGFloat {
        let fonts = fonts(height: height)
        let pad = paddings(height: height, settings: settings)
        let colored = hasColor(tab, settings: settings)
        var width = pad.right
        if colored && settings.colorStyle == .cap {
            width += capWidth(height: height, settings: settings) + 8
        } else {
            width += pad.left
            if colored && (settings.colorStyle == .dot || settings.colorStyle == .both) { width += dotSize + 6 }
            if settings.showNumbers { width += numberWidth(index, font: fonts.number) + 6 }
        }
        width += ceil(NSAttributedString(string: tab.title, attributes: [.font: fonts.selected]).size().width)
        if settings.closeButton != .never { width += 6 + closeSize }
        return min(max(width.rounded(.up), minWidth), maxWidth)
    }

    private func metrics() -> Metrics {
        let s = settings
        let fonts = Self.fonts(height: bounds.height)
        let pad = Self.paddings(height: bounds.height, settings: s)
        let midY = bounds.midY
        var x = pad.left
        var m = Metrics(title: .zero)
        let colored = tab.map { Self.hasColor($0, settings: s) } ?? false
        if colored && s.colorStyle == .cap {
            // The number lives in a colored cap on the capsule's leading end.
            let cap = NSRect(x: 0, y: 0, width: Self.capWidth(height: bounds.height, settings: s), height: bounds.height)
            m.cap = cap
            if s.showNumbers { m.number = cap }
            x = cap.maxX + 8
        } else {
            if colored && (s.colorStyle == .dot || s.colorStyle == .both) {
                m.dot = NSRect(x: x, y: midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
                x += Self.dotSize + 6
            }
            if s.showNumbers {
                let w = Self.numberWidth(index, font: fonts.number)
                m.number = NSRect(x: x, y: 0, width: w, height: bounds.height)
                x += w + 6
            }
        }
        var right = bounds.width - pad.right
        if s.closeButton != .never {
            m.close = NSRect(x: right - Self.closeSize, y: (midY - Self.closeSize / 2).rounded(),
                             width: Self.closeSize, height: Self.closeSize)
            right -= Self.closeSize + 6
        }
        m.title = NSRect(x: x, y: 0, width: max(0, right - x), height: bounds.height)
        return m
    }

    // MARK: State

    func update(_ tab: RoundedTerminalTabModel.Tab, index: Int, count: Int) {
        let wasSelected = self.tab?.selected
        self.tab = tab; self.index = index; self.count = count
        selectButton.setAccessibilityLabel("Tab \(index + 1): \(tab.title)")
        selectButton.setAccessibilityValue(tab.selected ? 1 : 0)
        closeButton.setAccessibilityLabel("Close \(tab.title)")
        toolTip = tab.title
        let target: CGFloat = tab.selected ? 1 : 0
        if wasSelected == nil {
            selectAmount = target  // First appearance: no fade-in from nothing.
        } else if selectAmount != target {
            animate { $0.selectAmount = target }
        }
        appearanceDidChange()
    }

    func appearanceDidChange() {
        updateCloseVisibility()
        closeButton.tint = theme.foreground
        needsLayout = true
        needsDisplay = true
    }

    private func updateCloseVisibility() {
        switch settings.closeButton {
        case .never: closeButton.isHidden = true
        case .always: closeButton.isHidden = false
        case .hover: closeButton.isHidden = !(tab?.selected == true || hovered)
        }
    }

    private func animate(_ change: @escaping (RoundedTabCell) -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            change(self.animator())
        }
    }

    override func layout() {
        super.layout()
        let m = metrics()
        // The select button covers the whole capsule; close sits on top of it.
        selectButton.frame = bounds
        closeButton.frame = m.close ?? .zero
        syncHoverWithPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncHoverWithPointer()
    }

    /// Tracking areas only report enter/exit when the pointer moves. Tabs are separate
    /// windows and cells move on relayout, so re-check against the real pointer position.
    private func syncHoverWithPointer() {
        guard let window else { return }
        let inside = window.isVisible && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside != hovered else { return }
        hovered = inside
        hoverAmount = inside ? 1 : 0
        updateCloseVisibility()
    }

    // MARK: Drawing

    private struct Palette { var fill: NSColor; var border: NSColor }

    private func palette(selected: Bool, hover: Bool) -> Palette {
        let fg = theme.foreground
        let accent = theme.accent(settings.accent)
        if let color = tabColor {
            let outline = settings.style == .outline
            switch (settings.colorStyle, selected) {
            case (.tint, true), (.both, true):
                return Palette(fill: color.withAlphaComponent(0.28), border: color.withAlphaComponent(0.7))
            case (.tint, false), (.both, false):
                return Palette(fill: color.withAlphaComponent(hover ? 0.19 : 0.11),
                               border: outline ? color.withAlphaComponent(0.38) : color.withAlphaComponent(0))
            case (.cap, true):
                return Palette(fill: color.withAlphaComponent(0.13), border: color.withAlphaComponent(0.6))
            case (.cap, false):
                return Palette(fill: hover ? color.withAlphaComponent(0.09) : fg.withAlphaComponent(0.055),
                               border: outline ? fg.withAlphaComponent(0.16) : color.withAlphaComponent(0))
            case (.dot, _):
                break
            }
        }
        switch (settings.style, selected) {
        case (.filled, true): return Palette(fill: accent.withAlphaComponent(0.22), border: accent.withAlphaComponent(0.55))
        case (.filled, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.10 : 0.06), border: .clear)
        case (.outline, true): return Palette(fill: accent.withAlphaComponent(0.12), border: accent.withAlphaComponent(0.7))
        case (.outline, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.05 : 0), border: fg.withAlphaComponent(0.16))
        case (.minimal, true): return Palette(fill: accent.withAlphaComponent(0.20), border: .clear)
        case (.minimal, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.07 : 0), border: .clear)
        }
    }

    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(srgbRed: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent),
                       blue: lerp(a.blueComponent, b.blueComponent), alpha: lerp(a.alphaComponent, b.alphaComponent))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tab else { return }
        let theme = theme
        let s = settings
        let sel = selectAmount
        let rest = Self.mix(palette(selected: false, hover: false).fill, palette(selected: false, hover: true).fill, hoverAmount)
        let restBorder = palette(selected: false, hover: false).border
        let on = palette(selected: true, hover: false)
        let fill = Self.mix(rest, on.fill, sel)
        let border = Self.mix(restBorder.usingColorSpace(.sRGB) ?? .clear, on.border.usingColorSpace(.sRGB) ?? .clear, sel)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(s.cornerRadius(height: rect.height), rect.height / 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()

        let m = metrics()
        let fonts = Self.fonts(height: bounds.height)
        let color = tabColor
        if let cap = m.cap, let color {
            // Muted cap for other tabs, solid for the selected one; clipped to the capsule.
            let rest = color.withAlphaComponent(0.24 + 0.12 * hoverAmount)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            Self.mix(rest, color.withAlphaComponent(1), sel).setFill()
            cap.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if border.alphaComponent > 0.001 {
            shape.lineWidth = 1
            border.setStroke()
            shape.stroke()
        }
        if let dot = m.dot, let color {
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if let numberRect = m.number {
            let numberColor: NSColor
            let style = s.colorStyle
            if let color, m.cap != nil {
                numberColor = Self.mix(color, theme.background, sel)
            } else if let color, style == .tint || style == .both {
                numberColor = Self.mix(color.withAlphaComponent(0.75), color, sel)
            } else {
                numberColor = Self.mix(theme.foreground.withAlphaComponent(0.35), theme.accent(s.accent), sel)
            }
            drawText("\(index + 1)", in: numberRect, font: fonts.number, color: numberColor,
                     centered: m.cap != nil)
        }
        let textAlpha = 0.6 + 0.25 * hoverAmount
        let titleColor = Self.mix(theme.foreground.withAlphaComponent(textAlpha), theme.foreground, sel)
        drawText(tab.title, in: m.title, font: sel > 0.5 ? fonts.selected : fonts.title, color: titleColor)
    }

    private func drawText(_ string: String, in rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .natural
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let height = ceil(font.ascender - font.descender + font.leading)
        let line = NSRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        text.draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateCloseVisibility()
        animate { $0.hoverAmount = 1 }
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateCloseVisibility()
        animate { $0.hoverAmount = 0 }
    }
    override func mouseDown(with event: NSEvent) { selectTab() }

    @objc private func selectTab() { if let tab { owner?.model.select(tab) } }
    @objc private func closeTab() { if let tab { owner?.model.close(tab) } }
    @objc private func renameTab() { if let tab { owner?.model.rename(tab) } }
    @objc private func moveTabBack() { if let tab { owner?.model.move(tab, by: -1) } }
    @objc private func moveTabForward() { if let tab { owner?.model.move(tab, by: 1) } }
    @objc private func detachTab() { if let tab { owner?.model.detach(tab) } }
    @objc private func setColor(_ sender: NSMenuItem) {
        guard let tab, let color = TerminalTabColor(rawValue: sender.tag) else { return }
        owner?.model.setColor(color, for: tab)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let vertical = owner?.isVertical == true
        for (title, action, enabled) in [
            ("Rename Tab…", #selector(renameTab), true),
            (vertical ? "Move Tab Up" : "Move Tab Left", #selector(moveTabBack), index > 0),
            (vertical ? "Move Tab Down" : "Move Tab Right", #selector(moveTabForward), index < count - 1),
            ("Move Tab to New Window", #selector(detachTab), count > 1),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        let colors = NSMenu()
        for color in TerminalTabColor.allCases {
            let item = NSMenuItem(title: color.localizedName, action: #selector(setColor(_:)), keyEquivalent: "")
            item.tag = color.rawValue; item.target = self
            item.state = tab?.color == color ? .on : .off
            colors.addItem(item)
        }
        let colorMenu = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorMenu.submenu = colors; menu.addItem(colorMenu)
        menu.addItem(.separator())
        owner?.addTabBarItems(to: menu)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
        close.target = self; menu.addItem(close)
        return menu
    }

    // MARK: Drag reorder

    private func beginTabDrag(_ event: NSEvent) {
        guard !dragging, let tab else { return }
        let item = NSPasteboardItem()
        item.setString(String(describing: tab.id), forType: Self.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        dragging = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging = false }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = sender.draggingPasteboard.string(forType: Self.dragType),
              owner?.model.tabs.contains(where: { String(describing: $0.id) == id }) == true else { return [] }
        return .move
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = sender.draggingPasteboard.string(forType: Self.dragType), let tab else { return false }
        return owner?.model.reorder([id], before: tab) ?? false
    }
}
