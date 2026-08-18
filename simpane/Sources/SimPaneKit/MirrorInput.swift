//  NSEvent -> Indigo, for SimulatorMirrorView.
//
//  Split from the rendering half so the event translation can be read on its
//  own. All geometry goes through Coordinates, all key translation through
//  KeyMap, so the parts worth testing have no AppKit in them.

import AppKit
import SimPaneCore

extension SimulatorMirrorView {

    // MARK: - Mouse as a single finger

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if SimulatorMirrorView.debugInput {
            let local = convert(event.locationInWindow, from: nil)
            FileHandle.standardError.write(Data("""
                mouseDown win=\(event.locationInWindow) view=\(local) bounds=\(bounds) \
                pixels=\(String(describing: displayPixelSize)) enabled=\(isInputEnabled) \
                norm=\(String(describing: normalizedPoint(for: event, clamped: false)))\n
                """.utf8))
        }
        guard isInputEnabled, let point = normalizedPoint(for: event, clamped: false) else { return }
        touchIsDown = true
        lastTouchSent = Date.distantPast
        send(.touch(x: point.x, y: point.y, phase: .down))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInputEnabled, touchIsDown else { return }
        // A finger that slides into the letterbox should track the edge rather
        // than drop the gesture, so drags clamp instead of rejecting.
        guard let point = normalizedPoint(for: event, clamped: true) else { return }

