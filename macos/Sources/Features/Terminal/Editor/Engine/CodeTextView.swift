import AppKit
import SwiftUI

/// The editable text surface.
///
/// An `NSTextView` behind `NSViewRepresentable` rather than SwiftUI's
/// `TextEditor`, and the reason is not taste. `TextEditor` binds to a
/// `String`: every keystroke sends the whole document through the binding
/// for SwiftUI to diff and reapply, which is O(file) per character typed.
/// A few hundred kilobytes in, typing visibly lags. It also hands out no
/// text storage, so there is nowhere to hang incremental highlighting, a
/// gutter, or anything else this needs.
///
/// ⚠️ **TextKit 2 is conditional.** `NSTextView` starts in TextKit 2, but
/// touching the legacy `.layoutManager` property makes AppKit silently fall
/// back to TextKit 1 for the rest of that view's life — and TextKit 1 lays
/// out the *entire* document instead of the viewport, which is exactly the
/// behavior this class exists to avoid. Reach for `textLayoutManager`; a
/// test asserts the view really is in TextKit 2.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String

    let language: CodeLanguage
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration

    /// Called after the user changes the text, so the host can mark the
    /// document dirty. Not the same as the binding: the binding also moves
    /// when the host replaces the text itself (a reload from disk), and
    /// that must not look like an edit.
    var onEdit: () -> Void = {}

    /// Whether the minimap is drawn beside the text.
    var showsMinimap: Bool = true

    /// Ranges to underline, with the colour to use. Supplied as plain
    /// values so the engine never learns what a language server is.
    var underlines: [(range: NSRange, color: NSColor)] = []

    /// Asked for the text to show when the pointer rests on an offset.
    var hoverProvider: ((Int) async -> String?)?

    /// Asked for the words to offer at an offset, for the completion list.
    var completionProvider: ((Int) async -> [String])?

    /// A range to select and scroll into view once. Carries an identity so
    /// the same range asked for twice still moves the view — jumping to a
    /// definition you are already looking at has to re-centre it, not do
    /// nothing.
    var reveal: (id: String, range: NSRange)?

    /// ⌘-click, and the editor commands the host implements.
    var onJumpToDefinition: ((Int) -> Void)?
    var onRename: ((Int) -> Void)?
    var onFindReferences: ((Int) -> Void)?
    var onFormat: (() -> Void)?

    /// Keyboard commands the host owns. Passed in rather than assumed, so
    /// the engine never decides what saving means.
    var onSave: () -> Void = {}
    var onSaveAll: () -> Void = {}
    var onCloseTab: () -> Void = {}
    var onSearchWorkspace: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            storage: CodeTextStorage(
                language: language,
                theme: theme,
                configuration: configuration
            ),
            onEdit: onEdit
        )
    }

    func makeNSView(context: Context) -> NSView {
        let textView = CodeNSTextView()
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.autoresizingMask = [.width]

        // Neither the text view nor its scroll view paints a background.
        // The host puts a layer behind this whole pane, so whatever the
        // window is doing — a solid theme colour, or blur through to the
        // desktop — reaches the code the same way it reaches the terminal.
        textView.drawsBackground = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !configuration.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        // Gutter and text sit side by side in a container, rather than the
        // gutter being a ruler inside the scroll view. Separate areas can't
        // overlap, so nothing has to police where the numbers land.
        let gutter = CodeGutterView(
            textView: textView,
            scrollView: scrollView,
            theme: theme,
            font: configuration.font
        )
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutter.isHidden = !configuration.showsLineNumbers

        let minimap = CodeMinimapView(theme: theme, scrollView: scrollView)
        minimap.translatesAutoresizingMaskIntoConstraints = false
        minimap.isHidden = !showsMinimap
        minimap.onSelectLine = { [weak textView] line in
            guard let textView else { return }
            let ns = textView.string as NSString
            var location = 0
            var current = 1
            while current < line, location < ns.length {
                location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
                current += 1
            }
            textView.setSelectedRange(NSRange(location: min(location, ns.length), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        let container = NSView()
        container.addSubview(gutter)
        container.addSubview(scrollView)
        container.addSubview(minimap)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let minimapWidth = minimap.widthAnchor.constraint(
            equalToConstant: showsMinimap ? 70 : 0
        )
        let gutterWidth = gutter.widthAnchor.constraint(
            equalToConstant: configuration.showsLineNumbers ? gutter.preferredWidth : 0
        )
        gutter.onWidthChange = { width in
            gutterWidth.constant = gutter.isHidden ? 0 : width
        }

        NSLayoutConstraint.activate([
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutterWidth,
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            minimap.topAnchor.constraint(equalTo: container.topAnchor),
            minimap.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            minimapWidth,
        ])

        context.coordinator.gutterWidth = gutterWidth
        context.coordinator.minimap = minimap
        context.coordinator.minimapWidth = minimapWidth

        textView.onSave = onSave
        textView.onSaveAll = onSaveAll
        textView.onCloseTab = onCloseTab
        textView.onSearchWorkspace = onSearchWorkspace
        textView.onRename = onRename
        textView.onFindReferences = onFindReferences
        textView.onFormat = onFormat
        textView.onJumpToDefinition = onJumpToDefinition
        textView.hoverProvider = hoverProvider
        textView.completionProvider = completionProvider

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        context.coordinator.apply(text: text)
        context.coordinator.applyAppearance(theme: theme, configuration: configuration)

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let textView = context.coordinator.textView,
              let scrollView = textView.enclosingScrollView
        else { return }

        // Refreshed every update: the closures capture the document that
        // was selected when the view was made, and the selection moves.
        if let code = textView as? CodeNSTextView {
            code.onSave = onSave
            code.onSaveAll = onSaveAll
            code.onCloseTab = onCloseTab
            code.onSearchWorkspace = onSearchWorkspace
            code.onRename = onRename
            code.onFindReferences = onFindReferences
            code.onFormat = onFormat
            code.onJumpToDefinition = onJumpToDefinition
            code.hoverProvider = hoverProvider
            code.completionProvider = completionProvider
        }
        context.coordinator.applyUnderlines(underlines)

        context.coordinator.storage.setLanguage(language)
        context.coordinator.applyAppearance(theme: theme, configuration: configuration)
        scrollView.hasHorizontalScroller = !configuration.wrapsLines

        // Only when it actually differs — writing the same string back
        // would reset the insertion point and wipe the undo stack on every
        // SwiftUI update, which happens for reasons unrelated to this view.
        if textView.string != text {
            context.coordinator.apply(text: text)
        }

        // After the text, so a jump into a file that is being opened in the
        // same breath lands on a document that already has its content.
        if let reveal { context.coordinator.reveal(reveal) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let storage: CodeTextStorage
        let onEdit: () -> Void
        weak var textView: NSTextView?
        weak var gutter: CodeGutterView?
        var gutterWidth: NSLayoutConstraint?
        weak var minimap: CodeMinimapView?
        var minimapWidth: NSLayoutConstraint?

        /// Set while the host is writing text in, so the delegate can tell
        /// a programmatic load from something the user typed.
        private var isApplyingExternalText = false

        /// The last reveal honoured, so a SwiftUI update that changes
        /// something unrelated doesn't drag the view back there.
        private var lastRevealID: String?

        /// The underlines currently drawn, so an update that changed
        /// something else doesn't walk the whole document to redraw marks
        /// that haven't moved.
        private var appliedUnderlines: [NSRange] = []

        init(storage: CodeTextStorage, onEdit: @escaping () -> Void) {
            self.storage = storage
            self.onEdit = onEdit
        }

        func apply(text: String) {
            guard let textView, let textStorage = textView.textStorage else { return }
            isApplyingExternalText = true
            defer { isApplyingExternalText = false }

            textStorage.setAttributedString(NSAttributedString(string: text))
            storage.highlight(textStorage, in: NSRange(location: 0, length: textStorage.length))
            gutter?.reload()
            refreshMinimap()

            // Put the view back at the start of the document.
            //
            // Replacing the storage leaves the scrollers wherever they
            // were, and with wrapping off the container is effectively
            // infinitely wide — so a file opened into a view that had been
            // scrolled arrived showing the middle of its lines, with the
            // left edge of every one of them cut off. It reads as a
            // rendering fault rather than a scroll position.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollToOrigin()

            // And again once layout has settled.
            //
            // The first call runs while the view still has no real frame —
            // a scroll view with zero bounds has nowhere to scroll *to*,
            // so the request is silently a no-op, and the position AppKit
            // arrives at after laying out is whatever it had before. Doing
            // it on the next turn is what actually moves it, and doing it
            // twice costs nothing when the first one already worked.
            DispatchQueue.main.async { [weak self] in
                self?.scrollToOrigin()
            }
        }

        /// Recomputes the minimap's bars from the current text.
        ///
        /// Reuses the tokens the highlighter already produces rather than
        /// scanning again — the map is a second view of the same answer.
        func refreshMinimap() {
            guard let minimap, minimap.isHidden == false, let textView else { return }
            let text = textView.string
            let tokens = SyntaxHighlighter(language: storage.language)
                .tokens(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            minimap.setRows(CodeMinimapView.rows(for: text, tokens: tokens))
        }

        /// Selects a range and brings it into view, centred.
        ///
        /// Centred rather than merely visible: `scrollRangeToVisible` does
        /// the least it can, so a definition one line below the fold lands
        /// on the very last row — technically visible, and with none of the
        /// surrounding code that makes it readable.
        func reveal(_ reveal: (id: String, range: NSRange)) {
            guard reveal.id != lastRevealID, let textView else { return }
            lastRevealID = reveal.id

            let length = (textView.string as NSString).length
            let clipped = NSRange(
                location: min(reveal.range.location, length),
                length: min(reveal.range.length, max(0, length - reveal.range.location))
            )

            textView.setSelectedRange(clipped)
            textView.scrollRangeToVisible(clipped)

            // Once layout has settled, for the same reason opening a file
            // needs a second scroll: the first runs before the view has the
            // frame it would be scrolling within.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let scrollView = textView.enclosingScrollView else { return }
                let rect = textView.firstRect(forCharacterRange: clipped, actualRange: nil)
                guard rect.height > 0 else { return }
                let local = textView.convert(
                    textView.window?.convertFromScreen(rect) ?? .zero,
                    from: nil
                )
                let target = max(0, local.midY - scrollView.contentView.bounds.height / 2)
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        /// Puts the text back at its top-left corner.
        private func scrollToOrigin() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            gutter?.needsDisplay = true
        }

        /// Draws the diagnostic underlines on top of the syntax colours.
        ///
        /// Applied as a separate pass rather than folded into highlighting:
        /// the two change for unrelated reasons — one when you type, the
        /// other when a server answers — and a single pass would mean
        /// re-tokenising the document every time a diagnostic arrived.
        func applyUnderlines(_ underlines: [(range: NSRange, color: NSColor)]) {
            guard let textView, let storage = textView.textStorage else { return }

            // SwiftUI updates this view for reasons that have nothing to do
            // with diagnostics — a theme change, a resize, a keystroke —
            // and each pass here walks the whole document. Skipping the
            // unchanged case is what keeps that off the typing path.
            let ranges = underlines.map(\.range)
            guard ranges != appliedUnderlines else { return }
            appliedUnderlines = ranges

            let full = NSRange(location: 0, length: storage.length)

            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            for underline in underlines {
                let clipped = NSIntersectionRange(underline.range, full)
                guard clipped.length > 0 else { continue }
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: underline.color,
                ], range: clipped)
            }
            storage.endEditing()
        }

        func applyAppearance(theme: CodeTheme, configuration: CodeEditorConfiguration) {
            guard let textView else { return }

            storage.theme = theme
            storage.configuration = configuration

            textView.font = configuration.font
            textView.insertionPointColor = theme.foreground
            textView.textColor = theme.foreground

            textView.textContainer?.widthTracksTextView = configuration.wrapsLines
            if configuration.wrapsLines {
                textView.textContainer?.size = NSSize(
                    width: textView.frame.width,
                    height: .greatestFiniteMagnitude
                )
            } else {
                textView.textContainer?.size = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }

            gutter?.theme = theme
            gutter?.font = configuration.font
            minimap?.theme = theme
            gutter?.isHidden = !configuration.showsLineNumbers
            gutterWidth?.constant = configuration.showsLineNumbers
                ? (gutter?.preferredWidth ?? 0)
                : 0

            if let textStorage = textView.textStorage {
                storage.highlight(
                    textStorage,
                    in: NSRange(location: 0, length: textStorage.length)
                )
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage
            else { return }

            let edited = textView.selectedRange()
            storage.highlight(
                textStorage,
                in: CodeTextStorage.invalidationRange(
                    for: edited,
                    in: textStorage.string as NSString
                )
            )
            gutter?.reload()
            refreshMinimap()
            onEdit()
        }
    }
}

/// The text view itself, kept as a named subclass so the tab and save
/// key handling in the host has something to attach to — and so a test can
/// assert it came up in TextKit 2.
final class CodeNSTextView: NSTextView {
    /// ⌘S, ⇧⌘S and ⌘W, supplied by the host.
    ///
    /// Handled here rather than by a window- or app-level monitor because
    /// this view is only in the responder chain while it has focus — which
    /// makes "the editor gets these keys only when the editor is being
    /// used" a property of where the code lives instead of a condition
    /// somebody has to remember to check. ⌘W closes a terminal tab
    /// otherwise, and getting that wrong breaks the app.
    var onSave: (() -> Void)?
    var onSaveAll: (() -> Void)?
    var onCloseTab: (() -> Void)?

    /// ⇧⌘F. Plain ⌘F is deliberately left to the find bar this view
    /// already has — replacing a working in-file search with a worse one
    /// would be a downgrade dressed as a feature.
    var onSearchWorkspace: (() -> Void)?

    /// The host's language features, reached by keyboard or ⌘-click.
    var onRename: ((Int) -> Void)?
    var onFindReferences: ((Int) -> Void)?
    var onFormat: (() -> Void)?
    var onJumpToDefinition: ((Int) -> Void)?
    var hoverProvider: ((Int) async -> String?)?
    var completionProvider: ((Int) async -> [String])?

    /// The last answer from `completionProvider`.
    ///
    /// AppKit asks for completions **synchronously**, and a language server
    /// answers over a pipe. The only way to bridge the two is to fetch
    /// first and open the list afterwards, serving it from here — which is
    /// what `complete(_:)` below does.
    private var pendingCompletions: [String] = []
    private var isFetchingCompletions = false

    /// The offset the pointer last rested on, so the tooltip describes
    /// what is under it rather than what the cursor happens to be near.
    private var hoverOffset: Int?
    private var hoverTask: Task<Void, Never>?

    /// Whether a click means "go to the definition" rather than "put the
    /// cursor here".
    ///
    /// Split out so it can be tested: `mouseDown` itself cannot be, because
    /// `NSTextView`'s runs an event-tracking loop waiting for the mouse to
    /// come back up — call it outside a window and it never returns.
    static func isJumpClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// ⌘-click goes to the definition; without the modifier this is an
    /// ordinary click and must stay one.
    override func mouseDown(with event: NSEvent) {
        guard Self.isJumpClick(event.modifierFlags), let onJumpToDefinition else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onJumpToDefinition(characterIndexForInsertion(at: point))
    }

    /// Hovering asks the host what to say, on a delay.
    ///
    /// Debounced because the pointer crosses a whole line on its way
    /// somewhere else, and asking a language server about every character
    /// it passes over is a request per pixel of travel.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let hoverProvider else { return }

        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        guard offset != hoverOffset else { return }
        hoverOffset = offset

        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let text = await hoverProvider(offset)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.hoverOffset == offset else { return }
                self.toolTip = text
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    /// Adds the language commands to the right-click menu.
    ///
    /// A shortcut nobody can find is a shortcut nobody uses, and this is
    /// the one place to put them that doesn't mean touching the
    /// application's menu bar — which belongs to the terminal.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }

        // Anchored to where the pointer is, not to the selection: the whole
        // point of right-clicking a symbol is to ask about *that* one.
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)

        var items: [NSMenuItem] = []
        if let onJumpToDefinition {
            items.append(item("Go to Definition", key: "") { onJumpToDefinition(offset) })
        }
        if let onFindReferences {
            items.append(item("Find All References", key: "g", [.command, .control]) {
                onFindReferences(offset)
            })
        }
        if let onRename {
            items.append(item("Rename Symbol…", key: "r", [.command, .control]) {
                onRename(offset)
            })
        }
        if let onFormat {
            items.append(item("Format Document", key: "f", [.command, .option]) { onFormat() })
        }

        guard !items.isEmpty else { return menu }
        menu.insertItem(NSMenuItem.separator(), at: 0)
        for (index, entry) in items.enumerated() {
            menu.insertItem(entry, at: index)
        }
        return menu
    }

    private func item(
        _ title: String,
        key: String,
        _ modifiers: NSEvent.ModifierFlags = [],
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.representedObject = MenuAction(run: action)
        return item
    }

    /// Boxes a closure so it can ride on `representedObject`, which only
    /// takes an object — the alternative is a selector per command and a
    /// property to remember which one was meant.
    private final class MenuAction: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuAction)?.run()
    }

    /// ⌃Space asks for completions, the way most editors bind it.
    ///
    /// In `keyDown` rather than `performKeyEquivalent` because that one only
    /// sees ⌘ combinations — a plain modifier+key never reaches it.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .control, event.charactersIgnoringModifiers == " ",
           completionProvider != nil {
            complete(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// Fetches, then opens the list.
    ///
    /// Re-entrant by design: the first call fetches and returns without a
    /// popup, then calls itself once the answer is in. The flag is what
    /// stops that second call from starting another fetch and never
    /// showing anything.
    override func complete(_ sender: Any?) {
        guard let completionProvider, !isFetchingCompletions else {
            super.complete(sender)
            return
        }

        isFetchingCompletions = true
        let offset = selectedRange().location
        Task { [weak self] in
            let words = await completionProvider(offset)
            await MainActor.run {
                guard let self else { return }
                self.pendingCompletions = words
                self.isFetchingCompletions = false
                guard !words.isEmpty else { return }
                self.openCompletionList(sender)
            }
        }
    }

    /// Reaches `super.complete` from inside the fetch's closure, which Swift
    /// will not let a captured `self` do directly.
    private func openCompletionList(_ sender: Any?) {
        super.complete(sender)
    }

    /// Serves what the last fetch returned, narrowed to what is typed.
    override func completions(
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String]? {
        guard completionProvider != nil else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        let partial = (string as NSString).substring(with: charRange)
        guard !partial.isEmpty else { return pendingCompletions }
        return pendingCompletions.filter {
            $0.range(of: partial, options: [.caseInsensitive, .anchored]) != nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s":
            if modifiers.contains(.shift) { onSaveAll?() } else { onSave?() }
            return true
        case "f" where modifiers.contains(.shift):
            guard let onSearchWorkspace else { break }
            onSearchWorkspace()
            return true
        case "r" where modifiers.contains(.control):
            guard let onRename else { break }
            onRename(selectedRange().location)
            return true
        case "f" where modifiers.contains(.option):
            guard let onFormat else { break }
            onFormat()
            return true
        case "g" where modifiers.contains(.control):
            guard let onFindReferences else { break }
            onFindReferences(selectedRange().location)
            return true
        case "w":
            // Only claimed when there is a handler: without one this is
            // still the terminal's close, and swallowing it would leave a
            // window nothing can shut.
            guard let onCloseTab else { break }
            onCloseTab()
            return true
        default:
            break
        }

        return super.performKeyEquivalent(with: event)
    }

    /// True when this view is laying out through TextKit 2.
    ///
    /// Exists for the test. The failure it guards against is invisible at
    /// runtime — everything still works, just with the whole document laid
    /// out on every change — so nothing else would ever notice.
    var isUsingTextKit2: Bool { textLayoutManager != nil }
}
