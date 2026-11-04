import AppKit
import Combine
import GhosttyKit

struct SettingsThemeSample {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let colors: [NSColor]

    init(config: ghostty_config_t?) {
        func color(_ key: String, fallback: NSColor) -> NSColor {
            var value = ghostty_config_color_s()
            guard config != nil, ghostty_config_get(config, &value, key, UInt(key.utf8.count)) else { return fallback }
            return NSColor(ghostty: value)
        }
        background = color("background", fallback: .textBackgroundColor)
        foreground = color("foreground", fallback: .textColor)
        cursor = color("cursor-color", fallback: foreground)
        var palette = ghostty_config_palette_s()
        if config != nil, ghostty_config_get(config, &palette, "palette", 7) {
            colors = withUnsafeBytes(of: &palette.colors) {
                Array($0.bindMemory(to: ghostty_config_color_s.self).prefix(16)).map { NSColor(ghostty: $0) }
            }
        } else {
            colors = Array(repeating: foreground, count: 16)
        }
    }

    static func load(_ name: String, resourceURL: URL? = Bundle.main.resourceURL,
                     homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self? {
        guard name == (name as NSString).lastPathComponent,
              let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        let roots = [homeURL.appendingPathComponent(".config/ghostty/themes"),
                     resourceURL?.appendingPathComponent("ghostty/themes")].compactMap { $0 }
        guard let path = roots.map({ $0.appendingPathComponent(name) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        // Use the same parser as the terminal, without user overlays or CLI flags.
        ghostty_config_load_file(config, path.path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        guard ghostty_config_diagnostics_count(config) == 0 else { return nil }
        return Self(config: config)
    }
}

final class SettingsTerminalPreview: NSView {
    var sample: SettingsThemeSample? { didSet { needsDisplay = true } }
    var font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) { didSet { needsDisplay = true } }
    var opacity: Double = 1 { didSet { needsDisplay = true } }
    var cursorStyle: OhMyGhosttyCursorStyle = .block { didSet { needsDisplay = true } }
    var compact = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let sample else { return }
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        sample.background.withAlphaComponent(opacity).setFill()
        bounds.fill()
        let padding: CGFloat = compact ? 8 : 14
        let size = compact ? NSFont.monospacedSystemFont(ofSize: 8, weight: .regular) : font
        let lineHeight = size.ascender - size.descender + (compact ? 3 : 6)
        let lines = compact ? ["~  git status", "  main  ✓", "$ _"] :
            ["~/project  main", "$ git status --short", " M Sources/App.swift", "✓ All tests passed", "$ "]
        for (index, text) in lines.enumerated() {
            let color = index == 0 ? sample.colors[4] : index == 2 ? sample.colors[3] :
                index == 3 ? sample.colors[2] : sample.foreground
            (text as NSString).draw(at: .init(x: padding, y: padding + CGFloat(index) * lineHeight),
                withAttributes: [.font: size, .foregroundColor: color])
        }
        if !compact {
            let x = padding + ("$ " as NSString).size(withAttributes: [.font: size]).width
            let y = padding + 4 * lineHeight
            sample.cursor.setFill()
            let width = ("M" as NSString).size(withAttributes: [.font: size]).width
            let rect: NSRect
            switch cursorStyle {
            case .bar: rect = .init(x: x, y: y, width: 2, height: lineHeight - 3)
            case .underline: rect = .init(x: x, y: y + lineHeight - 5, width: width, height: 2)
            default: rect = .init(x: x, y: y, width: width, height: lineHeight - 3)
            }
            if cursorStyle == .blockHollow { NSBezierPath(rect: rect).stroke() } else { rect.fill() }
            let dot: CGFloat = 8
            for (index, color) in sample.colors.enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: .init(x: bounds.maxX - 14 - CGFloat(16 - index) * 12,
                                          y: bounds.maxY - 15, width: dot, height: dot)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class SettingsThemeItem: NSCollectionViewItem {
    let preview = SettingsTerminalPreview()
    private let name = NSTextField(labelWithString: "")
    override func loadView() {
        view = NSView()
        preview.compact = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 11)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        view.addSubview(preview)
        view.addSubview(name)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            preview.heightAnchor.constraint(equalToConstant: 60),
            name.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 5),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            name.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
        view.wantsLayer = true
        view.layer?.cornerRadius = 9
    }
    func configure(name: String, sample: SettingsThemeSample?) {
        _ = view
        self.name.stringValue = name
        preview.sample = sample
        view.setAccessibilityLabel(name)
        updateBorder()
    }
    override var isSelected: Bool { didSet { updateBorder() } }
    private func updateBorder() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}

@MainActor
final class NativeThemeGallery: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate {
    private let settings: OhMyGhosttySettings
    private let names: [String]
    private var filtered: [String] = []
    private var cache: [String: SettingsThemeSample] = [:]
    private let collection = NSCollectionView()
    private let search = NSSearchField()
    private let scope = NSSegmentedControl()
    private let preview = SettingsTerminalPreview()
    private let caption = NSTextField(labelWithString: "")
    private let apply = SettingsActionButton("") {}
    private var token: AnyCancellable?
    private(set) var previewedTheme: String?
    var strings: SettingsStrings { .init(language: settings.language) }

    init(settings: OhMyGhosttySettings) {
        self.settings = settings
        let available = GhosttyThemeCatalog.availableThemes()
        let featured = [settings.darkThemeOverride, settings.lightThemeOverride,
                        "Atom One Dark", "Nord", "Dracula", "Solarized Dark",
                        "Solarized Light", "GitHub Light"].compactMap { $0 }
        var seen = Set<String>()
        names = (featured + available).filter { available.contains($0) && seen.insert($0).inserted }
        super.init(nibName: nil, bundle: nil)
        filtered = names
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        scope.segmentCount = 2
        scope.setLabel(strings.t("Light theme", "浅色主题"), forSegment: 0)
        scope.setLabel(strings.t("Dark theme", "深色主题"), forSegment: 1)
        scope.selectedSegment = settings.windowThemeOverride == .light ? 0 : 1
        scope.target = self
        scope.action = #selector(changeScope)
        search.placeholderString = strings.t("Find a theme", "搜索主题")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let header = NSStackView(views: [scope, NSView(), search])
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = .init(width: 130, height: 88)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(SettingsThemeItem.self, forItemWithIdentifier: .init("theme"))
        collection.setAccessibilityIdentifier("settings.theme.gallery")
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        apply.title = strings.t("Use theme", "使用此主题")
        apply.setAccessibilityIdentifier("settings.theme.apply")
        apply.invoke = { [weak self] in self?.applyPreview() }
        caption.font = .systemFont(ofSize: 12)
        caption.lineBreakMode = .byTruncatingMiddle
        let reset = SettingsActionButton(strings.t("Default", "默认")) { [weak self] in
            guard let self else { return }
            if self.scope.selectedSegment == 0 { self.settings.lightThemeOverride = nil } else { self.settings.darkThemeOverride = nil }
            self.changeScope()
        }
        let footer = NSStackView(views: [caption, NSView(), reset, apply])
        let stack = NSStackView(views: [header, scroll, preview, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            search.widthAnchor.constraint(equalToConstant: 180),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 185),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 160),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        changeScope()
        token = settings.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshPreview() }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { filtered.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("theme"), for: indexPath)
        guard let item = item as? SettingsThemeItem else { return item }
        let name = filtered[indexPath.item]
        item.configure(name: name, sample: sample(name))
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, filtered.indices.contains(index) else { return }
        previewTheme(filtered[index])
    }
    func controlTextDidChange(_ obj: Notification) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filtered = names.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        collection.reloadData()
    }
    @objc private func changeScope() {
        let name = scope.selectedSegment == 0 ? settings.lightThemeOverride : settings.darkThemeOverride
        previewedTheme = name
        collection.selectionIndexPaths = name.flatMap { filtered.firstIndex(of: $0) }.map { [.init(item: $0, section: 0)] } ?? []
        if let index = collection.selectionIndexPaths.first {
            collection.scrollToItems(at: [index], scrollPosition: .top)
        }
        refreshPreview()
    }
    func previewTheme(_ name: String) {
        previewedTheme = name
        refreshPreview()
    }
    func applyPreview() {
        guard let name = previewedTheme, sample(name) != nil else { return }
        if scope.selectedSegment == 0 { settings.lightThemeOverride = name } else { settings.darkThemeOverride = name }
        refreshPreview()
    }
    private func sample(_ name: String) -> SettingsThemeSample? {
        if let value = cache[name] { return value }
        let value = SettingsThemeSample.load(name)
        cache[name] = value
        return value
    }
    private func refreshPreview() {
        let current = scope.selectedSegment == 0 ? settings.lightThemeOverride : settings.darkThemeOverride
        preview.sample = previewedTheme.flatMap(sample) ??
            SettingsThemeSample(config: (NSApp.delegate as? AppDelegate)?.ghostty.inheritedConfig.config)
        preview.font = settings.fontFamilyOverride.flatMap { NSFont(name: $0, size: settings.fontSizeOverride ?? 13) } ??
            .monospacedSystemFont(ofSize: settings.fontSizeOverride ?? 13, weight: .regular)
        preview.opacity = settings.backgroundOpacityOverride ?? 1
        preview.cursorStyle = settings.cursorStyleOverride ?? .block
        caption.stringValue = (previewedTheme ?? strings.t("Terminal default", "终端默认")) +
            (previewedTheme == current ? strings.t(" · Current", " · 当前使用") : strings.t(" · Preview", " · 预览"))
        apply.isEnabled = previewedTheme != nil && previewedTheme != current && previewedTheme.flatMap(sample) != nil
    }
}
