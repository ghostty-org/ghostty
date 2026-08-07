import AppKit
import SwiftUI

/// A dedicated window for picking a font by family, with a live preview —
/// so choosing one doesn't depend on already knowing its exact name, the
/// problem with the free-text field it replaces.
///
/// Shared by two unrelated settings: the terminal's own font
/// (`font-family`, a real Ghostty config key) and Phantom's interface font
/// (`AppFont`, a Phantom-only preference — see `ThemedChrome.swift`). The
/// caller picks which preview to render and what happens with the result;
/// this window doesn't know or care which setting it's serving.
@MainActor
final class FontPickerWindowController: NSWindowController {
    static let shared = FontPickerWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("PhantomFontPicker")
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// - Parameter onPick: called with the chosen family, or `nil` for
    ///   "System Default." Not called on cancel.
    func show(
        title: String,
        currentFamily: String?,
        preview: FontPickerView.PreviewKind,
        onPick: @escaping (String?) -> Void
    ) {
        window?.title = title
        window?.contentView = NSHostingView(
            rootView: FontPickerView(
                currentFamily: currentFamily,
                preview: preview,
                onPick: { [weak self] family in
                    if let family { RecentFontFamilies.record(family, for: preview) }
                    onPick(family)
                    self?.window?.close()
                },
                onCancel: { [weak self] in self?.window?.close() }
            ).themedChrome()
        )
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The last few families picked in each field, most recent first —
/// tracked separately per field since a terminal pick and an interface
/// pick answer different questions (monospaced or not).
private enum RecentFontFamilies {
    static let limit = 6

    private static func key(for preview: FontPickerView.PreviewKind) -> String {
        switch preview {
        case .terminal: return "RecentTerminalFontFamilies"
        case .interface: return "RecentInterfaceFontFamilies"
        }
    }

    static func load(for preview: FontPickerView.PreviewKind) -> [String] {
        UserDefaults.standard.stringArray(forKey: key(for: preview)) ?? []
    }

    static func record(_ family: String, for preview: FontPickerView.PreviewKind) {
        var recents = load(for: preview)
        recents.removeAll { $0 == family }
        recents.insert(family, at: 0)
        if recents.count > limit { recents.removeLast(recents.count - limit) }
        UserDefaults.standard.set(recents, forKey: key(for: preview))
    }
}

struct FontPickerView: View {
    enum PreviewKind {
        case terminal
        case interface
    }

    let currentFamily: String?
    let preview: PreviewKind
    let onPick: (String?) -> Void
    let onCancel: () -> Void

    @State private var search = ""
    @State private var selected: String?
    @State private var families: [String] = []
    @State private var recents: [String] = []

    /// Terminal columns depend on every glyph being the same width, so a
    /// proportional family breaks alignment — the list defaults to
    /// monospaced families for that field, with an escape hatch for a
    /// nerd-font variant macOS doesn't report as fixed-pitch.
    @State private var monospaceOnly = true

    private var matchingFamilies: [String] {
        let base = (preview == .terminal && monospaceOnly)
            ? families.filter(Self.isFixedPitch)
            : families
        guard !search.isEmpty else { return base }
        return base.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    /// Recents, in most-recent-first order, restricted to whatever the
    /// current filter and search still allow through — a recent pick that
    /// no longer matches (monospace toggled on, a search typed) drops out
    /// rather than sitting in a section that contradicts the filter above.
    private var recentFamilies: [String] {
        let matching = Set(matchingFamilies)
        return recents.filter { matching.contains($0) }
    }

    /// Everything else, with whatever surfaced in "Recent" removed so a
    /// family never appears twice in the same list.
    private var otherFamilies: [String] {
        let recentSet = Set(recentFamilies)
        return matchingFamilies.filter { !recentSet.contains($0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("", text: $search, prompt: Text("Search \(families.count) fonts"))
                        .textFieldStyle(.plain)
                }
                .padding(10)

                if preview == .terminal {
                    Toggle("Monospaced only", isOn: $monospaceOnly)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }

                Divider()

                List(selection: $selected) {
                    if !recentFamilies.isEmpty {
                        Section("Recent") {
                            ForEach(recentFamilies, id: \.self) { family in
                                Text(family).lineLimit(1).tag(family)
                            }
                        }
                        Section("All Fonts") {
                            ForEach(otherFamilies, id: \.self) { family in
                                Text(family).lineLimit(1).tag(family)
                            }
                        }
                    } else {
                        ForEach(otherFamilies, id: \.self) { family in
                            Text(family).lineLimit(1).tag(family)
                        }
                    }
                }
                .listStyle(.plain)
            }
            .frame(width: 240)

            Divider()

            VStack(spacing: 0) {
                previewPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)

                Divider()

                HStack {
                    Button("System Default") { onPick(nil) }
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Select") { onPick(selected) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected == nil)
                }
                .padding(12)
            }
        }
        .frame(width: 640, height: 460)
        .onAppear {
            families = NSFontManager.shared.availableFontFamilies.sorted()
            selected = currentFamily
            recents = RecentFontFamilies.load(for: preview)
        }
    }

    @ViewBuilder
    private var previewPanel: some View {
        switch preview {
        case .terminal:
            FontPreviewTerminal(family: selected)
        case .interface:
            FontPreviewInterface(family: selected)
        }
    }

    private static func isFixedPitch(_ family: String) -> Bool {
        NSFont(name: family, size: 13)?.isFixedPitch ?? false
    }
}

/// A simulated terminal in the candidate font, colored by the theme in
/// use — the same idea as the theme creator's live preview, so a font is
/// judged against real-looking output rather than a sample alphabet line.
private struct FontPreviewTerminal: View {
    let family: String?

    @ObservedObject private var palette: ThemePalette = .shared

    private var font: Font {
        family.map { Font.custom($0, size: 13) } ?? .system(size: 13, design: .monospaced)
    }

    private func color(_ ansi: Int) -> Color {
        guard palette.colors.indices.contains(ansi) else { return .primary }
        return Color(nsColor: palette.colors[ansi])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("❯").foregroundStyle(color(2))
                Text("ls -la").foregroundStyle(.primary)
            }
            HStack(spacing: 10) {
                Text("src").foregroundStyle(color(4))
                Text("README.md").foregroundStyle(.primary)
                Text("bin -> ../usr/bin").foregroundStyle(color(6))
            }
            Text("warning: 2 unused imports").foregroundStyle(color(3))
            Text("error: build failed (3 errors)").foregroundStyle(color(1))
            HStack(spacing: 4) {
                Text("❯").foregroundStyle(color(2))
                Text("git status").foregroundStyle(.primary)
            }
        }
        .font(font)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(palette.background.map { Color(nsColor: $0) } ?? Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A slice of real Phantom chrome — labels, a row, a button — in the
/// candidate font, so an interface pick is judged against the controls it
/// will actually change.
private struct FontPreviewInterface: View {
    let family: String?

    private var font: Font? {
        family.map { .custom($0, size: NSFont.systemFontSize) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.title2.weight(.semibold))
            Text("Pick how Phantom's own windows read — Settings, the theme browser, About.")
                .foregroundStyle(.secondary)
            LabeledContent("Font Family") {
                Text(family ?? "System Default")
            }
            LabeledContent("Sidebar Width") {
                Text("240 pt")
            }
            Button("Save & Apply") {}
                .disabled(true)
        }
        .font(font)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}
