/// check-accessibility — Queries Ghostty's accessibility properties via the macOS AX API.
///
/// Usage:
///   swift build && .build/debug/check-accessibility [--listen]
///
/// Options:
///   --listen  After running checks, listen for accessibility notifications
///             (valueChanged, selectedTextChanged) and print them with timestamps.
///             Press Ctrl+C to stop.
///
/// Prerequisites:
///   - Ghostty must be running with a focused terminal window
///   - The terminal running this tool (or the tool binary itself) must have
///     Accessibility permission in System Settings > Privacy & Security > Accessibility
///
/// Tip: Run `seq 10000` in Ghostty first to generate scrollback, then run this tool.
/// With scrollback, AXVisibleCharacterRange should report a location >> 0 and a length
/// much smaller than AXNumberOfCharacters.

import Foundation
import AppKit
import ApplicationServices

let listenMode = CommandLine.arguments.contains("--listen")

// MARK: - Helpers

func axAttribute(_ element: AXUIElement, _ attr: String) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
    guard err == .success else { return nil }
    return value
}

func axParamAttribute(_ element: AXUIElement, _ attr: String, _ param: CFTypeRef) -> CFTypeRef? {
    var value: CFTypeRef?
    let err = AXUIElementCopyParameterizedAttributeValue(element, attr as CFString, param, &value)
    guard err == .success else { return nil }
    return value
}

/// Extract a CFRange from an AXValue-typed attribute.
func axRange(_ element: AXUIElement, _ attr: String) -> CFRange? {
    guard let ref = axAttribute(element, attr) else { return nil }
    // AX range attributes return an AXValue wrapping a CFRange.
    let axVal = ref as! AXValue
    var range = CFRange()
    guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
    return range
}

func axRect(_ value: AXValue) -> CGRect? {
    var rect = CGRect.zero
    guard AXValueGetValue(value, .cgRect, &rect) else { return nil }
    return rect
}

func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
    var cfRange = CFRange(location: location, length: length)
    guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
    guard let result = axParamAttribute(element, kAXBoundsForRangeParameterizedAttribute as String, param) else { return nil }
    return axRect(result as! AXValue)
}

func rangeForPosition(_ element: AXUIElement, point: CGPoint) -> CFRange? {
    var pt = point
    guard let param = AXValueCreate(.cgPoint, &pt) else { return nil }
    guard let result = axParamAttribute(element, kAXRangeForPositionParameterizedAttribute as String, param) else { return nil }
    let axVal = result as! AXValue
    var range = CFRange()
    guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
    return range
}

func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
    var cfRange = CFRange(location: location, length: length)
    guard let param = AXValueCreate(.cfRange, &cfRange) else { return nil }
    return axParamAttribute(element, kAXStringForRangeParameterizedAttribute as String, param) as? String
}

func rangeForLine(_ element: AXUIElement, line: Int) -> CFRange? {
    guard let result = axParamAttribute(element, kAXRangeForLineParameterizedAttribute as String, line as CFNumber) else { return nil }
    let axVal = result as! AXValue
    var range = CFRange()
    guard AXValueGetValue(axVal, .cfRange, &range) else { return nil }
    return range
}

func lineForIndex(_ element: AXUIElement, index: Int) -> Int? {
    return axParamAttribute(element, kAXLineForIndexParameterizedAttribute as String, index as CFNumber) as? Int
}

/// Recursively search for an AXTextArea element.
func findTextArea(in element: AXUIElement) -> AXUIElement? {
    if let role = axAttribute(element, kAXRoleAttribute as String) as? String, role == "AXTextArea" {
        return element
    }
    guard let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
        return nil
    }
    for child in children {
        if let found = findTextArea(in: child) { return found }
    }
    return nil
}

func truncated(_ s: String, maxLen: Int = 80) -> String {
    if s.count <= maxLen * 2 + 5 { return s.debugDescription }
    let prefix = s.prefix(maxLen)
    let suffix = s.suffix(maxLen)
    return "\"\(prefix)\" ... \"\(suffix)\" (\(s.count) chars)"
}

