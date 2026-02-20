import SwiftUI
import MetalKit

/// Renders an MTKView with the given renderer class.
struct MetalView<V: MTKView>: View {
    @State private var metalView = V()

    var body: some View {
        MetalViewRepresentable(metalView: $metalView)
    }
}

private struct MetalViewRepresentable<V: MTKView>: NSViewRepresentable {
    @Binding var metalView: V

    func makeNSView(context: Context) -> some NSView {
        metalView
    }

    func updateNSView(_ view: NSViewType, context: Context) {
        updateMetalView()
    }

    func updateMetalView() {
    }
}
