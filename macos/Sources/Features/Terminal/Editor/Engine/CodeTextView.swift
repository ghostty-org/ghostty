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

    func makeNSView(context: Context) -> NSScrollView {
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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !configuration.wrapsLines
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.documentView = textView

        let gutter = CodeLineNumberView(
            textView: textView,
            theme: theme,
            font: configuration.font
        )
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = configuration.showsLineNumbers

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        context.coordinator.apply(text: text)
        context.coordinator.applyAppearance(theme: theme, configuration: configuration)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        context.coordinator.storage.setLanguage(language)
        context.coordinator.applyAppearance(theme: theme, configuration: configuration)
        scrollView.rulersVisible = configuration.showsLineNumbers
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
        weak var gutter: CodeLineNumberView?

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
            gutter?.reloadLineNumbers()
        }

        func applyAppearance(theme: CodeTheme, configuration: CodeEditorConfiguration) {
            guard let textView else { return }

            storage.theme = theme
            storage.configuration = configuration

            textView.font = configuration.font
            textView.backgroundColor = theme.background
            textView.insertionPointColor = theme.foreground
            textView.textColor = theme.foreground
            textView.enclosingScrollView?.backgroundColor = theme.background

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
            gutter?.reloadLineNumbers()
            onEdit()
        }
    }
}

/// The text view itself, kept as a named subclass so the tab and save
/// key handling in the host has something to attach to — and so a test can
/// assert it came up in TextKit 2.
final class CodeNSTextView: NSTextView {
    /// True when this view is laying out through TextKit 2.
    ///
    /// Exists for the test. The failure it guards against is invisible at
    /// runtime — everything still works, just with the whole document laid
    /// out on every change — so nothing else would ever notice.
    var isUsingTextKit2: Bool { textLayoutManager != nil }
}
