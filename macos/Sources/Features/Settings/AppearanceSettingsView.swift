import SwiftUI
import UniformTypeIdentifiers

/// Theme management: a curated set of well-known themes split into dark
/// and light sections, import of external theme files, and an inline
/// theme creator at the bottom of the screen.
struct AppearanceSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @StateObject private var catalog: ThemeCatalog

    @State private var search = ""

    /// Famous themes shown by default; searching looks through the whole
    /// catalog. Names match the bundled theme files exactly.
    private static let curated: Set<String> = [
        "Dracula", "Dracula+",
        "TokyoNight", "TokyoNight Storm", "TokyoNight Moon", "TokyoNight Day",
        "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe", "Catppuccin Latte",
        "Gruvbox Dark", "Gruvbox Dark Hard", "Gruvbox Light",
        "Nord", "Nord Light",
        "One Half Dark", "One Half Light",
        "Monokai Pro", "Monokai Remastered", "Monokai Pro Light",
        "GitHub Dark Default", "GitHub Light Default",
        "Solarized Dark Higher Contrast", "iTerm2 Solarized Light",
        "Ayu", "Ayu Mirage", "Ayu Light",
        "Night Owl", "Night Owlish Light",
        "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn",
        "Kanagawa Dragon", "Kanagawa Lotus",
        "Everforest Dark Hard", "Everforest Light Med",
        "Snazzy", "Material Ocean", "Cobalt2", "Synthwave Everything",
    ]

    init(ghostty: Ghostty.App, store: GuiConfigStore) {
        self.ghostty = ghostty
        self.store = store
        _catalog = StateObject(wrappedValue: ThemeCatalog(userThemesDir: store.themesDirURL))
    }

    private var currentTheme: String {
        store.string("theme") ?? ""
    }

    private struct ThemeGroups {
        var user: [TerminalTheme] = []
        var dark: [TerminalTheme] = []
        var light: [TerminalTheme] = []
    }

    private var groups: ThemeGroups {
        var result = ThemeGroups()

        let visible: [TerminalTheme]
        if search.isEmpty {
            visible = catalog.themes.filter {
                $0.source == .user || Self.curated.contains($0.name)
            }
        } else {
            visible = catalog.themes.filter {
                $0.name.localizedCaseInsensitiveContains(search)
            }
        }

        for theme in visible {
            if theme.source == .user {
                result.user.append(theme)
            } else if theme.background?.isLightColor == true {
                result.light.append(theme)
            } else {
                result.dark.append(theme)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()

            if catalog.isLoading && catalog.themes.isEmpty {
                Spacer()
                ProgressView("Loading themes…")
                Spacer()
            } else {
                ScrollView {
                    let groups = groups

                    VStack(alignment: .leading, spacing: 18) {
                        if !groups.user.isEmpty {
                            themeSection("My Themes", groups.user)
                        }
                        if !groups.dark.isEmpty {
                            themeSection("Dark", groups.dark)
                        }
                        if !groups.light.isEmpty {
                            themeSection("Light", groups.light)
                        }

                        Divider()
                            .padding(.top, 6)

                        AppearanceStylePanel(ghostty: ghostty, store: store)

                        Divider()
                            .padding(.top, 6)

                        ThemeCreatorView(
                            ghostty: ghostty,
                            store: store,
                            catalog: catalog,
                            seed: catalog.themes.first { $0.name == currentTheme }
                        )
                    }
                    .padding(14)
                }
            }
        }
        .navigationTitle("Appearance")
        .onAppear {
            catalog.loadIfNeeded()
            applyDefaultThemeIfNeeded()
        }
    }

    /// Dracula is the out-of-the-box theme until the user picks another.
    private func applyDefaultThemeIfNeeded() {
        guard currentTheme.isEmpty else { return }
        store.set("theme", "Dracula")
        store.apply(ghostty: ghostty)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text("Search all \(catalog.themes.count) themes"))
                .textFieldStyle(.plain)

            Button("Import…") { importThemes() }
        }
        .padding(10)
    }

    private func themeSection(_ title: String, _ themes: [TerminalTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                spacing: 10
            ) {
                ForEach(themes) { theme in
                    ThemeCard(theme: theme, isSelected: theme.name == currentTheme) {
                        store.set("theme", theme.name)
                        store.apply(ghostty: ghostty)
                    }
                    .contextMenu {
                        if theme.source == .user {
                            Button("Delete", role: .destructive) { deleteTheme(theme) }
                        }
                    }
                }
            }
        }
    }

    private func deleteTheme(_ theme: TerminalTheme) {
        guard theme.source == .user else { return }
        try? FileManager.default.removeItem(at: theme.url)
        if currentTheme == theme.name {
            store.set("theme", "Dracula")
            store.apply(ghostty: ghostty)
        }
        catalog.reload()
    }

    private func importThemes() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: store.themesDirURL, withIntermediateDirectories: true)

        for url in panel.urls {
            let destination = store.themesDirURL.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: url, to: destination)
        }
        catalog.reload()
    }
}

