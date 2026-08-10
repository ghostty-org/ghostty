import SwiftUI

/// Phantom's app icon in the about window, cycling through the alternates.
///
/// The name promised this and the view had stopped doing it — it only scaled on
/// hover, a leftover from when the artwork could not be swapped.
///
/// **Preview only.** Hovering and clicking here change nothing: the icon the
/// app wears is chosen in Settings › Icon, and an app that silently rebranded
/// itself because a pointer crossed a window would be a worse toy than it is a
/// feature. Leaving the icon returns it to whatever is actually in use.
struct CyclingIconView: View {
    @EnvironmentObject var viewModel: AboutViewModel

    /// Which alternate is showing, or nil for the real one.
    @State private var previewed: PhantomAppIcon?
    @State private var cycle: Task<Void, Never>?

    /// Slow enough to see each one, quick enough that the whole set goes by
    /// while somebody is still looking.
    private static let interval = Duration.milliseconds(700)

    var body: some View {
        icon
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: 128)
            .scaleEffect(viewModel.isHovering ? 1.05 : 1)
            .animation(.easeInOut(duration: 0.2), value: viewModel.isHovering)
            // Keyed on the icon so each swap crossfades instead of cutting.
            .id(previewed?.rawValue ?? "current")
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.25), value: previewed)
            .onHover { hovering in
                viewModel.isHovering = hovering
                if hovering { startCycling() } else { stopCycling() }
            }
            .onTapGesture { advance() }
            .accessibilityLabel("Phantom Application Icon")
            .accessibilityHint("Cycles through the alternate icons. Choose one in Settings.")
    }

    /// The artwork to draw: an alternate while previewing, otherwise the
    /// running application's own, so it matches the Dock including any tint the
    /// system applies.
    private var icon: Image {
        if let previewed, let image = previewed.image() {
            return Image(nsImage: image)
        }
        return ghosttyIconImage()
    }

    private func startCycling() {
        cycle?.cancel()
        cycle = Task {
            // Every case, so adding an icon needs nothing here.
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard !Task.isCancelled else { return }
                await MainActor.run { advance() }
            }
        }
    }

    private func stopCycling() {
        cycle?.cancel()
        cycle = nil
        previewed = nil
    }

    private func advance() {
        let all = PhantomAppIcon.allCases
        guard !all.isEmpty else { return }

        guard let showing = previewed,
              let index = all.firstIndex(of: showing)
        else {
            previewed = all.first
            return
        }
        previewed = all[(index + 1) % all.count]
    }
}
