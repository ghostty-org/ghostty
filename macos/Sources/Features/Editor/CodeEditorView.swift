import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import CodeEditTextView
import SwiftTreeSitter
import SwiftUI

/// A lightweight native source editor surface for editable OMG documents.
///
/// Document loading and persistence intentionally remain with the caller. The
/// editor owns presentation state such as the current selection and find bar.
struct CodeEditorView: View {
    @Binding var text: String
    @ObservedObject private var settings = OhMyGhosttySettings.shared

    let fileURL: URL?
    var diffLines: [Int: Bool] = [:]
    var additionalCoordinators: [TextViewCoordinator] = []
    var isEditable = true
    var isActive = true
    var isPreview = false
    var isSurfaceFocused: () -> Bool = { true }
    var terminalBackground: NSColor = .textBackgroundColor
    var terminalBackgroundOpacity: Double = 1.0
    var terminalForeground: NSColor = .textColor
    var terminalTheme: EditorTheme?
    var wordWrapOverride: Bool?
    var onFocus: () -> Void = {}
    var onSave: () -> Void = {}
    var onClose: () -> Void = {}
    var onOpen: () -> Void = {}
    var onNextDocument: () -> Void = {}
    var onPreviousDocument: () -> Void = {}
    var onSaveAll: () -> Void = {}
    var onHide: () -> Void = {}

    @State private var editorState = SourceEditorState()
    @State private var editorCoordinator = EditorCoordinator()
    // Only the popup observes completion changes. Rebuilding the native editor
    // for every candidate/selection update feeds cursor bindings back into it.
    @State private var completionState = CompletionState()
    @State private var isFindVisible = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = false
    @State private var barMode: BarMode = .find
    @State private var cachedSearchMatches: [NSRange] = []
    @State private var isFindFocused = false

    init(
        text: Binding<String>,
        fileURL: URL?,
        diffLines: [Int: Bool] = [:],
        additionalCoordinators: [TextViewCoordinator] = [],
        isEditable: Bool = true,
        isActive: Bool = true,
        isPreview: Bool = false,
        isSurfaceFocused: @escaping () -> Bool = { true },
        terminalBackground: NSColor = .textBackgroundColor,
        terminalBackgroundOpacity: Double = 1.0,
        terminalForeground: NSColor = .textColor,
        terminalTheme: EditorTheme? = nil,
        wordWrapOverride: Bool? = nil,
        onFocus: @escaping () -> Void = {},
        onSave: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onOpen: @escaping () -> Void = {},
        onNextDocument: @escaping () -> Void = {},
        onPreviousDocument: @escaping () -> Void = {},
        onSaveAll: @escaping () -> Void = {},
        onHide: @escaping () -> Void = {}
    ) {
        self._text = text
        self.fileURL = fileURL
        self.diffLines = diffLines
        self.additionalCoordinators = additionalCoordinators
        self.isEditable = isEditable
        self.isActive = isActive
        self.isPreview = isPreview
        self.isSurfaceFocused = isSurfaceFocused
        self.terminalBackground = terminalBackground
        self.terminalBackgroundOpacity = terminalBackgroundOpacity
        self.terminalForeground = terminalForeground
        self.terminalTheme = terminalTheme
        self.wordWrapOverride = wordWrapOverride
        self.onFocus = onFocus
        self.onSave = onSave
        self.onClose = onClose
        self.onOpen = onOpen
        self.onNextDocument = onNextDocument
        self.onPreviousDocument = onPreviousDocument
        self.onSaveAll = onSaveAll
        self.onHide = onHide
    }

    var body: some View {
        SourceEditor(
            $text,
            language: editorCoordinator.language(fileURL: fileURL, text: text),
            configuration: editorConfiguration,
            state: $editorState,
            highlightProviders: editorCoordinator.highlightProviders,
            coordinators: [editorCoordinator] + additionalCoordinators
        )
        .clipped()
        .overlay(alignment: .topTrailing) {
            if isActive, isFindVisible {
                findBar
                    .padding(8)
            }
        }
        .background(Color.clear)
        .onAppear {
            editorCoordinator.setDiffLines(diffLines)
            editorCoordinator.setCompletionState(completionState)
            editorCoordinator.setFileURL(fileURL)
            editorCoordinator.setIsPreview(isPreview)
            configureCommands()
            editorCoordinator.setActive(isActive)
        }
        .onChange(of: diffLines) { editorCoordinator.setDiffLines($0) }
        .onChange(of: isActive) { isActive in
            configureCommands()
            editorCoordinator.setActive(isActive)
            if !isActive {
                isFindVisible = false
                completionState.dismiss()
            }
        }
        .onChange(of: isPreview) { isPreview in
            editorCoordinator.setIsPreview(isPreview)
        }
        .onChange(of: settings.editorKeymapPreset) { _ in configureCommands() }
        .onChange(of: resolvedTheme) { _ in editorCoordinator.refreshBackground() }
        .onChange(of: editorSettings) { _ in editorCoordinator.refreshBackground() }
        .onChange(of: findText) { _ in
            refreshSearchMatches()
            guard isFindVisible, barMode != .goToLine else { return }
            if let first = cachedSearchMatches.first {
                editorCoordinator.select(first, focusEditor: false)
            }
        }
        .onChange(of: text) { _ in refreshSearchMatches() }
        .onChange(of: caseSensitive) { _ in refreshSearchMatches() }
        .onChange(of: isFindVisible) { _ in refreshSearchMatches() }
        .onChange(of: barMode) { _ in refreshSearchMatches() }
    }

