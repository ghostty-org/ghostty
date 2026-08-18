//  The Indigo HID wire format.
//
//  Layout ported from facebook/idb (MIT), PrivateHeaders/SimulatorApp/Indigo.h
//  — see docs/simpane/ATTRIBUTIONS.md.
//
//  Messages are assembled byte by byte rather than by calling SimulatorKit's
//  `IndigoHIDMessageFor*` C builders, which both reference implementations
//  resolve with dlsym and call as raw C function pointers. Pure and
//  unit-testable: nothing here needs a simulator.

import Foundation

public enum IndigoWire {

    // MARK: Layout  (Indigo.h, #pragma pack(push, 4))

    /// Bytes before the first payload: a 24-byte mach header, innerSize, eventType.
    public static let payloadBase = 0x20
    /// sizeof(IndigoPayload) with pack(4): 0x10 of preamble + a 0x80 event union.
    public static let payloadStride = 0x90

    private static let offInnerSize = 0x18
    private static let offEventType = 0x1c

    // Payload-relative.
    private static let offEventKind = 0x00
    private static let offTimestamp = 0x04
    private static let offEvent = 0x10

    // IndigoTouch, relative to the event union.
    private static let offTouchField1 = 0x00
    private static let offTouchField2 = 0x04
    private static let offTouchEventMask = 0x08
    private static let offTouchXRatio = 0x0c
    private static let offTouchYRatio = 0x14
    private static let offTouchRange = 0x34
    private static let offTouchTouch = 0x38
    private static let offTouchTarget = 0x3c   // Indigo.h field11

    // IndigoButton, relative to the event union.
    private static let offButtonSource = 0x00
    private static let offButtonType = 0x04
    private static let offButtonTarget = 0x08
    private static let offButtonKeyCode = 0x0c

    // MARK: Constants

    /// IndigoPayload.eventKind — what the guest dispatches on.
    private static let eventKindButton: UInt32 = 2
    private static let eventKindTouch: UInt32 = 0x0B

    /// IndigoMessage.eventType.
    private static let messageTypeButton: UInt8 = 1
    private static let messageTypeSingleTouch: UInt8 = 2

    /// Digitizer routing target for the phone's main screen.
    private static let touchTargetPhone: UInt32 = 0x32

    /// Values the SimulatorKit builders are observed to write.
    private static let touchField1Default: UInt32 = 0x0040_0002
    private static let touchField2Default: UInt32 = 1

    /// IOHIDDigitizerEventMask bits.
    public struct DigitizerMask {
        public static let range: UInt32 = 0x01
        public static let touch: UInt32 = 0x02
        public static let position: UInt32 = 0x04
        public static let identity: UInt32 = 0x20
    }

    public enum TouchPhase {
        case down, move, up

        /// Kept together so the three-way relationship stays readable: a contact
        /// that is down is in range, and lifting clears both.
        public var mask: UInt32 {
            switch self {
            case .down: return DigitizerMask.range | DigitizerMask.touch
                              | DigitizerMask.position | DigitizerMask.identity
            // Identity must stay set on every event of the gesture. Dropping it
            // mid-drag leaves the guest unable to correlate the contact, and it
            // leaks contacts until the digitizer stops accepting touches
            // altogether — which looks exactly like input silently dying.
            case .move: return DigitizerMask.range | DigitizerMask.touch
                              | DigitizerMask.position | DigitizerMask.identity
            // Touch must be set on the lift too. The mask says which fields
            // *changed*, and on lift both range and touch go 1 -> 0. Omitting
            // Touch (idb's trackpad path uses Range|Identity for its "ended"
            // phase) leaves the guest believing the contact is still down: the
            // lift is accepted without error and every subsequent gesture is
            // then silently ignored. Exactly one gesture works per boot.
            case .up:   return DigitizerMask.range | DigitizerMask.touch
                              | DigitizerMask.identity
            }
        }
        public var range: UInt32 { self == .up ? 0 : 1 }
        public var touch: UInt32 { self == .up ? 0 : 1 }
    }

    public enum Button: UInt32 {
        case home = 0x0
        case lock = 0x1
        case applePay = 0x1f4
        case sideButton = 0xbb8
        case siri = 0x0040_0002
        case keyboard = 0x2710
    }

