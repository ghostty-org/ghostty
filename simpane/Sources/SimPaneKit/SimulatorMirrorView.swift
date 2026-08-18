//  Renders a device's live framebuffer.
//
//  The IOSurface goes straight into a CALayer's `contents`. CoreAnimation samples
//  it on the render server, so there is no blit and no copy on our side — the
//  cost of a frame is one property assignment.
//
//  The view exists before a device is attached and survives detaching, so a host
//  can install it in its hierarchy once and leave it there. Unattached, it draws
//  a status line instead of a screen.

import AppKit
import QuartzCore
import SimPaneCore

final class SimulatorMirrorView: NSView {

    // MARK: Attachment

    private(set) var display: SimDisplay?
    private(set) var hid: IndigoHIDClient?

    /// Shown centred when no device is attached.
    var statusText: String? {
        didSet { needsLayout = true }
    }

    /// Fired when the keyboard starts or stops going to the guest. A host that
    /// embeds this next to a terminal needs to say so out loud.
    var onFocusChanged: ((Bool) -> Void)?

    /// Fired on the main queue when the guest's surface is replaced — rotation,
    /// resize, reboot — and once when a display is first bound.
    var onSurfaceChanged: ((CGSize) -> Void)?

    func bind(display: SimDisplay, hid: IndigoHIDClient?) {
        unbind()
        self.display = display
        self.hid = hid
        statusText = nil

        display.onDamage = { [weak self] in self?.noteDamage() }
        display.onSurfaceChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // A replaced surface can be a different size, so the content rect
                // has to be recomputed before the next frame lands in it.
                self.needsLayout = true
                self.rebindSurface()
                self.onSurfaceChanged?(self.displayPixelSize ?? .zero)
            }
        }
        display.startObserving()

        framesPresented = 0
        damageEventsReceived = 0
        needsLayout = true
        rebindSurface()
        onSurfaceChanged?(displayPixelSize ?? .zero)
    }

    func unbind() {
        display?.stopObserving()
        display?.onDamage = nil
        display?.onSurfaceChanged = nil
        display = nil
        // Borrowed, not owned: the session disconnects it.
        hid = nil
        contentLayer.contents = nil
        resetInputState()
        needsLayout = true
    }

    // MARK: Input state (driven from MirrorInput.swift)

    var isInputEnabled = true {
        didSet { needsLayout = true }
    }
    var onFocusReleased: (() -> Void)?
    var onInputError: ((Error) -> Void)?

    var touchIsDown = false
    var lastTouchSent = Date.distantPast
    var pendingDragPoint: CGPoint?
    var scrollAnchor: CGPoint?
    var scrollPosition: CGPoint?
    var scrollTimeoutTimer: Timer?
    var lastEscape = Date.distantPast
    var previousModifiers: NSEvent.ModifierFlags = []

    static let debugInput = ProcessInfo.processInfo.environment["SIMPANE_DEBUG_INPUT"] != nil

    /// Hardware buttons are held briefly between down and up, which must not
    /// happen on the main thread.
    static let buttonQueue = DispatchQueue(label: "simpane.button")

    private func resetInputState() {
        touchIsDown = false
        pendingDragPoint = nil
        scrollAnchor = nil
        scrollPosition = nil
        scrollTimeoutTimer?.invalidate()
        scrollTimeoutTimer = nil
    }

    /// Pixel size of the device screen, for coordinate mapping.
    var displayPixelSize: CGSize? { display?.surfacePixelSize() }

    func send(_ event: MirrorInputEvent) {
        guard let hid else {
            if Self.debugInput { FileHandle.standardError.write(Data("send: NO HID CLIENT\n".utf8)) }
            return
        }
        do {
            try hid.send(event.bytes)
            if Self.debugInput { FileHandle.standardError.write(Data("send ok: \(event)\n".utf8)) }
        } catch {
            onInputError?(error)
            if Self.debugInput { FileHandle.standardError.write(Data("send FAILED: \(error)\n".utf8)) }
        }
    }

    // MARK: Layers

    /// The device screen. A sublayer rather than the view's own layer so its frame
    /// *is* the content rect — the same rect input maps against. Relying on
    /// `contentsGravity = .resizeAspect` would leave rendering and hit-testing
    /// computing the letterbox independently.
    private let contentLayer = CALayer()
    /// Drawn around the screen, not the view, so it stays next to the pixels a
    /// keystroke would reach.
    private let focusLayer = CALayer()
    private let statusLayer = CATextLayer()

    // MARK: Frame pump

    /// Damage arrives on an arbitrary thread at ~50/s. Repainting straight from
    /// there would touch AppKit off-main, so damage only sets a flag and the
    /// actual rebind is coalesced onto the main queue.
    private let stateLock = NSLock()
    private var pendingDamage = false
    private var repaintScheduled = false

    private(set) var framesPresented = 0
    private(set) var damageEventsReceived = 0
    private var lastSampleTime = Date()
    private var lastSampleFrames = 0
    private var lastSampleDamage = 0
    private(set) var presentedFPS: Double = 0
    private(set) var damageFPS: Double = 0

    var onStatsUpdated: (() -> Void)?

    /// False when the window is occluded or the view is hidden, so a pane nobody
    /// can see costs nothing. Maintained by the view itself: a host should not
    /// have to remember to do this.
    private(set) var isRenderingEnabled = false

    /// How a damage event is turned into a visible update. Phase 1 measured all
    /// three rather than assuming; see DEVLOG. Override with SIMPANE_NUDGE.
    enum Nudge: String {
        /// Reassign contents with the same surface.
        case contents
        /// Mark the layer dirty and let CoreAnimation decide.
        case needsDisplay
        /// Bind the surface once and never touch it again.
        case none
    }

    static let nudge: Nudge = {
        let raw = ProcessInfo.processInfo.environment["SIMPANE_NUDGE"] ?? "contents"
        return Nudge(rawValue: raw) ?? .contents
    }()

    // MARK: Lifecycle

    init() {
        super.init(frame: .zero)

        wantsLayer = true
        layerContentsRedrawPolicy = .never

        guard let layer else { return }
        layer.backgroundColor = NSColor.black.cgColor

        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .trilinear
        contentLayer.minificationFilter = .trilinear
        layer.addSublayer(contentLayer)

        focusLayer.borderWidth = 3
        focusLayer.borderColor = NSColor.controlAccentColor.cgColor
        focusLayer.isHidden = true
        layer.addSublayer(focusLayer)

        statusLayer.alignmentMode = .center
        statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        statusLayer.fontSize = 13
        statusLayer.isWrapped = true
        layer.addSublayer(statusLayer)

        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        scrollTimeoutTimer?.invalidate()
        display?.stopObserving()
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Visibility

    /// Only the window this view is in matters; the notification is not filtered
    /// by object because the view can move between windows.
    @objc private func occlusionChanged(_ note: Notification) {
        guard let window, (note.object as AnyObject?) === window else { return }
        updateRenderingState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        contentLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        statusLayer.contentsScale = contentLayer.contentsScale
        updateRenderingState()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRenderingState()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRenderingState()
    }

    private func updateRenderingState() {
        let visible = window != nil
            && !isHiddenOrHasHiddenAncestor
            && (window?.occlusionState.contains(.visible) ?? false)
        guard visible != isRenderingEnabled else { return }
        isRenderingEnabled = visible
        if visible { rebindSurface() }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        // Also the catch-up for visibility: `layout` runs when the view first
        // appears and on every resize, which covers the window states that do not
        // announce themselves with an occlusion notification.
        updateRenderingState()

        let content = contentRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = content
        contentLayer.isHidden = display == nil
        focusLayer.frame = content
        focusLayer.isHidden = !hasKeyboardFocus || display == nil
        statusLayer.isHidden = display != nil || statusText == nil
        statusLayer.string = statusText
        statusLayer.frame = CGRect(
            x: bounds.minX + 12, y: bounds.midY - 24, width: max(bounds.width - 24, 1), height: 48)
        CATransaction.commit()
    }

    /// Aspect-fit rect the device screen occupies. Clicks outside it are in the
    /// letterbox and are not on the device.
    var contentRect: CGRect {
        guard let pixels = displayPixelSize, pixels.width > 0, pixels.height > 0 else {
            return bounds
        }
        return Coordinates.contentRect(bounds: bounds, devicePixels: pixels)
    }

    /// A terminal user must never wonder where their keystrokes went, so focus is
    /// drawn, not implied.
    var hasKeyboardFocus: Bool { window?.firstResponder === self && isInputEnabled }

    // MARK: Frame pump

    private func noteDamage() {
        stateLock.lock()
        damageEventsReceived += 1
        pendingDamage = true
        let alreadyScheduled = repaintScheduled
        repaintScheduled = true
        stateLock.unlock()

        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak self] in self?.drainDamage() }
    }

    private func drainDamage() {
        stateLock.lock()
        repaintScheduled = false
        let hadDamage = pendingDamage
        pendingDamage = false
        stateLock.unlock()

        guard hadDamage, isRenderingEnabled else { return }

        switch Self.nudge {
        case .contents:
            rebindSurface()
        case .needsDisplay:
            contentLayer.setNeedsDisplay()
            framesPresented += 1
            updateStats()
        case .none:
            framesPresented += 1
            updateStats()
        }
    }

    /// Reassigning `contents` with the same IOSurface is what makes CoreAnimation
    /// re-read it. `setNeedsDisplay` does nothing here because the layer has no
    /// drawing of its own.
    func rebindSurface() {
        guard isRenderingEnabled, let surface = display?.framebufferSurface else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = surface
        contentLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        CATransaction.commit()

        framesPresented += 1
        updateStats()
    }

    private func updateStats() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        guard elapsed >= 0.5 else { return }

        stateLock.lock()
        let damage = damageEventsReceived
        stateLock.unlock()

        presentedFPS = Double(framesPresented - lastSampleFrames) / elapsed
        damageFPS = Double(damage - lastSampleDamage) / elapsed
        lastSampleDamage = damage
        lastSampleFrames = framesPresented
        lastSampleTime = now
        onStatsUpdated?()
    }
}
