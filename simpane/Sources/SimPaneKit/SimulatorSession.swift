//  One device, mirrored.
//
//  A session owns the whole chain for a single simulator: lifecycle through
//  `simctl`, the live display, the HID client, and the view that renders and
//  forwards input. It is the only type a host needs.
//
//  Threading: create the session and touch anything view-related on the main
//  thread. Delegate callbacks always arrive on the main queue. The `async`
//  methods do their blocking work off-main and are safe to await from the main
//  actor.

import AppKit
import Foundation
import SimPaneCore

/// State changes, surface size, and errors. Every callback arrives on the main
/// queue, and every method has a default no-op so a conformer implements only
/// what it cares about.
public protocol SimulatorSessionDelegate: AnyObject {
    func simulatorSession(_ session: SimulatorSession, didChangeState state: SimulatorSession.State)
    func simulatorSession(_ session: SimulatorSession, didChangeSurfaceSize size: CGSize)
    func simulatorSession(_ session: SimulatorSession, didFailWith error: Error)
    func simulatorSessionDidUpdateStatistics(_ session: SimulatorSession)
}

public extension SimulatorSessionDelegate {
    func simulatorSession(_ session: SimulatorSession, didChangeState state: SimulatorSession.State) {}
    func simulatorSession(_ session: SimulatorSession, didChangeSurfaceSize size: CGSize) {}
    func simulatorSession(_ session: SimulatorSession, didFailWith error: Error) {}
    func simulatorSessionDidUpdateStatistics(_ session: SimulatorSession) {}
}

public final class SimulatorSession {

