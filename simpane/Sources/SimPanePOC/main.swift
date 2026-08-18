//  SimPanePOC — proof that SimPaneKit's public API is enough to build the pane,
//  and the harness the reliability diagnostics run in.
//
//  Everything here goes through SimPaneKit. There is no private API in this
//  target, and no simulator knowledge beyond what the library exposes.
//
//  Usage: SimPanePOC [--udid <UDID>] [--list] ...

import AppKit
import SimPaneCore
import SimPaneKit

// MARK: - Arguments

var requestedUDID: String?
var listOnly = false
var snapshotPath: String?
var screenshotPath: String?
var statsSeconds: Double?
var pressButtonName: String?
var tapPoint: (Double, Double)?
var swipePoints: (Double, Double, Double, Double)?
var typeKeys: [UInt32] = []
var typeString: String?
var uiTestDirectory: String?
var soakIterations: Int?
var probeGap: Double?

var argv = Array(CommandLine.arguments.dropFirst())
while let arg = argv.first {
    argv.removeFirst()
    func next() -> String? {
        defer { if !argv.isEmpty { argv.removeFirst() } }
        return argv.first
    }
    switch arg {
    case "--udid": requestedUDID = next()
    case "--list": listOnly = true
    case "--snapshot": snapshotPath = next()
    case "--screenshot": screenshotPath = next()
    case "--stats": statsSeconds = next().flatMap(Double.init)
    case "--press": pressButtonName = next()
    case "--probe": probeGap = next().flatMap(Double.init)
    case "--soak": soakIterations = next().flatMap(Int.init)
    case "--uitest": uiTestDirectory = next()
    case "--text": typeString = next()
    case "--tap":
        if argv.count >= 2, let x = Double(argv[0]), let y = Double(argv[1]) {
            tapPoint = (x, y); argv.removeFirst(2)
        }
    case "--swipe":
        if argv.count >= 4, let a = Double(argv[0]), let b = Double(argv[1]),
           let c = Double(argv[2]), let d = Double(argv[3]) {
            swipePoints = (a, b, c, d); argv.removeFirst(4)
        }
    case "--keys":
        while let n = argv.first, let code = UInt32(n) { typeKeys.append(code); argv.removeFirst() }
    case "-h", "--help":
        print("""
        SimPanePOC — live iOS Simulator mirror

          --udid <UDID>       mirror a specific device (boots it if needed)
          --list              list available devices and exit
          --snapshot <png>    write one frame of the mirrored framebuffer and exit
          --screenshot <png>  write a simctl screenshot and exit
          --stats <secs>      measure the callback rate headlessly and exit

        Input, headless:
          --press <button>    home | lock | siri | side | applePay
          --tap <x> <y>       normalized 0...1 from the top-left of the screen
          --swipe <x0> <y0> <x1> <y1>
          --keys <usage>...   USB HID usages (page 0x07)
          --text <string>     typed through the HID usage table

        Diagnostics:
          --soak <n>          n scripted iterations through one client
          --probe <secs>      one gesture, a pause, a second gesture
          --uitest <dir>      drive the real view with synthesized NSEvents
        """)
        exit(0)
    default:
        break
    }
}

// MARK: - Helpers

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// Awaits an async call from synchronous top-level code.
///
/// Only valid before `NSApp.run()`. Pumping a nested runloop drains the main
/// queue while AppKit's own event loop is idle, but not once it is running — and
/// anything that needs the main actor then waits forever on a main thread that is
/// sitting in this loop. Code that runs inside the app is `async` for that
/// reason; the precondition turns a silent hang back into a stack trace.
func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    precondition(
        !NSApplication.shared.isRunning,
        "runBlocking cannot be used once the AppKit event loop is running; await instead")
    let box = ResultBox<T>()
    Task.detached {
        do { box.set(.success(try await body())) } catch { box.set(.failure(error)) }
    }
    while !box.isDone {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return try box.take()
}

final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return value != nil
    }

    func set(_ result: Result<T, Error>) {
        lock.lock(); value = result; lock.unlock()
    }

    func take() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw SimPaneError("no result") }
        return try value.get()
    }
}

/// Waits without blocking the main thread. Delivery of Indigo messages stalls if
/// the main runloop stops turning, so every pause pumps it.
func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

// MARK: - Preflight

if case .unsupported(let reason) = SimulatorSession.support() {
    die("SimPanePOC unsupported: \(reason)")
}

