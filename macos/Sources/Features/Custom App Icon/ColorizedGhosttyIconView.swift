import SwiftUI
import Cocoa

// For testing.
struct ColorizedGhosttyIconView: View {
    var body: some View {
        Image(nsImage: ColorizedGhosttyIcon(
            screenColors: [.purple, .blue],
            ghostColor: .yellow,
            frame: .aluminum
        ).makeImage(in: .main)!)
    }
}
