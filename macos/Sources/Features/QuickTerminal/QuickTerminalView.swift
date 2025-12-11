import SwiftUI
import UniformTypeIdentifiers

struct QuickTerminalView: View {
    let ghostty: Ghostty.App

    var controller: QuickTerminalController
    @ObservedObject var tabManager: QuickTerminalTabManager

    var body: some View {
        VStack(spacing: 0) {
            if tabManager.tabs.count > 1 {
                QuickTerminalTabBarView(tabManager: tabManager)
            }
            TerminalView(
                ghostty: ghostty,
                viewModel: controller,
                delegate: controller,
            )
            .onDrop(of: [.quickTerminalTab], isTargeted: nil) { _ in
                // Tab dropped on terminal surface - move to new window
                if let tab = tabManager.draggedTab {
                    tabManager.moveTabToNewWindow(tab)
                    return true
                }
                return false
            }
        }
    }
}
