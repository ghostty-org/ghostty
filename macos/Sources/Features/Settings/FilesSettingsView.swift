import SwiftUI

/// The editor's own preferences.
///
/// Separate from Appearance because these are about *reading and editing a
/// file*, not about how the app looks — the editor's font is the one you
/// want big enough to work in, which is rarely the same answer as the
/// terminal's.
struct FilesSettingsView: View {
    @AppStorage(FileOpenAction.defaultsKey)
    private var clickAction = FileOpenAction.builtInEditor.rawValue

    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.fontFamilyKey) private var fontFamily = ""
    @AppStorage(EditorSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(EditorSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = EditorSettings.defaultTabWidth

    @State private var isChoosingFont = false

    var body: some View {
        Form {
            Section {
                Picker("Clicking a File", selection: $clickAction) {
                    ForEach(FileOpenAction.allCases) { action in
                        Text(action.title).tag(action.rawValue)
                    }
                }
            } header: {
                Text("Opening")
            } footer: {
                Text("Whatever you pick here, the other ways stay available from a file's context menu — so \"Open With…\" can still send this one file to vim or to another app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text") {
                LabeledContent("Font") {
                    Button(fontFamily.isEmpty ? "System Monospace" : fontFamily) {
                        isChoosingFont = true
                    }
                }

                LabeledContent("Size") {
                    HStack(spacing: 8) {
                        Slider(value: $fontSize, in: 9...24, step: 1)
                            .frame(width: 180)
                        Text("\(Int(fontSize))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Picker("Tab Width", selection: $tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
            }

            Section {
                Toggle("Wrap Long Lines", isOn: $wrapsLines)
                    .toggleStyle(.switch)
                Toggle("Show Line Numbers", isOn: $showsLineNumbers)
                    .toggleStyle(.switch)
            } header: {
                Text("Display")
            } footer: {
                Text("Files larger than \(sizeLimit) or containing binary data open in an external app instead — there is nothing readable to show, and loading them would stall the window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Files")
        .sheet(isPresented: $isChoosingFont) {
            // The terminal preview, because that is what the editor is:
            // monospaced code on the theme's background. Reusing the same
            // picker the terminal and interface fonts already use keeps
            // one search-and-preview instead of three.
            FontPickerView(
                currentFamily: fontFamily.isEmpty ? nil : fontFamily,
                preview: .terminal,
                onPick: { family in
                    fontFamily = family ?? ""
                    isChoosingFont = false
                },
                onCancel: { isChoosingFont = false }
            )
        }
    }

    private var sizeLimit: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(FileOpenGuard.maxBytes),
            countStyle: .file
        )
    }
}
