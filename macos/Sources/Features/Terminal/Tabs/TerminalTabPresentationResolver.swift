import AppKit

@MainActor
enum TerminalTabPresentationResolver {
    static func resolve(_ controller: TerminalController, index: Int, selected: Bool,
                        activities: TabActivityStore?,
                        icons: AnyGhosttyTabIconProvider = .init(CompositeGhosttyTabIconProvider(overrides: []))) -> GhosttyTabPresentation? {
        guard let surface = controller.focusedSurface ?? controller.surfaceTree.first else { return nil }
        let settings = OhMyGhosttySettings.shared
        let session = controller.paneSessionContext(for: surface) ?? .init(workingDirectory: surface.pwd, terminalTitle: surface.title)
        let activity = controller.focusedAgentActivity() ?? activities?.activity(for: controller.tabSessionID)
        let agent = activity.flatMap { SupportedAgent(rawValue: $0.source) }
        let base = controller.titleOverride ?? (agent == nil ? session.presentationTitle(pathDisplay: settings.tabPathDisplay)
            : session.agentPathTitle(pathDisplay: settings.tabPathDisplay))
        let title = agent?.normalizedTitle(base) ?? base
        let context = GhosttyTabIconContext(tabID: controller.tabSessionID, title: title, activity: activity,
                                           defaultIcon: session.workspace?.icon ?? .systemSymbol(session.tabIconSystemName))
        return .init(title: title, remoteBreadcrumb: controller.titleOverride == nil ? session.remoteTabBreadcrumb : nil,
                     shortcut: settings.showShortcutLabels ? controller.tabShortcutLabel(for: index) : nil,
                     icon: icons.icon(for: context) ?? .systemSymbol("terminal"), activity: activity,
                     selected: selected, hovered: false)
    }
}
