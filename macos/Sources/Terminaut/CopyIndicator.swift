import SwiftUI

/// A brief "Copied" indicator that appears when text is copied to clipboard
struct CopyIndicator: View {
    @Binding var isVisible: Bool

    var body: some View {
        if isVisible {
            HStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 12))
                Text("Copied")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// View modifier that overlays a copy indicator at the bottom of the view
struct CopyIndicatorModifier: ViewModifier {
    @State private var isIndicatorVisible = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                CopyIndicator(isVisible: $isIndicatorVisible)
                    .padding(.bottom, 16)
                    .animation(.easeOut(duration: 0.15), value: isIndicatorVisible)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .ghosttyDidCopyToClipboard)
            ) { _ in
                triggerIndicator()
            }
    }

    private func triggerIndicator() {
        // Show the indicator
        withAnimation(.easeOut(duration: 0.15)) {
            isIndicatorVisible = true
        }

        // Hide after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeIn(duration: 0.2)) {
                self.isIndicatorVisible = false
            }
        }
    }
}

extension View {
    /// Adds a "Copied" indicator overlay that appears when clipboard copy occurs
    func copyIndicator() -> some View {
        modifier(CopyIndicatorModifier())
    }
}
