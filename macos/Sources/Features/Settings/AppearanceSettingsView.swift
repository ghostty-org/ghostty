import SwiftUI
import UniformTypeIdentifiers

/// Theme management: browse built-in and imported themes with live
/// previews, import theme files, and build custom themes locally.
struct AppearanceSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @StateObject private var catalog: ThemeCatalog

    @State private var search = ""
    @State private var isCustomizing = false
    @State private var customizerSeed: TerminalTheme?

    init(ghostty: Ghostty.App, store: GuiConfigStore) {
        self.ghostty = ghostty
        self.store = store
        _catalog = StateObject(wrappedValue: ThemeCatalog(userThemesDir: store.themesDirURL))
    }

    private var currentTheme: String {
        store.string("theme") ?? ""
    }

    private var filtered: [TerminalTheme] {
        guard !search.isEmpty else { return catalog.themes }
        return catalog.themes.filter {
            $0.name.localizedCaseInsensitiveContains(search)
        }
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
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 170), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filtered) { theme in
                            ThemeCard(
                                theme: theme,
                                isSelected: theme.name == currentTheme
                            ) {
                                applyTheme(theme)
                            }
                            .contextMenu {
                                if theme.source == .user {
                                    Button("Edit…") {
                                        customizerSeed = theme
                                        isCustomizing = true
                                    }
                                    Button("Delete", role: .destructive) {
                                        deleteTheme(theme)
                                    }
                                } else {
                                    Button("Duplicate as Custom…") {
                                        customizerSeed = theme
                                        isCustomizing = true
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Appearance")
        .onAppear { catalog.loadIfNeeded() }
        .sheet(isPresented: $isCustomizing) {
            ThemeCustomizerView(
                ghostty: ghostty,
                store: store,
                catalog: catalog,
                seed: customizerSeed
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("", text: $search, prompt: Text("Search \(catalog.themes.count) themes"))
                .textFieldStyle(.plain)

            if !currentTheme.isEmpty {
                Button("Reset Theme") {
                    store.set("theme", nil)
                    store.apply(ghostty: ghostty)
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Button("Import…") { importThemes() }

            Button {
                customizerSeed = catalog.themes.first { $0.name == currentTheme }
                isCustomizing = true
            } label: {
                Label("New Theme", systemImage: "plus")
            }
        }
        .padding(10)
    }

    private func applyTheme(_ theme: TerminalTheme) {
        store.set("theme", theme.name)
        store.apply(ghostty: ghostty)
    }

    private func deleteTheme(_ theme: TerminalTheme) {
        guard theme.source == .user else { return }
        try? FileManager.default.removeItem(at: theme.url)
        if currentTheme == theme.name {
            store.set("theme", nil)
            store.apply(ghostty: ghostty)
        }
        catalog.reload()
    }

    /// Copies picked theme files into the user themes directory.
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

/// One theme in the grid: a mini terminal mock plus the palette strip.
private struct ThemeCard: View {
    let theme: TerminalTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview

                HStack(spacing: 4) {
                    Text(theme.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if theme.source == .user {
                        Image(systemName: "person.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .help("Custom theme")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: theme.background ?? .black)

            VStack(alignment: .leading, spacing: 2) {
                Text("$ ghostty --theme")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Color(nsColor: theme.foreground ?? .white))

                HStack(spacing: 3) {
                    ForEach(Array(theme.previewColors.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(nsColor: color))
                            .frame(width: 12, height: 8)
                    }
                }
            }
            .padding(8)
        }
        .frame(height: 56)
    }
}

/// Local theme editor: name, core colors and the 16 ANSI palette
/// entries, saved as a theme file in the user themes directory.
private struct ThemeCustomizerView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore
    @ObservedObject var catalog: ThemeCatalog

    /// Starting point: an existing theme to copy values from, or nil for
    /// a plain dark seed.
    let seed: TerminalTheme?

    @Environment(\.dismiss) private var dismiss

    @State private var name = "My Theme"
    @State private var background = Color(nsColor: NSColor(hex: "#1d1f21")!)
    @State private var foreground = Color(nsColor: NSColor(hex: "#c5c8c6")!)
    @State private var cursor = Color(nsColor: NSColor(hex: "#c5c8c6")!)
    @State private var selectionBackground = Color(nsColor: NSColor(hex: "#373b41")!)
    @State private var palette: [Color] = Self.defaultPalette.map { Color(nsColor: $0) }

    private static let defaultPalette: [NSColor] = [
        "#282a2e", "#a54242", "#8c9440", "#de935f",
        "#5f819d", "#85678f", "#5e8d87", "#707880",
        "#373b41", "#cc6666", "#b5bd68", "#f0c674",
        "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
    ].map { NSColor(hex: $0)! }

    private static let paletteLabels = [
        "Black", "Red", "Green", "Yellow",
        "Blue", "Magenta", "Cyan", "White",
        "Bright Black", "Bright Red", "Bright Green", "Bright Yellow",
        "Bright Blue", "Bright Magenta", "Bright Cyan", "Bright White",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("", text: $name, prompt: Text("My Theme"))
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section("Colors") {
                    ColorPicker("Background", selection: $background, supportsOpacity: false)
                    ColorPicker("Foreground", selection: $foreground, supportsOpacity: false)
                    ColorPicker("Cursor", selection: $cursor, supportsOpacity: false)
                    ColorPicker("Selection", selection: $selectionBackground, supportsOpacity: false)
                }

                Section("ANSI Palette") {
                    ForEach(0..<16, id: \.self) { index in
                        ColorPicker(
                            Self.paletteLabels[index],
                            selection: $palette[index],
                            supportsOpacity: false
                        )
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save & Apply") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 380, height: 560)
        .onAppear { populate() }
    }

    private func populate() {
        guard let seed else { return }
        name = seed.source == .user ? seed.name : "\(seed.name) Custom"
        if let value = seed.background { background = Color(nsColor: value) }
        if let value = seed.foreground { foreground = Color(nsColor: value) }
        if let value = seed.cursorColor { cursor = Color(nsColor: value) }
        if let value = seed.selectionBackground { selectionBackground = Color(nsColor: value) }
        for index in 0..<16 {
            if let value = seed.palette[index] { palette[index] = Color(nsColor: value) }
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
    }

    private func hex(_ color: Color) -> String {
        NSColor(color).hexString ?? "#000000"
    }
}