/// Get the window's position and size via AX attributes.
func windowFrame(of window: AXUIElement) -> (pos: CGPoint, size: CGSize)? {
    guard let posRef = axAttribute(window, kAXPositionAttribute as String),
          let sizeRef = axAttribute(window, kAXSizeAttribute as String) else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    return (pos, size)
}

// MARK: - Main

guard AXIsProcessTrusted() else {
    fputs("""
    Error: Accessibility permission not granted.

    Grant access in:
      System Settings > Privacy & Security > Accessibility

    Add either this binary or the terminal app you're running it from.

    """, stderr)
    exit(1)
}

let bundleID = "com.mitchellh.ghostty.debug"
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
    fputs("Error: Ghostty is not running (looked for bundle ID: \(bundleID)).\n", stderr)
    exit(1)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
print("Found Ghostty (PID \(app.processIdentifier))")

// MARK: - AXFocusedUIElement

print("")
print("=== AXFocusedUIElement ===")
print("")

if let focusedRef = axAttribute(appElement, kAXFocusedUIElementAttribute as String) {
    let focused = focusedRef as! AXUIElement
    let focusedRole = axAttribute(focused, kAXRoleAttribute as String) as? String ?? "(nil)"
    let focusedRoleDesc = axAttribute(focused, kAXRoleDescriptionAttribute as String) as? String
    let focusedTitle = axAttribute(focused, kAXTitleAttribute as String) as? String
    let focusedDesc = axAttribute(focused, kAXDescriptionAttribute as String) as? String
    let focusedHelp = axAttribute(focused, kAXHelpAttribute as String) as? String
    let focusedValue = axAttribute(focused, kAXValueAttribute as String)

    print("AXRole: \(focusedRole)")
    if let rd = focusedRoleDesc { print("AXRoleDescription: \(rd)") }
    if let t = focusedTitle { print("AXTitle: \(t)") }
    if let d = focusedDesc { print("AXDescription: \(d)") }
    if let h = focusedHelp { print("AXHelp: \(h)") }

    if let val = focusedValue as? String {
        print("AXValue: \(truncated(val))")
    } else if let val = focusedValue {
        print("AXValue: \(val) (type: \(CFGetTypeID(val)))")
    } else {
        print("AXValue: (nil)")
    }

    // Dump the focused element's supported attributes list.
    var attrNames: CFArray?
    if AXUIElementCopyAttributeNames(focused, &attrNames) == .success, let names = attrNames as? [String] {
        print("Supported attributes (\(names.count)): \(names.sorted().joined(separator: ", "))")
    }

    // If the focused element supports parameterized attributes, list them.
    var paramNames: CFArray?
    if AXUIElementCopyParameterizedAttributeNames(focused, &paramNames) == .success, let names = paramNames as? [String] {
        if !names.isEmpty {
            print("Parameterized attributes (\(names.count)): \(names.sorted().joined(separator: ", "))")
        }
    }
} else {
    print("AXFocusedUIElement: (nil)")
}

// MARK: - Find text area via window hierarchy

// Get focused window.
guard let winRef = axAttribute(appElement, kAXFocusedWindowAttribute as String) else {
    fputs("Error: No focused window found.\n", stderr)
    exit(1)
}
let window = winRef as! AXUIElement

// Find the AXTextArea (terminal surface).
guard let textArea = findTextArea(in: window) else {
    fputs("Error: No AXTextArea element found in the focused window.\n", stderr)
    exit(1)
}

print("")
print("=== Text Area Attributes ===")
print("")

// AXRole
let role = axAttribute(textArea, kAXRoleAttribute as String) as? String ?? "(nil)"
print("AXRole: \(role)")

// AXNumberOfCharacters
let numChars = (axAttribute(textArea, kAXNumberOfCharactersAttribute as String) as? NSNumber)?.intValue
print("AXNumberOfCharacters: \(numChars.map(String.init) ?? "(nil)")")

// AXValue (truncated)
let fullText = axAttribute(textArea, kAXValueAttribute as String) as? String
if let text = fullText {
    print("AXValue: \(truncated(text))")
} else {
    print("AXValue: (nil)")
}

