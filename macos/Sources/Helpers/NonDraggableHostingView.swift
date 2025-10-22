import SwiftUI

/// An NSHostingView subclass that prevents window dragging when clicking on the view.
///
/// By default, NSHostingViews in the titlebar allow the window to be dragged when
/// clicked. This subclass overrides `mouseDownCanMoveWindow` to return false,
/// preventing the window from being dragged when the user clicks on this view.
///
/// This is useful for titlebar accessories that contain interactive elements
/// (buttons, links, etc.) where you don't want accidental window dragging.
class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
