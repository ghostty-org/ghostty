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
    @ObservedObject private var lsp: LSPCenter = .shared

    /// What the server answered for "find references", shown in its own
    /// sheet. Kept here rather than in the document view because following
    /// one of them opens a *different* document, which is this view's job.
    @State private var references: [LSPReference] = []

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
            .sheet(isPresented: Binding(
                get: { !references.isEmpty },
                set: { if !$0 { references = [] } }
            )) {
                ReferencesView(references: references) { reference in
                    references = []
                    center.open(
                        URL(fileURLWithPath: reference.location.path),
                        reveal: reference.location.range
                    )
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
                lsp: lsp,
                onSave: { center.saveSelected() },
                onSaveAll: { center.saveAll() },
                onCloseTab: { center.closeSelected() },
                onSearchWorkspace: {
                    search.present(root: (document.url.deletingLastPathComponent()).path)
                },
                onOpenLocation: { location in
                    center.open(URL(fileURLWithPath: location.path), reveal: location.range)
                },
                onShowReferences: { found in
                    references = found.map(LSPReference.init)
                }
            )
            .id(document.id)
        } else {
            Color.clear
        }
    }

    /// The identifier the cursor is inside, used to prefill the rename
    /// field — retyping a name in full to change one character of it is the
    /// kind of friction that stops a feature from being used.
    static func identifier(at offset: Int, in text: String) -> String {
        let characters = Array(text)
        guard !characters.isEmpty else { return "" }

        let isPart: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }

        // Back one when the cursor sits just past the end of a word, which
        // is exactly where it lands after double-clicking or typing it.
        var start = min(offset, characters.count - 1)
        if start > 0, !isPart(characters[start]) { start -= 1 }
        guard isPart(characters[start]) else { return "" }

        var end = start
        while start > 0, isPart(characters[start - 1]) { start -= 1 }
        while end + 1 < characters.count, isPart(characters[end + 1]) { end += 1 }
        return String(characters[start...end])
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
    @ObservedObject var lsp: LSPCenter
    let onSave: () -> Void
    let onSaveAll: () -> Void
    let onCloseTab: () -> Void
    let onSearchWorkspace: () -> Void
    let onOpenLocation: (LSPLocation) -> Void
    let onShowReferences: ([LSPLocation]) -> Void

    @ObservedObject private var palette: ThemePalette = .shared

    @State private var renamingAt: Int?
    @State private var newName = ""

    /// Where a rename or a jump reports it found nothing, since silence
    /// reads as the feature being broken.
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            if document.hasConflict {
                conflictBanner
            }

            if let missing = missingServer {
                missingServerBanner(missing)
            }

            CodeTextView(
                text: $document.text,
                language: document.language,
                theme: theme,
                configuration: configuration,
                onEdit: {
                    document.markEdited()
                    lsp.didChange(path: document.url.path, text: document.text)
                },
                showsMinimap: showsMinimap,
                underlines: underlines,
                hoverProvider: { offset in
                    await lsp.hover(path: document.url.path, position: position(at: offset))
                },
                completionProvider: { offset in
                    await lsp.completions(
                        path: document.url.path,
                        position: position(at: offset)
                    ).map(\.insertText)
                },
                reveal: revealRange,
                onJumpToDefinition: { offset in jump(from: offset) },
                onRename: { offset in
                    newName = EditorPaneView.identifier(at: offset, in: document.text)
                    renamingAt = offset
                },
                onFindReferences: { offset in findReferences(from: offset) },
                onFormat: { format() },
                onSave: onSave,
                onSaveAll: onSaveAll,
                onCloseTab: onCloseTab,
                onSearchWorkspace: onSearchWorkspace
            )
            .onAppear { lsp.didOpen(path: document.url.path, text: document.text) }
            .onDisappear { lsp.didClose(path: document.url.path) }
        }
        .sheet(isPresented: Binding(
            get: { renamingAt != nil },
            set: { if !$0 { renamingAt = nil } }
        )) {
            renameSheet
        }
        .alert(
            notice ?? "",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        }
    }

    /// The range the engine should jump to, translated out of the
    /// protocol's coordinates.
    private var revealRange: (id: String, range: NSRange)? {
        guard let reveal = document.reveal,
              let range = LSPTextCoordinates.range(of: reveal.range, in: document.text as NSString)
        else { return nil }
        return (id: reveal.id, range: range)
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Symbol")
                .font(palette.font(size: 13).weight(.semibold))

            TextField("New name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .font(palette.font(size: 12))
                .frame(width: 260)
                .onSubmit { commitRename() }

            HStack {
                Spacer()
                Button("Cancel") { renamingAt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commitRename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func commitRename() {
        guard let offset = renamingAt else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        renamingAt = nil
        newName = ""
        guard !name.isEmpty else { return }
        rename(at: offset, to: name)
    }

    /// The diagnostics for this file, as ranges the engine can underline.
    ///
    /// Converted here rather than in the engine: the engine is meant to
    /// know nothing about language servers, and a range with a colour is
    /// the smallest thing that carries the meaning across.
    private var underlines: [(range: NSRange, color: NSColor)] {
        let text = document.text as NSString
        return (lsp.diagnostics[document.url.path] ?? []).compactMap { diagnostic in
            guard let range = LSPTextCoordinates.range(of: diagnostic.range, in: text),
                  range.length > 0
            else { return nil }

            let color: NSColor
            switch diagnostic.severity {
            case .error: color = .systemRed
            case .warning: color = .systemOrange
            case .information, .hint: color = .systemBlue
            }
            return (range, color)
        }
    }

    private func position(at offset: Int) -> LSPPosition {
        LSPTextCoordinates.position(at: offset, in: document.text as NSString)
    }

    private func jump(from offset: Int) {
        Task {
            let found = await lsp.definition(path: document.url.path, position: position(at: offset))
            guard let first = found.first else {
                notice = "No definition found."
                return
            }
            onOpenLocation(first)
        }
    }

    private func findReferences(from offset: Int) {
        Task {
            let found = await lsp.references(path: document.url.path, position: position(at: offset))
            guard !found.isEmpty else {
                notice = "No references found."
                return
            }
            onShowReferences(found)
        }
    }

    private func format() {
        Task {
            let edits = await lsp.formatting(
                path: document.url.path,
                tabSize: configuration.tabWidth,
                insertSpaces: configuration.insertsSpacesForTab
            )
            guard !edits.isEmpty else {
                notice = "The language server returned no formatting."
                return
            }
            document.text = LSPTextEdit.apply(edits, to: document.text)
            document.markEdited()
        }
    }

    /// Applies a rename across every file the server named.
    ///
    /// Files that are not open are edited on disk directly — a rename that
    /// only touched the tabs you happened to have open would leave the
    /// project broken in exactly the places you were not looking.
    private func rename(at offset: Int, to name: String) {
        Task {
            let byFile = await lsp.rename(
                path: document.url.path,
                position: position(at: offset),
                to: name
            )
            guard !byFile.isEmpty else {
                notice = "This symbol can't be renamed here."
                return
            }

            var changed = 0
            for (path, edits) in byFile {
                if path == document.url.path {
                    document.text = LSPTextEdit.apply(edits, to: document.text)
                    document.markEdited()
                } else if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
                    let updated = LSPTextEdit.apply(edits, to: existing)
                    try? updated.write(toFile: path, atomically: true, encoding: .utf8)
                }
                changed += 1
            }
            notice = "Renamed in \(changed) file\(changed == 1 ? "" : "s")."
        }
    }

    /// The server this file's language would use, when it isn't installed.
    ///
    /// Worth saying out loud: without it, every language feature simply
    /// does nothing, and "nothing happens" is indistinguishable from a
    /// broken editor.
    private var missingServer: LSPServerDefinition? {
        guard let expected = LSPServerRegistry.server(forPath: document.url.path) else { return nil }
        return lsp.missing.first { $0.command == expected.command }
    }

    private func missingServerBanner(_ server: LSPServerDefinition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            Text("\(server.displayName) isn't installed — language features are off.")
                .font(palette.font(size: 11))

            Spacer(minLength: 0)

            Text(server.installHint)
                .font(palette.font(size: 11).monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12))
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
