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
    /// The minimap's width when shown. Named for the measurement rather than
    /// the view, because the coordinator already has a `minimapWidth`
    /// constraint and two things called the same thing is how the wrong one
    /// gets used.
    static let minimapColumnWidth: CGFloat = 70

    /// The text as the *host* last set it: loaded from disk, reverted,
    /// formatted, renamed. Not a binding, and not the live buffer — while
    /// you type, the buffer is ahead of this and that is correct.
    let text: String

    /// Bumped by the host whenever it replaces the text. The view applies
    /// `text` when this changes and at no other time.
    let textRevision: Int

    let language: CodeLanguage
    let theme: CodeTheme
    let configuration: CodeEditorConfiguration

    /// Called after the user changes the text, with what the buffer now
    /// holds.
    ///
    /// The text comes *out* through here rather than through a binding that
    /// goes both ways. A two-way binding is what `TextEditor` does, and the
    /// half that writes back into the view is what makes it destroy the
    /// selection and the undo stack — so this reports, and only the
    /// revision above can replace.
    var onEdit: (String) -> Void = { _ in }

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
        minimap.isHidden = !configuration.showsMinimap
        // Scrolls, and only scrolls. The selection is the reader's, not the
        // map's — and this also drops a walk over every line of the document
        // that used to run on each event of a drag.
        minimap.onScrollToFraction = { [weak scrollView] fraction in
            guard let scrollView, let document = scrollView.documentView else { return }
            scrollView.contentView.scroll(to: NSPoint(
                x: scrollView.contentView.bounds.minX,
                y: Coordinator.scrollTarget(
                    fraction: fraction,
                    documentHeight: document.frame.height,
                    visibleHeight: scrollView.contentView.bounds.height
                )
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        let container = NSView()
        container.addSubview(gutter)
        container.addSubview(scrollView)
        container.addSubview(minimap)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let minimapWidth = minimap.widthAnchor.constraint(
            equalToConstant: configuration.showsMinimap ? Self.minimapColumnWidth : 0
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

        // The gutter and the minimap already listen to this; the coordinator
        // needs it too, to colour a large document as it is scrolled into.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrolled),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        context.coordinator.applyIfNewRevision(text: text, revision: textRevision)
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

        // Applied when the *host* replaced the text, never because the two
        // differ.
        //
        // Comparing strings was the bug: as soon as anything was typed the
        // view held more than the host did, so the next SwiftUI update —
        // which happens for reasons that have nothing to do with this view —
        // read that difference as "the host has new content" and overwrote
        // the edits, insertion point back to zero. A revision the host bumps
        // when it means it says the one thing a comparison cannot: who
        // changed it.
        context.coordinator.applyIfNewRevision(text: text, revision: textRevision)

        // After the text, so a jump into a file that is being opened in the
        // same breath lands on a document that already has its content.
        if let reveal { context.coordinator.reveal(reveal) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let storage: CodeTextStorage
        let onEdit: (String) -> Void
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

        /// The host revision currently in the buffer. Starts at a value no
        /// host will use, so the first update always loads.
        private var appliedRevision = Int.min

        /// The pending minimap rebuild. See `scheduleMinimapRefresh`.
        private var minimapTask: Task<Void, Never>?

        /// Whether this document is too big to colour in one go.
        ///
        /// Highlighting is one regex pass over everything it is given, and
        /// on a generated module interface — tens of thousands of lines,
        /// which is precisely where go-to-definition lands — that pass is
        /// the pause between clicking and seeing the file. Past this size
        /// only what you are looking at is coloured, and the rest follows as
        /// you scroll to it.
        private var highlightsOnDemand = false
        private var highlightTask: Task<Void, Never>?

        /// Around a quarter of a megabyte: comfortably above any file a
        /// person wrote by hand, and well below the generated ones.
        private static let wholeDocumentBudget = 256 * 1024

        /// The underlines currently drawn, so an update that changed
        /// something else doesn't walk the whole document to redraw marks
        /// that haven't moved.
        private var appliedUnderlines: [NSRange] = []

        /// The bracket spans currently coloured, guarded the same way.
        private var appliedBrackets: [BracketDepth.Span] = []

        /// The look currently applied, so an update that changed something
        /// else doesn't rewrite every attribute in the document.
        private var appliedTheme: CodeTheme?
        private var appliedConfiguration: CodeEditorConfiguration?

        init(storage: CodeTextStorage, onEdit: @escaping (String) -> Void) {
            self.storage = storage
            self.onEdit = onEdit
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Replaces the buffer only when the host says it has new content.
        func applyIfNewRevision(text: String, revision: Int) {
            guard revision != appliedRevision else { return }
            appliedRevision = revision
            apply(text: text)
        }

        func apply(text: String) {
            guard let textView, let textStorage = textView.textStorage else { return }
            isApplyingExternalText = true
            defer { isApplyingExternalText = false }

            textStorage.setAttributedString(NSAttributedString(string: text))

            highlightsOnDemand = textStorage.length > Self.wholeDocumentBudget
            if highlightsOnDemand {
                highlightVisibleRegion()
            } else {
                let full = NSRange(location: 0, length: textStorage.length)
                storage.highlight(textStorage, in: full)
                colorBrackets(in: full)
            }

            gutter?.reload()
            scheduleMinimapRefresh()

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

        /// Where to scroll so a fraction of the document sits in the middle
        /// of the viewport.
        ///
        /// Centred, because the pointer is asking to *look* at that part of
        /// the file, and clamped so dragging to either end of the map stops
        /// at the ends of the document instead of overscrolling into blank
        /// space.
        static func scrollTarget(
            fraction: CGFloat,
            documentHeight: CGFloat,
            visibleHeight: CGFloat
        ) -> CGFloat {
            let scrollable = max(0, documentHeight - visibleHeight)
            let centred = fraction * documentHeight - visibleHeight / 2
            return min(scrollable, max(0, centred))
        }

        /// Colours what is on screen, plus a margin either side.
        ///
        /// The margin is what makes scrolling look continuous rather than
        /// like colour arriving behind the text.
        func highlightVisibleRegion() {
            guard let textView,
                  let textStorage = textView.textStorage,
                  let scrollView = textView.enclosingScrollView
            else { return }

            let visible = scrollView.contentView.bounds
            guard visible.height > 0 else { return }

            let top = textView.characterIndexForInsertion(
                at: NSPoint(x: 0, y: visible.minY)
            )
            let bottom = textView.characterIndexForInsertion(
                at: NSPoint(x: textView.bounds.width, y: visible.maxY)
            )
            let lower = max(0, min(top, bottom))
            let upper = min(textStorage.length, max(top, bottom))
            guard upper > lower else { return }

            let region = CodeTextStorage.invalidationRange(
                for: NSRange(location: lower, length: upper - lower),
                in: textStorage.string as NSString
            )
            storage.highlight(textStorage, in: region)
            colorBrackets(in: region)
        }

        /// Colours the brackets in a region by nesting depth.
        ///
        /// A pass of its own, because depth is counted and the highlighter's
        /// single regex cannot count. Runs after the syntax colours so it
        /// paints over them — a bracket is punctuation, and whatever rule
        /// happened to claim it has nothing to say about which pair it is.
        func colorBrackets(in region: NSRange) {
            guard let textView, let textStorage = textView.textStorage else { return }
            guard storage.configuration.colorsBracketPairs else {
                if !appliedBrackets.isEmpty {
                    appliedBrackets = []
                }
                return
            }

            let text = textStorage.string as NSString
            // The tokens the highlighter already produced, so a brace inside
            // a string or a comment doesn't open a level that never closes.
            let skipped = SyntaxHighlighter(language: storage.language)
                .tokens(in: textStorage.string, range: region)
                .filter { $0.kind == .string || $0.kind == .comment }
                .map(\.range)

            let spans = BracketDepth.spans(in: text, range: region, skipping: skipped)
            guard spans != appliedBrackets else { return }
            appliedBrackets = spans

            let colors = storage.theme.bracketColors
            guard !colors.isEmpty else { return }

            textStorage.beginEditing()
            for span in spans {
                let clipped = NSIntersectionRange(
                    span.range,
                    NSRange(location: 0, length: textStorage.length)
                )
                guard clipped.length > 0 else { continue }
                textStorage.addAttribute(
                    .foregroundColor,
                    value: colors[BracketDepth.slot(for: span.depth)],
                    range: clipped
                )
            }
            textStorage.endEditing()
            invalidateLayout(of: textView)
        }

        /// Tells TextKit 2 that what it laid out is no longer what to draw.
        ///
        /// Rewriting attributes in bulk leaves fragments the layout manager
        /// still believes are current, and the result is lines that go blank
        /// and come back when something else forces a redraw — the "text
        /// disappears for a moment" that showed up whenever a setting changed.
        /// Saying so explicitly beats hoping a later event does it.
        private func invalidateLayout(of textView: NSTextView) {
            guard let layoutManager = textView.textLayoutManager else {
                textView.needsDisplay = true
                return
            }

            layoutManager.invalidateLayout(for: layoutManager.documentRange)
            textView.needsLayout = true
            textView.needsDisplay = true
            gutter?.needsDisplay = true
        }

        /// Re-colours after a scroll settles, for a document being coloured
        /// on demand. Debounced: a flick of the wheel is one destination,
        /// not forty.
        @objc func scrolled() {
            guard highlightsOnDemand else { return }
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.highlightVisibleRegion()
            }
        }

        /// Rebuilds the minimap shortly, rather than now.
        ///
        /// The rebuild tokenises the **whole** document — a second full pass
        /// on top of the one that colours the text. Doing it inline meant
        /// paying it twice to open a file and once per keystroke, which on a
        /// fifty-thousand-line generated interface is exactly the pause that
        /// made going to a definition feel broken. The map is an overview:
        /// arriving a moment after the text is not a compromise, and while
        /// you type it only needs to settle when you stop.
        func scheduleMinimapRefresh() {
            guard let minimap, !minimap.isHidden else { return }
            minimapTask?.cancel()
            minimapTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self?.refreshMinimap()
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
            if highlightsOnDemand { highlightVisibleRegion() }

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

            // Nothing to do unless the look actually changed.
            //
            // This used to re-colour the **whole document** on every SwiftUI
            // update, and SwiftUI updates for reasons that have nothing to do
            // with appearance — including saving, which publishes the text.
            // Rewriting every attribute made TextKit 2 discard the laid-out
            // viewport and move the insertion point, which is exactly the
            // "⌘S blanks the top of the file and the cursor jumps a line"
            // that was reported.
            let unchanged = appliedTheme == theme && appliedConfiguration == configuration
            appliedTheme = theme
            appliedConfiguration = configuration

            storage.theme = theme
            storage.configuration = configuration
            guard !unchanged else { return }

            textView.font = configuration.font
            textView.insertionPointColor = theme.foreground
            textView.textColor = theme.foreground
            (textView as? CodeNSTextView)?.currentLineColor =
                configuration.highlightsCurrentLine ? theme.currentLineBackground : nil

            // Horizontal scrolling, when lines are not wrapped.
            //
            // `autoresizingMask` containing `.width` ties the text view to the
            // clip view's width, so it can never be wider than what is on
            // screen — and a scroll view does not scroll to somewhere its
            // document does not reach. A long line was simply cut off at the
            // right edge with no scroller to bring the rest in.
            textView.textContainer?.widthTracksTextView = configuration.wrapsLines
            if configuration.wrapsLines {
                textView.autoresizingMask = [.width]
                textView.textContainer?.size = NSSize(
                    width: textView.frame.width,
                    height: .greatestFiniteMagnitude
                )
            } else {
                textView.autoresizingMask = []
                textView.isHorizontallyResizable = true
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

            minimap?.isHidden = !configuration.showsMinimap
            minimapWidth?.constant = configuration.showsMinimap ? CodeTextView.minimapColumnWidth : 0
            if configuration.showsMinimap { refreshMinimap() }

            guard let textStorage = textView.textStorage else { return }

            // The selection is the reader's and must survive a recolour. A
            // full rewrite of the attributes moves it otherwise, which is how
            // the cursor climbed a line on save.
            let selection = textView.selectedRange()

            if highlightsOnDemand {
                highlightVisibleRegion()
            } else {
                let full = NSRange(location: 0, length: textStorage.length)
                storage.highlight(textStorage, in: full)
                colorBrackets(in: full)
            }

            if selection.location <= textStorage.length {
                textView.setSelectedRange(selection)
            }

            invalidateLayout(of: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // The band follows the cursor, and so does the highlighted number
            // in the gutter — both are the same fact drawn in two places.
            textView.needsDisplay = true
            gutter?.setCurrentLine(currentLineNumber(in: textView))
        }

        /// The one-based line the insertion point is on.
        private func currentLineNumber(in textView: NSTextView) -> Int? {
            guard textView.selectedRange().length == 0 else { return nil }
            let text = textView.string as NSString
            let upTo = NSRange(location: 0, length: min(textView.selectedRange().location, text.length))
            var line = 1
            text.enumerateSubstrings(in: upTo, options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                line += 1
            }
            return line
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText,
                  let textView = notification.object as? NSTextView,
                  let textStorage = textView.textStorage
            else { return }

            let edited = textView.selectedRange()
            let region = CodeTextStorage.invalidationRange(
                for: edited,
                in: textStorage.string as NSString
            )
            storage.highlight(textStorage, in: region)
            // Typing a brace changes the depth of everything after it, so
            // the whole document's colours are stale — but recolouring all of
            // it per keystroke is the cost this editor exists to avoid. The
            // visible region is what a reader can see being wrong.
            colorBrackets(in: region)
            gutter?.reload()
            scheduleMinimapRefresh()
            onEdit(textView.string)
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
    /// ⌘ held, and none of the modifiers that mean something else.
    ///
    /// Tested against the three that change what a click *is* — ⇧ extends a
    /// selection, ⌥ makes it rectangular, ⌃ opens a menu — rather than
    /// against the whole flag set. Demanding that the flags equal exactly
    /// `.command` is what broke this: a real event also carries caps lock,
    /// the function bit and the numeric-pad bit depending on the keyboard,
    /// so the comparison was false on hardware where it should have been
    /// true, and go-to-definition stopped responding at all.
    static func isJumpClick(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else { return false }
        return modifiers.isDisjoint(with: [.shift, .option, .control])
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

    /// This view's own undo stack.
    ///
    /// `NSTextView` asks the responder chain for an undo manager, and in this
    /// app the window's delegate answers with the *application's* one — the
    /// manager Ghostty uses to undo closing a split or a tab. So ⌘Z in the
    /// editor performed a window operation instead of undoing a keystroke, and
    /// typing registered nothing anybody could reach.
    ///
    /// Owning one here keeps the two apart: text undo belongs to the buffer,
    /// window undo belongs to the window, and neither can consume the other's
    /// ⌘Z because only one of them has focus at a time.
    private let textUndoManager = UndoManager()

    override var undoManager: UndoManager? { textUndoManager }

    /// The band behind the line the cursor is on, or nil for none.
    ///
    /// The colour comes from the host's theme — it was already there, and
    /// already populated, with nothing drawing it.
    var currentLineColor: NSColor? {
        didSet { needsDisplay = true }
    }

    /// Drawn *before* the text, so the band sits under the glyphs.
    ///
    /// In `draw` rather than `drawBackground(in:)` because this view draws no
    /// background at all — that is what lets the window's blur reach the code
    /// — and AppKit skips the background pass when it is off.
    override func draw(_ dirtyRect: NSRect) {
        drawCurrentLine()
        super.draw(dirtyRect)
    }

    private func drawCurrentLine() {
        guard let color = currentLineColor,
              // Only with a collapsed cursor: over a selection the band would
              // fight the selection's own highlight and read as a glitch.
              selectedRange().length == 0,
              let frame = currentLineFragmentFrame()
        else { return }

        color.setFill()
        NSRect(
            x: 0,
            y: frame.minY,
            width: bounds.width,
            height: frame.height
        ).intersection(bounds).fill()
    }

    /// The rect of the line the insertion point is on.
    ///
    /// Through `textLayoutManager`, never the legacy one: touching
    /// `.layoutManager` silently drops this view to TextKit 1 for good.
    private func currentLineFragmentFrame() -> NSRect? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(
                  contentManager.documentRange.location,
                  offsetBy: selectedRange().location
              ),
              let fragment = layoutManager.textLayoutFragment(for: location)
        else { return nil }

        var frame = fragment.layoutFragmentFrame
        frame.origin.y += textContainerOrigin.y
        return frame
    }

    /// True when this view is laying out through TextKit 2.
    ///
    /// Exists for the test. The failure it guards against is invisible at
    /// runtime — everything still works, just with the whole document laid
    /// out on every change — so nothing else would ever notice.
    var isUsingTextKit2: Bool { textLayoutManager != nil }
}
