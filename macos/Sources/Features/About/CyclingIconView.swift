import SwiftUI
import GhosttyKit

/// A view that cycles through Ghostty's official icon variants.
struct CyclingIconView: View {
    @State private var currentIcon: Ghostty.MacOSIcon = .official
    @State private var isHovering: Bool = false

    private let icons: [Ghostty.MacOSIcon] = [
        .official,
        .blueprint,
        .chalkboard,
        .microchip,
        .glass,
        .holographic,
        .paper,
        .retro,
        .xray,
    ]
    private let timerPublisher = Timer.publish(every: 3, on: .main, in: .common)

    var body: some View {
        ZStack {
            iconView(for: currentIcon)
                .id(currentIcon)
        }
        .animation(.easeInOut(duration: 0.5), value: currentIcon)
        .frame(height: 128)
        .onReceive(timerPublisher.autoconnect()) { _ in
            if !isHovering {
                advanceToNextIcon()
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            advanceToNextIcon()
        }
        .help("macos-icon = \(currentIcon.rawValue)")
        .accessibilityLabel("Ghostree Application Icon")
        .accessibilityHint("Click to cycle through icon variants")
    }

    @ViewBuilder
    private func iconView(for icon: Ghostty.MacOSIcon) -> some View {
        let iconImage: Image = switch icon.assetName {
        case let assetName?: Image(assetName)
        case nil: ghosttyIconImage()
        }

        iconImage
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    private func advanceToNextIcon() {
        let currentIndex = icons.firstIndex(of: currentIcon) ?? 0
        let nextIndex = icons.indexWrapping(after: currentIndex)
        currentIcon = icons[nextIndex]
    }
}
