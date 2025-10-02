import Cocoa
import GhosttyKit
import SwiftUI

struct ThemePreviewContentView: View {
    let surfaceView: Ghostty.SurfaceView

    var body: some View {
        Ghostty.ThemePreviewSection(surfaceView: surfaceView)
            .padding()
        Form {
            // Header with theme selector
            HStack {
                Text("Theme Preview")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
        .formStyle(.grouped)
    }
}
