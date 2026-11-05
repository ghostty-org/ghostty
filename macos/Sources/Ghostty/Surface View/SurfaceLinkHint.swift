import SwiftUI

/// OMG: a small "⌘ Click to open" chip that follows the mouse while a link is
/// hovered. It replaces the pointing-hand cursor, which flickers on macOS 27.
struct SurfaceLinkHint: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let config: Ghostty.Config

    /// Offset from the hotspot so the chip sits below-right of the cursor.
    static let cursorOffset = CGSize(width: 14, height: 18)
    static let edgeInset: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            if surfaceView.isHoveringLink,
               surfaceView.linkHintCommandPressed,
               surfaceView.mouseOverSurface,
               let location = surfaceView.mouseLocationInSurface {
                chip
                    .fixedSize()
                    .modifier(PositionedChip(location: location, container: geo.size))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var chip: some View {
        let palette = OMGThemeBackground.palette(config: config)
        return Text(verbatim: Self.title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(palette.foreground))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(palette.sidebar))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(palette.foreground).opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }

    @MainActor static var title: String {
        SettingsStrings(language: OhMyGhosttySettings.shared.language).isChinese
            ? "⌘ 点击打开" : "⌘ Click to open"
    }

    /// Top-left origin for a chip of `size`, kept inside `container`.
    /// `location` is in the surface's AppKit (bottom-left origin) space.
    static func origin(for location: CGPoint, chip size: CGSize, container: CGSize) -> CGPoint {
        var x = location.x + cursorOffset.width
        var y = container.height - location.y + cursorOffset.height
        // Flip to the other side of the cursor rather than covering it.
        if x + size.width > container.width - edgeInset {
            x = location.x - cursorOffset.width - size.width
        }
        if y + size.height > container.height - edgeInset {
            y = container.height - location.y - cursorOffset.height - size.height
        }
        x = min(max(edgeInset, x), max(edgeInset, container.width - size.width - edgeInset))
        y = min(max(edgeInset, y), max(edgeInset, container.height - size.height - edgeInset))
        return CGPoint(x: x, y: y)
    }
}

/// Measures the chip once, then places it with `origin(for:chip:container:)`.
private struct PositionedChip: ViewModifier {
    let location: CGPoint
    let container: CGSize
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        let origin = SurfaceLinkHint.origin(for: location, chip: size, container: container)
        content
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { size = proxy.size }
                    .onChange(of: proxy.size) { size = $0 }
            })
            .offset(x: origin.x, y: origin.y)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
