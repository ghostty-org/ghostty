import CoreGraphics
import XCTest
@testable import SimPaneCore

// MARK: - Coordinate mapping

final class CoordinatesTests: XCTestCase {

    /// A 2:1 device in a square view: full width, letterboxed top and bottom.
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
    private let pixels = CGSize(width: 200, height: 400)

    func testContentRectIsAspectFitAndCentred() {
        let rect = Coordinates.contentRect(bounds: bounds, devicePixels: pixels)
        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(rect.midY, bounds.midY, accuracy: 0.001)
    }

    func testCentreMapsToCentre() {
        let point = Coordinates.normalized(
            viewPoint: CGPoint(x: 200, y: 200), bounds: bounds,
            devicePixels: pixels, viewIsFlipped: true)
        XCTAssertEqual(point?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? -1, 0.5, accuracy: 0.001)
    }

    /// Indigo's origin is top-left; AppKit's default is bottom-left. Getting this
    /// backwards puts every tap in the wrong half of the screen.
    func testYOrientationDependsOnFlippedness() {
        let near = CGPoint(x: 200, y: 40)
        let flipped = Coordinates.normalized(
            viewPoint: near, bounds: bounds, devicePixels: pixels, viewIsFlipped: true)
        let unflipped = Coordinates.normalized(
            viewPoint: near, bounds: bounds, devicePixels: pixels, viewIsFlipped: false)
        XCTAssertEqual(flipped?.y ?? -1, 0.1, accuracy: 0.001)
        XCTAssertEqual(unflipped?.y ?? -1, 0.9, accuracy: 0.001)
    }

    func testLetterboxIsRejected() {
        // 400x200 view, 200x400 device -> pillarboxed left and right.
        let wide = CGRect(x: 0, y: 0, width: 400, height: 200)
        let content = Coordinates.contentRect(bounds: wide, devicePixels: pixels)
        XCTAssertEqual(content.width, 100, accuracy: 0.001)

        XCTAssertNil(Coordinates.normalized(
            viewPoint: CGPoint(x: 10, y: 100), bounds: wide,
            devicePixels: pixels, viewIsFlipped: true), "left pillarbox must not be a tap")
        XCTAssertNotNil(Coordinates.normalized(
            viewPoint: CGPoint(x: 200, y: 100), bounds: wide,
            devicePixels: pixels, viewIsFlipped: true))
    }

    func testDragClampsInsteadOfRejecting() {
        let clamped = Coordinates.normalizedClamped(
            viewPoint: CGPoint(x: -50, y: 1000), bounds: bounds,
            devicePixels: pixels, viewIsFlipped: true)
        XCTAssertEqual(clamped.x, 0, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 1, accuracy: 0.001)
    }

    func testDegenerateInputsDoNotCrash() {
        _ = Coordinates.contentRect(bounds: .zero, devicePixels: .zero)
        XCTAssertNil(Coordinates.normalized(
            viewPoint: .zero, bounds: .zero, devicePixels: .zero, viewIsFlipped: true))
    }
}

// MARK: - Keycodes

final class KeyMapTests: XCTestCase {

    /// Regression guard for the bug that produced "668k[e2=" when "apple.com" was
    /// typed: the guest reads USB HID usage codes, not HIToolbox virtual codes.
    func testVirtualCodesTranslateToHIDUsages() {
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x00), 0x04, "a")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x23), 0x13, "p")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x25), 0x0F, "l")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x0E), 0x08, "e")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x2F), 0x37, ".")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x08), 0x06, "c")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x1F), 0x12, "o")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x2E), 0x10, "m")
    }

    func testTypingAppleDotComProducesTheRightUsages() {
        let usages = "apple.com".compactMap { KeyMap.hidUsage(forCharacter: $0) }
        XCTAssertEqual(usages, [0x04, 0x13, 0x13, 0x0F, 0x08, 0x37, 0x06, 0x12, 0x10])
    }

    func testDigitsAndReturn() {
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x12), 0x1E, "1")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x1D), 0x27, "0 is not 1+9")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x24), 0x28, "return")
        XCTAssertEqual(KeyMap.hidUsage(forCharacter: "0"), 0x27)
        XCTAssertEqual(KeyMap.hidUsage(forCharacter: "\n"), 0x28)
    }

    func testModifiersAndArrows() {
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x38), 0xE1, "left shift")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x37), 0xE3, "left command")
        XCTAssertEqual(KeyMap.hidUsage(forVirtualKeyCode: 0x7E), 0x52, "up arrow")
    }

    func testUsagesAreUnique() {
        let usages = KeyMap.virtualToHIDUsage.values
        XCTAssertEqual(Set(usages).count, usages.count, "two keys map to the same usage")
    }

    func testUnknownKeyIsNil() {
        XCTAssertNil(KeyMap.hidUsage(forVirtualKeyCode: 0xFFF))
        XCTAssertNil(KeyMap.hidUsage(forCharacter: "€"))
    }
}

// MARK: - Indigo wire format

