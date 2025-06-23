import SwiftUI
import GhosttyKit

extension Ghostty {
    /// The UIView implementation for a terminal surface.
    class SurfaceView: UIView, ObservableObject {
        /// Unique ID per surface
        let uuid: UUID

        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes. This is public because the callbacks go
        // to the app level and it is set from there.
        @Published var title: String = "👻"

        // The current pwd of the surface.
        @Published var pwd: String? = nil

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: OSSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error? = nil

        // The hovered URL
        @Published var hoverUrl: String? = nil

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        @Published var focusInstant: ContinuousClock.Instant? = nil

        /// True when the bell is active. This is set inactive on focus or event.
        @Published var bell: Bool = false

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        var surfaceSize: ghostty_surface_size_s? {
            guard let surface = self.surface else { return nil }
            return ghostty_surface_size(surface)
        }

        private(set) var surface: ghostty_surface_t?

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.uuid = uuid ?? .init()

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface = surface else {
                // TODO
                return
            }
            self.surface = surface;
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            guard let surface = self.surface else { return }
            ghostty_surface_free(surface)
        }

        func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            ghostty_surface_set_focus(surface, focused)

            // On macOS 13+ we can store our continuous clock...
            if (focused) {
                focusInstant = ContinuousClock.now
            }
        }

        func sizeDidChange(_ size: CGSize) {
            guard let surface = self.surface else { return }

            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scale = self.contentScaleFactor
            ghostty_surface_set_content_scale(surface, scale, scale)
            ghostty_surface_set_size(
                surface,
                UInt32(size.width * scale),
                UInt32(size.height * scale)
            )
        }

        // MARK: UIView

        override class var layerClass: AnyClass {
            get {
                return CAMetalLayer.self
            }
        }

        override func didMoveToWindow() {
            sizeDidChange(frame.size)
        }
    }
}