    public enum Direction: UInt32 {
        case down = 1
        case up = 2
    }

    private static let targetHardware: UInt32 = 0x33
    private static let targetKeyboard: UInt32 = 0x64

    // MARK: Primitives

    /// Unaligned-safe store. pack(4) puts doubles on 4-byte boundaries, which
    /// `storeBytes(of:as:)` will not accept.
    private static func poke<T>(_ buffer: inout [UInt8], _ offset: Int, _ value: T) {
        withUnsafeBytes(of: value) { src in
            for i in 0..<src.count { buffer[offset + i] = src[i] }
        }
    }

    // MARK: Builders

    /// A hardware button (Home, Lock, Side, Siri, Apple Pay).
    public static func button(_ button: Button, _ direction: Direction) -> [UInt8] {
        // One payload. SimulatorKit's own builders allocate 0xC0 and declare
        // innerSize 0xA0; matched exactly rather than using the tighter 0x90,
        // since this is the shape the guest is known to accept.
        var msg = [UInt8](repeating: 0, count: 0xC0)
        poke(&msg, offInnerSize, UInt32(0xA0))
        poke(&msg, offEventType, messageTypeButton)

        let p = payloadBase
        poke(&msg, p + offEventKind, eventKindButton)
        poke(&msg, p + offTimestamp, mach_absolute_time())

        let e = p + offEvent
        poke(&msg, e + offButtonSource, button.rawValue)
        poke(&msg, e + offButtonType, direction.rawValue)
        poke(&msg, e + offButtonTarget, targetHardware)
        return msg
    }

    /// A key press. `keyCode` is a HIToolbox hardware-independent virtual key
    /// code, which is exactly what `NSEvent.keyCode` reports — no translation
    /// table is involved.
    public static func key(code: UInt32, _ direction: Direction) -> [UInt8] {
        var msg = [UInt8](repeating: 0, count: 0xC0)
        poke(&msg, offInnerSize, UInt32(0xA0))
        poke(&msg, offEventType, messageTypeButton)

        let p = payloadBase
        poke(&msg, p + offEventKind, eventKindButton)
        poke(&msg, p + offTimestamp, mach_absolute_time())

        let e = p + offEvent
        poke(&msg, e + offButtonSource, Button.keyboard.rawValue)
        poke(&msg, e + offButtonType, direction.rawValue)
        poke(&msg, e + offButtonTarget, targetKeyboard)
        poke(&msg, e + offButtonKeyCode, code)
        return msg
    }

    /// A single-finger touch. `x`/`y` are normalized 0...1 from the top-left.
    ///
    /// Two payloads: the contact itself, then a near-duplicate the digitizer
    /// expects, distinguished by field1/field2. The stride is the packed 0x90,
    /// which is what innerSize advertises.
    public static func touch(x: Double, y: Double, phase: TouchPhase) -> [UInt8] {
        var msg = [UInt8](repeating: 0, count: payloadBase + payloadStride * 2)
        poke(&msg, offInnerSize, UInt32(payloadStride))
        poke(&msg, offEventType, messageTypeSingleTouch)

        // One timestamp for the whole message: both payloads describe the same
        // instant, and idb produces its second contact by memcpy so they always
        // match. Sampling the clock twice would make them differ by a few ticks.
        let timestamp = mach_absolute_time()

        for index in 0..<2 {
            let p = payloadBase + payloadStride * index
            poke(&msg, p + offEventKind, eventKindTouch)
            poke(&msg, p + offTimestamp, timestamp)

            let e = p + offEvent
            // The repeated contact is tagged 1/2; the primary carries the
            // builder-observed defaults.
            poke(&msg, e + offTouchField1, index == 0 ? touchField1Default : 1)
            poke(&msg, e + offTouchField2, index == 0 ? touchField2Default : 2)
            poke(&msg, e + offTouchEventMask, phase.mask)
            poke(&msg, e + offTouchXRatio, x)
            poke(&msg, e + offTouchYRatio, y)
            poke(&msg, e + offTouchRange, phase.range)
            poke(&msg, e + offTouchTouch, phase.touch)
            poke(&msg, e + offTouchTarget, touchTargetPhone)
        }
        return msg
    }
}
