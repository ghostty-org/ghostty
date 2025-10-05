import SwiftUI

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
        }
    }
}