/// Every style control in one place, sectioned by area — the specific
/// settings tabs keep only behavior.
private struct AppearanceStylePanel: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var fontFamily: String = ""
    @State private var fontSize: Double = 13
    @State private var cursorStyle: String = ""
    @State private var backgroundOpacity: Double = 1
    @State private var blurMode: String = "off"
    @State private var blurRadius: Double = 20
    @State private var backgroundColorOverride: Color?
    @State private var sidebarBackgroundMode: String = "theme"
    @State private var tintColor: Color = .black
    @State private var tintOpacity: Double = 0
    @State private var sidebarWidth: Double = 240
    @State private var dividerMode: String = "default"
    @State private var dividerColor: Color = .gray

    @AppStorage("SidebarTabDensity") private var tabDensity = "default"

    private static let cursorStyles: [(value: String, label: String)] = [
        ("", "Default"),
        ("block", "Block"),
        ("bar", "Bar"),
        ("underline", "Underline"),
        ("block_hollow", "Hollow Block"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            styleGroup("Terminal") {
                LabeledContent("Font Family") {
                    TextField("", text: $fontFamily, prompt: Text("System default"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit { apply("font-family", fontFamily) }
                }

                LabeledContent("Font Size") {
                    HStack {
                        Slider(value: $fontSize, in: 8...32, step: 1) { editing in
                            if !editing { apply("font-size", String(Int(fontSize))) }
                        }
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Cursor Style") {
                    Picker("", selection: $cursorStyle) {
                        ForEach(Self.cursorStyles, id: \.value) { style in
                            Text(style.label).tag(style.value)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .onChange(of: cursorStyle) { value in
                        apply("cursor-style", value)
                    }
                }
            }

            styleGroup("Window") {
                LabeledContent("Background Color") {
                    HStack(spacing: 8) {
                        if backgroundColorOverride != nil {
                            Button("Use Theme Color") {
                                backgroundColorOverride = nil
                                apply("background", "")
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }

                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { backgroundColorOverride ?? .black },
                                set: { newValue in
                                    backgroundColorOverride = newValue
                                    apply("background", NSColor(newValue).hexString ?? "")
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }
                }

                LabeledContent("Background Opacity") {
                    HStack {
                        Slider(value: $backgroundOpacity, in: 0.3...1) { editing in
                            if !editing {
                                apply("background-opacity", String(format: "%.2f", backgroundOpacity))
                            }
                        }
                        Text(String(format: "%.2f", backgroundOpacity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Background Blur") {
                    Picker("", selection: $blurMode) {
                        Text("Off").tag("off")
                        Text("Blur Radius").tag("radius")
                        Text("Glass").tag("glass-regular")
                        Text("Glass (Clear)").tag("glass-clear")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .onChange(of: blurMode) { _ in applyBlur() }
                }

                if blurMode == "radius" {
                    LabeledContent("Blur Intensity") {
                        HStack {
                            Slider(value: $blurRadius, in: 1...80, step: 1) { editing in
                                if !editing { applyBlur() }
                            }
                            Text("\(Int(blurRadius))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }

            styleGroup("Sidebar") {
                LabeledContent("Background") {
                    Picker("", selection: $sidebarBackgroundMode) {
                        Text("Match Theme").tag("theme")
                        Text("Match Window").tag("window")
                        Text("Custom Tint").tag("custom")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                    .onChange(of: sidebarBackgroundMode) { _ in saveTint() }
                }

                if sidebarBackgroundMode == "custom" {
                    LabeledContent("Tint") {
                        HStack {
                            Slider(value: $tintOpacity, in: 0...1) { editing in
                                if !editing { saveTint() }
                            }
                            ColorPicker("", selection: $tintColor, supportsOpacity: false)
                                .labelsHidden()
                                .onChange(of: tintColor) { _ in saveTint() }
                        }
                    }
                }

                LabeledContent("Default Width") {
                    HStack {
                        Slider(value: $sidebarWidth, in: 180...480, step: 10) { editing in
                            if !editing {
                                store.set("sidebar-width", String(Int(sidebarWidth)))
                                store.apply(ghostty: ghostty)
                            }
                        }
                        Text("\(Int(sidebarWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                }

                LabeledContent("Divider") {
                    HStack(spacing: 8) {
                        Picker("", selection: $dividerMode) {
                            Text("Default").tag("default")
                            Text("Hidden").tag("hidden")
                            Text("Custom").tag("custom")
                        }
                        .labelsHidden()
                        .frame(maxWidth: 130)
                        .onChange(of: dividerMode) { _ in saveDivider() }

                        if dividerMode == "custom" {
                            ColorPicker("", selection: $dividerColor, supportsOpacity: false)
                                .labelsHidden()
                                .onChange(of: dividerColor) { _ in saveDivider() }
                        }
                    }
                }
            }

            styleGroup("Tab Item") {
                LabeledContent("Style") {
                    Picker("", selection: $tabDensity) {
                        Text("Default").tag("default")
                        Text("Compact").tag("compact")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
            }
        }
        .onAppear { populate() }
    }

    private func styleGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
        }
    }

    private func populate() {
        fontFamily = store.string("font-family") ?? ""
        fontSize = store.double("font-size", default: 13)
        backgroundOpacity = store.double("background-opacity", default: 1)
        cursorStyle = store.string("cursor-style") ?? ""
        backgroundColorOverride = store.string("background")
            .flatMap { NSColor(hex: $0) }
            .map { Color(nsColor: $0) }
        sidebarWidth = store.double("sidebar-width", default: 240)

        switch store.string("background-blur") ?? "false" {
        case "false":
            blurMode = "off"
        case "true":
            blurMode = "radius"
            blurRadius = 20
        case "macos-glass-regular":
            blurMode = "glass-regular"
        case "macos-glass-clear":
            blurMode = "glass-clear"
        case let raw:
            if let value = Double(raw), value > 0 {
                blurMode = "radius"
                blurRadius = value
            } else {
                blurMode = "off"
            }
        }

        let defaults = UserDefaults.standard
        sidebarBackgroundMode = defaults.string(forKey: "SidebarBackgroundMode") ?? "theme"
        tintOpacity = defaults.double(forKey: "SidebarTintOpacity")
        if let hex = defaults.string(forKey: "SidebarTintHex"),
           let color = NSColor(hex: hex) {
            tintColor = Color(nsColor: color)
        }
        dividerMode = defaults.string(forKey: "SidebarDividerMode") ?? "default"
        if let hex = defaults.string(forKey: "SidebarDividerColorHex"),
           let color = NSColor(hex: hex) {
            dividerColor = Color(nsColor: color)
        }
    }

    private func saveDivider() {
        let defaults = UserDefaults.standard
        defaults.set(dividerMode, forKey: "SidebarDividerMode")
        defaults.set(NSColor(dividerColor).hexString ?? "#808080", forKey: "SidebarDividerColorHex")
        NotificationCenter.default.post(
            name: TerminalController.sidebarTintDidChange,
            object: nil
        )
    }

    private func apply(_ key: String, _ value: String) {
        store.set(key, value.isEmpty ? nil : value)
        store.apply(ghostty: ghostty)
    }

    private func applyBlur() {
        let value: String
        switch blurMode {
        case "radius": value = String(Int(blurRadius))
        case "glass-regular": value = "macos-glass-regular"
        case "glass-clear": value = "macos-glass-clear"
        default: value = "false"
        }
        apply("background-blur", value)
    }

    private func saveTint() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarBackgroundMode, forKey: "SidebarBackgroundMode")
        defaults.set(NSColor(tintColor).hexString ?? "#000000", forKey: "SidebarTintHex")
        defaults.set(tintOpacity, forKey: "SidebarTintOpacity")
        NotificationCenter.default.post(
            name: TerminalController.sidebarTintDidChange,
            object: nil
        )
    }
}

/// One theme in the grid: a miniature Phantom window — sidebar strip,
/// prompt line and text skeleton, all in the theme's real colors — with
/// the name centered underneath.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var background: Color { Color(nsColor: theme.background ?? .black) }
    private var foreground: Color { Color(nsColor: theme.foreground ?? .white) }
    private var prompt: Color {
        Color(nsColor: theme.palette[2] ?? theme.foreground ?? .green)
    }
    private var accent: Color {
        Color(nsColor: theme.palette[4] ?? theme.foreground ?? .blue)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                miniWindow

                HStack(spacing: 4) {
                    Text(theme.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    if theme.source == .user {
                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .padding(.trailing, 2)
                    }
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var miniWindow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                skeletonBar(accent.opacity(0.85), width: 22)
                skeletonBar(foreground.opacity(0.25), width: 16)
                skeletonBar(foreground.opacity(0.18), width: 19)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 38, alignment: .topLeading)
            .background(foreground.opacity(0.05))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 3) {
                    Circle()
                        .fill(prompt)
                        .frame(width: 5, height: 5)
                    skeletonBar(foreground.opacity(0.75), width: 42)
                }
                skeletonBar(foreground.opacity(0.35), width: 64)
                skeletonBar(foreground.opacity(0.2), width: 50)

                Spacer(minLength: 0)

                HStack(spacing: 3) {
                    ForEach(Array(theme.previewColors.prefix(7).enumerated()), id: \.offset) { _, color in
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 5, height: 5)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 86)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func skeletonBar(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: width, height: 4)
    }
}

/// A labeled compact color well used by the theme creator grids.
private struct NamedColorWell: View {
    let label: String
    @Binding var color: Color

    var body: some View {
        VStack(spacing: 3) {
            ColorPicker("", selection: $color, supportsOpacity: false)
                .labelsHidden()

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Inline theme creator: every color is labeled with what it applies to,
/// grouped by terminal element. Lives at the bottom of the Appearance
/// screen — no modal.
private struct ThemeCreatorView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore
    @ObservedObject var catalog: ThemeCatalog
    let seed: TerminalTheme?

    @State private var name = ""
    @State private var background = Color(nsColor: NSColor(hex: "#282a36")!)
    @State private var foreground = Color(nsColor: NSColor(hex: "#f8f8f2")!)
    @State private var cursor = Color(nsColor: NSColor(hex: "#f8f8f2")!)
    @State private var selectionBackground = Color(nsColor: NSColor(hex: "#44475a")!)
    @State private var palette: [Color] = Self.draculaPalette.map { Color(nsColor: $0) }
    @State private var savedName: String?

    private static let draculaPalette: [NSColor] = [
        "#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
        "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
        "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
        "#d6acff", "#ff92df", "#a4ffff", "#ffffff",
    ].map { NSColor(hex: $0)! }

    private static let ansiNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
    ]

    private let ansiColumns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 8
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Create Theme")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if let seed {
                    Button("Start from \(seed.name)") { populate(from: seed) }
                        .font(.caption)
                }
            }

            HStack(spacing: 10) {
                TextField("", text: $name, prompt: Text("Theme name"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                livePreview
            }

            colorGroup("Terminal") {
                HStack(spacing: 14) {
                    labeledWell("Background", $background)
                    labeledWell("Text", $foreground)
                    labeledWell("Cursor", $cursor)
                    labeledWell("Selection", $selectionBackground)
                    Spacer()
                }
            }

            colorGroup("ANSI Colors") {
                LazyVGrid(columns: ansiColumns, spacing: 6) {
                    ForEach(0..<8, id: \.self) { index in
                        NamedColorWell(label: Self.ansiNames[index], color: $palette[index])
                    }
                }
            }

            colorGroup("ANSI Bright Colors") {
                LazyVGrid(columns: ansiColumns, spacing: 6) {
                    ForEach(8..<16, id: \.self) { index in
                        NamedColorWell(
                            label: Self.ansiNames[index - 8],
                            color: $palette[index]
                        )
                    }
                }
            }

            HStack {
                if let savedName {
                    Label("Saved and applied: \(savedName)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Save & Apply") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var livePreview: some View {
        HStack(spacing: 4) {
            Text("❯")
                .foregroundStyle(palette[2])
            Text("echo hello")
                .foregroundStyle(foreground)
            Rectangle()
                .fill(cursor)
                .frame(width: 6, height: 12)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func colorGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }

    private func labeledWell(_ label: String, _ binding: Binding<Color>) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: binding, supportsOpacity: false)
                .labelsHidden()
            Text(label)
                .font(.system(size: 11))
        }
    }

    private func populate(from theme: TerminalTheme) {
        name = theme.source == .user ? theme.name : "\(theme.name) Custom"
        if let value = theme.background { background = Color(nsColor: value) }
        if let value = theme.foreground { foreground = Color(nsColor: value) }
        if let value = theme.cursorColor { cursor = Color(nsColor: value) }
        if let value = theme.selectionBackground { selectionBackground = Color(nsColor: value) }
        for index in 0..<16 {
            if let value = theme.palette[index] { palette[index] = Color(nsColor: value) }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var content = ""
        content += "background = \(hex(background))\n"
        content += "foreground = \(hex(foreground))\n"
        content += "cursor-color = \(hex(cursor))\n"
        content += "selection-background = \(hex(selectionBackground))\n"
        for index in 0..<16 {
            content += "palette = \(index)=\(hex(palette[index]))\n"
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: store.themesDirURL, withIntermediateDirectories: true)
        let url = store.themesDirURL.appendingPathComponent(trimmedName)
        try? content.write(to: url, atomically: true, encoding: .utf8)

        store.set("theme", trimmedName)
        store.apply(ghostty: ghostty)
        catalog.reload()
        savedName = trimmedName
    }

    private func hex(_ color: Color) -> String {
        NSColor(color).hexString ?? "#000000"
    }
}
