import SwiftUI

/// Pushes the terminal's content down by the pane tab bar's height.
///
/// A wrapper that *observes* the centre, because reactivity is the entire
/// point: the terminal's container closure is built once, so reading the
/// inset inline captured the value at build time — zero — and opening a file
/// changed nothing. The bar and the shell each get their own space; with no
/// file open the inset is zero and the terminal is exactly what it was.
struct PaneTabBarInsetView<Content: View>: View {
    @ObservedObject var center: EditorCenter
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.top, center.paneTabBarInset)
    }
}