    /// Where the session is in its own lifecycle, which is not the same as the
    /// device's: a booted device is not yet mirrored.
    public enum State: Equatable {
        case idle
        case booting
        case attaching
        case mirroring
        case shuttingDown
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "Idle"
            case .booting: return "Booting"
            case .attaching: return "Attaching"
            case .mirroring: return "Mirroring"
            case .shuttingDown: return "Shutting Down"
            case .failed(let reason): return "Failed: \(reason)"
            }
        }
    }

    public struct Statistics: Equatable {
        public let framesPresented: Int
        public let damageEvents: Int
        public let presentedFPS: Double
        public let damageFPS: Double
        public let surfacePixelSize: CGSize?
    }

    // MARK: - Discovery

    /// Whether this machine can mirror a simulator at all, and why not when it
    /// cannot. Cheap and cached; safe to call before anything else.
    public static func support() -> SimPaneSupport { PrivateFrameworks.support() }

    /// Every available device, newest runtime first. Uses `simctl` only, so it
    /// works — and is worth showing — even when `support()` is `.unsupported`.
    public static func listDevices() -> [SimDeviceInfo] { Simctl.devices() }

    /// An already-booted device if there is one, else the newest iPhone.
    public static func preferredDevice() -> SimDeviceInfo? { Simctl.preferredTarget() }

    // MARK: - Identity

    public let udid: String

    /// Re-read from simctl on access, so it never goes stale behind the caller.
    public var device: SimDeviceInfo {
        Simctl.device(udid: udid) ?? lastKnownDevice
    }

    private var lastKnownDevice: SimDeviceInfo

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            let state = state
            onMain { self.delegate?.simulatorSession(self, didChangeState: state) }
        }
    }

    public weak var delegate: SimulatorSessionDelegate?

    // MARK: - Internals

    private let view = SimulatorMirrorView()
    private var handle: SimDeviceHandle?
    private var display: SimDisplay?
    /// Owned here rather than read back off the view. Scripted input runs off the
    /// main thread, and reaching through a main-actor-isolated view to find the
    /// client would make every gesture wait for the main thread — which
    /// deadlocks outright if the caller is what is blocking it.
    private var hid: IndigoHIDClient?

    /// Scripted gestures hold the finger down between messages. Doing that on the
    /// caller's thread would stall whatever runloop it belongs to, so all of it
    /// runs here.
    private let scriptQueue = DispatchQueue(label: "simpane.script")

    // MARK: - Creation

    /// Fails only if `udid` names no available device. Neither Xcode nor a booted
    /// device is required yet: a host can build a session, show its view, and let
    /// the user boot from there.
    public init(udid: String) throws {
        guard let device = Simctl.device(udid: udid) else {
            throw SimPaneError("no available simulator with UDID \(udid)")
        }
        self.udid = udid
        self.lastKnownDevice = device
        configureView()
    }

    /// The preferred device — already booted if there is one.
    public convenience init() throws {
        guard let device = Simctl.preferredTarget() else {
            throw SimPaneError("no simulator devices are available")
        }
        try self.init(udid: device.udid)
    }

    private func configureView() {
        view.statusText = statusTextForCurrentState()
        view.onInputError = { [weak self] error in
            guard let self else { return }
            self.delegate?.simulatorSession(self, didFailWith: error)
        }
        view.onStatsUpdated = { [weak self] in
            guard let self else { return }
            self.delegate?.simulatorSessionDidUpdateStatistics(self)
        }
        view.onSurfaceChanged = { [weak self] size in
            guard let self else { return }
            self.delegate?.simulatorSession(self, didChangeSurfaceSize: size)
        }
    }

    deinit {
        display?.stopObserving()
    }

    // MARK: - The view

    /// The pane. Stable for the lifetime of the session: install it once and it
    /// fills in when a device attaches, rather than being replaced. Rendering
    /// pauses on its own whenever the view is hidden or its window is occluded.
    ///
    /// Main thread only, like any NSView.
    public var mirrorView: NSView { view }

    /// Forwarding of mouse, scroll, and keyboard events to the guest. Rendering
    /// is unaffected.
    public var isInputEnabled: Bool {
        get { view.isInputEnabled }
        set { view.isInputEnabled = newValue }
    }

    /// Called when the user presses Escape twice, which hands the keyboard back
    /// to the host. A terminal needs a guaranteed way out.
    public var onFocusReleased: (() -> Void)? {
        get { view.onFocusReleased }
        set { view.onFocusReleased = newValue }
    }

    public var isAttached: Bool { display != nil }

    /// Why input forwarding is unavailable, or nil when it works. Rendering can
    /// be fine while this is set — a CoreSimulator new enough to route HID
    /// through `dtuhidd` renders normally and silently discards Indigo events —
    /// so it is reported separately from `support()`.
    public var inputUnavailableReason: String? { PrivateFrameworks.inputUnavailableReason }

    public var displayPixelSize: CGSize? { view.displayPixelSize }

    public var statistics: Statistics {
        Statistics(
            framesPresented: view.framesPresented,
            damageEvents: view.damageEventsReceived,
            presentedFPS: view.presentedFPS,
            damageFPS: view.damageFPS,
            surfacePixelSize: view.displayPixelSize)
    }

    // MARK: - Lifecycle

    /// Boots the device if it is not already running, waits for it to be usable,
    /// and attaches the mirror. Safe to call on an already-mirroring session.
    public func bootIfNeeded(timeout: TimeInterval = 120) async throws {
        guard !isAttached else { return }

        if Simctl.state(udid: udid) != .booted {
            await setState(.booting)
            do {
                try await offMain { try Simctl.boot(udid: self.udid) }
                try await offMain { try Simctl.wait(udid: self.udid, for: .booted, timeout: timeout) }
            } catch {
                await fail(error)
                throw error
            }
        }

        do {
            try await MainActor.run { try self.attach() }
        } catch {
            await fail(error)
            throw error
        }
    }

    /// Detaches and shuts the device down. A session is never shut down
    /// implicitly — closing a pane leaves the device running.
    public func shutdown() async throws {
        await MainActor.run { self.detach() }
        await setState(.shuttingDown)
        do {
            try await offMain { try Simctl.shutdown(udid: self.udid) }
            try await offMain { try Simctl.wait(udid: self.udid, for: .shutdown, timeout: 60) }
        } catch {
            await fail(error)
            throw error
        }
        await setState(.idle)
    }

    /// Binds the mirror to an already-booted device. `bootIfNeeded()` calls this;
    /// it is public for a host that boots devices its own way.
    ///
    /// Main thread only.
    public func attach() throws {
        guard !isAttached else { return }
        state = .attaching

        let support = Self.support()
        guard support.isSupported else {
            let error = SimPaneError(support.reason ?? "simulator mirroring is unsupported here")
            failNow(error)
            throw error
        }

        do {
            guard let handle = try SimDevices.find(udid: udid) else {
                throw SimPaneError("device \(udid) is not visible through CoreSimulator")
            }
            guard handle.state == .booted else {
                throw SimPaneError("device is \(handle.state.label); it must be booted to mirror")
            }
            let display = try SimDisplay.mainDisplay(of: handle)
            guard display.framebufferSurface != nil else {
                throw SimPaneError("the device's main display has no framebuffer surface yet")
            }

            // Input is optional. A mirror that only renders still beats no mirror,
            // so a HID failure is reported and then set aside.
            var hid: IndigoHIDClient?
            do {
                hid = try IndigoHIDClient(device: handle)
            } catch {
                delegate?.simulatorSession(self, didFailWith: error)
            }

            self.handle = handle
            self.display = display
            self.hid = hid
            self.lastKnownDevice = device
            view.bind(display: display, hid: hid)
            state = .mirroring
        } catch {
            failNow(error)
            throw error
        }
    }

    /// Releases the display and HID client and blanks the pane. The device keeps
    /// running.
    ///
    /// Main thread only.
    public func detach() {
        guard isAttached else { return }
        view.unbind()
        display?.stopObserving()
        display = nil
        hid?.disconnect()
        hid = nil
        handle = nil
        state = .idle
        view.statusText = statusTextForCurrentState()
    }

    // MARK: - Input

    /// Presses and releases a hardware button. Returns immediately; the hold
    /// happens on a background queue. Suitable for a menu item.
    public func pressButton(_ button: HardwareButton) {
        view.press(button.wire)
    }

    /// Presses and releases a hardware button, reporting a send failure.
    public func pressButton(_ button: HardwareButton, hold: TimeInterval = 0.08) async throws {
        try await script { hid in
            try hid.send(IndigoWire.button(button.wire, .down))
            Thread.sleep(forTimeInterval: hold)
            try hid.send(IndigoWire.button(button.wire, .up))
        }
    }

    /// Taps at a point in normalized device coordinates, 0...1 from the top-left
    /// of the screen.
    ///
    /// The hold is not decoration: iOS ignores a zero-duration contact, so a tap
    /// that goes down and straight back up does nothing at all.
    public func tap(x: Double, y: Double, hold: TimeInterval = 0.06) async throws {
        try await script { hid in
            try hid.send(IndigoWire.touch(x: x, y: y, phase: .down))
            Thread.sleep(forTimeInterval: hold)
            try hid.send(IndigoWire.touch(x: x, y: y, phase: .up))
        }
    }

    /// Drags between two points in normalized device coordinates.
    public func swipe(
        from start: CGPoint, to end: CGPoint,
        steps: Int = 24, stepDelay: TimeInterval = 0.008
    ) async throws {
        try await script { hid in
            try hid.send(IndigoWire.touch(x: start.x, y: start.y, phase: .down))
            for i in 1...max(steps, 1) {
                let t = Double(i) / Double(max(steps, 1))
                try hid.send(IndigoWire.touch(
                    x: start.x + (end.x - start.x) * t,
                    y: start.y + (end.y - start.y) * t,
                    phase: .move))
                Thread.sleep(forTimeInterval: stepDelay)
            }
            try hid.send(IndigoWire.touch(x: end.x, y: end.y, phase: .up))
        }
    }

    /// Types USB HID keyboard usages (page 0x07). Note these are not macOS
    /// virtual key codes; `typeText` does that translation.
    public func typeKeys(_ usages: [UInt32]) async throws {
        try await script { hid in
            for usage in usages {
                try hid.send(IndigoWire.key(code: usage, .down))
                Thread.sleep(forTimeInterval: 0.03)
                try hid.send(IndigoWire.key(code: usage, .up))
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Types text, skipping characters with no entry in the HID usage table.
    public func typeText(_ text: String) async throws {
        try await typeKeys(text.compactMap { KeyMap.hidUsage(forCharacter: $0) })
    }

    private func script(_ body: @escaping (IndigoHIDClient) throws -> Void) async throws {
        guard let hid else {
            throw SimPaneError(inputUnavailableReason ?? "no HID client; the session is not attached")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            scriptQueue.async {
                do {
                    try body(hid)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Capture

    /// An exact, unscaled PNG of the device screen, from `simctl io screenshot`.
    /// Independent of the pane's own render path, which is what makes it the
    /// right thing to hand a user.
    public func screenshotPNG() async throws -> Data {
        try await offMain { try Simctl.screenshotPNG(udid: self.udid) }
    }

    /// A PNG of the framebuffer this session is actually rendering. Proves the
    /// render path rather than working around it, which is why it exists
    /// alongside `screenshotPNG()`.
    public func framebufferPNG() throws -> Data {
        guard let surface = display?.framebufferSurface else {
            throw SimPaneError("not attached to a display")
        }
        guard let image = Snapshot.cgImage(from: surface) else {
            throw SimPaneError("could not read the framebuffer surface")
        }
        return try Snapshot.pngData(image)
    }

    /// A sparse sample of the current frame. Compare two with
    /// `SimulatorSession.frameDifference` to tell a screen that responded from
    /// one that silently ignored the input.
    public func framebufferSample() -> [UInt8] {
        guard let surface = display?.framebufferSurface else { return [] }
        return Snapshot.sample(of: surface)
    }

    /// Fraction of sampled bytes that differ between two `framebufferSample()`
    /// results, 0...1.
    public static func frameDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        Snapshot.difference(a, b)
    }

    // MARK: - Apps

    /// Launches an installed app by bundle identifier, via `simctl launch`.
    public func launchApp(bundleIdentifier: String) async throws {
        try await offMain { try Simctl.launch(udid: self.udid, bundleIdentifier: bundleIdentifier) }
    }

    // MARK: - Plumbing

    private func statusTextForCurrentState() -> String {
        if case .unsupported(let reason) = Self.support() { return reason }
        return "\(lastKnownDevice.name) — not attached"
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func setState(_ new: State) async {
        await MainActor.run { self.state = new }
    }

    /// Records a failure as state and tells the delegate, so a host that only
    /// watches one of the two still learns about it.
    private func failNow(_ error: Error) {
        state = .failed(error.localizedDescription)
        view.statusText = error.localizedDescription
        delegate?.simulatorSession(self, didFailWith: error)
    }

    private func fail(_ error: Error) async {
        await MainActor.run { self.failNow(error) }
    }

    /// Runs blocking work off the main thread and propagates its error.
    private func offMain<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

extension HardwareButton {
    var wire: IndigoWire.Button {
        switch self {
        case .home: return .home
        case .lock: return .lock
        case .siri: return .siri
        case .side: return .sideButton
        case .applePay: return .applePay
        }
    }
}
