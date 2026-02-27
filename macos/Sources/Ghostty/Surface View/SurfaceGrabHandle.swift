import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging the window.
    struct SurfaceGrabHandle: View {
        @ObservedObject var surfaceView: SurfaceView

        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false

        private var ellipsisVisible: Bool {
            surfaceView.mouseOverSurface && surfaceView.cursorVisible
        }

        var body: some View {
            ZStack {
                SurfaceDragSource(
                    surfaceView: surfaceView,
                    isDragging: $isDragging,
                    isHovering: $isHovering
                )
                .frame(width: 80, height: 12)
                .contentShape(Rectangle())

                if ellipsisVisible {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.primary.opacity(isHovering ? 0.8 : 0.3))
                        .offset(y: -3)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