// AXVisibleCharacterRange
let visibleRange = axRange(textArea, kAXVisibleCharacterRangeAttribute as String)
if let vr = visibleRange {
    print("AXVisibleCharacterRange: {loc: \(vr.location), len: \(vr.length)}")
} else {
    print("AXVisibleCharacterRange: (nil)")
}

// AXSelectedTextRange
let selectedRange = axRange(textArea, kAXSelectedTextRangeAttribute as String)
if let sr = selectedRange {
    print("AXSelectedTextRange: {loc: \(sr.location), len: \(sr.length)}")
} else {
    print("AXSelectedTextRange: (nil)")
}

// AXSelectedText
let selectedText = axAttribute(textArea, kAXSelectedTextAttribute as String) as? String
print("AXSelectedText: \(selectedText.map { $0.isEmpty ? "(empty)" : truncated($0) } ?? "(nil)")")

// AXInsertionPointLineNumber
let insertionLine = axAttribute(textArea, kAXInsertionPointLineNumberAttribute as String) as? Int
print("AXInsertionPointLineNumber: \(insertionLine.map(String.init) ?? "(nil)")")

print("")
print("=== Text Area Parameterized Attributes ===")
print("")

// AXBoundsForRange — test a few positions within the visible range.
if let vr = visibleRange {
    let testOffsets: [(String, Int)] = [
        ("first visible char", vr.location),
        ("mid visible char", vr.location + vr.length / 2),
        ("last visible char", vr.location + vr.length - 1),
    ]
    for (label, offset) in testOffsets {
        if let rect = boundsForRange(textArea, location: offset, length: 1) {
            print("AXBoundsForRange(\(label), loc=\(offset)): origin=(\(Int(rect.origin.x)), \(Int(rect.origin.y))) size=\(Int(rect.size.width))x\(Int(rect.size.height))")
        } else {
            print("AXBoundsForRange(\(label), loc=\(offset)): (failed)")
        }
    }
} else {
    print("AXBoundsForRange: skipped (no visible range)")
}

// AXRangeForPosition — use the center of the window's frame.
let winFrame = windowFrame(of: window)
if let frame = winFrame {
    let center = CGPoint(x: frame.pos.x + frame.size.width / 2, y: frame.pos.y + frame.size.height / 2)
    if let range = rangeForPosition(textArea, point: center) {
        print("AXRangeForPosition(window center (\(Int(center.x)), \(Int(center.y)))): {loc: \(range.location), len: \(range.length)}")
        if range.length > 0, let charStr = stringForRange(textArea, location: range.location, length: range.length) {
            print("  -> character: \(charStr.debugDescription)")
        }
    } else {
        print("AXRangeForPosition(window center): (failed)")
    }
} else {
    print("AXRangeForPosition: skipped (couldn't get window frame)")
}

// AXStringForRange — first 40 chars of visible range.
if let vr = visibleRange {
    let len = min(40, vr.length)
    if let str = stringForRange(textArea, location: vr.location, length: len) {
        print("AXStringForRange(first \(len) visible chars): \(str.debugDescription)")
    } else {
        print("AXStringForRange: (failed)")
    }
} else {
    print("AXStringForRange: skipped (no visible range)")
}

// AXRangeForLine / AXLineForIndex — test line navigation.
if let insertionLineNum = insertionLine {
    print("")
    print("--- AXRangeForLine / AXLineForIndex ---")
    print("")

    // Test a few lines around the insertion point.
    let testLines = Set([0, max(0, insertionLineNum - 1), insertionLineNum, insertionLineNum + 1])
    for lineNum in testLines.sorted() {
        if let range = rangeForLine(textArea, line: lineNum) {
            let lineText = stringForRange(textArea, location: range.location, length: range.length)
            let preview = lineText.map { truncated($0, maxLen: 40) } ?? "(nil)"
            print("AXRangeForLine(\(lineNum)): {loc: \(range.location), len: \(range.length)} -> \(preview)")

            // Round-trip: the first character of this line should map back to the same line number.
            if range.length > 0, let recoveredLine = lineForIndex(textArea, index: range.location) {
                let match = recoveredLine == lineNum ? "OK" : "MISMATCH (got \(recoveredLine))"
                print("  AXLineForIndex(\(range.location)) -> \(recoveredLine) [\(match)]")
            }
        } else {
            print("AXRangeForLine(\(lineNum)): (failed)")
        }
    }
}