        // AppKit delivers far more mouse-moved events than the digitizer needs;
        // 120 Hz is well past what iOS samples and keeps the wire quiet.
        let now = Date()
        guard now.timeIntervalSince(lastTouchSent) >= 1.0 / 120.0 else {
            pendingDragPoint = point
            return
        }
        lastTouchSent = now
        pendingDragPoint = nil
        send(.touch(x: point.x, y: point.y, phase: .move))
    }

    override func mouseUp(with event: NSEvent) {
        guard isInputEnabled, touchIsDown else { return }
        touchIsDown = false
        // Flush a coalesced position first so the gesture ends where the cursor
        // actually is; otherwise a fast flick lifts off at a stale point and iOS
        // reads no velocity.
        if let pending = pendingDragPoint {
            send(.touch(x: pending.x, y: pending.y, phase: .move))
            pendingDragPoint = nil
        }
        let point = normalizedPoint(for: event, clamped: true) ?? pendingDragPoint ?? .zero
        send(.touch(x: point.x, y: point.y, phase: .up))
    }

    // MARK: - Scroll wheel as a synthesized pan

    override func scrollWheel(with event: NSEvent) {
        guard isInputEnabled else { return }
        guard let anchor = normalizedPoint(for: event, clamped: false) ?? scrollAnchor else { return }

        // Trackpads report a phase; a plain wheel does not, so an idle timer ends
        // the gesture for those.
        let began = event.phase.contains(.began) || (scrollAnchor == nil && !event.momentumPhase.contains(.ended))
        let ended = event.phase.contains(.ended) || event.phase.contains(.cancelled)
            || event.momentumPhase.contains(.ended)

        if began, scrollAnchor == nil {
            scrollAnchor = anchor
            scrollPosition = anchor
            send(.touch(x: anchor.x, y: anchor.y, phase: .down))
        }
        guard var position = scrollPosition else { return }

        // Natural scrolling means content follows the fingers, which is what a
        // touch drag already expresses; an inverted device flips it back.
        let pixels = displayPixelSize ?? CGSize(width: 1, height: 1)
        let content = Coordinates.contentRect(bounds: bounds, devicePixels: pixels)
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        position.x += sign * event.scrollingDeltaX / max(content.width, 1)
        position.y += sign * event.scrollingDeltaY / max(content.height, 1)
        position.x = min(max(position.x, 0), 1)
        position.y = min(max(position.y, 0), 1)
        scrollPosition = position

        send(.touch(x: position.x, y: position.y, phase: .move))

        if ended {
            endScroll()
        } else {
            scheduleScrollTimeout()
        }
    }

    func endScroll() {
        scrollTimeoutTimer?.invalidate()
        scrollTimeoutTimer = nil
        guard let position = scrollPosition else { return }
        send(.touch(x: position.x, y: position.y, phase: .up))
        scrollAnchor = nil
        scrollPosition = nil
    }

    private func scheduleScrollTimeout() {
        scrollTimeoutTimer?.invalidate()
        scrollTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.endScroll()
        }
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsLayout = true
        onFocusChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsLayout = true
        onFocusChanged?(false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled else { super.keyDown(with: event); return }
        // Two Escapes in a row hand the keyboard back, so a user can always get
        // out without reaching for the mouse.
        if event.keyCode == 0x35 {
            let now = Date()
            if now.timeIntervalSince(lastEscape) < 0.6 {
                lastEscape = .distantPast
                window?.makeFirstResponder(nil)
                onFocusReleased?()
                return
            }
            lastEscape = now
        }
        guard let usage = KeyMap.hidUsage(forVirtualKeyCode: event.keyCode) else { return }
        send(.key(code: usage, direction: .down))
    }

    override func keyUp(with event: NSEvent) {
        guard isInputEnabled else { super.keyUp(with: event); return }
        guard let usage = KeyMap.hidUsage(forVirtualKeyCode: event.keyCode) else { return }
        send(.key(code: usage, direction: .up))
    }

    /// Modifiers arrive as a flags-changed event rather than key up/down, so the
    /// transition has to be derived from what changed.
    override func flagsChanged(with event: NSEvent) {
        guard isInputEnabled else { super.flagsChanged(with: event); return }
        guard let usage = KeyMap.hidUsage(forVirtualKeyCode: event.keyCode) else { return }
        let isDown = !previousModifiers.contains(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            && !event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        previousModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        send(.key(code: usage, direction: isDown ? .down : .up))
    }

    // MARK: - Hardware buttons

    /// Press and release, both halves guaranteed.
    ///
    /// The release used to be scheduled with DispatchQueue.main.asyncAfter, which
    /// silently never ran whenever the caller was spinning a nested runloop. A
    /// button left held down is not a cosmetic bug: the guest ignores all further
    /// input until it is released, so every event after the first press vanished.
    /// Both halves now run on a queue of their own, off the main thread.
    func press(_ button: IndigoWire.Button) {
        guard isInputEnabled, let hid else { return }
        let down = MirrorInputEvent.button(button, direction: .down).bytes
        let up = MirrorInputEvent.button(button, direction: .up).bytes
        SimulatorMirrorView.buttonQueue.async { [weak self] in
            do {
                try hid.send(down)
                Thread.sleep(forTimeInterval: 0.08)
                try hid.send(up)
            } catch {
                DispatchQueue.main.async { self?.onInputError?(error) }
            }
        }
    }

    // MARK: - Helpers

    private func normalizedPoint(for event: NSEvent, clamped: Bool) -> CGPoint? {
        guard let pixels = displayPixelSize else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        if clamped {
            return Coordinates.normalizedClamped(
                viewPoint: local, bounds: bounds, devicePixels: pixels, viewIsFlipped: isFlipped)
        }
        return Coordinates.normalized(
            viewPoint: local, bounds: bounds, devicePixels: pixels, viewIsFlipped: isFlipped)
    }
}

/// What the view can ask the HID layer to do, so the view never touches the
/// wire format directly.
enum MirrorInputEvent {
    case touch(x: Double, y: Double, phase: IndigoWire.TouchPhase)
    case key(code: UInt32, direction: IndigoWire.Direction)
    case button(IndigoWire.Button, direction: IndigoWire.Direction)

    var bytes: [UInt8] {
        switch self {
        case .touch(let x, let y, let phase): return IndigoWire.touch(x: x, y: y, phase: phase)
        case .key(let code, let direction): return IndigoWire.key(code: code, direction)
        case .button(let button, let direction): return IndigoWire.button(button, direction)
        }
    }
}
