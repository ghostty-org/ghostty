//  Scripted exercise of the pane's NSEvent handling.
//
//  The CLI modes prove the Indigo layer; this proves the layer above it — that
//  real AppKit events translate to the right coordinates and key codes. Events
//  are synthesized and handed to the view exactly as AppKit would deliver them,
//  which is why this drives `session.mirrorView` rather than the session's own
//  scripted-input API.

import AppKit
import SimPaneCore
import SimPaneKit

@MainActor
final class UITestRunner {

    private let session: SimulatorSession
    private let view: NSView
    private let window: NSWindow
    private let outputDirectory: String
    private var step = 0

    init(session: SimulatorSession, window: NSWindow, outputDirectory: String) {
        self.session = session
        self.view = session.mirrorView
        self.window = window
        self.outputDirectory = outputDirectory
        try? FileManager.default.createDirectory(
            atPath: outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: Synthesis

    /// View coordinates -> window coordinates, which is what NSEvent carries.
    private func windowPoint(_ fraction: CGPoint) -> CGPoint {
        let content = Coordinates.contentRect(
            bounds: view.bounds, devicePixels: session.displayPixelSize ?? .zero)
        let inView = CGPoint(
            x: content.minX + content.width * fraction.x,
            y: content.minY + content.height * fraction.y)
        return view.convert(inView, to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, at fraction: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint(fraction),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, characters: String) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code)
    }

    // MARK: Actions

    private func tap(_ x: Double, _ y: Double) async {
        guard let down = mouse(.leftMouseDown, at: CGPoint(x: x, y: y)),
              let up = mouse(.leftMouseUp, at: CGPoint(x: x, y: y)) else {
            note("tap: NSEvent.mouseEvent returned nil")
            return
        }
        view.mouseDown(with: down)
        // iOS ignores a zero-duration contact, so the finger has to rest.
        await wait(0.06)
        view.mouseUp(with: up)
    }

    private func drag(from: CGPoint, to: CGPoint, steps: Int = 20) async {
        guard let down = mouse(.leftMouseDown, at: from) else { return }
        view.mouseDown(with: down)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            if let moved = mouse(.leftMouseDragged, at: point) { view.mouseDragged(with: moved) }
            // The view coalesces to 120 Hz, so a real-time drag is what exercises it.
            await wait(0.012)
        }
        if let up = mouse(.leftMouseUp, at: to) { view.mouseUp(with: up) }
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func type(_ text: String) async {
        // Virtual key codes for the characters this script uses. Deliberately raw
        // rather than routed through KeyMap: the point is to prove the view's own
        // translation, so feeding it pre-translated usages would test nothing.
        let codes: [Character: UInt16] = [
            "a": 0x00, "p": 0x23, "l": 0x25, "e": 0x0E, ".": 0x2F,
            "c": 0x08, "o": 0x1F, "m": 0x2E, "\n": 0x24,
        ]
        for character in text {
            guard let code = codes[character] else { continue }
            if let down = key(.keyDown, code: code, characters: String(character)) {
                view.keyDown(with: down)
            }
            await wait(0.02)
            if let up = key(.keyUp, code: code, characters: String(character)) {
                view.keyUp(with: up)
            }
            await wait(0.04)
        }
    }

    /// Runs one action and reports whether the screen actually responded.
    private func act(_ label: String, settleFor: TimeInterval = 2.0,
                     _ body: () async -> Void) async {
        let before = session.framebufferSample()
        await body()
        await wait(settleFor)
        let delta = SimulatorSession.frameDifference(before, session.framebufferSample())
        print(String(format: "    %-22s %5.1f%%  %@", (label as NSString).utf8String!,
                     delta * 100, delta > 0.01 ? "responded" : "NO RESPONSE"))
    }

    private func snapshot(_ name: String) {
        step += 1
        let path = "\(outputDirectory)/step\(step)-\(name).png"
        do {
            try session.framebufferPNG().write(to: URL(fileURLWithPath: path))
            print("  step \(step): \(name) -> \(path)")
        } catch {
            note("  step \(step): \(name) -> \(error.localizedDescription)")
        }
    }

    // MARK: Script

    func run() async {
        print("UI test: driving the view with synthesized NSEvents")

        await act("home") { self.session.pressButton(.home) }
        snapshot("home")

        // A drag across the home screen should page it.
        await act("swipe page") {
            await self.drag(from: CGPoint(x: 0.8, y: 0.5), to: CGPoint(x: 0.2, y: 0.5))
        }
        snapshot("swiped-page")

        await act("home") { self.session.pressButton(.home) }

        // Settings, last icon of the second row.
        await act("tap Settings", settleFor: 2.4) { await self.tap(0.843, 0.483) }
        snapshot("tapped-settings")

        // Drag upward to scroll the settings list.
        await act("scroll list") {
            await self.drag(from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.5, y: 0.35))
        }
        snapshot("scrolled-list")

        await act("home") { self.session.pressButton(.home) }
        snapshot("home-again")

        try? await session.launchApp(bundleIdentifier: "com.apple.mobilesafari")
        await wait(2.8)
        await act("tap address bar") { await self.tap(0.5, 0.94) }
        snapshot("address-bar")

        await act("type apple.com", settleFor: 3.5) { await self.type("apple.com\n") }
        snapshot("typed-and-loaded")

        await act("lock") { self.session.pressButton(.lock) }
        snapshot("locked")

        await act("wake") { self.session.pressButton(.lock) }
        await act("swipe to unlock") {
            await self.drag(from: CGPoint(x: 0.5, y: 0.9), to: CGPoint(x: 0.5, y: 0.35))
        }
        snapshot("unlocked")

        print("UI test complete")
    }
}