    private var findBar: some View {
        NativeEditorFindBar(
            state: .init(
                query: findText, replacement: replaceText, summary: matchSummary,
                isReplace: barMode == .replace, isGoToLine: barMode == .goToLine,
                isCaseSensitive: caseSensitive, shouldFocus: isFindFocused
            ),
            actions: .init(
                queryChanged: { findText = $0 },
                replacementChanged: { replaceText = $0 },
                caseChanged: { caseSensitive = $0 },
                focusChanged: { isFindFocused = $0 },
                submit: barMode == .goToLine ? goToLine : findNext,
                findPrevious: findPrevious,
                findNext: findNext,
                replaceCurrent: replaceCurrent,
                replaceAll: replaceAll,
                close: leaveFindBar
            )
        )
        .fixedSize()
    }

    private func presentFind() {
        if let selection = editorCoordinator.selectedRange,
           selection.location != NSNotFound,
           selection.length > 0,
           let range = Range(selection, in: text) {
            findText = String(text[range])
        }
        barMode = .find
        isFindVisible = true
        isFindFocused = true
    }

    private func presentReplace() {
        presentFind()
        barMode = .replace
    }

    private func presentGoToLine() {
        barMode = .goToLine
        findText = ""
        isFindVisible = true
        isFindFocused = true
    }

    private func findNext() {
        selectMatch(searchingForward: true)
    }

    private func findPrevious() {
        selectMatch(searchingForward: false)
    }

    private func selectMatch(searchingForward: Bool) {
        let current = editorCoordinator.selectedRange ?? NSRange(location: 0, length: 0)
        let matches = searchMatches
        guard let index = EditorTextSearch.matchIndex(
            in: matches, selection: current, searchingForward: searchingForward
        ) else { return }
        editorCoordinator.select(matches[index], focusEditor: false)
    }

    private var searchMatches: [NSRange] {
        if isFindVisible { return cachedSearchMatches }
        // Find Next remains available after the bar is closed.
        return EditorTextSearch.matches(in: text, query: findText, caseSensitive: caseSensitive)
    }

    private func refreshSearchMatches() {
        cachedSearchMatches = isFindVisible && barMode != .goToLine
            ? EditorTextSearch.matches(in: text, query: findText, caseSensitive: caseSensitive)
            : []
    }

    private var matchSummary: String {
        let matches = searchMatches
        guard !matches.isEmpty else { return "0/0" }
        let selected = editorCoordinator.selectedRange
        let index = matches.firstIndex(of: selected ?? .notFound).map { $0 + 1 } ?? 0
        return "\(index)/\(matches.count)"
    }

