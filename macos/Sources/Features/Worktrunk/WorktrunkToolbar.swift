import AppKit

final class WorktrunkToolbar: NSToolbar, NSToolbarDelegate {
    private weak var targetController: TerminalController?

    init(target: TerminalController?) {
        self.targetController = target
        super.init(identifier: NSToolbar.Identifier("WorktrunkToolbar.v2"))
        delegate = self
        displayMode = .iconOnly
        allowsUserCustomization = false
        autosavesConfiguration = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .toggleSidebar:
            let item = NSToolbarItem(itemIdentifier: .toggleSidebar)
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
            button.bezelStyle = .toolbar
            button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            button.imagePosition = .imageOnly
            button.target = targetController
            button.action = #selector(TerminalController.toggleSidebar(_:))
            item.view = button
            item.label = "Toggle Sidebar"
            item.isNavigational = true
            return item
        default:
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
    }
}