// Word-by-word bounds for the last visible line.
if let vr = visibleRange, let frame = winFrame {
    let visibleText = stringForRange(textArea, location: vr.location, length: vr.length) ?? ""
    // Find the last line (split by newline, take the last non-empty one).
    let lines = visibleText.components(separatedBy: "\n")
    let lastLine = lines.last(where: { !$0.isEmpty }) ?? ""
    // Compute the character offset of the last line within the visible range.
    let lastLineOffset: Int
    if let range = visibleText.range(of: lastLine, options: .backwards) {
        lastLineOffset = vr.location + visibleText.distance(from: visibleText.startIndex, to: range.lowerBound)
    } else {
        lastLineOffset = vr.location
    }

    print("")
    print("=== Last Visible Line: Word Bounds ===")
    print("")
    print("Window frame: origin=(\(Int(frame.pos.x)), \(Int(frame.pos.y))) size=\(Int(frame.size.width))x\(Int(frame.size.height))")
    let winLeft = Int(frame.pos.x)
    let winRight = Int(frame.pos.x + frame.size.width)
    let winTop = Int(frame.pos.y)
    let winBottom = Int(frame.pos.y + frame.size.height)
    print("Window edges: left=\(winLeft) right=\(winRight) top=\(winTop) bottom=\(winBottom)")
    print("Last line: \(lastLine.debugDescription)")
    print("")

    // Split into words (whitespace-separated tokens).
    var scanner = lastLine[lastLine.startIndex...]
    var wordOffset = 0 // character offset within lastLine
    while !scanner.isEmpty {
        // Skip whitespace.
        let wsPrefix = scanner.prefix(while: { $0 == " " || $0 == "\t" })
        wordOffset += wsPrefix.count
        scanner = scanner.dropFirst(wsPrefix.count)
        if scanner.isEmpty { break }

        // Collect word.
        let wordChars = scanner.prefix(while: { $0 != " " && $0 != "\t" })
        let word = String(wordChars)
        let charLoc = lastLineOffset + wordOffset
        let charLen = word.count

        if let rect = boundsForRange(textArea, location: charLoc, length: charLen) {
            let rx = Int(rect.origin.x)
            let ry = Int(rect.origin.y)
            let rw = Int(rect.size.width)
            let rh = Int(rect.size.height)
            let inWindow = rx >= winLeft && (rx + rw) <= winRight && ry >= winTop && (ry + rh) <= winBottom
            print("  \"\(word)\" [loc=\(charLoc), len=\(charLen)] -> (\(rx), \(ry)) \(rw)x\(rh) \(inWindow ? "IN_WINDOW" : "OUT_OF_WINDOW")")
        } else {
            print("  \"\(word)\" [loc=\(charLoc), len=\(charLen)] -> (bounds failed)")
        }

        wordOffset += wordChars.count
        scanner = scanner.dropFirst(wordChars.count)
    }
}

