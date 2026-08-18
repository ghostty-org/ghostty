#if DEBUG
import AppKit
import SimPaneKit

/// Drives the simulator pane end-to-end from inside the app, for verifying the
/// integration without taking over the machine's foreground.
///
/// Enable with `GHOSTTY_SIMPANE_SELFTEST=1`. Results go to stderr. Debug builds
/// only, and inert unless the variable is set.
///
/// This exists because the pane cannot otherwise be exercised headlessly:
/// synthesizing clicks and menu shortcuts from outside needs accessibility
/// permission, and stealing focus from whoever is using the machine is not an
/// acceptable way to run a test.
@MainActor
enum SimulatorPaneSelfTest {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GHOSTTY_SIMPANE_SELFTEST"] != nil
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[simpane-selftest] \(message)\n".utf8))
    }

    private static func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    static func run(on controller: TerminalController) async {
        log("support: \(SimulatorPaneModel.support)")
        guard SimulatorPaneModel.support.isSupported else {
            log("unsupported, nothing to test")
            return
        }

        let model = controller.simulatorPane
        model.isVisible = true
        await model.refreshDevices()
        log("devices: \(model.devices.count), selected: \(model.selectedDevice?.name ?? "none") "
            + "(\(model.selectedDevice?.state.label ?? "?"))")

        await model.attach()
        log("after attach: state=\(model.state.label) attached=\(model.isAttached)")
        guard let session = model.session, model.isAttached else {
            log("FAILED to attach: \(model.status ?? "no reason given")")
            return
        }
        await wait(2)
        log("surface: \(session.displayPixelSize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?")")

        // Focus handover, terminal -> simulator.
        let mirror = session.mirrorView
        controller.window?.makeFirstResponder(mirror)
        await wait(0.5)
        log("keyboard to simulator: \(model.keyboardGoesToSimulator) "
            + "(firstResponder is mirror: \(controller.window?.firstResponder === mirror))")

        // A swipe through the view's own NSEvent path, not the scripted API, so
        // this covers the pane's event handling rather than just the wire format.
        let before = session.framebufferSample()
        await swipe(in: mirror, window: controller.window, fromX: 0.7, toX: 0.3)
        await wait(2)
        let delta = SimulatorSession.frameDifference(before, session.framebufferSample())
        log(String(format: "swipe through the view: %.1f%% of the screen changed %@",
                   delta * 100, delta > 0.01 ? "(responded)" : "(NO RESPONSE)"))

        // Focus handover back, via double-Escape.
        for _ in 0..<2 {
            if let escape = key(0x35, in: controller.window) { mirror.keyDown(with: escape) }
            await wait(0.15)
        }
        await wait(0.5)
        log("after double-Escape: keyboard to simulator=\(model.keyboardGoesToSimulator), "
            + "firstResponder is mirror=\(controller.window?.firstResponder === mirror)")

        // Hold the pane open long enough to be observed from outside, then close
        // it and confirm nothing is retained. The plan's gate asks specifically
        // that closing the pane leaves no simulator work running.
        log("holding the pane open for 20s")
        await wait(20)
        model.isVisible = false
        await wait(2)
        log("pane closed: session=\(model.session == nil ? "released" : "STILL HELD"), "
            + "device still booted=\(SimulatorSession.listDevices().first { $0.udid == model.selectedUDID }?.isBooted ?? false)")
        log("done")
    }

    // MARK: Event synthesis

    private static func point(_ fractionX: CGFloat, _ fractionY: CGFloat, in view: NSView) -> CGPoint {
        let local = CGPoint(x: view.bounds.width * fractionX, y: view.bounds.height * fractionY)
        return view.convert(local, to: nil)
    }

    private static func mouse(
        _ type: NSEvent.EventType, at location: CGPoint, window: NSWindow?
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    private static func key(_ code: UInt16, in window: NSWindow?) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: code)
    }

    private static func swipe(
        in view: NSView, window: NSWindow?, fromX: CGFloat, toX: CGFloat
    ) async {
        guard let down = mouse(.leftMouseDown, at: point(fromX, 0.5, in: view), window: window)
        else { return }
        view.mouseDown(with: down)
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = fromX + (toX - fromX) * t
            if let moved = mouse(.leftMouseDragged, at: point(x, 0.5, in: view), window: window) {
                view.mouseDragged(with: moved)
            }
            await wait(0.012)
        }
        if let up = mouse(.leftMouseUp, at: point(toX, 0.5, in: view), window: window) {
            view.mouseUp(with: up)
        }
    }
}
#endif
