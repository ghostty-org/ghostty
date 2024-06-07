import SwiftUI
import UserNotifications
import GhosttyKit

extension Ghostty {
    /// The NSView implementation for a terminal surface.
    class SurfaceView: OSView, ObservableObject {
        /// Unique ID per surface
        let uuid: UUID
        
        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes. This is public because the callbacks go
        // to the app level and it is set from there.
        @Published var title: String = "👻"

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: NSSize = .zero
        
        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true
        
        // Any error while initializing the surface.
        @Published var error: Error? = nil

        // An initial size to request for a window. This will only affect
        // then the view is moved to a new window.
        var initialSize: NSSize? = nil
        
        // Returns true if quit confirmation is required for this surface to
        // exit safely.
        var needsConfirmQuit: Bool {
            guard let surface = self.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }
        
        /// Returns the pwd of the surface if it has one.
        var pwd: String? {
            guard let surface = self.surface else { return nil }
            let v = String(unsafeUninitializedCapacity: 1024) {
                Int(ghostty_surface_pwd(surface, $0.baseAddress, UInt($0.count)))
            }
            
            if (v.count == 0) { return nil }
            return v
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
        private var markedText: NSMutableAttributedString
        private var mouseEntered: Bool = false
        private(set) var focused: Bool = true
        private var cursor: NSCursor = .iBeam
        private var cursorVisible: CursorVisibility = .visible
        private var appearanceObserver: NSKeyValueObservation? = nil
        
        // This is set to non-null during keyDown to accumulate insertText contents
        private var keyTextAccumulator: [String]? = nil
        
        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        // I don't think we need this but this lets us know we should redraw our layer
        // so we'll use that to tell ghostty to refresh.
        override var wantsUpdateLayer: Bool { return true }
        
        private let app: Ghostty.App

        // State machine for mouse cursor visibility because every call to
        // NSCursor.hide/unhide must be balanced.
        enum CursorVisibility {
            case visible
            case hidden
            case pendingVisible
            case pendingHidden
        }

        init(_ app: Ghostty.App, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.markedText = NSMutableAttributedString()
            self.uuid = uuid ?? .init()
            self.app = app

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: NSMakeRect(0, 0, 800, 600))
            
            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(onUpdateRendererHealth),
                name: Ghostty.Notification.didUpdateRendererHealth,
                object: self)
            center.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: nil)
            
            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            var surface_cfg_c = surface_cfg.ghosttyConfig(view: self)
            guard let surface = ghostty_surface_new(app.app, &surface_cfg_c) else {
                self.error = AppError.surfaceCreateError
                return
            }
            self.surface = surface;
            
            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()
            
