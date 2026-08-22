import SwiftUI

/// Allows us to capture and handle middle mouse click events.
///
/// WARNING: This will overlay the entire View it's applied to,
/// so it "disables" other normal events from that View.
private class MiddleClickNSView: NSView {
    var onMiddleClick: () -> Void

    init(onMiddleClick: @escaping () -> Void) {
        self.onMiddleClick = onMiddleClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == Constants.middleMouseClickButtonNumber {
            onMiddleClick()
        }
    }
}

extension MiddleClickNSView {
    enum Constants {
        static let middleMouseClickButtonNumber = 2
    }
}

private struct MiddleClickRepresentable: NSViewRepresentable {
    var onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        MiddleClickNSView(onMiddleClick: onMiddleClick)
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}

private struct MiddleClickModifier: ViewModifier {
    var action: () -> Void

    func body(content: Content) -> some View {
        content.overlay(MiddleClickRepresentable(onMiddleClick: action))
    }
}

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        self.modifier(MiddleClickModifier(action: action))
    }
}
