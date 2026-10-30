import AppKit
import Testing
@testable import Ghostty

@MainActor
struct WeakLocalEventMonitorTests {
    final class Owner { var consume = false }

    private func event(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }

    @Test func releasedOwnerPassesEventsButLiveOwnerCanConsume() throws {
        let window = NSWindow()
        var owner: Owner? = Owner()
        let handler = WeakLocalEventMonitor.handler(for: owner!) { owner, event in owner.consume ? nil : event }
        let click = try event(.leftMouseDown, in: window, at: .zero)
        #expect(handler(click) === click)
        owner?.consume = true
        #expect(handler(click) == nil)
        owner = nil
        #expect(handler(click) === click)
    }

    @Test func modalButtonsReceiveClicksAfterMonitorOwnerExpires() async throws {
        var owner: Owner? = Owner()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown,
            handler: WeakLocalEventMonitor.handler(for: owner!) { _, event in event })
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        owner = nil
        for index in [0, 1] {
            let alert = NSAlert()
            alert.messageText = "Mouse event regression"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Confirm")
            alert.window.isReleasedWhenClosed = false
            NSApp.activate(ignoringOtherApps: true)
            let click = Timer(timeInterval: 0.15, repeats: true) { _ in
                MainActor.assumeIsolated {
                    alert.window.makeKeyAndOrderFront(nil)
                    let button = alert.buttons[index]
                    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    if let down = try? event(.leftMouseDown, in: alert.window, at: point),
                       let up = try? event(.leftMouseUp, in: alert.window, at: point) {
                        NSApp.postEvent(down, atStart: false)
                        NSApp.postEvent(up, atStart: false)
                    }
                }
            }
            let timeout = Timer(timeInterval: 2, repeats: false) { _ in
                MainActor.assumeIsolated { NSApp.abortModal() }
            }
            RunLoop.main.add(click, forMode: .modalPanel)
            RunLoop.main.add(timeout, forMode: .modalPanel)
            let response = alert.runModal()
            click.invalidate(); timeout.invalidate()
            alert.window.close()
            #expect(response == (index == 0 ? .alertFirstButtonReturn : .alertSecondButtonReturn))
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
