import CoreGraphics
import Foundation

func point(_ x: String, _ y: String) -> CGPoint {
    CGPoint(x: Double(x)!, y: Double(y)!)
}

func source() -> CGEventSource? {
    CGEventSource(stateID: .hidSystemState)
}

func post(_ type: CGEventType, _ location: CGPoint) {
    CGEvent(mouseEventSource: source(), mouseType: type, mouseCursorPosition: location, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func drag(_ from: CGPoint, _ to: CGPoint, steps: Int) {
    post(.mouseMoved, from)
    usleep(120_000)
    post(.leftMouseDown, from)
    usleep(120_000)
    for step in 1...steps {
        let t = Double(step) / Double(steps)
        let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
        post(.leftMouseDragged, p)
        usleep(12_000)
    }
    usleep(120_000)
    post(.leftMouseUp, to)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage\n", stderr); exit(2) }
switch args[1] {
case "move":
    post(.mouseMoved, point(args[2], args[3]))
case "click":
    let p = point(args[2], args[3])
    post(.mouseMoved, p); usleep(60_000)
    post(.leftMouseDown, p); usleep(80_000); post(.leftMouseUp, p)
case "drag":
    let from = point(args[2], args[3]), to = point(args[4], args[5])
    drag(from, to, steps: args.count > 6 ? Int(args[6])! : 20)
case "windows":
    let pid = Int32(args[2])!
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    var count = 0
    for window in windows {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
        count += 1
    }
    print("count=\(count)")
case "key":
    let code = CGKeyCode(UInt16(args[2])!)
    var flags: CGEventFlags = []
    for mod in args.dropFirst(3) {
        switch mod {
        case "cmd": flags.insert(.maskCommand)
        case "ctrl": flags.insert(.maskControl)
        case "shift": flags.insert(.maskShift)
        case "alt": flags.insert(.maskAlternate)
        default: break
        }
    }
    let down = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: true)!
    down.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(30_000)
    let up = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: false)!
    up.flags = flags
    up.post(tap: .cghidEventTap)
default:
    fputs("unknown command\n", stderr); exit(2)
}
