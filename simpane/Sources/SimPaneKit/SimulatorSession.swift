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
    public enum State: Equatable, Sendable {
        case idle
        case booting
        case attaching
        case mirroring
        case shuttingDown
        /// The device went away underneath us. The pane keeps watching for it to
        /// come back rather than making the user reattach by hand.
        case deviceShutDown
        case failed(String)

        public var label: String {
            switch self {
            case .idle: return "Idle"
            case .booting: return "Booting"
            case .attaching: return "Attaching"
            case .mirroring: return "Mirroring"
            case .shuttingDown: return "Shutting Down"
            case .deviceShutDown: return "Device Shut Down"
            case .failed(let reason): return "Failed: \(reason)"
            }
        }
    }

    public struct Statistics: Equatable, Sendable {
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

    /// Set while the pane wants to be mirroring. Distinguishes "the device went
    /// away" — where reattaching automatically is the right thing — from "the
    /// host asked us to stop", where it very much is not.
    private var cachedDisplay: SimDisplay?
    private var wantsMirroring = false
    private var deviceWatch: DispatchSourceTimer?
    private var devicePID: pid_t?
    private var isCheckingDeviceState = false
    private var lastAuthoritativeCheck = Date.distantPast
    /// How often the device's state is confirmed with `simctl`. Long enough that
    /// the cost is invisible, short enough that a shut-down device does not sit
    /// there looking live.
    private let authoritativeInterval: TimeInterval = 5
    private var rebootPoll: DispatchSourceTimer?

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
        deviceWatch?.cancel()
        rebootPoll?.cancel()
        display?.stopObserving()
        hid?.disconnect()
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

    /// Called when the keyboard starts or stops going to the guest, so a host can
    /// say which one is listening. The pane draws its own accent border too, but
    /// a terminal user needs this to be unmissable.
    public var onFocusChanged: ((Bool) -> Void)? {
        get { view.onFocusChanged }
        set { view.onFocusChanged = newValue }
    }

    /// Whether the mirror currently holds the keyboard.
    public var hasKeyboardFocus: Bool { view.hasKeyboardFocus }

    public var isAttached: Bool { display != nil }

    /// Why input forwarding is unavailable, or nil when it works. Rendering can
    /// be fine while this is set — a CoreSimulator new enough to route HID
    /// through `dtuhidd` renders normally and silently discards Indigo events —
    /// so it is reported separately from `support()`.
    public var inputUnavailableReason: String? { PrivateFrameworks.inputUnavailableReason }

    public var displayPixelSize: CGSize? { view.displayPixelSize }

    /// The rect inside `mirrorView` that the device screen actually occupies, in
    /// the view's own coordinates. The rest is letterbox and is not the device:
    /// input that lands there is ignored, so anything positioning against the
    /// screen — an overlay, a scripted gesture — has to use this rather than
    /// `mirrorView.bounds`.
    ///
    /// Main thread only.
    public var contentRect: CGRect { view.contentRect }

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
            // "Booted" is not "ready". simctl reports the state as soon as the
            // device process is up, but the guest's display has no IOSurface
            // until its window server has started — several seconds later on a
            // cold boot. Attaching in that window fails with "no framebuffer
            // surface yet", so wait for the surface rather than the state.
            try await offMain { try self.waitForDisplay(timeout: timeout) }
        } catch {
            await fail(error)
            throw error
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
        // detach() clears the intent to mirror, so the watchdog will not race
        // this and reattach to the device on its way down.
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
            // Reuse the device we already found. Re-walking the device set mints
            // a fresh ROCK proxy for every device on the machine each time, and
            // those are not cheap: repeated attach/detach cycles grew resident
            // memory by ~300 KB each until this was cached.
            let handle: SimDeviceHandle
            if let existing = self.handle {
                handle = existing
            } else if let found = try SimDevices.find(udid: udid) {
                handle = found
            } else {
                throw SimPaneError("device \(udid) is not visible through CoreSimulator")
            }
            guard handle.state == .booted else {
                throw SimPaneError("device is \(handle.state.label); it must be booted to mirror")
            }
            let display: SimDisplay
            if let cached = cachedDisplay, cached.framebufferSurface != nil {
                display = cached
            } else {
                display = try SimDisplay.mainDisplay(of: handle)
                cachedDisplay = display
            }
            guard display.framebufferSurface != nil else {
                throw SimPaneError("the device's main display has no framebuffer surface yet")
            }

            // Input is optional. A mirror that only renders still beats no mirror,
            // so a HID failure is reported and then set aside.
            //
            // Reused across attaches for the same reason the handle is: building
            // one costs ~86 KB that SimulatorKit never gives back, which is a
            // measurable leak when a user toggles the pane repeatedly. A stale
            // client is not a risk — a dropped mach port is exactly what
            // IndigoHIDClient.sendWithRecovery already rebuilds itself from.
            var hid: IndigoHIDClient? = self.hid
            if hid == nil {
                do {
                    hid = try IndigoHIDClient(device: handle)
                } catch {
                    delegate?.simulatorSession(self, didFailWith: error)
                }
            }

            self.handle = handle
            self.display = display
            self.hid = hid
            self.lastKnownDevice = device
            view.bind(display: display, hid: hid)
            state = .mirroring
            wantsMirroring = true
            startWatchingDevice()
        } catch {
            failNow(error)
            throw error
        }
    }

    /// Polls until the device's main display exists and has a framebuffer, which
    /// is the real "ready to mirror" signal. Blocking, so it runs off the main
    /// thread.
    private func waitForDisplay(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error = SimPaneError("timed out waiting for the device's display")
        while Date() < deadline {
            do {
                guard let handle = try SimDevices.find(udid: udid) else {
                    throw SimPaneError("device \(udid) is not visible through CoreSimulator")
                }
                let display = try SimDisplay.mainDisplay(of: handle)
                if display.framebufferSurface != nil { return }
                lastError = SimPaneError("the device's main display has no framebuffer surface yet")
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw lastError
    }

    /// Releases the display and HID client and blanks the pane. The device keeps
    /// running.
    ///
    /// Main thread only.
    public func detach() {
        wantsMirroring = false
        stopWatchingDevice()
        stopRebootPolling()
        // The device handle is deliberately kept: it is one reference to a
        // device that still exists, and re-deriving it means re-walking every
        // device on the machine. It goes away with the session.
        guard isAttached else {
            // Nothing bound, but the session may have been sitting in
            // .deviceShutDown waiting for a reboot. Stop waiting.
            if state != .idle { state = .idle }
            view.statusText = statusTextForCurrentState()
            return
        }
        releaseMirror()
        state = .idle
        view.statusText = statusTextForCurrentState()
    }

    /// Drops everything bound to the device without touching the intent to
    /// mirror, so both the deliberate and the accidental paths share it.
    private func releaseMirror() {
        view.unbind()
        display?.stopObserving()
        display = nil
    }

    /// Everything tied to a *particular boot* of the device. A reboot invalidates
    /// the display ports and the HID session, so both are rebuilt rather than
    /// reused when the device comes back.
    private func releaseDeviceResources() {
        releaseMirror()
        cachedDisplay = nil
        hid?.disconnect()
        hid = nil
    }

    // MARK: - Watching for the device going away and coming back

    /// Starts watching whether the device is still up.
    ///
    /// Two signals, because neither is sufficient alone:
    ///
    /// * `kill`/`sysctl` on the device's `launchd_sim` pid is free, so it runs
    ///   often. It is a fast path only — it has been observed reporting a
    ///   running process after the device was shut down, and a
    ///   `DISPATCH_SOURCE_TYPE_PROC` exit source never fires at all for a
    ///   process we did not spawn.
    /// * `simctl` is authoritative and costs ~40 ms of CPU, so it runs every few
    ///   seconds on a background queue and is what actually decides.
    ///
    /// The device's own `state` is not used: it is a value cached on the XPC
    /// proxy and keeps reporting `Booted` indefinitely. See DEVLOG, Phase 5.
    private func startWatchingDevice() {
        stopWatchingDevice()
        devicePID = DeviceProcess.pid(forUDID: udid)
        lastAuthoritativeCheck = Date()

        // A dispatch timer rather than a `Timer`: run-loop timers depend on which
        // mode the loop happens to be running in, and were observed simply never
        // firing under a nested run loop. This fires off the main queue whatever
        // the loop is doing.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkDeviceIsAlive() }
        timer.resume()
        deviceWatch = timer
    }

    private func stopWatchingDevice() {
        deviceWatch?.cancel()
        deviceWatch = nil
        devicePID = nil
    }

    private func checkDeviceIsAlive() {
        guard wantsMirroring, isAttached else { stopWatchingDevice(); return }

        // The pid may not have been findable when the pane attached — a device
        // that has only just booted takes a moment to show up — so keep looking
        // rather than silently never watching, which is a failure mode that
        // looks exactly like "everything is fine".
        if devicePID == nil {
            devicePID = DeviceProcess.pid(forUDID: udid)
        }

        // Free path: the guest's process is definitively gone.
        if let pid = devicePID, !DeviceProcess.isAlive(pid) {
            deviceDidGoAway()
            return
        }

        // Authoritative path, rate-limited because it spawns a process. Note
        // this cannot see a device that is merely *asked* to shut down while
        // this pane holds it open — see DEVLOG, Phase 5 — so it is a backstop
        // for the case where the pid was never found, not the primary signal.
        guard devicePID == nil,
              !isCheckingDeviceState,
              Date().timeIntervalSince(lastAuthoritativeCheck) >= authoritativeInterval
        else { return }
        isCheckingDeviceState = true
        lastAuthoritativeCheck = Date()

        let udid = self.udid
        DispatchQueue.global(qos: .utility).async {
            let state = Simctl.state(udid: udid, scrubEnvironment: true)
            DispatchQueue.main.async {
                self.isCheckingDeviceState = false
                guard self.wantsMirroring, self.isAttached else { return }
                guard state != .booted else { return }
                self.deviceDidGoAway()
            }
        }
    }

    private func deviceDidGoAway() {
        stopWatchingDevice()
        guard wantsMirroring else { return }

        releaseDeviceResources()
        state = .deviceShutDown
        view.statusText = "Device shut down. Waiting for it to come back…"
        delegate?.simulatorSession(self, didFailWith: SimPaneError("the device shut down"))
        startRebootPolling()
    }

    /// Polling is only acceptable here because it is transient: it runs while the
    /// pane is visibly waiting for a device to come back, never in steady state.
    private func startRebootPolling() {
        guard rebootPoll == nil, wantsMirroring else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.checkForReboot() }
        timer.resume()
        rebootPoll = timer
    }

    private func stopRebootPolling() {
        rebootPoll?.cancel()
        rebootPoll = nil
    }

    private func checkForReboot() {
        guard wantsMirroring, !isAttached else { stopRebootPolling(); return }
        guard Simctl.state(udid: udid) == .booted else { return }

        // The process is back, but "booted" arrives well before the guest's
        // framebuffer does, so keep waiting until there is something to show.
        guard let handle,
              let display = try? SimDisplay.mainDisplay(of: handle),
              display.framebufferSurface != nil
        else { return }

        var hid: IndigoHIDClient?
        do { hid = try IndigoHIDClient(device: handle) } catch {
            delegate?.simulatorSession(self, didFailWith: error)
        }
        cachedDisplay = display
        self.display = display
        self.hid = hid
        view.bind(display: display, hid: hid)
        state = .mirroring
        stopRebootPolling()
        startWatchingDevice()
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
