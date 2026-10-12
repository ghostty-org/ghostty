import SwiftUI

extension Ghostty {
    struct SurfaceWrapper: View {
        // The surface to create a view for. This must be created upstream. As long as this
        // remains the same, the surface that is being rendered remains the same.
        @ObservedObject var surfaceView: SurfaceView

        // True if this surface is part of a split view. This is important to know so
        // we know whether to dim the surface out of focus.
        var isSplit: Bool = false

        // Maintain whether our view has focus or not
        @FocusState private var surfaceFocus: Bool

        // Maintain whether our window has focus (is key) or not
        @State private var windowFocus: Bool = true

        // Observe SecureInput to detect when its enabled
        @ObservedObject private var secureInput = SecureInput.shared

        @EnvironmentObject private var ghostty: Ghostty.App
        @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface

        private var isFocusedSurface: Bool {
            surfaceFocus || lastFocusedSurface?.value === surfaceView
        }

        var body: some View {
            let center = NotificationCenter.default

            ZStack {
                // We use a GeometryReader to get the frame bounds so that our metal surface
                // is up to date. See TerminalSurfaceView for why we don't use the NSView
                // resize callback.
                GeometryReader { geo in
                    let pubBecomeKey = center.publisher(for: NSWindow.didBecomeKeyNotification)
                    let pubResign = center.publisher(for: NSWindow.didResignKeyNotification)

                    SurfaceRepresentable(view: surfaceView, size: geo.size)
                        .focused($surfaceFocus)
                        .focusedValue(\.ghosttySurfacePwd, surfaceView.pwd)
                        .focusedValue(\.ghosttySurfaceView, surfaceView)
                        .focusedValue(\.ghosttySurfaceCellSize, surfaceView.cellSize)
                        .onReceive(pubBecomeKey) { notification in
                            guard let window = notification.object as? NSWindow else { return }
                            guard let surfaceWindow = surfaceView.window else { return }
                            windowFocus = surfaceWindow == window
                        }
                        .onReceive(pubResign) { notification in
                            guard let window = notification.object as? NSWindow else { return }
                            guard let surfaceWindow = surfaceView.window else { return }
                            if surfaceWindow == window {
                                windowFocus = false
                            }
                        }

                    // If our geo size changed then we show the resize overlay as configured.
                    if let surfaceSize = surfaceView.surfaceSize {
                        SurfaceResizeOverlay(
                            geoSize: geo.size,
                            size: surfaceSize,
                            overlay: ghostty.config.resizeOverlay,
                            position: ghostty.config.resizeOverlayPosition,
                            duration: ghostty.config.resizeOverlayDuration,
                            focusInstant: surfaceView.focusInstant)

                    }
                }
                .ghosttySurfaceView(surfaceView)

                // Progress report
                if let progressReport = surfaceView.progressReport, progressReport.state != .remove {
                    VStack(spacing: 0) {
                        SurfaceProgressBar(report: progressReport)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                // Readonly indicator badge
                if surfaceView.readonly {
                    ReadonlyBadge {
                        surfaceView.toggleReadonly(nil)
                    }
                }

                // Show key state indicator for active key tables and/or pending key sequences
                KeyStateIndicator(
                    keyTables: surfaceView.keyTables,
                    keySequence: surfaceView.keySequence
                )
                .zIndex(1)

                VStack(spacing: 0) {
                    // If we have a URL from hovering a link, we show that.
                    if let url = surfaceView.hoverUrl {
                        URLHoverBanner(url: url)
                    }

                    // Show a bar to indicate a child process has exited.
                    if let msg = surfaceView.childExitedMessage {
                        ChildExitedMessageBar(msg: msg)
                            .font(.system(size: min(surfaceView.cellSize.height * 0.8, 30)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

                // If we have secure input enabled and we're the focused surface and window
                // then we want to show the secure input overlay.
                if ghostty.config.secureInputIndication &&
                    secureInput.enabled &&
                    surfaceFocus &&
                    windowFocus {
                    SecureInputOverlay()
                }

                // Search overlay
                if let searchState = surfaceView.searchState {
                    SurfaceSearchOverlay(
                        surfaceView: surfaceView,
                        searchState: searchState,
                        onClose: {
                            surfaceView.endSearch()
                        }
                    )
                }

                // Show bell border if enabled
                if ghostty.config.bellFeatures.contains(.border) {
                    BellBorderOverlay(bell: surfaceView.bell)
                }

                // Show a highlight effect when this surface needs attention
                HighlightOverlay(highlighted: surfaceView.highlighted)

                // If our surface is not healthy, then we render an error view over it.
                if !surfaceView.healthy {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceRendererUnhealthyView()
                } else if surfaceView.error != nil {
                    Rectangle().fill(ghostty.config.backgroundColor)
                    SurfaceErrorView()
                }

                // If we're part of a split view and don't have focus, we put a semi-transparent
                // rectangle above our view to make it look unfocused. We include the last
                // focused surface so this still works while SwiftUI focus is temporarily nil.
                if isSplit && !isFocusedSurface {
                    let overlayOpacity = ghostty.config.unfocusedSplitOpacity
                    if overlayOpacity > 0 {
                        Rectangle()
                            .fill(ghostty.config.unfocusedSplitFill)
                            .allowsHitTesting(false)
                            .opacity(overlayOpacity)
                    }
                }

                // Grab handle for dragging the window. We want this to appear at the very
                // top Z-index os it isn't faded by the unfocused overlay.
                SurfaceGrabHandle(
                    surfaceView: surfaceView,
                    dragHandle: ghostty.config.dragHandle,
                )
            }
        }
    }

    /// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
    /// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
    /// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
    private struct SurfaceRepresentable: NSViewRepresentable {
        /// The view to render for the terminal surface.
        let view: SurfaceView

        /// The size of the frame containing this view. We use this to update the the underlying
        /// surface. This does not actually SET the size of our frame, this only sets the size
        /// of our Metal surface for drawing.
        ///
        /// Note: we do NOT use the NSView.resize function because SwiftUI on macOS 12
        /// does not call this callback (macOS 13+ does).
        ///
        /// The best approach is to wrap this view in a GeometryReader and pass in the geo.size.
        let size: CGSize

        func makeNSView(context: Context) -> SurfaceScrollView {
            return SurfaceScrollView(contentSize: size, surfaceView: view)
        }

        func updateNSView(_ scrollView: SurfaceScrollView, context: Context) {
            // SwiftUI may defer frame updates under system load (e.g., memory
            // pressure, heavy I/O) or when external window managers trigger rapid
            // layout changes. When that happens, the scroll view's bounds can
            // fall out of sync with the size reported by GeometryReader, causing
            // the surface to render at stale dimensions.
            guard scrollView.bounds.size != size else { return }
            scrollView.needsLayout = true
        }
    }
}
