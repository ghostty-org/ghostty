import SwiftUI

/// Root of the settings window: section list on the left, the selected
/// section's form on the right.
struct SettingsRootView: View {
    let ghostty: Ghostty.App

    @ObservedObject private var store = GuiConfigStore.shared

    enum SettingsSection: String, CaseIterable, Identifiable {
        case general
        case appearance
        case sidebar

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .sidebar: return "Sidebar"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .sidebar: return "sidebar.left"
            }
        }
    }

    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection {
            case .general:
                GeneralSettingsView(ghostty: ghostty, store: store)
            case .appearance:
                AppearanceSettingsView(ghostty: ghostty, store: store)
            case .sidebar:
                SidebarSettingsView(ghostty: ghostty, store: store)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

/// Basic terminal options: font, opacity, cursor.
struct GeneralSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var fontFamily: String = ""
    @State private var fontSize: Double = 13
    @State private var backgroundOpacity: Double = 1
    @State private var blurRadius: Double = 0
    @State private var backgroundColorOverride: Color?
    @State private var cursorStyle: String = ""

    private static let cursorStyles: [(value: String, label: String)] = [
        ("", "Default"),
        ("block", "Block"),
        ("bar", "Bar"),
        ("underline", "Underline"),
        ("block_hollow", "Hollow Block"),
    ]

    var body: some View {
        Form {
            Section("Font") {
                LabeledContent("Family") {
                    TextField("", text: $fontFamily, prompt: Text("System default"))
                        .labelsHidden()
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onSubmit { apply("font-family", fontFamily) }
                }

                LabeledContent("Size") {
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
            }

            Section("Window") {
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
                                apply("background-opacity", formatOpacity(backgroundOpacity))
                            }
                        }
                        Text(formatOpacity(backgroundOpacity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                LabeledContent("Background Blur") {
                    HStack {
                        Slider(value: $blurRadius, in: 0...40, step: 1) { editing in
                            if !editing {
                                apply(
                                    "background-blur",
                                    blurRadius <= 0 ? "false" : String(Int(blurRadius))
                                )
                            }
                        }
                        Text(blurRadius <= 0 ? "Off" : "\(Int(blurRadius))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Picker("Cursor Style", selection: $cursorStyle) {
                    ForEach(Self.cursorStyles, id: \.value) { style in
                        Text(style.label).tag(style.value)
                    }
                }
                .onChange(of: cursorStyle) { value in
                    apply("cursor-style", value)
                }
            }

            Section {
                LabeledContent("Config File") {
                    Button("Open in Editor") {
                        ghostty.openConfig()
                    }
                }
            } footer: {
                Text("Settings changed here are stored in \(GuiConfigStore.fileName) and included from your config file. Hand-written options stay untouched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .onAppear { populate() }
    }

    private func populate() {
        fontFamily = store.string("font-family") ?? ""
        fontSize = store.double("font-size", default: 13)
        backgroundOpacity = store.double("background-opacity", default: 1)
        let rawBlur = store.string("background-blur") ?? "false"
        if rawBlur == "true" {
            blurRadius = 20
        } else {
            blurRadius = Double(rawBlur) ?? 0
        }
        backgroundColorOverride = store.string("background")
            .flatMap { NSColor(hex: $0) }
            .map { Color(nsColor: $0) }
        cursorStyle = store.string("cursor-style") ?? ""
    }

    private func apply(_ key: String, _ value: String) {
        store.set(key, value.isEmpty ? nil : value)
        store.apply(ghostty: ghostty)
    }

    private func formatOpacity(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Options for the tab sidebar itself.
struct SidebarSettingsView: View {
    let ghostty: Ghostty.App
    @ObservedObject var store: GuiConfigStore

    @State private var sidebarEnabled: Bool = false
    @State private var sidebarWidth: Double = 240

    @AppStorage("SidebarShowDirectory") private var showDirectory = true
    @AppStorage("SidebarShowGitBranch") private var showGitBranch = true
    @AppStorage("SidebarShowGitStatus") private var showGitStatus = true
    @AppStorage("SidebarShowPullRequest") private var showPullRequest = true
    @AppStorage("SidebarRestoreAgentSessions") private var restoreAgentSessions = true
    @AppStorage("SidebarNewTabPosition") private var newTabPosition = "end"

    @State private var tintColor: Color = .black
    @State private var tintOpacity: Double = 0

    var body: some View {
        Form {
            Section {
                Toggle("Show Sidebar", isOn: $sidebarEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: sidebarEnabled) { value in
                        store.set("sidebar", value ? "true" : "false")
                        store.apply(ghostty: ghostty)
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
            } footer: {
                Text("The sidebar toggle applies to new windows. Dragging the divider overrides the default width.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("New Terminal Position", selection: $newTabPosition) {
                    Text("Bottom of List").tag("end")
                    Text("Top of List").tag("start")
                }
            }

            Section {
                LabeledContent("Sidebar Tint") {
                    HStack {
                        Slider(value: $tintOpacity, in: 0...0.9) { editing in
                            if !editing { saveTint() }
                        }

                        ColorPicker("", selection: $tintColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: tintColor) { _ in saveTint() }

                        Text(tintOpacity <= 0.001 ? "Off" : String(format: "%.0f%%", tintOpacity * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Backgrounds are layered: the window background (General) is the base for every pane, the terminal adds its theme background, and the sidebar adds this tint. Keep it at zero so the sidebar matches the window exactly, or raise it with a dark (or light) color to set the sidebar apart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tab Info") {
                Toggle("Show Working Directory", isOn: $showDirectory)
                    .toggleStyle(.switch)
                Toggle("Show Git Branch", isOn: $showGitBranch)
                    .toggleStyle(.switch)
                Toggle("Show Uncommitted Changes", isOn: $showGitStatus)
                    .toggleStyle(.switch)
                Toggle("Show Open Pull Request", isOn: $showPullRequest)
                    .toggleStyle(.switch)
            }

            Section {
                Toggle("Resume Agent Sessions on Restore", isOn: $restoreAgentSessions)
                    .toggleStyle(.switch)
            } footer: {
                Text("When windows are restored, tabs that were running a Claude Code session run `claude --continue` to pick the conversation back up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sidebar")
        .onAppear {
            sidebarEnabled = store.bool("sidebar")
            sidebarWidth = store.double("sidebar-width", default: 240)

            let defaults = UserDefaults.standard
            tintOpacity = defaults.double(forKey: "SidebarTintOpacity")
            if let hex = defaults.string(forKey: "SidebarTintHex"),
               let color = NSColor(hex: hex) {
                tintColor = Color(nsColor: color)
            }
        }
    }

    private func saveTint() {
        let defaults = UserDefaults.standard
        defaults.set(NSColor(tintColor).hexString ?? "#000000", forKey: "SidebarTintHex")
        defaults.set(tintOpacity, forKey: "SidebarTintOpacity")
        NotificationCenter.default.post(
            name: TerminalController.sidebarTintDidChange,
            object: nil
        )
    }
}