            // Observe our appearance so we can report the correct value to libghostty.
            // This is the best way I know of to get appearance change notifications.
            self.appearanceObserver = observe(\.effectiveAppearance, options: [.new, .initial]) { view, change in
                guard let appearance = change.newValue else { return }
                guard let surface = view.surface else { return }
                let scheme: ghostty_color_scheme_e
                switch (appearance.name) {
                case .aqua, .vibrantLight:
                    scheme = GHOSTTY_COLOR_SCHEME_LIGHT
                    
                case .darkAqua, .vibrantDark:
                    scheme = GHOSTTY_COLOR_SCHEME_DARK
                    
                default:
                    return
                }
                
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            // Remove all of our notificationcenter subscriptions
            let center = NotificationCenter.default
            center.removeObserver(self)
            
            // Whenever the surface is removed, we need to note that our restorable
            // state is invalid to prevent the surface from being restored.
            invalidateRestorableState()
            
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
            guard self.focused != focused else { return }
            self.focused = focused
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
        
        // MARK: - Notifications
        
        @objc private func onUpdateRendererHealth(notification: SwiftUI.Notification) {
            guard let healthAny = notification.userInfo?["health"] else { return }
            guard let health = healthAny as? ghostty_renderer_health_e else { return }
            healthy = health == GHOSTTY_RENDERER_HEALTH_OK
        }
        
        @objc private func windowDidChangeScreen(notification: SwiftUI.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            guard let screen = window.screen else { return }
            guard let surface = self.surface else { return }
            
            // When the window changes screens, we need to update libghostty with the screen
            // ID. If vsync is enabled, this will be used with the CVDisplayLink to ensure
            // the proper refresh rate is going.
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            ghostty_surface_set_display_id(surface, id)
        }
        
        // MARK: - NSView
        
        override func viewDidMoveToWindow() {
            // Set our background blur if requested
            setWindowBackgroundBlur(window)
        }
        
        /// This function sets the window background to blur if it is configured on the surface.
        private func setWindowBackgroundBlur(_ targetWindow: NSWindow?) {
            // Surface must desire transparency
            guard let surface = self.surface,
                  ghostty_surface_transparent(surface) else { return }
            
            // Our target should always be our own view window
            guard let target = targetWindow,
                  let window = self.window,
                  target == window else { return }
            
            // If our window is not visible, then delay this. This is possible specifically
            // during state restoration but probably in other scenarios as well. To delay,
            // we just loop directly on the dispatch queue.
            guard window.isVisible else {
                // Weak window so that if the window changes or is destroyed we aren't holding a ref
                DispatchQueue.main.async { [weak self, weak window] in self?.setWindowBackgroundBlur(window) }
                return
            }
            
            // Set the window transparency settings
            window.isOpaque = false
            
            if app.config.macosWindowShadow {
                window.hasShadow = true
                // NOTE(haze): I have no idea why this works, but it does. This emulates the
                // aesthetic of `Terminal.app`.
                window.backgroundColor = .white.withAlphaComponent(0.001)
            } else {
                window.hasShadow = false
                window.backgroundColor = .clear
            }

            // If we have a blur, set the blur
            ghostty_set_window_background_blur(surface, Unmanaged.passUnretained(window).toOpaque())
        }
        
        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if (result) { focusDidChange(true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()

            // We sometimes call this manually (see SplitView) as a way to force us to
            // yield our focus state.
            if (result) { focusDidChange(false) }

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
            super.viewDidChangeBackingProperties()
            
            // The Core Animation compositing engine uses the layer's contentsScale property
            // to determine whether to scale its contents during compositing. When the window
            // moves between a high DPI display and a low DPI display, or the user modifies
            // the DPI scaling for a display in the system settings, this can result in the
            // layer being scaled inappropriately. Since we handle the adjustment of scale
            // and resolution ourselves below, we update the layer's contentsScale property
            // to match the window's backingScaleFactor, so as to ensure it is not scaled by
            // the compositor.
            //
            // Ref: High Resolution Guidelines for OS X
            // https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html#//apple_ref/doc/uid/TP40012302-CH10-SW27
            if let window = window {
                CATransaction.begin()
                // Disable the implicit transition animation that Core Animation applies to
                // property changes. Otherwise it will apply a scale animation to the layer
                // contents which looks pretty janky.
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }
            
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
            ghostty_surface_draw(surface);
        }
        
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            // "Override this method in a subclass to allow instances to respond to
            // click-through. This allows the user to click on a view in an inactive
            // window, activating the view with one click, instead of clicking first
            // to make the window active and then clicking the view."
            return true
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

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            guard event.buttonNumber == 2 else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            guard event.buttonNumber == 2 else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods)
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
            
            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            
            // By setting this to non-nil, we note that we're in a keyDown event. From here,
            // we call interpretKeyEvents so that we can handle complex input such as Korean
            // language.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }
            
            // We need to know what the length of marked text was before this event to
            // know if these events cleared it.
            let markedTextBefore = markedText.length > 0
            
            self.interpretKeyEvents([translationEvent])
            
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
            // If we don't have marked text but we had marked text before, then the preedit
            // was cleared so we want to send down an empty string to ensure we've cleared
            // the preedit.
            if (markedText.length > 0 || markedTextBefore) {
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

        /// Special case handling for some control keys
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Only process keys when Control is the only modifier
            if (!event.modifierFlags.contains(.control) ||
                !event.modifierFlags.isDisjoint(with: [.shift, .command, .option])) {
                return false
            }

            // Only process key down events
            if (event.type != .keyDown) {
                return false
            }
            
            // Only process events if we're focused. Some key events like C-/ macOS
            // appears to send to the first view in the hierarchy rather than the
            // the first responder (I don't know why). This prevents us from handling it.
            if (!focused) {
                return false
            }

            let equivalent: String
            switch (event.charactersIgnoringModifiers) {
            case "/":
                // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
                // sound and we don't like the beep sound.
                equivalent = "_"
                
            default:
                // Ignore other events
                return false
            }

            let newEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: .control,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )

            self.keyDown(with: newEvent!)
            return true
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

            // If the key that pressed this is active, its a press, else release.
            var action = GHOSTTY_ACTION_RELEASE
            if (mods.rawValue & mod != 0) {
                // If the key is pressed, its slightly more complicated, because we
                // want to check if the pressed modifier is the correct side. If the
                // correct side is pressed then its a press event otherwise its a release
                // event with the opposite modifier still held.
                let sidePressed: Bool
                switch (event.keyCode) {
                case 0x3C:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0;
                case 0x3E:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0;
                case 0x3D:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0;
                case 0x36:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0;
                default:
                    sidePressed = true
                }
                
                if (sidePressed) {
                    action = GHOSTTY_ACTION_PRESS
                }
            }
            
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
        
        @IBAction override func selectAll(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "select_all"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.count))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        /// Show a user notification and associate it with this surface
        func showUserNotification(title: String, body: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self.title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = Ghostty.userNotificationCategory
            content.userInfo = ["surface": self.uuid.uuidString]

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

// MARK: - NSTextInputClient

extension Ghostty.SurfaceView: NSTextInputClient {
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
        let viewRect = NSMakeRect(x, frame.size.height - y, 0, 0)
        
        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
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
}

// MARK: Services

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension Ghostty.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // Types that we accept sent to us
        let accepted: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]
        
        // We can always receive the accepted types
        if (returnType == nil || accepted.contains(returnType!)) {
            return self
        }
        
        // If we have a selection we can send the accepted types too
        if ((self.surface != nil && ghostty_surface_has_selection(self.surface)) &&
            (sendType == nil || accepted.contains(sendType!))
        ) {
            return self
        }
        
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    
    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surface else { return false }
        
        // We currently cap the maximum copy size to 1MB. iTerm2 I believe
        // caps theirs at 0.1MB (configurable) so this is probably reasonable.
        let v = String(unsafeUninitializedCapacity: 1000000) {
            Int(ghostty_surface_selection(surface, $0.baseAddress, UInt($0.count)))
        }
        
        pboard.declareTypes([.string], owner: nil)
        pboard.setString(v, forType: .string)
        return true
    }
    
    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.getOpinionatedStringContents() else { return false }
        
        let len = str.utf8CString.count
        if (len == 0) { return true }
        str.withCString { ptr in
            // len includes the null terminator so we do len - 1
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
        
        return true
    }
}
