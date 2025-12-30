import AppKit
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
                            Image(systemName: "ellipsis")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .contentShape(Rectangle())
                    .overlay {
                        SurfaceDragSource(
                            surfaceView: surfaceView,
                            isDragging: $isDragging,
                            isHovering: $isHovering
                        )
                    }
                
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
