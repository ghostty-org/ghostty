import SwiftUI
import GhosttyKit

struct TerminalCommandPaletteView: View {
    /// The surface that this command palette represents.
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any actions
    /// result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup keyboard shortcuts.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    // The commands available to the command palette.
    private var commandOptions: [CommandOption] {
        guard let surface = surfaceView.surface else { return [] }

        var ptr: UnsafeMutablePointer<ghostty_command_s>? = nil
        var count: Int = 0
        ghostty_surface_commands(surface, &ptr, &count)
        guard let ptr else { return [] }

        let buffer = UnsafeBufferPointer(start: ptr, count: count)
        return Array(buffer).filter { c in
            let key = String(cString: c.action_key)
            switch (key) {
            case "toggle_tab_overview",
                "toggle_window_decorations",
                "show_gtk_inspector",
                "toggle_tab_icons":
                return false
            default:
                return true
            }
        }.map { c in
            let action = String(cString: c.action)
            return CommandOption(
                title: String(cString: c.title),
                description: String(cString: c.description),
                symbols: ghosttyConfig.keyboardShortcut(for: action)?.keyList
            ) {
                onAction(action)
            }
        }
    }

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .transition(
                            .move(edge: .top)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.4, dampingFraction: 0.8))
                        ) // Spring animation
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the command palette disappears we need to send focus back to the
            // surface view we were overlaid on top of. There's probably a better way
            // to handle the first responder state here but I don't know it.
            if !newValue {
                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }
}

/// This is done to ensure that the given view is in the responder chain.
fileprivate struct ResponderChainInjector: NSViewRepresentable {
    let responder: NSResponder

    func makeNSView(context: Context) -> NSView {
        let dummy = NSView()
        DispatchQueue.main.async {
            dummy.nextResponder = responder
        }
        return dummy
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
