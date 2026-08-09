import AppKit
import SwiftUI

/// The editor as it sits in the terminal's pane: tab bar on top, text
/// below.
///
/// Reads Phantom's settings and theme here and hands them to the engine as
/// plain values — `CodeTheme`, `CodeEditorConfiguration`. That direction is
/// the whole arrangement: everything under `Engine/` stays ignorant of this
/// app, and this file is where the two meet.
struct EditorPaneView: View {
    @ObservedObject var center: EditorCenter
    @ObservedObject private var palette: ThemePalette = .shared

    @AppStorage(EditorSettings.fontSizeKey) private var fontSize = EditorSettings.defaultFontSize
    @AppStorage(EditorSettings.wrapsLinesKey) private var wrapsLines = false
    @AppStorage(EditorSettings.showsLineNumbersKey) private var showsLineNumbers = true
    @AppStorage(EditorSettings.tabWidthKey) private var tabWidth = EditorSettings.defaultTabWidth
    @AppStorage(EditorSettings.showsMinimapKey) private var showsMinimap = true

    @ObservedObject var search: WorkspaceSearchCenter

    var body: some View {
        content
            // A `safeAreaInset` rather than a `VStack`, so the tab bar's
            // height is *reserved* instead of merely drawn above the text.
            // Stacked, the text view kept its full height and scrolled
            // underneath the bar — the first lines of every file sat behind
            // it, and the bar's transparency made that read as a rendering
            // fault rather than a layout one.
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    EditorTabBar(
                        tabs: center.tabs.tabs,
                        selection: center.tabs.selection,
                        needsDirectory: { center.tabs.needsDirectory(for: $0) },
                        onSelect: { center.select($0) },
                        onClose: { center.close($0) }
                    )
                    Divider()
                }
            }
            .sheet(isPresented: $search.isPresented) {
                WorkspaceSearchView(center: search) { hit in
                    search.dismiss()
                    center.open(URL(fileURLWithPath: hit.path))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let document = center.selectedDocument {
            DocumentView(
                document: document,
                theme: theme,
                configuration: configuration,
                showsMinimap: showsMinimap,
                onSave: { center.saveSelected() },
                onSaveAll: { center.saveAll() },
                onCloseTab: { center.closeSelected() },
                onSearchWorkspace: {
                    search.present(root: (document.url.deletingLastPathComponent()).path)
                }
            )
            .id(document.id)
        } else {
            Color.clear
        }
    }

    /// The terminal's palette, translated for the editor.
    private var theme: CodeTheme {
        EditorTheme.make(from: palette)
    }

    private var configuration: CodeEditorConfiguration {
        CodeEditorConfiguration(
            font: EditorSettings.font(size: fontSize, family: palette.interfaceFontFamily),
            showsLineNumbers: showsLineNumbers,
            wrapsLines: wrapsLines,
            tabWidth: tabWidth,
            insertsSpacesForTab: true,
            highlightsCurrentLine: true
        )
    }
}

/// One document's text surface, plus the banner for a file that changed
/// underneath it.
private struct DocumentView: View {
    @ObservedObject var document: EditorDocument
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration
    let showsMinimap: Bool
    let onSave: () -> Void
    let onSaveAll: () -> Void
    let onCloseTab: () -> Void
    let onSearchWorkspace: () -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                conflictBanner
            }

            CodeTextView(
                text: $document.text,
                language: document.language,
                theme: theme,
                configuration: configuration,
                onEdit: { document.markEdited() },
                showsMinimap: showsMinimap,
                onSave: onSave,
                onSaveAll: onSaveAll,
                onCloseTab: onCloseTab,
                onSearchWorkspace: onSearchWorkspace
            )
        }
    }

    /// Shown only when both sides have changes, which is the one case that
    /// can't be resolved without asking. A clean buffer reloads silently.
    private var conflictBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("This file changed on disk while you were editing it.")
                .font(palette.font(size: 11))

            Spacer(minLength: 0)

            Button("Keep Mine") { document.markEdited() }
                .font(palette.font(size: 11))
            Button("Reload") { document.revert() }
                .font(palette.font(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.15))
    }
}