final class IndigoWireTests: XCTestCase {

    private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    private func f64(_ bytes: [UInt8], _ offset: Int) -> Double {
        var bits: UInt64 = 0
        for i in (0..<8).reversed() { bits = bits << 8 | UInt64(bytes[offset + i]) }
        return Double(bitPattern: bits)
    }

    /// Sizes come from Indigo.h under `#pragma pack(4)`: a 0x20 preamble and
    /// 0x90 payloads. Getting these wrong makes the guest silently ignore
    /// everything, so they are pinned.
    func testTouchMessageSizeAndEnvelope() {
        let msg = IndigoWire.touch(x: 0.5, y: 0.25, phase: .down)
        XCTAssertEqual(msg.count, 0x140, "0x20 preamble + two 0x90 payloads")
        XCTAssertEqual(u32(msg, 0x18), 0x90, "innerSize is the payload stride")
        XCTAssertEqual(msg[0x1c], 2, "eventType 2 = single touch")
        XCTAssertEqual(u32(msg, 0x20), 0x0B, "eventKind 0xB = touch")
    }

    func testTouchCoordinatesLandAtTheDocumentedOffsets() {
        let msg = IndigoWire.touch(x: 0.25, y: 0.75, phase: .down)
        XCTAssertEqual(f64(msg, 0x3c), 0.25, accuracy: 1e-12, "xRatio")
        XCTAssertEqual(f64(msg, 0x44), 0.75, accuracy: 1e-12, "yRatio")
    }

    func testTouchPhaseDrivesRangeAndTouch() {
        let down = IndigoWire.touch(x: 0.5, y: 0.5, phase: .down)
        XCTAssertEqual(u32(down, 0x64), 1, "in range")
        XCTAssertEqual(u32(down, 0x68), 1, "contact down")

        let up = IndigoWire.touch(x: 0.5, y: 0.5, phase: .up)
        XCTAssertEqual(u32(up, 0x64), 0, "out of range")
        XCTAssertEqual(u32(up, 0x68), 0, "contact lifted")

        // Regression guard for the defect that made exactly one gesture work per
        // boot: the mask reports which fields changed, and touch changes on lift.
        XCTAssertEqual(u32(up, 0x38) & 0x02, 0x02, "lift must still flag the touch transition")
        XCTAssertEqual(u32(up, 0x38) & 0x01, 0x01, "and the range transition")
        XCTAssertEqual(u32(up, 0x38) & 0x20, 0x20, "and keep contact identity")
    }

    func testSecondContactIsTaggedAndCarriesTheSameCoordinates() {
        let msg = IndigoWire.touch(x: 0.4, y: 0.6, phase: .move)
        let second = 0x20 + 0x90
        XCTAssertEqual(u32(msg, second + 0x10 + 0x00), 1, "duplicate contact field1")
        XCTAssertEqual(u32(msg, second + 0x10 + 0x04), 2, "duplicate contact field2")
        XCTAssertEqual(f64(msg, second + 0x10 + 0x0c), 0.4, accuracy: 1e-12)
    }

    func testTouchRoutesToThePhoneDigitizer() {
        let msg = IndigoWire.touch(x: 0.5, y: 0.5, phase: .down)
        XCTAssertEqual(u32(msg, 0x6c), 0x32, "field11 is the routing target")
    }

    func testButtonMessage() {
        let msg = IndigoWire.button(.home, .down)
        XCTAssertEqual(msg.count, 0xC0)
        XCTAssertEqual(u32(msg, 0x18), 0xA0)
        XCTAssertEqual(msg[0x1c], 1, "eventType 1 = button")
        XCTAssertEqual(u32(msg, 0x20), 2, "eventKind 2 = button")
        XCTAssertEqual(u32(msg, 0x30), 0x00, "home source")
        XCTAssertEqual(u32(msg, 0x34), 1, "down")
        XCTAssertEqual(u32(msg, 0x38), 0x33, "hardware target")
    }

    func testLockAndSiriUseDistinctSources() {
        XCTAssertEqual(u32(IndigoWire.button(.lock, .down), 0x30), 0x01)
        XCTAssertEqual(u32(IndigoWire.button(.siri, .down), 0x30), 0x0040_0002)
        XCTAssertEqual(u32(IndigoWire.button(.lock, .up), 0x34), 2, "up")
    }

    func testKeyMessageTargetsTheKeyboardService() {
        let msg = IndigoWire.key(code: 0x04, .down)
        XCTAssertEqual(u32(msg, 0x30), 0x2710, "keyboard source")
        XCTAssertEqual(u32(msg, 0x38), 0x64, "keyboard target")
        XCTAssertEqual(u32(msg, 0x3c), 0x04, "usage code for 'a'")
    }

    func testTimestampIsPopulated() {
        XCTAssertNotEqual(IndigoWire.touch(x: 0, y: 0, phase: .down)[0x24..<0x2c], [0, 0, 0, 0, 0, 0, 0, 0])
    }
}