if listOnly {
    for device in SimulatorSession.listDevices() {
        let state = device.state.label.padding(toLength: 13, withPad: " ", startingAt: 0)
        let runtime = device.runtime.padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(device.udid)  \(state)  \(runtime)  \(device.name)")
    }
    exit(0)
}

// MARK: - Session

guard let target = requestedUDID.flatMap({ udid in
    SimulatorSession.listDevices().first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
}) ?? (requestedUDID == nil ? SimulatorSession.preferredDevice() : nil) else {
    die("no usable simulator device found (try --list)")
}

let session: SimulatorSession
do {
    session = try SimulatorSession(udid: target.udid)
} catch {
    die("could not open a session: \(error.localizedDescription)")
}

if !target.isBooted { print("booting \(target.name) (\(target.udid))...") }
do {
    try runBlocking { try await session.bootIfNeeded() }
} catch {
    die("attach failed: \(error.localizedDescription)")
}
print("mirroring \(target.name) (\(target.udid))")

if let reason = session.inputUnavailableReason {
    // Rendering still works; only input would silently fail. Warn, continue.
    note("warning: input forwarding unavailable — \(reason)")
}

// MARK: - Headless modes

if let snapshotPath {
    do {
        try session.framebufferPNG().write(to: URL(fileURLWithPath: snapshotPath))
    } catch {
        die(error.localizedDescription)
    }
    let size = session.displayPixelSize ?? .zero
    print("wrote \(Int(size.width))x\(Int(size.height)) PNG to \(snapshotPath)")
    exit(0)
}

if let screenshotPath {
    do {
        try runBlocking { try await session.screenshotPNG() }
            .write(to: URL(fileURLWithPath: screenshotPath))
    } catch {
        die(error.localizedDescription)
    }
    print("wrote a simctl screenshot to \(screenshotPath)")
    exit(0)
}

if let statsSeconds {
    // Measures the same pump the view uses. Without a window nothing is
    // presented, which is the point: damage/s is the device's rate, not ours.
    let start = Date()
    let before = session.statistics
    pump(statsSeconds)
    let elapsed = Date().timeIntervalSince(start)
    let after = session.statistics

    let pixels = after.surfacePixelSize ?? .zero
    let damage = after.damageEvents - before.damageEvents
    print(String(format: "surface        : %.0fx%.0f", pixels.width, pixels.height))
    print(String(format: "damage events  : %d in %.1fs = %.1f/s", damage, elapsed, Double(damage) / elapsed))
    exit(0)
}

if let probeGap {
    MainActor.assumeIsolated { runProbe(session: session, gap: probeGap) }
    exit(0)
}

if let soakIterations {
    MainActor.assumeIsolated {
        let runner = SoakRunner(session: session, iterations: soakIterations)
        if ProcessInfo.processInfo.environment["SIMPANE_SOAK_DRAGS"] != nil {
            runner.runWithDrags()
        } else {
            runner.run()
        }
    }
    exit(0)
}

// MARK: - Input test modes
//
// Each event class is exercised on its own so a failure points at one thing.

func sendOrDie(_ label: String, _ body: @escaping () async throws -> Void) {
    do { try runBlocking(body) } catch { die("\(label) failed: \(error.localizedDescription)") }
    pump(0.4)
}

if let pressButtonName {
    guard let button = HardwareButton(rawValue: pressButtonName) ?? HardwareButton.allCases.first(
        where: { $0.rawValue.caseInsensitiveCompare(pressButtonName) == .orderedSame })
    else {
        die("unknown button \(pressButtonName); try \(HardwareButton.allCases.map(\.rawValue))")
    }
    sendOrDie("press") { try await session.pressButton(button) }
    print("pressed \(button.rawValue)")
    exit(0)
}

if let tapPoint {
    sendOrDie("tap") { try await session.tap(x: tapPoint.0, y: tapPoint.1) }
    print(String(format: "tapped %.3f, %.3f", tapPoint.0, tapPoint.1))
    exit(0)
}

if let swipePoints {
    sendOrDie("swipe") {
        try await session.swipe(
            from: CGPoint(x: swipePoints.0, y: swipePoints.1),
            to: CGPoint(x: swipePoints.2, y: swipePoints.3))
    }
    print("swiped")
    exit(0)
}

if let typeString {
    sendOrDie("type") { try await session.typeText(typeString) }
    print("typed \(typeString.count) characters")
    exit(0)
}