// Cross-line bounds: test that multi-line ranges produce a bounding box
// spanning the full view width, while same-line ranges produce tight rects.
if let vr = visibleRange, let frame = winFrame {
    let visibleText = stringForRange(textArea, location: vr.location, length: vr.length) ?? ""
    let lines = visibleText.components(separatedBy: "\n").filter { !$0.isEmpty }

    print("")
    print("=== Cross-Line Bounds ===")
    print("")

    // Same-line range: first 5 chars of the first visible line.
    if let firstLine = lines.first, firstLine.count >= 5 {
        let len = min(firstLine.count, 10)
        if let rect = boundsForRange(textArea, location: vr.location, length: len) {
            let rw = Int(rect.size.width)
            let rh = Int(rect.size.height)
            print("Same-line range (first \(len) chars of first visible line):")
            print("  \(firstLine.prefix(len).debugDescription)")
            print("  -> (\(Int(rect.origin.x)), \(Int(rect.origin.y))) \(rw)x\(rh)")
            // For a same-line range, width should be roughly len * cell_width,
            // not the full window width.
            let expectedWidth = len * 8  // approximate cell width
            print("  Expected width ~\(expectedWidth), got \(rw) (same-line: \(rw < Int(frame.size.width) ? "tight" : "FULL WIDTH — unexpected"))")
        }
    }

    // Cross-line range: span from partway through the first visible line
    // to partway through the second visible line. This tests the multi-line
    // bounding box logic: the rect should use full view width since
    // intermediate content spans the whole line.
    if lines.count >= 2 {
        let firstLineLen = lines[0].count
        // Start 1 char into the first line, end 1 char into the second line.
        // Account for the newline between lines (+1).
        let crossLen = firstLineLen + 1  // rest of first line + newline + start of second
        if let str = stringForRange(textArea, location: vr.location + 1, length: crossLen) {
            if let rect = boundsForRange(textArea, location: vr.location + 1, length: crossLen) {
                let rw = Int(rect.size.width)
                let rh = Int(rect.size.height)
                print("Cross-line range (2 lines, \(crossLen) chars):")
                print("  \(str.debugDescription)")
                print("  -> (\(Int(rect.origin.x)), \(Int(rect.origin.y))) \(rw)x\(rh)")
                // For a cross-line range, width should be ~full view width and
                // height should be ~2 * cell_height.
                print("  Width: \(rw) (full view width = \(Int(frame.size.width)), multi-line: \(rw >= Int(frame.size.width) - 20 ? "FULL WIDTH" : "narrow — unexpected"))")
                print("  Height: \(rh) (expected ~2 lines = ~34, got \(rh))")
            }
        }
    }

    // Larger cross-line range: span 5 lines.
    if lines.count >= 5 {
        // Sum up character counts for first 5 lines + 4 newlines.
        let fiveLineLen = lines.prefix(5).map(\.count).reduce(0, +) + 4
        if let str = stringForRange(textArea, location: vr.location, length: fiveLineLen) {
            if let rect = boundsForRange(textArea, location: vr.location, length: fiveLineLen) {
                let rw = Int(rect.size.width)
                let rh = Int(rect.size.height)
                print("Cross-line range (5 lines, \(fiveLineLen) chars):")
                print("  \(truncated(str, maxLen: 30))")
                print("  -> (\(Int(rect.origin.x)), \(Int(rect.origin.y))) \(rw)x\(rh)")
                print("  Width: \(rw) (multi-line: \(rw >= Int(frame.size.width) - 20 ? "FULL WIDTH" : "narrow — unexpected"))")
                print("  Height: \(rh) (expected ~5 lines = ~85, got \(rh))")
            }
        }
    }
}

// MARK: - Assertions

print("")
print("=== Checks ===")
print("")

var allPassed = true

func check(_ label: String, _ ok: Bool, detail: String = "") {
    let marker = ok ? "PASS" : "FAIL"
    let extra = detail.isEmpty ? "" : " — \(detail)"
    print("[\(marker)] \(label)\(extra)")
    if !ok { allPassed = false }
}

if let nc = numChars, let vr = visibleRange {
    check(
        "Visible range length < total chars",
        vr.length < nc,
        detail: "\(vr.length) < \(nc)"
    )
    check(
        "Visible range has reasonable length",
        vr.length > 0 && vr.length <= 100_000,
        detail: "length = \(vr.length)"
    )
} else {
    check("Visible range available", false, detail: "numChars or visibleRange is nil")
}

if let vr = visibleRange {
    let rect = boundsForRange(textArea, location: vr.location, length: 1)
    check(
        "BoundsForRange returns non-zero rect",
        rect != nil && rect!.size.width > 0 && rect!.size.height > 0,
        detail: rect.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
    )
} else {
    check("BoundsForRange returns non-zero rect", false, detail: "no visible range to test")
}

// Use the center of the first visible character's bounds as the test point,
// since the window center may land on empty space below the terminal content.
if let vr = visibleRange, vr.length > 0,
   let firstCharRect = boundsForRange(textArea, location: vr.location, length: 1) {
    let testPoint = CGPoint(
        x: firstCharRect.origin.x + firstCharRect.size.width / 2,
        y: firstCharRect.origin.y + firstCharRect.size.height / 2
    )
    let range = rangeForPosition(textArea, point: testPoint)
    check(
        "RangeForPosition returns valid range",
        range != nil && range!.location != kCFNotFound && range!.length > 0,
        detail: range.map { "{loc: \($0.location), len: \($0.length)}" } ?? "nil"
    )
} else {
    check("RangeForPosition returns valid range", false, detail: "no visible character to test")
}

