import SwiftUI

extension Ghostty {
    /// A grab handle overlay at the top of the surface for dragging the window.
    /// Only appears when hovering in the top region of the surface.
    struct SurfaceGrabHandle: View {
        private let handleHeight: CGFloat = 10
        private let previewScale: CGFloat = 0.2
        
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
            .draggable(surfaceView) {
                SurfaceDragPreview(surfaceView: surfaceView, scale: previewScale)
            }
        }
    }
    
    /// A miniature preview of the surface view for drag operations that updates periodically.
    private struct SurfaceDragPreview: View {
        let surfaceView: SurfaceView
        let scale: CGFloat
        
        var body: some View {
            // We need to use a TimelineView to ensure that this doesn't
            // cache forever. This will NOT let the view live update while
            // being dragged; macOS doesn't seem to allow that. But it will
            // make sure on new drags the screenshot is updated.
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                if let snapshot = surfaceView.asImage {
                    #if canImport(AppKit)
                    Image(nsImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: snapshot.size.width * scale,
                            height: snapshot.size.height * scale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 10)
                    #elseif canImport(UIKit)
                    Image(uiImage: snapshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            width: snapshot.size.width * scale,
                            height: snapshot.size.height * scale
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 10)
                    #endif
                }
            }
        }
    }
}