if !typeKeys.isEmpty {
    let usages = typeKeys
    sendOrDie("keys") { try await session.typeKeys(usages) }
    print("sent \(usages.count) key events")
    exit(0)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, SimulatorSessionDelegate {
    let session: SimulatorSession
    let uiTestDirectory: String?
    var window: NSWindow!

    init(session: SimulatorSession, uiTestDirectory: String?) {
        self.session = session
        self.uiTestDirectory = uiTestDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.delegate = self

        // Open at a comfortable fraction of the device's real pixel size, keeping
        // its aspect ratio so the letterbox starts out empty.
        let pixels = session.displayPixelSize ?? CGSize(width: 1179, height: 2556)
        let aspect = pixels.width / pixels.height
        let height: CGFloat = 780
        let contentSize = CGSize(width: (height * aspect).rounded(), height: height)

        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = session.device.name
        window.contentAspectRatio = contentSize
        window.contentView = session.mirrorView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.mirrorView)
        installMenu()
        updateTitle()

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["SIMPANE_OCCLUSION_TEST"] != nil {
            Task { @MainActor in await self.runOcclusionTest() }
        }

        if let uiTestDirectory {
            Task { @MainActor in
                // Let the window settle before driving it.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await UITestRunner(
                    session: session, window: window, outputDirectory: uiTestDirectory).run()
                NSApp.terminate(nil)
            }
        }
    }

    /// Home on Cmd-Shift-H, matching Simulator.app.
    private func installMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let deviceItem = NSMenuItem()
        let deviceMenu = NSMenu(title: "Device")
        let home = NSMenuItem(title: "Home", action: #selector(pressHome), keyEquivalent: "H")
        home.keyEquivalentModifierMask = [.command, .shift]
        home.target = self
        deviceMenu.addItem(home)
        let lock = NSMenuItem(title: "Lock", action: #selector(pressLock), keyEquivalent: "L")
        lock.keyEquivalentModifierMask = [.command, .shift]
        lock.target = self
        deviceMenu.addItem(lock)
        deviceItem.submenu = deviceMenu
        mainMenu.addItem(deviceItem)
        NSApp.mainMenu = mainMenu
    }

    /// Proves the pane stops rendering when nothing can see it.
    ///
    /// Driven from inside the app because miniaturizing from outside needs
    /// accessibility permission this process cannot assume it has. Run something
    /// that keeps the guest painting for the duration, then compare the three
    /// windows: frames should climb, stop, and climb again.
    @MainActor
    private func runOcclusionTest() async {
        func frames() -> Int { session.statistics.framesPresented }
        func wait(_ s: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        }

        await wait(3)
        let visibleStart = frames()
        await wait(5)
        let visibleEnd = frames()

        window.miniaturize(nil)
        await wait(1.5)
        let hiddenStart = frames()
        await wait(5)
        let hiddenEnd = frames()

        window.deminiaturize(nil)
        await wait(1.5)
        let restoredStart = frames()
        await wait(5)
        let restoredEnd = frames()

        print("occlusion test (frames presented over 5s in each state):")
        print("  visible : \(visibleEnd - visibleStart)")
        print("  hidden  : \(hiddenEnd - hiddenStart)")
        print("  restored: \(restoredEnd - restoredStart)")
        let paused = (hiddenEnd - hiddenStart) == 0
        let resumed = (restoredEnd - restoredStart) > 0
        print(paused && resumed
            ? "PASS: rendering paused while hidden and resumed when visible"
            : "FAIL: paused=\(paused) resumed=\(resumed)")
        NSApp.terminate(nil)
    }

    @objc private func pressHome() { session.pressButton(.home) }
    @objc private func pressLock() { session.pressButton(.lock) }

    private func updateTitle() {
        let stats = session.statistics
        let dims = stats.surfacePixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
        let title = String(
            format: "%@ — %@ — %.0f fps presented / %.0f damage/s — %d frames",
            session.device.name, dims, stats.presentedFPS, stats.damageFPS, stats.framesPresented)
        window.title = title
        // Mirrored to stderr so the render loop can be verified without a
        // screen recording permission.
        note(title)
    }

    // MARK: SimulatorSessionDelegate

    func simulatorSessionDidUpdateStatistics(_ session: SimulatorSession) {
        updateTitle()
    }

    func simulatorSession(_ session: SimulatorSession, didFailWith error: Error) {
        note("session error: \(error.localizedDescription)")
    }

    func simulatorSession(_ session: SimulatorSession, didChangeState state: SimulatorSession.State) {
        note("session state: \(state.label)")
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Detach cleanly; never shut the device down on our way out.
        session.detach()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        session.detach()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate(session: session, uiTestDirectory: uiTestDirectory)
app.delegate = delegate
app.run()