// InsertionPointLineNumber
check(
    "InsertionPointLineNumber is available",
    insertionLine != nil,
    detail: insertionLine.map { "line \($0)" } ?? "nil"
)

// RangeForLine round-trip with LineForIndex
if let lineNum = insertionLine {
    let lineRange = rangeForLine(textArea, line: lineNum)
    check(
        "RangeForLine returns valid range for cursor line",
        lineRange != nil && lineRange!.location >= 0 && lineRange!.length >= 0,
        detail: lineRange.map { "{loc: \($0.location), len: \($0.length)}" } ?? "nil"
    )

    if let lr = lineRange, lr.length > 0 {
        let recoveredLine = lineForIndex(textArea, index: lr.location)
        check(
            "LineForIndex(RangeForLine(cursor).location) round-trips",
            recoveredLine == lineNum,
            detail: "expected \(lineNum), got \(recoveredLine.map(String.init) ?? "nil")"
        )
    }

    // RangeForLine line 0 should always work and start at location 0.
    let line0Range = rangeForLine(textArea, line: 0)
    check(
        "RangeForLine(0) starts at location 0",
        line0Range != nil && line0Range!.location == 0,
        detail: line0Range.map { "loc=\($0.location)" } ?? "nil"
    )
} else {
    check("RangeForLine returns valid range for cursor line", false, detail: "no insertion line")
    check("LineForIndex round-trips", false, detail: "no insertion line")
    check("RangeForLine(0) starts at location 0", false, detail: "no insertion line")
}

print("")

if !allPassed {
    exit(1)
}

// MARK: - Listen Mode

guard listenMode else { exit(0) }

print("=== Listening for Accessibility Notifications ===")
print("(Press Ctrl+C to stop)")
print("")

let pid = app.processIdentifier
var observer: AXObserver?
let createErr = AXObserverCreate(pid, { (_: AXObserver, element: AXUIElement, notification: CFString, _: UnsafeMutableRawPointer?) in
    let name = notification as String
    let timestamp = ISO8601DateFormatter().string(from: Date())

    // Print the notification with relevant context.
    switch name {
    case kAXValueChangedNotification:
        let numChars = axAttribute(element, kAXNumberOfCharactersAttribute as String) as? Int
        let insertionLine = axAttribute(element, kAXInsertionPointLineNumberAttribute as String) as? Int
        var lastLineInfo = ""
        if let value = axAttribute(element, kAXValueAttribute as String) as? String {
            let lastLine = value.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            lastLineInfo = ", last line: \(truncated(lastLine, maxLen: 60))"
        }
        print("[\(timestamp)] \(name) — chars: \(numChars ?? -1), cursor line: \(insertionLine ?? -1)\(lastLineInfo)")

    case kAXSelectedTextChangedNotification:
        let selRange = axRange(element, kAXSelectedTextRangeAttribute as String)
        if let sr = selRange {
            print("[\(timestamp)] \(name) — range: {loc: \(sr.location), len: \(sr.length)}")
        } else {
            print("[\(timestamp)] \(name) — range: (nil)")
        }

    default:
        print("[\(timestamp)] \(name)")
    }
}, &observer)

guard createErr == .success, let observer = observer else {
    fputs("Error: Failed to create AX observer (err: \(createErr.rawValue)).\n", stderr)
    exit(1)
}

// Register for notifications on the text area element.
let notifications: [String] = [
    kAXValueChangedNotification as String,
    kAXSelectedTextChangedNotification as String,
]

for notif in notifications {
    let err = AXObserverAddNotification(observer, textArea, notif as CFString, nil)
    if err == .success {
        print("Registered for: \(notif)")
    } else {
        fputs("Warning: Failed to register for \(notif) (err: \(err.rawValue)).\n", stderr)
    }
}

CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
print("")

// Run forever until Ctrl+C.
RunLoop.current.run()
