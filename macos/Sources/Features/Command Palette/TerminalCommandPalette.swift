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
    
    /// The update view model for showing update commands.
    var updateViewModel: UpdateViewModel?

    /// The callback when an action is submitted.
    var onAction: ((String) -> Void)

    // The commands available to the command palette.
    private var commandOptions: [CommandOption] {
        var options: [CommandOption] = []
        
        // Add update command if an update is installable. This must always be the first so
        // it is at the top.
        if let updateViewModel, updateViewModel.state.isInstallable {
            // We override the update available one only because we want to properly
            // convey it'll go all the way through.
            let title: String
            if case .updateAvailable = updateViewModel.state {
                title = "Update Ghostty and Restart"
            } else {
                title = updateViewModel.text
            }
            
            options.append(CommandOption(
                title: title,
                description: updateViewModel.description,
                leadingIcon: updateViewModel.iconName ?? "shippingbox.fill",
                badge: updateViewModel.badge,
                emphasis: true
            ) {
                (NSApp.delegate as? AppDelegate)?.updateController.installUpdate()
            })
        }
        
        // Add cancel/skip update command if the update is installable
        if let updateViewModel, updateViewModel.state.isInstallable {
            options.append(CommandOption(
                title: "Cancel or Skip Update",
                description: "Dismiss the current update process"
            ) {
                updateViewModel.state.cancel()
            })
        }
        
        // Add terminal commands
        guard let surface = surfaceView.surfaceModel else { return options }
        do {
            let terminalCommands = try surface.commands().map { c in
                return CommandOption(
                    title: c.title,
                    description: c.description,
                    symbols: ghosttyConfig.keyboardShortcut(for: c.action)?.keyList
                ) {
                    onAction(c.action)
                }
            }
            options.append(contentsOf: terminalCommands)
        } catch {
            return options
        }
        
        return options
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
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
                .transition(
                    .move(edge: .top)
                    .combined(with: .opacity)
                )
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isPresented)
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
