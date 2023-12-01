import SwiftUI
import UserNotifications
import GhosttyKit

extension Ghostty {
    /// Render a terminal for the active app in the environment.
    struct Terminal: View {
        @EnvironmentObject private var ghostty: Ghostty.AppState
        @FocusedValue(\.ghosttySurfaceTitle) private var surfaceTitle: String?

        var body: some View {
            if let app = self.ghostty.app {
                SurfaceForApp(app) { surfaceView in
                    SurfaceWrapper(surfaceView: surfaceView)
                }
                .navigationTitle(surfaceTitle ?? "Ghostty")
            }
        }
    }

    /// Yields a SurfaceView for a ghostty app that can then be used however you want.
    struct SurfaceForApp<Content: View>: View {
        let content: ((SurfaceView) -> Content)

        @StateObject private var surfaceView: SurfaceView

        init(_ app: ghostty_app_t, @ViewBuilder content: @escaping ((SurfaceView) -> Content)) {
            _surfaceView = StateObject(wrappedValue: SurfaceView(app, nil))
            self.content = content
        }

        var body: some View {
            content(surfaceView)
        }
    }
    
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

        @EnvironmentObject private var ghostty: Ghostty.AppState

        // This is true if the terminal is considered "focused". The terminal is focused if
        // it is both individually focused and the containing window is key.
        private var hasFocus: Bool { surfaceFocus && windowFocus }

        // The opacity of the rectangle when unfocused.
        private var unfocusedOpacity: Double {
            var opacity: Double = 0.85
            let key = "unfocused-split-opacity"
            _ = ghostty_config_get(ghostty.config, &opacity, key, UInt(key.count))
            return 1 - opacity
        }

        var body: some View {
            ZStack {
                // We use a GeometryReader to get the frame bounds so that our metal surface
                // is up to date. See TerminalSurfaceView for why we don't use the NSView
                // resize callback.
                GeometryReader { geo in
                    // We use these notifications to determine when the window our surface is
                    // attached to is or is not focused.
                    let pubBecomeFocused = NotificationCenter.default.publisher(for: Notification.didBecomeFocusedSurface, object: surfaceView)
                    let pubBecomeKey = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
                    let pubResign = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)

                    Surface(view: surfaceView, hasFocus: hasFocus, size: geo.size)
                        .focused($surfaceFocus)
                        .focusedValue(\.ghosttySurfaceTitle, surfaceView.title)
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
                            if (surfaceWindow == window) {
                                windowFocus = false
                            }
                        }
                        .onReceive(pubBecomeFocused) { notification in
                            // We only want to run this on older macOS versions where the .focused
                            // method doesn't work properly. See the dispatch of this notification
                            // for more information.
                            if #available(macOS 13, *) { return }

                            DispatchQueue.main.async {
                                surfaceFocus = true
                            }
                        }
                        .onAppear() {
                            // Welcome to the SwiftUI bug house of horrors. On macOS 12 (at least
                            // 12.5.1, didn't test other versions), the order in which the view
                            // is added to the window hierarchy is such that $surfaceFocus is
                            // not set to true for the first surface in a window. As a result,
                            // new windows are key (they have window focus) but the terminal surface
                            // does not have surface until the user clicks. Bad!
                            //
                            // There is a very real chance that I am doing something wrong, but it
                            // works great as-is on macOS 13, so I've instead decided to make the
                            // older macOS hacky. A workaround is on initial appearance to "steal
                            // focus" under certain conditions that seem to imply we're in the
                            // screwy state.
                            if #available(macOS 13, *) {
                                // If we're on a more modern version of macOS, do nothing.
                                return
                            }
                            if #available(macOS 12, *) {
                                // On macOS 13, the view is attached to a window at this point,
                                // so this is one extra check that we're a new view and behaving odd.
                                guard surfaceView.window == nil else { return }
                                DispatchQueue.main.async {
                                    surfaceFocus = true
                                }
                            }

