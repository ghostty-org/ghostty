import GhosttyKit
import SwiftUI

struct ThemeContentView: View {
    var body: some View {
        Form {
            SurfacePreviewView()
            FontPicker()
        }
        .formStyle(.grouped)
    }
}
