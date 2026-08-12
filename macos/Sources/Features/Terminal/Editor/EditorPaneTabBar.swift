import SwiftUI

/// The pane's tab bar, above whichever surface is showing.
///
/// Rendered by **both** the terminal and the editor, from the same
/// `EditorCenter`. That looks like duplication and is the opposite: the bar
/// has to be present while the terminal is on screen — otherwise there is no
/// way back to a file — and the terminal and the editor are sibling AppKit
/// views with no shared SwiftUI parent to hang it on. One view, one state,
/// drawn by whichever half is visible; only ever one at a time.
///
/// Collapses to nothing when no file is open. With the terminal alone there
/// is nothing to switch to, so the bar would be a control that does nothing
/// while costing the terminal a row of its height to say so.
struct EditorPaneTabBar: View {
    @ObservedObject var center: EditorCenter

    var body: some View {
        content
            // Always full width, never an opinion about it.
            //
            // With no file open the body below is *empty*, and an
            // `NSHostingView` wrapping empty SwiftUI reports an intrinsic
            // width of nothing. Pinned to both sides of the pane, that made
            // the hosting view dictate the pane's width instead of following
            // it: the window opened narrow and refused to grow sideways —
            // double-clicking the titlebar only made it taller.
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if center.tabs.showsTabBar {
            VStack(spacing: 0) {
                EditorTabBar(
                    tabs: center.tabs.tabs,
                    selection: center.tabs.selection,
                    needsDirectory: { center.tabs.needsDirectory(for: $0) },
                    onSelect: { center.select($0) },
                    onClose: { center.requestClose($0) },
                    terminalTitle: center.terminalTitle,
                    onSelectTerminal: { center.selectTerminal() }
                )
                Divider()
            }
        }
    }
}
