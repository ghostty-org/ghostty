import SwiftUI

struct QuickTerminalView: View {
    let ghostty: Ghostty.App

    let controller: QuickTerminalController
    let tabManager: QuickTerminalTabManager

    var body: some View {
        VStack(spacing: 0) {
            QuickTerminalTabBarView(tabManager: tabManager)
            TerminalView(
                ghostty: ghostty,
                viewModel: controller,
                delegate: controller,
            )
        }
    }
}
