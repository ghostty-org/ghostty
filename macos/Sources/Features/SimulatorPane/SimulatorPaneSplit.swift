import SwiftUI

/// Puts the simulator pane to the right of the terminal, or gets out of the way
/// entirely when the pane is closed.
///
/// When hidden this renders `content` and nothing else — no split, no divider,
/// no sidebar view in the hierarchy — so a window that never opens the pane is
/// exactly the window it was before.
struct SimulatorPaneSplit<Content: View>: View {
    @ObservedObject var model: SimulatorPaneModel
    let dividerColor: Color
    @ViewBuilder let content: Content

    init(
        model: SimulatorPaneModel,
        dividerColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.dividerColor = dividerColor
        self.content = content()
    }

    var body: some View {
        if model.isVisible {
            SplitView(
                .horizontal,
                $model.split,
                dividerColor: dividerColor,
                left: { content },
                right: { SimulatorPaneView(model: model) },
                // Ghostty equalizes splits on a double-click of the divider.
                // A simulator sidebar taking half the window is not "equal",
                // it is just wrong, so this resets to the default instead.
                onEqualize: { model.split = 0.68 })
        } else {
            content
        }
    }
}
