import Foundation
import MetalKit
import SwiftUI
import GhosttyKit

extension Ghostty {
    /// InspectableSurface is a type of Surface view that allows an inspector to be attached.
    struct InspectableSurface: View {
        @EnvironmentObject var ghostty: Ghostty.App

        /// Same as SurfaceWrapper, see the doc comments there.
        @ObservedObject var surfaceView: SurfaceView
        var isSplit: Bool = false

        // Maintain whether our view has focus or not
        @FocusState private var inspectorFocus: Bool

        // The fractional area of the surface view vs. the inspector (0.5 means a 50/50 split)
        @State private var split: CGFloat = 0.5

        var body: some View {
            let center = NotificationCenter.default
            let pubInspector = center.publisher(for: Notification.didControlInspector, object: surfaceView)

            ZStack {
                if (!surfaceView.inspectorVisible) {
                    SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                } else {
                    SplitView(.vertical, $split, dividerColor: ghostty.config.splitDividerColor, left: {
                        SurfaceWrapper(surfaceView: surfaceView, isSplit: isSplit)
                    }, right: {
                        InspectorViewRepresentable(surfaceView: surfaceView)
                            .focused($inspectorFocus)
                            .focusedValue(\.ghosttySurfaceView, surfaceView)
                    })
                }
            }
            .onReceive(pubInspector) { onControlInspector($0) }
            .onChange(of: surfaceView.inspectorVisible) { inspectorVisible in
                // When we show the inspector, we want to focus on the inspector.
                // When we hide the inspector, we want to move focus back to the surface.
                if (inspectorVisible) {
                    // We need to delay this until SwiftUI shows the inspector.
                    DispatchQueue.main.async {
                        _ = surfaceView.resignFirstResponder()
                        inspectorFocus = true
                    }
                } else {
                    Ghostty.moveFocus(to: surfaceView)
                }
            }
        }

        private func onControlInspector(_ notification: SwiftUI.Notification) {
            // Determine our mode
            guard let modeAny = notification.userInfo?["mode"] else { return }
            guard let mode = modeAny as? ghostty_action_inspector_e else { return }

            switch (mode) {
            case GHOSTTY_INSPECTOR_TOGGLE:
                surfaceView.inspectorVisible = !surfaceView.inspectorVisible

            case GHOSTTY_INSPECTOR_SHOW:
                surfaceView.inspectorVisible = true

            case GHOSTTY_INSPECTOR_HIDE:
                surfaceView.inspectorVisible = false

            default:
                return
            }
        }
    }

    struct InspectorViewRepresentable: NSViewRepresentable {
        /// The surface that this inspector represents.
        let surfaceView: SurfaceView

        func makeNSView(context: Context) -> InspectorView {
            let view = InspectorView()
            view.surfaceView = self.surfaceView
            return view
        }

        func updateNSView(_ view: InspectorView, context: Context) {
            view.surfaceView = self.surfaceView
        }
    }

    /// Inspector view is the view for the surface inspector (similar to a web inspector).
    class InspectorView: MTKView, NSTextInputClient {
        let commandQueue: MTLCommandQueue

        var surfaceView: SurfaceView? = nil {
            didSet { surfaceViewDidChange() }
        }

        private var inspector: ghostty_inspector_t? {
            guard let surfaceView = self.surfaceView else { return nil }
            return surfaceView.inspector
        }

        private var markedText: NSMutableAttributedString = NSMutableAttributedString()

        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        override init(frame: CGRect, device: MTLDevice?) {
            // Initialize our Metal primitives
            guard
              let device = device ?? MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
                fatalError("GPU not available")
            }

            // Setup our properties before initializing the parent
            self.commandQueue = commandQueue
            super.init(frame: frame, device: device)

            // This makes it so renders only happen when we request
            self.enableSetNeedsDisplay = true
            self.isPaused = true

            // After initializing the parent we can set our own properties
            self.device = MTLCreateSystemDefaultDevice()
            self.clearColor = MTLClearColor(red: 0x28 / 0xFF, green: 0x2C / 0xFF, blue: 0x34 / 0xFF, alpha: 1.0)

            // Setup our tracking areas for mouse events
            updateTrackingAreas()
        }

        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            trackingAreas.forEach { removeTrackingArea($0) }
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Internal Inspector Funcs

        private func surfaceViewDidChange() {
            let center = NotificationCenter.default
            center.removeObserver(self)

            guard let surfaceView = self.surfaceView else { return }
            guard let inspector = self.inspector else { return }
            guard let device = self.device else { return }
            let devicePtr = Unmanaged.passRetained(device).toOpaque()
            ghostty_inspector_metal_init(inspector, devicePtr)

            // Register an observer for render requests
            center.addObserver(
                self,
                selector: #selector(didRequestRender),
                name: Ghostty.Notification.inspectorNeedsDisplay,
                object: surfaceView)
        }

        @objc private func didRequestRender(notification: SwiftUI.Notification) {
            self.needsDisplay = true
        }

        private func updateSize() {
            guard let inspector = self.inspector else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_inspector_set_content_scale(inspector, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            ghostty_inspector_set_size(inspector, UInt32(fbFrame.size.width), UInt32(fbFrame.size.height))
        }

        // MARK: NSView

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if (result) {
                if let inspector = self.inspector {
                    ghostty_inspector_set_focus(inspector, true)
                }
            }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if (result) {
                if let inspector = self.inspector {
                    ghostty_inspector_set_focus(inspector, false)
                }
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

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateSize()
        }

        override func mouseDown(with event: NSEvent) {
            guard let inspector = self.inspector else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            guard let inspector = self.inspector else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let inspector = self.inspector else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let inspector = self.inspector else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
        }

        override func mouseMoved(with event: NSEvent) {
            guard let inspector = self.inspector else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let pos = self.convert(event.locationInWindow, from: nil)
            ghostty_inspector_mouse_pos(inspector, pos.x, frame.height - pos.y)

        }

        override func mouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let inspector = self.inspector else { return }

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

            ghostty_inspector_mouse_scroll(inspector, x, y, mods)
        }

        override func keyDown(with event: NSEvent) {
            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyAction(action, event: event)
            self.interpretKeyEvents([event])
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
            guard let inspector = self.inspector else { return }
            guard let key = Ghostty.Input.Key(keyCode: event.keyCode) else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_inspector_key(inspector, action, key.cKey, mods)
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
            return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0)
        }

        func insertText(_ string: Any, replacementRange: NSRange) {
            // We must have an associated event
            guard NSApp.currentEvent != nil else { return }
            guard let inspector = self.inspector else { return }

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

            let len = chars.utf8CString.count
            if (len == 0) { return }

            chars.withCString { ptr in
                ghostty_inspector_text(inspector, ptr)
            }
        }

        override func doCommand(by selector: Selector) {
            // This currently just prevents NSBeep from interpretKeyEvents but in the future
            // we may want to make some of this work.
        }

        // MARK: MTKView

        override func draw(_ dirtyRect: NSRect) {
            guard
              let commandBuffer = self.commandQueue.makeCommandBuffer(),
              let descriptor = self.currentRenderPassDescriptor else {
                return
            }

            // If the inspector is nil, then our surface is freed and it is unsafe
            // to use.
            guard let inspector = self.inspector else { return }

            // We always update our size because sometimes draw is called
            // between resize events and if our size is wrong with the underlying
            // drawable we will crash.
            updateSize()

            // Render
            ghostty_inspector_metal_render(
                inspector,
                Unmanaged.passRetained(commandBuffer).toOpaque(),
                Unmanaged.passRetained(descriptor).toOpaque()
            )

            guard let drawable = self.currentDrawable else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
