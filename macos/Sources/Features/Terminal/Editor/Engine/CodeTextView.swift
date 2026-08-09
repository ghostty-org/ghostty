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

        let minimap = CodeMinimapView(theme: theme)
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
        }

        context.coordinator.storage.setLanguage(language)
        context.coordinator.applyAppearance(theme: theme, configuration: configuration)
        scrollView.hasHorizontalScroller = !configuration.wrapsLines

        // Only when it actually differs — writing the same string back
        // would reset the insertion point and wipe the undo stack on every
        // SwiftUI update, which happens for reasons unrelated to this view.
        if textView.string != text {
            context.coordinator.apply(text: text)
        }
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

        /// Puts the text back at its top-left corner.
        private func scrollToOrigin() {
            guard let textView, let scrollView = textView.enclosingScrollView else { return }
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            gutter?.needsDisplay = true
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
