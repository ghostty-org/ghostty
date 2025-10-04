import GhosttyKit
import SwiftUI

struct ThemeContentView: View {
    var body: some View {
        VStack(spacing: 5) {
            SurfacePreviewView()
            Form {
                FontPicker()
            }
            .formStyle(.grouped)
        }
    }
}
