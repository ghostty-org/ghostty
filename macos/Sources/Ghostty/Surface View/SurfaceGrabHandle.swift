import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging the window.
    /// Only appears when hovering in the top region of the surface.
    struct SurfaceGrabHandle: View {
        private let handleHeight: CGFloat = 10
        
        let surfaceView: SurfaceView
        
        @State private var isHovering: Bool = false
        @State private var isDragging: Bool = false
        
        var body: some View {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(isHovering || isDragging ? 0.15 : 0))
                    .frame(height: handleHeight)
                    .overlay(alignment: .center) {
                        if isHovering || isDragging {
                            Capsule()
                                .fill(Color.white.opacity(0.4))
                                .frame(width: 40, height: 4)
                        }
                    }
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHovering = hovering
                        }
                    }
                    .backport.pointerStyle(isHovering ? .grabIdle : nil)
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .draggable(surfaceView)
        }
    }
}
