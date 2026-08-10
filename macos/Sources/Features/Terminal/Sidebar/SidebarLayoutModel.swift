import AppKit
import Combine
import Foundation

/// App-wide sidebar collapse state. Shared by every window so switching
/// tabs never changes the sidebar geometry, and persisted so it
/// survives relaunches.
@MainActor
final class SidebarCollapseState: ObservableObject {
    static let shared = SidebarCollapseState()

    @Published var isCollapsed: Bool {
        didSet {
            UserDefaults.standard.set(isCollapsed, forKey: "SidebarCollapsed")
        }
    }

    init() {
        isCollapsed = UserDefaults.standard.bool(forKey: "SidebarCollapsed")
    }
}

/// Window-level sidebar actions and state shared between the controller
/// (which owns the split view) and the SwiftUI sidebar chrome.
@MainActor
final class SidebarLayoutModel: ObservableObject {
    /// Creates a new terminal tab in this window's tab group.
    var onNewTab: () -> Void = {}

    /// Creates a new terminal tab that immediately starts a Claude session.
    var onNewClaudeTab: () -> Void = {}

    /// Which panel the sidebar is showing.
    ///
    /// Per-window, and deliberately **not** persisted. Every terminal tab is
    /// its own window with its own sidebar, so a remembered "last used
    /// panel" meant that switching tabs landed you in the file explorer you
    /// had opened somewhere else entirely — the panel appeared to follow you
    /// around. Files is somewhere you go on purpose, so a window always
    /// starts on terminals and only an actual click on the tab moves it.
    ///
    /// This lives here because both `SidebarView` and `SidebarTitlebarChrome`
    /// already observe this object, so the panel switch reaches the sidebar
    /// body and the titlebar buttons with no extra wiring.
    @Published var selectedPane: SidebarPane = .terminals
}

/// The sidebar | terminal split view, with a user-configurable divider:
/// default system color, hidden, or a custom color.
final class SidebarSplitView: NSSplitView {
    /// The pane whose tabs the ⌥⌘ shortcuts move between.
    ///
    /// Handled here, and not in `CodeNSTextView`, because that view is only
    /// in the responder chain while the *editor* has focus — and the whole
    /// point of the shortcut is to reach a file while you are typing in the
    /// terminal. This split view is the window's content view, so its
    /// `performKeyEquivalent` is consulted before the terminal surface sees
    /// the key.
    weak var editorCenter: EditorCenter?

    /// The standard editing keys, when a field in the sidebar has focus.
    ///
    /// Ghostty binds ⌘V, ⌘C, ⌘X and friends to the *terminal* above the
    /// responder chain, so a text field in the sidebar never saw them: typing
    /// in the search box worked and pasting into it did nothing. Handled here
    /// because this view is consulted before the surface, and only when the
    /// thing with focus is an editable field — otherwise the terminal keeps
    /// every one of them.
    private static let editingCommands: [String: Selector] = [
        "v": #selector(NSText.paste(_:)),
        "c": #selector(NSText.copy(_:)),
        "x": #selector(NSText.cut(_:)),
        "a": #selector(NSText.selectAll(_:)),
    ]

    private func routeEditingCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard modifiers == .command,
              let characters = event.charactersIgnoringModifiers?.lowercased(),
              let selector = Self.editingCommands[characters],
              let responder = window?.firstResponder
        else { return false }

        // Editable text only. A terminal surface is a responder too, and it
        // must keep these keys.
        guard let textView = responder as? NSTextView, textView.isEditable,
              textView.isDescendant(of: self)
        else { return false }

        return NSApp.sendAction(selector, to: responder, from: nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeEditingCommand(event) { return true }

        if let center = editorCenter,
           let characters = event.charactersIgnoringModifiers,
           let command = EditorCommands.paneCommand(
               for: characters,
               modifiers: event.modifierFlags,
               hasOpenFiles: !center.tabs.isEmpty
           ) {
            switch command {
            case .toggleTerminal: center.toggleTerminal()
            case .selectFile(let number): center.selectFile(at: number)
            }
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override var dividerColor: NSColor {
        switch AppearanceCoordinator.dividerMode {
        case .hidden: return .clear
        case .custom(let color): return color
        case .system: return super.dividerColor
        }
    }

    /// A hidden divider takes no space at all, so the panes meet edge to
    /// edge. Painting it to match instead never quite worked: the strip
    /// still sat above a transparent window, and no fill matches glass.
    /// The drag area it would have provided is restored by the delegate's
    /// `additionalEffectiveRectOfDividerAt`.
    override var dividerThickness: CGFloat {
        AppearanceCoordinator.dividerMode.isHidden ? 0 : super.dividerThickness
    }

    /// Drawing the divider directly rather than relying only on the
    /// `dividerColor` override: AppKit does not reliably re-read that
    /// property for an already-drawn divider, so a mode change in settings
    /// left the old divider on screen until the window was recreated.
    override func drawDivider(in rect: NSRect) {
        // The titlebar paints its own strip and composites above this view,
        // so drawing the divider up into it stacks a second coat over that
        // one column — a short dark tick in an otherwise even strip.
        let inset = safeAreaInsets.top
        let rect = rect.intersection(
            NSRect(
                x: bounds.minX,
                y: isFlipped ? bounds.minY + inset : bounds.minY,
                width: bounds.width,
                height: bounds.height - inset
            )
        )
        guard !rect.isEmpty else { return }

        switch AppearanceCoordinator.dividerMode {
        case .hidden:
            // Nothing to draw: the divider has no width in this mode.
            return
        case .custom(let color):
            color.setFill()
            rect.fill()
        case .system:
            super.drawDivider(in: rect)
        }
    }
}