    private func replaceCurrent() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let selection = editorCoordinator.selectedRange
        let nextIndex = EditorTextSearch.matchIndex(in: matches, selection: selection, searchingForward: true) ?? 0
        let range = matches.first(where: { $0 == selection }) ?? matches[nextIndex]
        editorCoordinator.replace(
            ranges: [range],
            with: replaceText,
            selectionAfterEdit: NSRange(location: range.location, length: (replaceText as NSString).length),
            focusEditor: false
        )
    }

    private func replaceAll() {
        let matches = searchMatches
        guard !matches.isEmpty else { return }
        let first = matches[0]
        editorCoordinator.replace(
            ranges: matches,
            with: replaceText,
            selectionAfterEdit: NSRange(location: first.location, length: (replaceText as NSString).length),
            focusEditor: false
        )
    }

    private func goToLine() {
        guard let target = EditorTextSearch.lineAndColumn(from: findText),
              let range = EditorTextSearch.range(forLine: target.line, column: target.column, in: text) else { return }
        leaveFindBar()
        editorCoordinator.select(range, focusEditor: true)
    }

    private func leaveFindBar() {
        isFindVisible = false
        isFindFocused = false
        editorCoordinator.focus()
    }

    private func configureCommands() {
        editorCoordinator.configure(
            keymap: editorSettings.keymap,
            findFieldFocused: { isFindFocused },
            onFocus: onFocus,
            isSurfaceFocused: isSurfaceFocused,
            actionHandler: { action in
            switch action {
            case .find: presentFind()
            case .replace: presentReplace()
            case .goToLine: presentGoToLine()
            case .findNext: findNext()
            case .findPrevious: findPrevious()
            case .save: onSave()
            case .saveAll: onSaveAll()
            case .close: onClose()
            case .open: onOpen()
            case .nextDocument: onNextDocument()
            case .previousDocument: onPreviousDocument()
            case .hide:
                leaveFindBar()
                onHide()
            default: return false
            }
            return true
        })
    }

    private var editorSettings: EditorSettings { settings.editorSettings }

    /// SourceEditor takes its whole presentation as one value type, so OMG
    /// options are folded here instead of being threaded as loose parameters.
    private var editorConfiguration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: resolvedTheme,
                useThemeBackground: true,
                font: resolvedFont,
                lineHeightMultiple: 1.2,
                letterSpacing: 1.0,
                wrapLines: wordWrapOverride ?? editorSettings.wordWrap,
                useSystemCursor: true,
                tabWidth: editorSettings.tabWidth,
                bracketPairEmphasis: .flash
            ),
            behavior: .init(
                isEditable: isEditable && isActive && !isPreview,
                isSelectable: isActive && !isPreview,
                indentOption: resolvedIndentOption
            ),
            layout: .init(
                editorOverscroll: 0,
                contentInsets: NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
                additionalTextInsets: nil
            ),
            peripherals: .init(
                showGutter: true,
                showMinimap: false,
                showReformattingGuide: false,
                showFoldingRibbon: false
            )
        )
    }

    private var resolvedIndentOption: IndentOption {
        if let name = fileURL?.lastPathComponent.lowercased(),
           name == "makefile" || name.hasSuffix(".mk") {
            return .tab
        }
        return .spaces(count: max(1, editorSettings.tabWidth))
    }

    private var resolvedFont: NSFont {
        let size = editorSettings.fontSize
        switch editorSettings.fontFamily {
        case .jetbrainsMono:
            return NSFont(name: "JetBrainsMono-Regular", size: size)
                ?? NSFont(name: "JetBrains Mono", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sfMono:
            return NSFont(name: "SFMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .menlo:
            return NSFont(name: "Menlo-Regular", size: size)
                ?? NSFont(name: "Menlo", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .firaCode:
            return NSFont(name: "FiraCode-Regular", size: size)
                ?? NSFont(name: "Fira Code", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    private var resolvedTheme: EditorTheme {
        var theme = terminalTheme ?? (editorSettings.followsOMG
            ? .adaptive(background: terminalBackground, foreground: terminalForeground)
            : editorSettings.syntaxTheme.preset)
        // The workspace paints one backdrop for toolbar, gutter and text.
        theme.background = EditorTheme.transparentBackground
        return EditorSyntaxHighlightProvider.renderTheme(theme)
    }

    private enum BarMode { case find, replace, goToLine }
}

@MainActor
final class EditorCoordinator: @preconcurrency TextViewCoordinator, @preconcurrency TextViewDelegate {
    let highlightProviders: [HighlightProviding] = [EditorSyntaxHighlightProvider(), MarkdownHighlightProvider()]
    private weak var controller: TextViewController?
    private var diffOverlay: EditorDiffLineOverlay?
    private var layoutDelegate: EditorLayoutDelegate?
    private var diffLines: [Int: Bool] = [:]
    private weak var completionState: CompletionState?
    private var completionPresenter: EditorCompletionPresenter?
    private var completionTask: Task<Void, Never>?
    private var completionCursor: Int?
    private var mouseMonitor: Any?
    private var textChangeObserver: NSObjectProtocol?
    private var textWillChangeObserver: NSObjectProtocol?
    private var viewportObserver: NSObjectProtocol?
    private var editDepth = 0
    private var groupsMultipleCarets = false
    private var startedUndoGroup = false
    private var needsViewportReconciliation = false
    private var viewportReconciliationPending = false
    private var columnDragStart: CGPoint?
    private var fileURL: URL?
    private var cachedLanguage: CodeLanguage?
    private var isActive = false
    private var keymap = EditorKeymap(profile: .idea)
    private var findFieldFocused: () -> Bool = { false }
    private var onFocus: () -> Void = {}
    private var isSurfaceFocused: () -> Bool = { true }
    private var actionHandler: (EditorAction) -> Bool = { _ in false }

    func setCompletionState(_ state: CompletionState) {
        self.completionState = state
        completionPresenter?.detach()
        completionPresenter = EditorCompletionPresenter(state: state) { [weak self] item in
            self?.commit(completion: item)
        }
        attachCompletionPresenter()
    }

    private func attachCompletionPresenter() {
        guard let scroll = controller?.textView.enclosingScrollView else { return }
        completionPresenter?.attach(to: scroll)
    }

    func setFileURL(_ fileURL: URL?) {
        self.fileURL = fileURL
    }

    var selectedRange: NSRange? {
        controller?.textView.selectionManager.textSelections.first?.range
    }

    func configure(
        keymap: EditorKeymap,
        findFieldFocused: @escaping () -> Bool,
        onFocus: @escaping () -> Void,
        isSurfaceFocused: @escaping () -> Bool = { true },
        actionHandler: @escaping (EditorAction) -> Bool
    ) {
        self.keymap = keymap
        self.findFieldFocused = findFieldFocused
        self.onFocus = onFocus
        self.isSurfaceFocused = isSurfaceFocused
        self.actionHandler = actionHandler
    }

    static func usesXMLHighlighting(_ url: URL) -> Bool {
        ["xml", "xsd", "xsl", "xslt", "svg", "plist", "xib", "storyboard", "xcscheme", "entitlements"]
            .contains(url.pathExtension.lowercased())
    }

    func language(fileURL: URL?, text: String) -> CodeLanguage {
        if let cachedLanguage, cachedLanguage.id != .plainText { return cachedLanguage }
        if let fileURL, Self.usesXMLHighlighting(fileURL) {
            // The bundled grammars have no XML parser. HTML provides tag,
            // attribute, string and comment highlighting for XML-family files.
            cachedLanguage = .html
            return .html
        }
        if let fileURL, let language = Self.knownLanguage(for: fileURL) {
            cachedLanguage = language
            return language
        }

        // Prefer filename, shebang and modeline signals before content probing.
        // A cached plain-text result is deliberately rechecked: editor panes can
        // first mount before the document finishes loading.
        let detected = CodeLanguage.detectLanguageFrom(
            url: fileURL ?? URL(fileURLWithPath: ""),
            prefixBuffer: String(text.prefix(2_048)),
            suffixBuffer: String(text.suffix(2_048))
        )
        if detected.id != .plainText {
            cachedLanguage = detected
            return detected
        }
        let contentLanguage = Self.detectStructuredContent(text)
        cachedLanguage = contentLanguage ?? .default
        return cachedLanguage!
    }

    /// Resolves Zed's useful filename aliases and compound suffixes before
    /// generic extension/content detection. `.lock` alone is ambiguous, so only
    /// known JSON/YAML lockfile names are treated specially.
    private static func knownLanguage(for url: URL) -> CodeLanguage? {
        let name = url.lastPathComponent.lowercased()
        let jsonNames: Set<String> = ["flake.lock", "deno.lock", "bun.lock", "bun.lockb"]
        let yamlNames: Set<String> = ["pixi.lock", "clang-format", "clangd", "bst"]
        if jsonNames.contains(name) || name.hasSuffix(".json") || name.hasSuffix(".jsonc") ||
            name == ".prettierrc" || name.hasSuffix(".json.dist") || name.hasSuffix(".geojson") ||
            name.hasSuffix(".topojson") {
            return .json
        }
        if yamlNames.contains(name) || name.hasSuffix(".yml") || name.hasSuffix(".yaml") {
            return .yaml
        }
        if [".ghostty", ".conf", ".ini", ".cfg", ".toml"].contains(where: name.hasSuffix) {
            return .toml
        }
        return nil
    }

    /// Conservatively detects structured text when name, shebang and modeline
    /// provide no language. Tree-sitter is used for recognition only on bounded
    /// text and only when the root contains the expected data structure.
    private static func detectStructuredContent(_ text: String) -> CodeLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.utf8.count <= 512_000 else { return nil }

        // Prefer distinctive syntax before permissive data grammars such as YAML.
        if looksLikeXML(trimmed), parsesStructured(strippingXMLProlog(text), as: .html) {
            return .html
        }
        if looksLikePython(trimmed), parsesStructured(text, as: .python) { return .python }
        if looksLikeJavaScript(trimmed), parsesStructured(text, as: .javascript) { return .javascript }
        if looksLikeRust(trimmed), parsesStructured(text, as: .rust) { return .rust }
        if looksLikeSQL(trimmed), parsesStructured(text, as: .sql) { return .sql }
        if looksLikeMarkdown(trimmed), parsesStructured(text, as: .markdown) { return .markdown }

        // Ordered signatures avoid asking permissive grammars to decide prose.
        if trimmed.first == "{" || trimmed.first == "[" {
            if parsesStructured(text, as: .json) { return .json }
        }
        if looksLikeYAML(trimmed), parsesStructured(text, as: .yaml) { return .yaml }
        if looksLikeTOML(trimmed), parsesStructured(text, as: .toml) { return .toml }
        return nil
    }

    private static func parsesStructured(_ text: String, as language: CodeLanguage) -> Bool {
        guard let grammar = language.language else { return false }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar)) != nil,
              let tree = parser.parse(text),
              let root = tree.rootNode else { return false }
        switch language.id {
        case .json:
            return !root.hasError && root.childCount > 0 &&
                (root.child(at: 0)?.nodeType == "object" || root.child(at: 0)?.nodeType == "array")
        case .yaml:
            // YAML accepts plain scalars and can mark a full stream as erroneous
            // while still returning useful mapping/sequence nodes. Recognize by
            // structure, then bound parser recovery errors.
            return hasTreeStructure(root,
                nodes: ["block_mapping_pair", "flow_pair", "block_sequence_item"], minimumCount: 2)
        case .toml:
            return hasTreeStructure(root,
                nodes: ["pair", "table", "table_array_element"], minimumCount: 1)
        default:
            // Source languages: require a clean parse and at least one named
            // node so a single stray token is not mistaken for a whole file.
            return !root.hasError && root.namedChildCount > 0
        }
    }

    private static func hasTreeStructure(_ root: Node, nodes: [String], minimumCount: Int) -> Bool {
        let structureCount = nodes.reduce(0) { count, type in count + countNodes(type: type, in: root) }
        return structureCount >= minimumCount
    }

    private static func countNodes(type: String, in node: Node) -> Int {
        let own = node.nodeType == type ? 1 : 0
        return (0..<node.childCount).reduce(own) { count, index in
            guard let child = node.child(at: index) else { return count }
            return count + countNodes(type: type, in: child)
        }
    }

    private static func containsNode(type: String, in node: Node) -> Bool {
        countNodes(type: type, in: node) > 0
    }

    private static func looksLikeXML(_ text: String) -> Bool {
        return text.hasPrefix("<?xml") || text.hasPrefix("<!DOCTYPE") ||
            (text.hasPrefix("<") && text.contains(">") && text.contains("</"))
    }

    /// Removes an XML prolog and DOCTYPE before parsing with the HTML grammar,
    /// which treats `<?xml ... ?>` as an error even though the markup below it is
    /// valid. XML-family files are already routed here because this checkout
    /// ships no XML grammar.
    private static func strippingXMLProlog(_ text: String) -> String {
        var result = Substring(text)
        while true {
            let trimmed = result.drop { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
            if trimmed.hasPrefix("<?"), let end = trimmed.range(of: "?>") {
                result = trimmed[end.upperBound...]
            } else if trimmed.hasPrefix("<!--"), let end = trimmed.range(of: "-->") {
                result = trimmed[end.upperBound...]
            } else {
                result = trimmed
                break
            }
        }
        return String(result)
    }

    private static func looksLikePython(_ text: String) -> Bool {
        return ["def ", "class ", "from ", "import ", "if __name__ ==", "async def "]
            .contains { text.hasPrefix($0) || text.contains("\n" + $0) }
    }

    private static func looksLikeJavaScript(_ text: String) -> Bool {
        return ["import ", "export ", "const ", "let ", "function ", "=>"]
            .contains { text.hasPrefix($0) || text.contains("\n" + $0) }
    }

    private static func looksLikeRust(_ text: String) -> Bool {
        return ["fn main", "use std::", "pub struct ", "impl ", "fn "]
            .contains { text.hasPrefix($0) || text.contains("\n" + $0) }
    }

    private static func looksLikeSQL(_ text: String) -> Bool {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["SELECT ", "INSERT INTO ", "CREATE TABLE ", "UPDATE ", "WITH "]
            .contains { upper.hasPrefix($0) }
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        return text.hasPrefix("# ") || text.hasPrefix("## ") || text.hasPrefix("```") ||
            text.hasPrefix("---\n") || text.contains("\n```\n")
    }

    private static func looksLikeYAML(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let mappingLines = lines.filter { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("-") &&
                line.contains(":")
        }
        let sequenceLines = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("-") }
        // A single YAML mapping-looking line is too ambiguous (`sentence: tail`
        // is valid YAML syntax as well). Require multiple mappings, a sequence,
        // an explicit document marker, or an indented nested block.
        let hasNestedBlock = lines.dropFirst().contains { line in
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            return !prefix.isEmpty
        }
        return mappingLines.count >= 2 || sequenceLines.count >= 2 || hasNestedBlock ||
            text.hasPrefix("---") || text.hasPrefix("%YAML")
    }

    private static func looksLikeTOML(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return lines.contains { $0.hasPrefix("[") && $0.hasSuffix("]") } ||
            lines.contains { $0.contains("=") }
    }

    func setDiffLines(_ lines: [Int: Bool]) {
        diffLines = lines
        guard let textView = controller?.textView else { return }
        if lines.isEmpty {
            diffOverlay?.layer.removeFromSuperlayer()
            diffOverlay = nil
        } else {
            let overlay = diffOverlay ?? EditorDiffLineOverlay(textView: textView)
            overlay.lines = lines
            diffOverlay = overlay
            overlay.refresh()
        }
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller
        layoutDelegate = EditorLayoutDelegate(textView: controller.textView)
        controller.textView.layoutManager.delegate = layoutDelegate
        setDiffLines(diffLines)
        if let scrollView = controller.textView.enclosingScrollView {
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            scrollView.documentCursor = .iBeam
        }
        refreshBackground()
        installTextObservers(controller: controller)
        // A read-only snapshot never gets an edit to initialize the provider's
        // visible range. Notify it once after the native viewport is laid out.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller, self.controller === controller,
                  let scroll = controller.textView.enclosingScrollView else { return }
            attachCompletionPresenter()
            // prepareCoordinator precedes the editor's scroll-view creation.
            // Register only after mounting, otherwise long-document scrolling
            // never invalidates the diff overlay at all.
            if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
            scroll.contentView.postsBoundsChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionCompletion(); self?.diffOverlay?.refresh() }
            }
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        installMouseMonitor()
        if isActive { registerCommands() }
        focusIfActive(onNextRunLoop: true)
    }

    func refreshBackground() {
        // CodeEdit reloadUI runs after prepareCoordinator and reinstates AppKit
        // scroll backgrounds. Clear them after that update, including the
        // macOS scroll view backing layer, so the workspace backdrop is visible.
        DispatchQueue.main.async { [weak self] in
            guard let scroll = self?.controller?.textView.enclosingScrollView else { return }
            scroll.drawsBackground = false
            scroll.backgroundColor = .clear
            scroll.layer?.backgroundColor = NSColor.clear.cgColor
            scroll.contentView.drawsBackground = false
            scroll.contentView.backgroundColor = .clear
            scroll.contentView.layer?.backgroundColor = NSColor.clear.cgColor
            self?.diffOverlay?.refresh()
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.isActive, !self.isPreview, let textView = self.controller?.textView,
                  event.window === textView.window else {
                return event
            }
            let locInTextView = textView.convert(event.locationInWindow, from: nil)

            switch event.type {
            case .leftMouseDown:
                // Completion rows are native children of the editor scroll view,
                // but must not trigger column selection or dismiss before commit.
                if self.completionPresenter?.contains(event) == true { return event }
                self.dismissCompletion()
                if event.modifierFlags.contains(.option), textView.bounds.contains(locInTextView) {
                    self.columnDragStart = locInTextView
                    self.handleColumnSelection(at: locInTextView, start: locInTextView)
                    return nil
                }
            case .leftMouseDragged:
                if let start = self.columnDragStart {
                    self.handleColumnSelection(at: locInTextView, start: start)
                    return nil
                }
            case .leftMouseUp:
                if self.columnDragStart != nil {
                    self.columnDragStart = nil
                    return nil
                }
            default:
                break
            }
            return event
        }
    }

    private func handleColumnSelection(at current: CGPoint, start: CGPoint) {
        guard let controller, let layoutManager = controller.textView.layoutManager else { return }
        let lineHeight = max(14, layoutManager.estimateLineHeight())
        let minY = min(start.y, current.y)
        let maxY = max(start.y, current.y)
        let isBox = abs(current.x - start.x) >= 6

        var ranges: [NSRange] = []
        var seen = Set<Int>()

        var y = minY + lineHeight / 2
        while y <= maxY + lineHeight / 2 {
            if isBox {
                if let o1 = layoutManager.textOffsetAtPoint(CGPoint(x: start.x, y: y)),
                   let o2 = layoutManager.textOffsetAtPoint(CGPoint(x: current.x, y: y)) {
                    let loc = min(o1, o2)
                    let len = abs(o2 - o1)
                    if !seen.contains(loc) {
                        seen.insert(loc)
                        ranges.append(NSRange(location: loc, length: len))
                    }
                }
            } else {
                if let offset = layoutManager.textOffsetAtPoint(CGPoint(x: start.x, y: y)) {
                    if !seen.contains(offset) {
                        seen.insert(offset)
                        ranges.append(NSRange(location: offset, length: 0))
                    }
                }
            }
            y += lineHeight
        }

        if !ranges.isEmpty {
            controller.textView.selectionManager.setSelectedRanges(ranges)
            controller.textView.setNeedsDisplay()
            NotificationCenter.default.post(
                name: TextSelectionManager.selectionChangedNotification,
                object: controller.textView.selectionManager
            )
        }
    }

    func setActive(_ isActive: Bool) {
        refreshBackground()
        let didActivate = isActive && !self.isActive
        self.isActive = isActive
        if didActivate {
            registerCommands()
            if !isPreview {
                focusIfActive(onNextRunLoop: true)
            }
        } else if !isActive {
            dismissCompletion()
            columnDragStart = nil
            EditorCommandRouter.shared.unregister(owner: self)
            if let textView = controller?.textView,
               textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }
    }

    private(set) var isPreview: Bool = false

    func setIsPreview(_ isPreview: Bool) {
        refreshBackground()
        let changed = self.isPreview != isPreview
        self.isPreview = isPreview
        if changed {
            if isPreview {
                dismissCompletion()
                if let textView = controller?.textView,
                   textView.window?.firstResponder === textView {
                    textView.window?.makeFirstResponder(nil)
                }
            } else if isActive {
                focusIfActive(onNextRunLoop: true)
            }
        }
    }

    func focus() {
        focusIfActive(onNextRunLoop: false)
    }

    private func focusIfActive(onNextRunLoop: Bool) {
        let applyFocus = { [weak self] in
            guard let self, isActive, let textView = controller?.textView,
                  let window = textView.window else { return }
            // Splitting rebuilds the existing leaf's view. Its deferred onAppear
            // focus must not steal focus from the newly created terminal pane.
            if onNextRunLoop && !isSurfaceFocused() { return }
            if window.firstResponder !== textView {
                if window.makeFirstResponder(textView) {
                    onFocus()
                }
            }
        }
        if onNextRunLoop {
            DispatchQueue.main.async { applyFocus() }
        } else {
            applyFocus()
        }
    }

    func select(_ range: NSRange, focusEditor: Bool = true) {
        guard let controller, let textView = controller.textView else { return }
        if focusEditor {
            focus()
        }
        controller.setCursorPositions([CursorPosition(range: range)])
        EditorNativeTextActions.select(range, on: textView)
    }

    func replace(
        ranges: [NSRange],
        with replacement: String,
        selectionAfterEdit: NSRange,
        focusEditor: Bool
    ) {
        guard let controller else { return }
        guard EditorTextEditing.replace(on: controller.textView, ranges: ranges, with: replacement) else { return }
        select(selectionAfterEdit, focusEditor: focusEditor)
    }

    private func installTextObservers(controller: TextViewController) {
        let textView = controller.textView!
        textWillChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textWillChangeNotification, object: textView, queue: .main
        ) { [weak self, weak textView] _ in
            MainActor.assumeIsolated {
                guard let self, let textView else { return }
                self.editDepth += 1
                guard self.editDepth == 1 else { return }
                self.groupsMultipleCarets = textView.selectionManager.textSelections.count > 1
                    && !textView.hasMarkedText() && textView.undoManager?.isUndoing != true
                    && textView.undoManager?.isRedoing != true
            }
        }
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification, object: textView, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                guard let self, let controller else { return }
                self.editDepth = max(0, self.editDepth - 1)
                guard self.editDepth == 0 else { return }
                if self.startedUndoGroup {
                    controller.textView._undoManager?.endUndoGrouping()
                    self.startedUndoGroup = false
                }
                self.groupsMultipleCarets = false
                if self.needsViewportReconciliation {
                    self.needsViewportReconciliation = false
                    self.reconcileViewportAfterEdit(controller: controller)
                }
                self.updateCompletion(controller: controller)
            }
        }
    }

    private func reconcileViewportAfterEdit(controller: TextViewController) {
        guard !viewportReconciliationPending else { return }
        viewportReconciliationPending = true
        // CodeEdit lays out during endTransaction, before selection scrolling and
        // SwiftUI's text binding have settled. A multi-line paste can leave its
        // fragment cache describing the old viewport, particularly when the
        // clip view moved without posting a bounds notification during layout.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self else { return }
            self.viewportReconciliationPending = false
            guard let controller, self.controller === controller,
                  let textView = controller.textView,
                  let scrollView = textView.enclosingScrollView else { return }
            textView.layoutManager.setNeedsLayout()
            textView.updatedViewport(scrollView.documentVisibleRect)
            textView.needsLayout = true
            textView.needsDisplay = true
        }
    }

    func textView(_ textView: TextView, willReplaceContentsIn range: NSRange, with string: String) {
        if string.contains("\n") || string.contains("\r") {
            needsViewportReconciliation = true
        }
        // Open the group before the first mutation lands. The undo manager
        // breaks a group opened after a mutation was registered, which would
        // leave the remaining carets outside it and cost one undo per caret.
        if groupsMultipleCarets, !startedUndoGroup, textView._undoManager?.isGrouping == false {
            textView._undoManager?.beginUndoGrouping()
            startedUndoGroup = true
        }
    }

    func textView(_ textView: TextView, didReplaceContentsIn range: NSRange, with string: String) {
        if string.contains("\n") || string.contains("\r") {
            needsViewportReconciliation = true
        }
        // Undo/redo replace text with selection updates skipped and then scroll
        // the stale carets into view. Trim here: the storage has already shrunk,
        // and the scroll happens right after this callback.
        EditorSelectionClamp.trim(textView)
    }

    func textViewDidChangeText(controller: TextViewController) {
        // Explicit callers/tests may request completions; native edits use the
        // transaction-complete notification after all selections are updated.
        updateCompletion(controller: controller)
    }

    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        // TextView notifies selections before textDidChange. Keep the popup
        // alive until that transaction updates its prefix and candidates.
        guard editDepth == 0 else { return }
        let selections = controller.textView.selectionManager.textSelections
        guard selections.count == 1, let selection = selections.first?.range,
              selection.length == 0, selection.location == completionCursor,
              !controller.textView.hasMarkedText() else {
            dismissCompletion()
            return
        }
    }

    private func dismissCompletion() {
        completionTask?.cancel()
        completionTask = nil
        completionCursor = nil
        completionState?.dismiss()
    }

    private func updateCompletion(controller: TextViewController) {
        // Cancel before validating: whitespace, a selection or IME composition invalidates old work too.
        completionTask?.cancel()
        completionTask = nil
        completionCursor = nil
        guard isActive, controller.textView.isEditable, !controller.textView.hasMarkedText(),
              controller.textView.selectionManager.textSelections.count == 1,
              let textSelection = controller.textView.selectionManager.textSelections.first,
              textSelection.range.length == 0 else {
            dismissCompletion()
            return
        }

        let cursorLocation = textSelection.range.location
        let string = controller.textView.string as NSString
        guard cursorLocation >= 0, cursorLocation <= string.length else {
            dismissCompletion()
            return
        }

        var wordStart = cursorLocation
        while wordStart > 0 {
            let char = string.character(at: wordStart - 1)
            if let scalar = UnicodeScalar(char),
               CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                wordStart -= 1
            } else {
                break
            }
        }

        let prefixLength = cursorLocation - wordStart
        let memberReceiver = CompletionContext.memberReceiver(in: string, prefixStart: wordStart)
        guard prefixLength >= 1 || memberReceiver != nil else {
            dismissCompletion()
            return
        }

        let prefix = string.substring(with: NSRange(location: wordStart, length: prefixLength))
        let prefixRange = NSRange(location: wordStart, length: prefixLength)

        let lineIdx = controller.textView.layoutManager.textLineForOffset(cursorLocation)?.index ?? 0
        let estHeight = max(14, controller.textView.layoutManager.estimateLineHeight())
        let cursorRect: CGRect
        if let rect = controller.textView.layoutManager.rectForOffset(cursorLocation), rect.height > 0 {
            cursorRect = rect
        } else {
            cursorRect = CGRect(x: 40, y: CGFloat(lineIdx) * estHeight, width: 2, height: estHeight)
        }

        guard let scrollView = controller.textView.enclosingScrollView else {
            dismissCompletion()
            return
        }
        let originInScroll = controller.textView.convert(cursorRect.origin, to: scrollView)
        guard originInScroll.y >= 0 else {
            dismissCompletion()
            return
        }

        let anchorPoint = CompletionState.popupOrigin(
            caret: CGRect(origin: originInScroll, size: cursorRect.size),
            viewport: scrollView.bounds.size, candidateCount: completionState?.candidates.count ?? 0
        )

        // Immediately update existing candidates and prefix synchronously!
        if let completionState, completionState.isPresented {
            if completionState.prefixRange.location == prefixRange.location {
                completionState.filter(prefix: prefix, prefixRange: prefixRange, at: anchorPoint)
                repositionCompletion()
            } else {
                // A new token (notably the empty prefix after a dot) must never
                // temporarily reuse the previous receiver's candidates.
                completionState.dismiss()
            }
        }

        let lineRange = string.lineRange(for: NSRange(location: cursorLocation, length: 0))
        let lineText = string.substring(with: lineRange)
        let lang = self.cachedLanguage?.tsName.lowercased()

        let context = CompletionContext(
            documentText: controller.textView.string,
            cursorOffset: cursorLocation,
            prefix: prefix,
            lineText: lineText,
            language: lang,
            fileURL: self.fileURL
        )

        completionCursor = cursorLocation
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000)
            guard !Task.isCancelled else { return }
            let candidates = await EditorCompletionEngine.shared.completions(for: context)
            guard !Task.isCancelled, let self, self.isActive,
                  let textView = self.controller?.textView,
                  !textView.hasMarkedText(), textView.window?.firstResponder === textView,
                  textView.selectionManager.textSelections.count == 1,
                  self.selectedRange == NSRange(location: cursorLocation, length: 0) else { return }

            let currentText = textView.string as NSString
            guard NSMaxRange(prefixRange) <= currentText.length,
                  currentText.substring(with: prefixRange) == prefix else { return }
            self.completionState?.update(
                candidates: candidates,
                prefix: prefix,
                prefixRange: prefixRange,
                at: anchorPoint
            )
            self.repositionCompletion()
        }
    }

    private func repositionCompletion() {
        guard let state = completionState, state.isPresented,
              let textView = controller?.textView, let scroll = textView.enclosingScrollView,
              scroll.bounds.width > 0, scroll.bounds.height > 0,
              let offset = selectedRange?.location,
              let rect = textView.layoutManager.rectForOffset(offset) else { return }
        let caret = textView.convert(rect, to: scroll)
        guard caret.maxY >= 0, caret.minY < scroll.bounds.height else {
            dismissCompletion()
            return
        }
        let origin = CompletionState.popupOrigin(caret: caret, viewport: scroll.bounds.size,
                                                candidateCount: state.candidates.count)
        if state.presentationPoint != origin { state.presentationPoint = origin }
    }

    func commit(completion: CompletionItem) {
        guard let controller,
              let completionState,
              completionState.isPresented else { return }

        let range = completionState.prefixRange
        let insertText = completion.insertText
        let prefix = completionState.prefix
        dismissCompletion()

        guard controller.textView.isEditable, !controller.textView.hasMarkedText(),
              controller.textView.selectionManager.textSelections.count == 1,
              selectedRange == NSRange(location: NSMaxRange(range), length: 0),
              range.location != NSNotFound, range.location >= 0,
              NSMaxRange(range) <= controller.textView.textStorage.length,
              (controller.textView.string as NSString).substring(with: range) == prefix else { return }

        controller.textView.replaceCharacters(in: range, with: insertText)
        let newCursorPos = range.location + (insertText as NSString).length
        let newRange = NSRange(location: newCursorPos, length: 0)
        controller.setCursorPositions([CursorPosition(range: newRange)])
        controller.textView.selectionManager.setSelectedRange(newRange)
        controller.textView.scrollSelectionToVisible()
        controller.textView.updatedViewport(controller.textView.visibleRect)
        controller.textView.needsDisplay = true
        dismissCompletion()
    }

    func destroy() {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        viewportObserver = nil
        if let textChangeObserver { NotificationCenter.default.removeObserver(textChangeObserver) }
        if let textWillChangeObserver { NotificationCenter.default.removeObserver(textWillChangeObserver) }
        textChangeObserver = nil
        textWillChangeObserver = nil
        if startedUndoGroup { controller?.textView._undoManager?.endUndoGrouping() }
        startedUndoGroup = false
        needsViewportReconciliation = false
        viewportReconciliationPending = false
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        dismissCompletion()
        completionPresenter?.detach()
        completionPresenter = nil
        completionState = nil
        EditorCommandRouter.shared.unregister(owner: self)
        controller = nil
        isActive = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard isActive, let textView = controller?.textView,
              event.window === textView.window else { return false }

        if isPreview {
            guard isSurfaceFocused() else { return false }
            guard let action = keymap.action(for: event) else { return false }
            switch action {
            case .close, .open, .nextDocument, .previousDocument, .hide:
                return actionHandler(action)
            default:
                return false
            }
        }

        let responder = textView.window?.firstResponder
        let isTextViewOrChild = responder === textView || (responder as? NSView)?.isDescendant(of: textView) == true
        let editingField = (responder as? NSTextView)?.isFieldEditor == true
        guard isTextViewOrChild || editingField else {
            dismissCompletion()
            return false
        }
        if editingField {
            dismissCompletion()
            guard findFieldFocused(), (responder as? NSTextView)?.hasMarkedText() != true else { return false }
        }
        if isTextViewOrChild, textView.hasMarkedText() {
            dismissCompletion()
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        // Shift + Escape: Hide Editor
        if event.keyCode == 53, modifiers == .shift {
            dismissCompletion()
            return actionHandler(.hide)
        }
        if isTextViewOrChild, modifiers.isEmpty || modifiers == .shift,
           EditorPairedInput.apply(event.characters ?? "", backspace: event.keyCode == 51,
                                   enabled: OhMyGhosttySettings.shared.editorAutoClosePairs, on: textView) {
            dismissCompletion()
            return true
        }
        // Escape must cancel pending results even before the popup becomes visible.
        if isTextViewOrChild, event.keyCode == 53, modifiers.isEmpty {
            let wasPresented = completionState?.isPresented == true
            dismissCompletion()
            return wasPresented
        }

        if let completionState, completionState.isPresented, !completionState.candidates.isEmpty {
            switch event.keyCode {
            case 125 where modifiers.isEmpty: // Down arrow
                completionState.selectNext()
                return true
            case 126 where modifiers.isEmpty: // Up arrow
                completionState.selectPrevious()
                return true
            case 48 where modifiers.isEmpty: // Tab
                if let candidate = completionState.currentSelection {
                    commit(completion: candidate)
                    return true
                }
            case 36 where modifiers.isEmpty: // Enter / Return
                if let candidate = completionState.currentSelection {
                    commit(completion: candidate)
                    return true
                }
            case 45 where modifiers == .control: // Ctrl + N
                completionState.selectNext()
                return true
            case 35 where modifiers == .control: // Ctrl + P
                completionState.selectPrevious()
                return true
            default:
                break
            }
        }

        guard let action = keymap.action(for: event) else { return false }
        if action == .find || action == .replace || action == .goToLine { dismissCompletion() }
        if editingField {
            switch action {
            case .cut, .copy, .paste, .selectAll, .selectLine, .undo, .redo,
                 .duplicateLine, .deleteLine, .moveLineUp, .moveLineDown, .indent, .outdent, .toggleLineComment:
                return false
            default: return actionHandler(action)
            }
        }
        guard let controller else { return false }
        return EditorNativeTextActions.perform(action, on: controller) || actionHandler(action)
    }

    private func registerCommands() {
        EditorCommandRouter.shared.register(owner: self) { [weak self] event in
            self?.handle(event) ?? false
        }
    }
}

