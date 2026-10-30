import AppKit
import GhosttyKit
import SwiftUI

/// Shared terminal chrome and opaque auxiliary-window theme policy.
enum OMGThemeBackground {
    static func matchingChrome(
        color: Color,
        opacity: Double,
        windowIsOpaque: Bool,
        colorspaceIsDisplayP3: Bool
    ) -> Color {
        if windowIsOpaque || opacity >= 1 {
            return TerminalRenderColorQuantizer.matchingRenderedColor(
                color, colorspaceIsDisplayP3: colorspaceIsDisplayP3
            ).opacity(1)
        }
        return color.opacity(max(0, min(1, opacity)))
    }

    @MainActor
    static func palette(for window: NSWindow? = nil, config: Ghostty.Config? = nil) -> OMGThemePalette {
        let controller = (window?.windowController as? TerminalController)
            ?? ([NSApp.keyWindow, NSApp.mainWindow].compactMap { $0?.windowController as? TerminalController }.first)
        let config = config ?? controller?.ghostty.config ?? (NSApp.delegate as? AppDelegate)?.ghostty.config
        let background = config.map { NSColor($0.backgroundColor) } ?? .windowBackgroundColor
        let rendered = TerminalRenderColorQuantizer.matchingRenderedNSColor(
            background, colorspaceIsDisplayP3: config?.windowColorspaceIsDisplayP3 ?? false
        ).withAlphaComponent(1)
        var foreground = rendered.isLightColor ? NSColor.black : NSColor.white
        if let config {
            var value = ghostty_config_color_s()
            let key = "foreground"
            if ghostty_config_get(config.config, &value, key, UInt(key.utf8.count)) {
                foreground = TerminalRenderColorQuantizer.matchingRenderedNSColor(
                    NSColor(srgbRed: Double(value.r) / 255, green: Double(value.g) / 255,
                            blue: Double(value.b) / 255, alpha: 1),
                    colorspaceIsDisplayP3: config.windowColorspaceIsDisplayP3
                )
            }
        }
        return OMGThemePalette(background: rendered, foreground: foreground)
    }

    @MainActor
    static func windowBackground() -> NSColor { palette().background }

    @MainActor
    static func sidebarBackground() -> NSColor { palette().sidebar }
}

struct OMGThemePalette {
    let background: NSColor
    let foreground: NSColor

    var sidebar: NSColor { background.blended(withFraction: 0.08, of: foreground) ?? background }
    var colorScheme: ColorScheme { background.isLightColor ? .light : .dark }
}

/// Auxiliary windows stay opaque even when the invoking terminal is translucent.
/// Listen to config notifications, not just light/dark appearance changes: two
/// dark themes can have entirely different palettes.
private struct OMGThemedSurface: ViewModifier {
    @State private var palette: OMGThemePalette

    init(palette: OMGThemePalette) { _palette = State(initialValue: palette) }

    func body(content: Content) -> some View {
        content
            // Native semantic text keeps primary/secondary/disabled contrast.
            // A terminal foreground used as a hierarchical style compounds
            // dimming, and using it as tint makes enabled controls look disabled.
            .foregroundStyle(.primary)
            .tint(Color.accentColor)
            .background(Color(palette.background))
            // Drive the subtree's semantic colors from the theme palette without
            // taking over the window appearance: preferredColorScheme pushes onto
            // the hosting NSWindow and would override an explicit window-theme
            // setting, while the environment key is what AppKit-backed controls
            // read when resolving primary/secondary colors.
            .environment(\.colorScheme, palette.colorScheme)
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)) { notification in
                guard notification.object == nil,
                      let config = notification.userInfo?[Notification.Name.GhosttyConfigChangeKey] as? Ghostty.Config else { return }
                palette = OMGThemeBackground.palette(config: config)
            }
    }
}

extension View {
    @MainActor
    func omgThemedSurface(palette: OMGThemePalette) -> some View {
        modifier(OMGThemedSurface(palette: palette))
    }
}

/// A themed presentation adapter for OMG's two-button Git prompts. The existing
/// accessory controls and return codes are retained; no operation semantics move
/// into the presentation layer. System-owned alerts/file choosers remain native.
@MainActor
enum OMGThemeDialog {
    static func present(_ alert: NSAlert, for window: NSWindow?) async -> NSApplication.ModalResponse {
        precondition(alert.buttons.count == 2)
        let palette = OMGThemeBackground.palette(for: window)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = alert.messageText
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = palette.background
        panel.isOpaque = true
        panel.isReleasedWhenClosed = false
        if let accessory = alert.accessoryView { themeControls(accessory, palette: palette) }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (NSApplication.ModalResponse) -> Void = { response in
                guard !finished else { return }
                finished = true
                if let window { window.endSheet(panel) } else { NSApp.stopModal() }
                panel.orderOut(nil)
                panel.contentViewController = nil
                continuation.resume(returning: response)
            }
            let host = OMGNativeDialogController(alert: alert, finish: finish)
            host.bindTheme(to: window)
            panel.contentViewController = host
            panel.setContentSize(host.view.fittingSize)
            if let window {
                window.beginSheet(panel) { _ in finish(.alertSecondButtonReturn) }
            } else {
                panel.center()
                NSApp.runModal(for: panel)
            }
        }
    }

    private static func themeControls(_ view: NSView, palette: OMGThemePalette) {
        if let field = view as? NSTextField {
            field.textColor = .labelColor
            if field.drawsBackground { field.backgroundColor = palette.sidebar }
        }
        view.subviews.forEach { themeControls($0, palette: palette) }
    }
}

/// The native grouped Form paints its own opaque system-gray canvas and cards.
/// Use explicit themed sections instead, with wrapping captions and no native
/// column layout (which can give long captions an unbounded horizontal size).
struct OMGSettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        }
        .fixedSize(horizontal: false, vertical: true)
        .id(title)
    }
}

struct OMGSettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { configuration.content }
                .toggleStyle(OMGSettingsToggleStyle())
                .buttonStyle(OMGSettingsButtonStyle())
                .textFieldStyle(OMGSettingsTextFieldStyle())
                .controlSize(.small)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
    }
}
