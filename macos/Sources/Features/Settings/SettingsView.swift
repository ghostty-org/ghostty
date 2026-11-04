import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum OhMyGhosttySettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case tabs
    case terminal
    case controls
    case editor
    case keyboard
    case git
    case ssh
    case agents
    case plugins
    case advanced

    static let navigationOrder: [Self] = [
        .general, .appearance, .tabs, .terminal, .controls, .editor,
        .keyboard, .agents, .git, .ssh, .plugins, .advanced
    ]

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "rectangle.split.3x1"
        case .terminal: "terminal"
        case .controls: "cursorarrow"
        case .editor: "curlybraces.square"
        case .keyboard: "keyboard"
        case .git: "point.3.connected.trianglepath.dotted"
        case .ssh: "network"
        case .agents: "sparkles"
        case .plugins: "puzzlepiece.extension"
        case .advanced: "slider.horizontal.3"
        }
    }
}

@MainActor
final class OhMyGhosttySettingsWindowController: NSWindowController {
    private var appearanceCancellables: Set<AnyCancellable> = []

    init(
        settings: OhMyGhosttySettings,
        initialSelection: OhMyGhosttySettingsTab = .tabs
    ) {
        let root = NativeSettingsController(settings: settings, initialSelection: initialSelection)
        let window = SettingsWindow(contentViewController: root)
        window.title = SettingsStrings(language: settings.language).windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.isOpaque = true
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 820, height: 540)
        window.setFrameAutosaveName("OhMyGhosttySettingsWindow")
        super.init(window: window)

        applyAppearance(settings)
        settings.objectWillChange.sink { [weak self, weak settings] _ in
            DispatchQueue.main.async {
                guard let self, let settings else { return }
                self.applyAppearance(settings)
            }
        }.store(in: &appearanceCancellables)
        // Re-apply when the app appearance changes (theme/config switches), so a
        // settings window opened before the change follows the new OMG theme.
        NSApp.publisher(for: \.effectiveAppearance).sink { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            self.applyAppearance(settings)
        }.store(in: &appearanceCancellables)
        NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)
            .filter { $0.object == nil }
            .sink { [weak self, weak settings] _ in
                // The notification precedes replacement of the app's config.
                DispatchQueue.main.async {
                    guard let self, let settings else { return }
                    self.applyAppearance(settings)
                }
            }.store(in: &appearanceCancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        // Capture the invoking terminal before Settings becomes the key window.
        let source = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { $0.windowController is TerminalController }
        if let screen = source?.screen, let window, window.screen != screen {
            window.setFrame(Self.frame(window.frame, on: screen.visibleFrame), display: false)
        }
        super.showWindow(sender)
    }

    static func frame(_ frame: NSRect, on visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(frame.width, visibleFrame.width),
            height: min(frame.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func applyAppearance(_ settings: OhMyGhosttySettings) {
        guard let window else { return }
        let title = SettingsStrings(language: settings.language).windowTitle
        if window.title != title {
            window.title = title
        }
        let appearance: NSAppearance?
        switch settings.windowThemeOverride {
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        case .system:
            appearance = nil
        case nil:
            // Follow the same effective appearance as terminal windows so the
            // settings window tracks OMG's theme, including automatic switches.
            appearance = NSApp.effectiveAppearance
        }
        // Follow the OMG/terminal theme background color (e.g. Atom One Dark),
        // not the default aqua/darkAqua window background.
        let palette = OMGThemeBackground.palette()
        window.backgroundColor = palette.background
        (window.contentViewController as? NativeSettingsController)?.applyPalette(palette)
        window.appearance = appearance
        window.contentView?.needsDisplay = true
    }
}

final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Compatibility entry point for previews; the live window owns this controller directly.
struct SettingsView: NSViewControllerRepresentable {
    let settings: OhMyGhosttySettings
    var initialSelection: OhMyGhosttySettingsTab = .tabs
    var palette: OMGThemePalette?
    var initialSearch = ""

    func makeNSViewController(context: Context) -> NativeSettingsController {
        let controller = NativeSettingsController(settings: settings, initialSelection: initialSelection)
        _ = controller.view
        if let palette {
            controller.applyPalette(palette)
            controller.view.appearance = NSAppearance(named: palette.colorScheme == .dark ? .darkAqua : .aqua)
        }
        controller.searchFor(initialSearch)
        return controller
    }
    func updateNSViewController(_ controller: NativeSettingsController, context: Context) {}
}