/// Layers tint source lines without contributing to AppKit's intrinsic layout.
@MainActor
private final class EditorDiffLineOverlay {
    let layer = CALayer()
    private weak var textView: TextView?
    var lines: [Int: Bool] = [:]
    private var refreshPending = false
    private var observations: [NSObjectProtocol] = []

    deinit { observations.forEach(NotificationCenter.default.removeObserver) }

    init(textView: TextView) {
        self.textView = textView
        layer.name = "omg.diff-line-overlay"
        textView.wantsLayer = true
        textView.layer?.addSublayer(layer)
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: textView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        guard !refreshPending else { return }
        refreshPending = true
        // Scroll notifications arrive before lazy line layout has settled.
        // Coalesce them, then obtain final wrapped-line positions on the next
        // main-loop turn. Drawing inside a layout callback can re-enter layout.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { refreshPending = false }
            guard let textView else { return }
            textView.layoutSubtreeIfNeeded()
            drawHighlights(in: textView)
        }
    }

    private func drawHighlights(in textView: TextView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = textView.bounds
        layer.sublayers = []
        let added = CGMutablePath()
        let removed = CGMutablePath()
        for line in textView.layoutManager.visibleLines() {
            guard let isAdded = lines[line.index] else { continue }
            let path = isAdded ? added : removed
            path.addRect(CGRect(x: 0, y: line.yPos, width: textView.bounds.width, height: line.height))
        }
        for (path, color) in [(added, NSColor.systemGreen), (removed, NSColor.systemRed)] {
            let tint = CAShapeLayer()
            tint.path = path
            tint.fillColor = color.withAlphaComponent(0.14).cgColor
            layer.addSublayer(tint)
        }
        CATransaction.commit()
    }
}