                            // I don't know how older macOS versions behave but Ghostty only
                            // supports back to macOS 12 so its moot.
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            providers.forEach { provider in
                                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                    guard let url = url else { return }
                                    let path = Shell.escape(url.path)
                                    DispatchQueue.main.async {
                                        surfaceView.insertText(
                                            path,
                                            replacementRange: NSMakeRange(0, 0)
                                        )
                                    }
                                }
                            }
                            
                            return true
                        }
                }
                .ghosttySurfaceView(surfaceView)

                // If we're part of a split view and don't have focus, we put a semi-transparent
                // rectangle above our view to make it look unfocused. We use "surfaceFocus"
                // because we want to keep our focused surface dark even if we don't have window
                // focus.
                if (isSplit && !surfaceFocus) {
                    Rectangle()
                        .fill(.white)
                        .allowsHitTesting(false)
                        .opacity(unfocusedOpacity)
                }
            }
        }
    }

    /// A surface is terminology in Ghostty for a terminal surface, or a place where a terminal is actually drawn
    /// and interacted with. The word "surface" is used because a surface may represent a window, a tab,
    /// a split, a small preview pane, etc. It is ANYTHING that has a terminal drawn to it.
    ///
    /// We just wrap an AppKit NSView here at the moment so that we can behave as low level as possible
    /// since that is what the Metal renderer in Ghostty expects. In the future, it may make more sense to
    /// wrap an MTKView and use that, but for legacy reasons we didn't do that to begin with.
    struct Surface: NSViewRepresentable {
        /// The view to render for the terminal surface.
        let view: SurfaceView

        /// This should be set to true when the surface has focus. This is up to the parent because
        /// focus is also defined by window focus. It is important this is set correctly since if it is
        /// false then the surface will idle at almost 0% CPU.
        let hasFocus: Bool

        /// The size of the frame containing this view. We use this to update the the underlying
        /// surface. This does not actually SET the size of our frame, this only sets the size
        /// of our Metal surface for drawing.
        ///
        /// Note: we do NOT use the NSView.resize function because SwiftUI on macOS 12
        /// does not call this callback (macOS 13+ does).
        ///
        /// The best approach is to wrap this view in a GeometryReader and pass in the geo.size.
        let size: CGSize

        func makeNSView(context: Context) -> SurfaceView {
            // We need the view as part of the state to be created previously because
            // the view is sent to the Ghostty API so that it can manipulate it
            // directly since we draw on a render thread.
            return view;
        }

        func updateNSView(_ view: SurfaceView, context: Context) {
            view.focusDidChange(hasFocus)
            view.sizeDidChange(size)
        }
    }
    
    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// libghostty, usually from the Ghostty configuration.
    struct SurfaceConfiguration {
        /// Explicit font size to use in points
        var fontSize: UInt16? = nil
        
        /// Explicit working directory to set
        var workingDirectory: String? = nil
        
        init() {}
        
        init(from config: ghostty_surface_config_s) {
            self.fontSize = config.font_size
            self.workingDirectory = String.init(cString: config.working_directory, encoding: .utf8)
        }
        
        /// Returns the ghostty configuration for this surface configuration struct. The memory
        /// in the returned struct is only valid as long as this struct is retained.
        func ghosttyConfig(view: SurfaceView) -> ghostty_surface_config_s {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            config.nsview = Unmanaged.passUnretained(view).toOpaque()
            config.scale_factor = NSScreen.main!.backingScaleFactor

            if let fontSize = fontSize { config.font_size = fontSize }
            if let workingDirectory = workingDirectory {
                config.working_directory = (workingDirectory as NSString).utf8String
            }
            
            return config
        }
    }
    
    /// The NSView implementation for a terminal surface.
    class SurfaceView: NSView, NSTextInputClient, ObservableObject {
        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes. This is public because the callbacks go
        // to the app level and it is set from there.
        @Published var title: String = "👻"

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: NSSize = .zero

        // An initial size to request for a window. This will only affect
        // then the view is moved to a new window.
        var initialSize: NSSize? = nil
        
        // Returns true if quit confirmation is required for this surface to
        // exit safely.
        var needsConfirmQuit: Bool {
            guard let surface = self.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
        
        // Returns the inspector instance for this surface, or nil if the
        // surface has been closed.
        var inspector: ghostty_inspector_t? {
            guard let surface = self.surface else { return nil }
            return ghostty_surface_inspector(surface)
        }
        
        // True if the inspector should be visible
        @Published var inspectorVisible: Bool = false {
            didSet {
                if (oldValue && !inspectorVisible) {
                    guard let surface = self.surface else { return }
                    ghostty_inspector_free(surface)
                }
            }
        }

        // Notification identifiers associated with this surface
        var notificationIdentifiers: Set<String> = []
        
        private(set) var surface: ghostty_surface_t?
        var error: Error? = nil

        private var markedText: NSMutableAttributedString
        private var mouseEntered: Bool = false
        private(set) var focused: Bool = true
        private var cursor: NSCursor = .iBeam
        private var cursorVisible: CursorVisibility = .visible
        
        // This is set to non-null during keyDown to accumulate insertText contents
        private var keyTextAccumulator: [String]? = nil

        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        // I don't think we need this but this lets us know we should redraw our layer
        // so we'll use that to tell ghostty to refresh.
        override var wantsUpdateLayer: Bool { return true }

        // State machine for mouse cursor visibility because every call to
        // NSCursor.hide/unhide must be balanced.
        enum CursorVisibility {
            case visible
            case hidden
            case pendingVisible
            case pendingHidden
        }

        init(_ app: ghostty_app_t, _ baseConfig: SurfaceConfiguration?) {
            self.markedText = NSMutableAttributedString()

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: NSMakeRect(0, 0, 800, 600))

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            var surface_cfg_c = surface_cfg.ghosttyConfig(view: self)
            guard let surface = ghostty_surface_new(app, &surface_cfg_c) else {
                self.error = AppError.surfaceCreateError
                return
            }
            self.surface = surface;
            
            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            trackingAreas.forEach { removeTrackingArea($0) }
            
            // mouseExited is not called by AppKit one last time when the view
            // closes so we do it manually to ensure our NSCursor state remains
            // accurate.
            if (mouseEntered) {
                mouseExited(with: NSEvent())
            }
            
            guard let surface = self.surface else { return }
            ghostty_surface_free(surface)
        }

        /// Close the surface early. This will free the associated Ghostty surface and the view will
        /// no longer render. The view can never be used again. This is a way for us to free the
        /// Ghostty resources while references may still be held to this view. I've found that SwiftUI
        /// tends to hold this view longer than it should so we free the expensive stuff explicitly.
        func close() {
            // Remove any notifications associated with this surface
            let identifiers = Array(self.notificationIdentifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)

            guard let surface = self.surface else { return }
            ghostty_surface_free(surface)
            self.surface = nil
        }

        func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            ghostty_surface_set_focus(surface, focused)
        }

        func sizeDidChange(_ size: CGSize) {
            guard let surface = self.surface else { return }

            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
            
            // Frame changes do not always call mouseEntered/mouseExited, so we do some
            // calculations ourself to call those events.
            if let window = self.window {
                let mouseScreen = NSEvent.mouseLocation
                let mouseWindow = window.convertPoint(fromScreen: mouseScreen)
                let mouseView = self.convert(mouseWindow, from: nil)
                let isEntered = self.isMousePoint(mouseView, in: bounds)
                if (isEntered) {
                    mouseEntered(with: NSEvent())
                } else {
                    mouseExited(with: NSEvent())
                }
            } else {
                // If we don't have a window, then our mouse can NOT be in our view.
                // When the window comes back, I believe this event fires again so
                // we'll get a mouseEntered.
                mouseExited(with: NSEvent())
            }
        }

        func setCursorShape(_ shape: ghostty_mouse_shape_e) {
            switch (shape) {
            case GHOSTTY_MOUSE_SHAPE_DEFAULT:
                cursor = .arrow

            case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
                cursor = .contextualMenu

            case GHOSTTY_MOUSE_SHAPE_TEXT:
                cursor = .iBeam

            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                cursor = .crosshair

            case GHOSTTY_MOUSE_SHAPE_GRAB:
                cursor = .openHand

            case GHOSTTY_MOUSE_SHAPE_GRABBING:
                cursor = .closedHand

            case GHOSTTY_MOUSE_SHAPE_POINTER:
                cursor = .pointingHand

            case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
                cursor = .resizeLeft

            case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
                cursor = .resizeRight

            case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
                cursor = .resizeUp

            case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
                cursor = .resizeDown

            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                cursor = .resizeUpDown

            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                cursor = .resizeLeftRight

            case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
                cursor = .iBeamCursorForVerticalLayout

            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
                cursor = .operationNotAllowed

            default:
                // We ignore unknown shapes.
                return
            }

            // Set our cursor immediately if our mouse is over our window
            if (mouseEntered) { cursorUpdate(with: NSEvent()) }
            if let window = self.window {
                window.invalidateCursorRects(for: self)
            }
        }
        
        func setCursorVisibility(_ visible: Bool) {
            switch (cursorVisible) {
            case .visible:
                // If we want to be visible, do nothing. If we want to be hidden
                // enter the pending state.
                if (visible) { return }
                cursorVisible = .pendingHidden
                
            case .hidden:
                // If we want to be hidden, do nothing. If we want to be visible
                // enter the pending state.
                if (!visible) { return }
                cursorVisible = .pendingVisible
                
            case .pendingVisible:
                // If we want to be visible, do nothing because we're already pending.
                // If we want to be hidden, we're already hidden so reset state.
                if (visible) { return }
                cursorVisible = .hidden
                
            case .pendingHidden:
                // If we want to be hidden, do nothing because we're pending that switch.
                // If we want to be visible, we're already visible so reset state.
                if (!visible) { return }
                cursorVisible = .visible
            }

            if (mouseEntered) {
                cursorUpdate(with: NSEvent())
            }
        }

        override func viewDidMoveToWindow() {
            guard let window = self.window else { return }
            guard let surface = self.surface else { return }

            if ghostty_surface_transparent(surface) {
                // Set the window transparency settings
                window.isOpaque = false
                window.hasShadow = false
                window.backgroundColor = .clear

                // If we have a blur, set the blur
                ghostty_set_window_background_blur(surface, Unmanaged.passUnretained(window).toOpaque())
            }

            // Try to set the initial window size if we have one
            setInitialWindowSize()
        }
       
        /// Sets the initial window size requested by the Ghostty config.
        ///
        /// This only works under certain conditions:
        ///   - The window must be "uninitialized"
        ///   - The window must have no tabs
        ///   - Ghostty must have requested an initial size
        ///   
        private func setInitialWindowSize() {
            guard let initialSize = initialSize else { return }
            
            // If we have tabs, then do not change the window size
            guard let window = self.window else { return }
            guard let windowControllerRaw = window.windowController else { return }
            guard let windowController = windowControllerRaw as? TerminalController else { return }
            guard case .leaf = windowController.surfaceTree else { return }
            
            // If our window is full screen, we do not set the frame
            guard !window.styleMask.contains(.fullScreen) else { return }
            
            // Setup our frame. We need to first subtract the views frame so that we can
            // just get the chrome frame so that we only affect the surface view size.
            var frame = window.frame
            frame.size.width -= self.frame.size.width
            frame.size.height -= self.frame.size.height
            frame.size.width += initialSize.width
            frame.size.height += initialSize.height
            
            // We have no tabs and we are not a split, so set the initial size of the window.
            window.setFrame(frame, display: true)
        }
        
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if (result) { focused = true }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()

            // We sometimes call this manually (see SplitView) as a way to force us to
            // yield our focus state.
            if (result) {
                focusDidChange(false)
                focused = false
            }

            return result
        }

        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    
                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }

        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(frame, cursor: self.cursor)
        }

        override func viewDidChangeBackingProperties() {
            guard let surface = self.surface else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            ghostty_surface_set_size(surface, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        }

        override func updateLayer() {
            guard let surface = self.surface else { return }
            ghostty_surface_refresh(surface);
        }

        override func mouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
        }
        
        override func mouseMoved(with event: NSEvent) {
            guard let surface = self.surface else { return }
            
            // Convert window position to view position. Note (0, 0) is bottom left.
            let pos = self.convert(event.locationInWindow, from: nil)
            ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y)

        }

        override func mouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            // For reasons unknown (Cocoaaaaaaaaa), mouseEntered is called
            // multiple times in an unbalanced way with mouseExited when a new
            // tab is created. In this scenario, we only want to process our
            // callback once since this is stateful and we expect balancing.
            if (mouseEntered) { return }
            
            mouseEntered = true
            
            // Update our cursor when we enter so we fully process our
            // cursorVisible state.
            cursorUpdate(with: NSEvent())
        }

        override func mouseExited(with event: NSEvent) {
            // See mouseEntered
            if (!mouseEntered) { return }
            
            mouseEntered = false
            
            // If the mouse is currently hidden, we want to show it when we exit
            // this view. We go through the cursorVisible dance so that only
            // cursorUpdate manages cursor state.
            if (cursorVisible == .hidden) {
                cursorVisible = .pendingVisible
                cursorUpdate(with: NSEvent())
                assert(cursorVisible == .visible)
                
                // We set the state to pending hidden again for the next time
                // we enter.
                cursorVisible = .pendingHidden
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surface = self.surface else { return }

            // Builds up the "input.ScrollMods" bitmask
            var mods: Int32 = 0

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                mods = 1

                // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
                x *= 2;
                y *= 2;

                // TODO(mitchellh): do we have to scale the x/y here by window scale factor?
            }

            // Determine our momentum value
            var momentum: ghostty_input_mouse_momentum_e = GHOSTTY_MOUSE_MOMENTUM_NONE
            switch (event.momentumPhase) {
            case .began:
                momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
            case .stationary:
                momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
            case .changed:
                momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
            case .ended:
                momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
            case .cancelled:
                momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
            case .mayBegin:
                momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
            default:
                break
            }

            // Pack our momentum value into the mods bitmask
            mods |= Int32(momentum.rawValue) << 1

            ghostty_surface_mouse_scroll(surface, x, y, mods)
        }

        override func cursorUpdate(with event: NSEvent) {
            switch (cursorVisible) {
            case .visible, .hidden:
                // Do nothing, stable state
                break
                
            case .pendingHidden:
                NSCursor.hide()
                cursorVisible = .hidden
                
            case .pendingVisible:
                NSCursor.unhide()
                cursorVisible = .visible
            }
            
            cursor.set()
        }

        override func keyDown(with event: NSEvent) {
            guard let surface = self.surface else { 
                self.interpretKeyEvents([event])
                return
            }
            
            // We need to translate the mods (maybe) to handle configs such as option-as-alt
            let translationModsGhostty = Ghostty.eventModifierFlags(
                mods: ghostty_surface_key_translation_mods(
                    surface,
                    Ghostty.ghosttyMods(event.modifierFlags)
                )
            )
            
            // There are hidden bits set in our event that matter for certain dead keys
            // so we can't use translationModsGhostty directly. Instead, we just check
            // for exact states and set them.
            var translationMods = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if (translationModsGhostty.contains(flag)) {
                    translationMods.insert(flag)
                } else {
                    translationMods.remove(flag)
                }
            }

            // If the translation modifiers are not equal to our original modifiers
            // then we need to construct a new NSEvent. If they are equal we reuse the
            // old one. IMPORTANT: we MUST reuse the old event if they're equal because
            // this keeps things like Korean input working. There must be some object
            // equality happening in AppKit somewhere because this is required.
            let translationEvent: NSEvent
            if (translationMods == event.modifierFlags) {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
            }
            
            // By setting this to non-nil, we note that we'rein a keyDown event. From here,
            // we call interpretKeyEvents so that we can handle complex input such as Korean
            // language.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }
            self.interpretKeyEvents([translationEvent])

            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            
            // If we have text, then we've composed a character, send that down. We do this
            // first because if we completed a preedit, the text will be available here
            // AND we'll have a preedit.
            var handled: Bool = false
            if let list = keyTextAccumulator, list.count > 0 {
                handled = true
                for text in list {
                    keyAction(action, event: event, text: text)
                }
            }
            
            // If we have marked text, we're in a preedit state. Send that down.
            if (markedText.length > 0) {
                handled = true
                keyAction(action, event: event, preedit: markedText.string)
            }
            
            if (!handled) {
                // No text or anything, we want to handle this manually.
                keyAction(action, event: event)
            }
        }

        override func keyUp(with event: NSEvent) {
            keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        override func flagsChanged(with event: NSEvent) {
            let mod: UInt32;
            switch (event.keyCode) {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            // The keyAction function will do this AGAIN below which sucks to repeat
            // but this is super cheap and flagsChanged isn't that common.
            let mods = Ghostty.ghosttyMods(event.modifierFlags)

            // If the key that pressed this is active, its a press, else release
            var action = GHOSTTY_ACTION_RELEASE
            if (mods.rawValue & mod != 0) { action = GHOSTTY_ACTION_PRESS }

            keyAction(action, event: event)
        }

        private func keyAction(_ action: ghostty_input_action_e, event: NSEvent) {
            guard let surface = self.surface else { return }
            
            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.mods = Ghostty.ghosttyMods(event.modifierFlags)
            key_ev.keycode = UInt32(event.keyCode)
            key_ev.text = nil
            key_ev.composing = false
            ghostty_surface_key(surface, key_ev)
        }
        
        private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, preedit: String) {
            guard let surface = self.surface else { return }

            preedit.withCString { ptr in
                var key_ev = ghostty_input_key_s()
                key_ev.action = action
                key_ev.mods = Ghostty.ghosttyMods(event.modifierFlags)
                key_ev.keycode = UInt32(event.keyCode)
                key_ev.text = ptr
                key_ev.composing = true
                ghostty_surface_key(surface, key_ev)
            }
        }
        
        private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, text: String) {
            guard let surface = self.surface else { return }

            text.withCString { ptr in
                var key_ev = ghostty_input_key_s()
                key_ev.action = action
                key_ev.mods = Ghostty.ghosttyMods(event.modifierFlags)
                key_ev.keycode = UInt32(event.keyCode)
                key_ev.text = ptr
                ghostty_surface_key(surface, key_ev)
            }
        }

        // MARK: Menu Handlers

        @IBAction func copy(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "copy_to_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func paste(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func pasteAsPlainText(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        // MARK: NSTextInputClient

        func hasMarkedText() -> Bool {
            return markedText.length > 0
        }

        func markedRange() -> NSRange {
            guard markedText.length > 0 else { return NSRange() }
            return NSRange(0...(markedText.length-1))
        }

        func selectedRange() -> NSRange {
            return NSRange()
        }

        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            switch string {
            case let v as NSAttributedString:
                self.markedText = NSMutableAttributedString(attributedString: v)

            case let v as String:
                self.markedText = NSMutableAttributedString(string: v)

            default:
                print("unknown marked text: \(string)")
            }
        }

        func unmarkText() {
            self.markedText.mutableString.setString("")
        }

        func validAttributesForMarkedText() -> [NSAttributedString.Key] {
            return []
        }

        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
            return nil
        }

        func characterIndex(for point: NSPoint) -> Int {
            return 0
        }

        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
            guard let surface = self.surface else {
                return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0)
            }

            // Ghostty will tell us where it thinks an IME keyboard should render.
            var x: Double = 0;
            var y: Double = 0;
            ghostty_surface_ime_point(surface, &x, &y)

            // Ghostty coordinates are in top-left (0, 0) so we have to convert to
            // bottom-left since that is what UIKit expects
            let rect = NSMakeRect(x, frame.size.height - y, 0, 0)

            // Convert from view to screen coordinates
            guard let window = self.window else { return rect }
            return window.convertToScreen(rect)
        }

        func insertText(_ string: Any, replacementRange: NSRange) {
            // We must have an associated event
            guard NSApp.currentEvent != nil else { return }
            guard let surface = self.surface else { return }

            // We want the string view of the any value
            var chars = ""
            switch (string) {
            case let v as NSAttributedString:
                chars = v.string
            case let v as String:
                chars = v
            default:
                return
            }
            
            // If insertText is called, our preedit must be over.
            unmarkText()
            
            // If we have an accumulator we're in another key event so we just
            // accumulate and return.
            if var acc = keyTextAccumulator {
                acc.append(chars)
                keyTextAccumulator = acc
                return
            }
            
            let len = chars.utf8CString.count
            if (len == 0) { return }
            
            chars.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        override func doCommand(by selector: Selector) {
            // This currently just prevents NSBeep from interpretKeyEvents but in the future
            // we may want to make some of this work.

            print("SEL: \(selector)")
        }

        /// Show a user notification and associate it with this surface
        func showUserNotification(title: String, body: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self.title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = Ghostty.userNotificationCategory

            // The userInfo must conform to NSSecureCoding, which SurfaceView
            // does not. So instead we pass an integer representation of the
            // SurfaceView's address, which is reconstructed back into a
            // SurfaceView if the notification is clicked. This is safe to do
            // so long as the SurfaceView removes all of its notifications when
            // it closes so that there are no dangling pointers.
            content.userInfo = [
                "address": Int(bitPattern: Unmanaged.passUnretained(self).toOpaque()),
            ]

            let uuid = UUID().uuidString
            let request = UNNotificationRequest(
                identifier: uuid,
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    AppDelegate.logger.error("Error scheduling user notification: \(error)")
                    return
                }

                self.notificationIdentifiers.insert(uuid)
            }
        }

        /// Handle a user notification click
        func handleUserNotification(notification: UNNotification, focus: Bool) {
            let id = notification.request.identifier
            guard self.notificationIdentifiers.remove(id) != nil else { return }
            if focus {
                self.window?.makeKeyAndOrderFront(self)
                Ghostty.moveFocus(to: self)
            }
        }
    }
}

