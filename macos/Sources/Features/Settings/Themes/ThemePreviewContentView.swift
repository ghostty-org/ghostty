import GhosttyKit
import SwiftUI

struct ThemePreviewContentView: View {
    var body: some View {
        SurfacePreviewView()
        Form {
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
