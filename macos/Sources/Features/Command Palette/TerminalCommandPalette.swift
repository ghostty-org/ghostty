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

    @State private var query: String = ""

    private enum WorktrunkPaletteMode: Hashable {
        case root
        case pickRepo
        case createWorktree(repoID: UUID)
    }

    @State private var worktrunkMode: WorktrunkPaletteMode = .root

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
                            query: $query,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: commandOptions
                        )
                        .id(worktrunkMode)
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
                worktrunkMode = .root
                query = ""

                // Has to be on queue because onChange happens on a user-interactive
                // thread and Xcode is mad about this call on that.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }
    
    /// All commands available in the command palette, combining update and terminal options.
    private var commandOptions: [CommandOption] {
        switch worktrunkMode {
        case .root:
            var options: [CommandOption] = []
            // Updates always appear first
            options.append(contentsOf: updateOptions)

            let rest = (worktrunkRootOptions + jumpOptions + terminalOptions).sorted { a, b in
                let aNormalized = a.title.replacingOccurrences(of: ":", with: "\t")
                let bNormalized = b.title.replacingOccurrences(of: ":", with: "\t")
                let comparison = aNormalized.localizedCaseInsensitiveCompare(bNormalized)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                if let aSortKey = a.sortKey, let bSortKey = b.sortKey {
                    return aSortKey < bSortKey
                }
                return false
            }
            options.append(contentsOf: rest)
            return options

        case .pickRepo:
            return worktrunkPickRepoOptions

        case .createWorktree:
            return worktrunkCreateWorktreeOptions
        }
    }

    /// Commands for installing or canceling available updates.
    private var updateOptions: [CommandOption] {
        var options: [CommandOption] = []
        
        guard let updateViewModel, updateViewModel.state.isInstallable else {
            return options
        }
        
        // We override the update available one only because we want to properly
        // convey it'll go all the way through.
        let title: String
        if case .updateAvailable = updateViewModel.state {
            title = "Update Ghostree and Restart"
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
        
        options.append(CommandOption(
            title: "Cancel or Skip Update",
            description: "Dismiss the current update process"
        ) {
            updateViewModel.state.cancel()
        })
        
        return options
    }

    /// Custom commands from the command-palette-entry configuration.
    private var terminalOptions: [CommandOption] {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return [] }
        return appDelegate.ghostty.config.commandPaletteEntries
            .filter(\.isSupported)
            .map { c in
                CommandOption(
                    title: c.title,
                    description: c.description
                ) {
                    onAction(c.action)
                }
            }
    }

    /// Commands for jumping to other terminal surfaces.
    private var jumpOptions: [CommandOption] {
        TerminalController.all.flatMap { controller -> [CommandOption] in
            guard let window = controller.window else { return [] }

            let color = (window as? TerminalWindow)?.tabColor
            let displayColor = color != TerminalTabColor.none ? color : nil

            return controller.surfaceTree.map { surface in
                let title = surface.title.isEmpty ? window.title : surface.title
                let displayTitle = title.isEmpty ? "Untitled" : title
                let pwd = surface.pwd?.abbreviatedPath
                let subtitle: String? = if let pwd, !displayTitle.contains(pwd) {
                    pwd
                } else {
                    nil
                }

                return CommandOption(
                    title: "Focus: \(displayTitle)",
                    subtitle: subtitle,
                    leadingIcon: "rectangle.on.rectangle",
                    leadingColor: displayColor?.displayColor.map { Color($0) },
                    sortKey: AnySortKey(ObjectIdentifier(surface))
                ) {
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: surface
                    )
                }
            }
        }
    }

    private var terminalController: TerminalController? {
        surfaceView.window?.windowController as? TerminalController
    }

    private var worktrunkStore: WorktrunkStore? {
        (NSApp.delegate as? AppDelegate)?.worktrunkStore
    }

    private var worktrunkRootOptions: [CommandOption] {
        guard terminalController != nil, let store = worktrunkStore else { return [] }

        let linkFromCwd = CommandOption(
            title: "Worktrunk: Link repo from current directory",
            description: "Add the current directory to Worktrunk (runs `wt -C <pwd> list` to validate)."
        ) { [surfaceView] in
            guard let pwd = surfaceView.pwd else { return }
            Task { await store.addRepositoryValidated(path: pwd) }
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkAtTitle = trimmed.isEmpty
            ? "Worktrunk: Link repo at “<type path in palette>”"
            : "Worktrunk: Link repo at “\(trimmed)”"

        let linkAtPath = CommandOption(
            title: linkAtTitle,
            description: "Uses the palette query as a path and adds it to Worktrunk."
        ) { [trimmed] in
            guard !trimmed.isEmpty else { return }
            Task { await store.addRepositoryValidated(path: trimmed) }
        }

        let newWorktree = CommandOption(
            title: "Worktrunk: New worktree…",
            description: "Pick a repo, then type a branch/worktree name and press Enter.",
            dismissOnSelect: false
        ) {
            worktrunkMode = .pickRepo
            query = ""
        }

        return [newWorktree, linkFromCwd, linkAtPath]
    }

    private var worktrunkPickRepoOptions: [CommandOption] {
        guard terminalController != nil, let store = worktrunkStore else { return [] }

        var options: [CommandOption] = []

        for repo in store.repositories {
            options.append(CommandOption(
                title: "Worktrunk: Use repo “\(repo.name)”",
                subtitle: repo.path,
                dismissOnSelect: false
            ) {
                worktrunkMode = .createWorktree(repoID: repo.id)
                query = ""
            })
        }

        options.append(CommandOption(
            title: "Worktrunk: Back",
            dismissOnSelect: false,
            pinned: true
        ) {
            worktrunkMode = .root
            query = ""
        })

        return options
    }

    private var worktrunkCreateWorktreeOptions: [CommandOption] {
        guard let controller = terminalController, let store = worktrunkStore else { return [] }
        guard case .createWorktree(let repoID) = worktrunkMode else { return [] }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var options: [CommandOption] = []
        if trimmed.isEmpty {
            options.append(CommandOption(
                title: "Worktrunk: Type branch/worktree name to create",
                description: "Type the branch/worktree name in the palette query, then press Enter.",
                dismissOnSelect: false
            ) {})
        } else {
            options.append(CommandOption(
                title: "Worktrunk: Create worktree “\(trimmed)”",
                emphasis: true,
                dismissOnSelect: false
            ) { [trimmed] in
                Task {
                    let created = await store.createWorktree(
                        repoID: repoID,
                        branch: trimmed,
                        base: nil,
                        createBranch: true
                    )
                    guard let created else { return }
                    await MainActor.run {
                        controller.openWorktreeFromPalette(atPath: created.path)
                        worktrunkMode = .root
                        query = ""
                        isPresented = false
                    }
                }
            })
        }

        options.append(CommandOption(
            title: "Worktrunk: Back",
            dismissOnSelect: false,
            pinned: true
        ) {
            worktrunkMode = .pickRepo
            query = ""
        })

        options.append(CommandOption(
            title: "Worktrunk: Cancel",
            dismissOnSelect: false,
            pinned: true
        ) {
            worktrunkMode = .root
            query = ""
        })

        return options
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