// MARK: Surface Environment Keys

private struct GhosttySurfaceViewKey: EnvironmentKey {
    static let defaultValue: Ghostty.SurfaceView? = nil
}

extension EnvironmentValues {
    var ghosttySurfaceView: Ghostty.SurfaceView? {
        get { self[GhosttySurfaceViewKey.self] }
        set { self[GhosttySurfaceViewKey.self] = newValue }
    }
}

extension View {
    func ghosttySurfaceView(_ surfaceView: Ghostty.SurfaceView?) -> some View {
        environment(\.ghosttySurfaceView, surfaceView)
    }
}

// MARK: Surface Focus Keys

extension FocusedValues {
    var ghosttySurfaceView: Ghostty.SurfaceView? {
        get { self[FocusedGhosttySurface.self] }
        set { self[FocusedGhosttySurface.self] = newValue }
    }

    struct FocusedGhosttySurface: FocusedValueKey {
        typealias Value = Ghostty.SurfaceView
    }
}

extension FocusedValues {
    var ghosttySurfaceTitle: String? {
        get { self[FocusedGhosttySurfaceTitle.self] }
        set { self[FocusedGhosttySurfaceTitle.self] = newValue }
    }

    struct FocusedGhosttySurfaceTitle: FocusedValueKey {
        typealias Value = String
    }
}

extension FocusedValues {
    var ghosttySurfaceZoomed: Bool? {
        get { self[FocusedGhosttySurfaceZoomed.self] }
        set { self[FocusedGhosttySurfaceZoomed.self] = newValue }
    }

    struct FocusedGhosttySurfaceZoomed: FocusedValueKey {
        typealias Value = Bool
    }
}

extension FocusedValues {
    var ghosttySurfaceCellSize: NSSize? {
        get { self[FocusedGhosttySurfaceCellSize.self] }
        set { self[FocusedGhosttySurfaceCellSize.self] = newValue }
    }

    struct FocusedGhosttySurfaceCellSize: FocusedValueKey {
        typealias Value = NSSize
    }
}
