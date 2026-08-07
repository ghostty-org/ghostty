import SwiftUI

/// Phantom's app icon, as shown in the about window.
///
/// Read from the running application rather than an asset so it always
/// matches whatever the Dock is showing, including the system's tinting.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    var body: some View {
        ghosttyIconImage()
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(height: 128)
            .scaleEffect(viewModel.isHovering ? 1.05 : 1)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isHovering)
            .onHover { hovering in
                viewModel.isHovering = hovering
            }
            .accessibilityLabel("Phantom Application Icon")
    }
}
