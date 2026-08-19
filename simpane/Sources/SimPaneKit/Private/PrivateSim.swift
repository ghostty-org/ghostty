//  The only file in SimPaneKit that knows CoreSimulator and SimulatorKit exist.
//
//  Ground rule: no other file may name a private class or selector. That is
//  checkable, and Phase 3's acceptance gate checks it:
//
//      grep -rn 'NSClassFromString\|dlopen\|SimDisplay\|SimulatorKit\.' Sources/SimPaneKit \
//        | grep -v Private/PrivateSim.swift
//
//  Everything private is reached by name at runtime through SPObjC, which uses
//  -methodSignatureForSelector: + NSInvocation inside @try/@catch. Nothing is
//  linked against, so a machine without Xcode gets `.unsupported(reason:)`
//  instead of a launch failure.
//
//  Selector inventory and the evidence behind it: docs/simpane/API-NOTES.md.
//  Re-derive after an Xcode update with `simdump`.

import Foundation
import SimPaneCore
import SimPaneObjC

// MARK: - Private dispatch helpers

/// Thin Swift skin over SPObjC so call sites read like ordinary message sends.
enum ObjCSend {
    static func call(_ target: AnyObject?, _ selector: String, _ args: [Any] = []) -> Any? {
        guard let target else { return nil }
        return try? SPObjC.send(NSSelectorFromString(selector), to: target, args: args)
    }

    /// For the `...error:` shape, where the trailing out-parameter must be a real
    /// NSError** slot rather than an object argument.
    static func callWithErrorOut(_ target: AnyObject?, _ selector: String, _ args: [Any] = []) throws -> Any? {
        guard let target else { throw SimPaneError("nil target for \(selector)") }
        return try SPObjC.send(NSSelectorFromString(selector), to: target, argsPlusNilError: args)
    }

    static func object(_ target: AnyObject?, _ selector: String, _ args: [Any] = []) -> AnyObject? {
        call(target, selector, args) as AnyObject?
    }

    static func int(_ target: AnyObject?, _ selector: String) -> Int? {
        (call(target, selector) as? NSNumber)?.intValue
    }

    static func string(_ target: AnyObject?, _ selector: String) -> String? {
        call(target, selector) as? String
    }

    /// Trustworthy existence test. ROCK XPC proxies answer -respondsToSelector:
    /// optimistically, but only vend a method signature for real methods.
    static func exists(_ target: AnyObject?, _ selector: String) -> Bool {
        guard let target else { return false }
        return SPObjC.typeEncoding(for: NSSelectorFromString(selector), on: target) != nil
    }

    static func conforms(_ target: AnyObject?, _ protocolName: String) -> Bool {
        guard let target else { return false }
        return SPObjC.protocolNames(of: target).contains(protocolName)
    }
}

// MARK: - Framework loading

enum PrivateFrameworks {

    private(set) static var isLoaded = false
    private static var cachedSupport: SimPaneSupport?

    static var developerDir: String? {
        Shell.run("/usr/bin/xcode-select", ["-p"])
    }

    static var coreSimulatorPath: String {
        "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    }

    static func simulatorKitPath(developerDir: String) -> String {
        "\(developerDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"
    }

    /// CoreSimulator hands the guest's HID services to `dtuhidd` from this version
    /// on, after which legacy Indigo messages are accepted and silently dropped.
    /// See API-NOTES.md §C — input fails without an error, so we refuse instead.
    static let firstDTUHIDCoreSimulatorVersion = "1155.4"

    static var coreSimulatorVersion: String? {
        let plist = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Info.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    static var legacyHIDIsSuppressed: Bool {
        guard let v = coreSimulatorVersion else { return false }
        return v.compare(firstDTUHIDCoreSimulatorVersion, options: .numeric) != .orderedAscending
    }

    @discardableResult
    static func load() -> SimPaneSupport {
        if let cachedSupport { return cachedSupport }
        let result = doLoad()
        cachedSupport = result
        return result
    }

    private static func doLoad() -> SimPaneSupport {
        guard let dir = developerDir, !dir.isEmpty else {
            return .unsupported(reason: "xcode-select -p produced no developer directory")
        }
        guard dir.contains(".app/Contents/Developer") else {
            return .unsupported(reason: "Xcode is required; developer dir is \(dir) (Command Line Tools only)")
        }

        for path in [coreSimulatorPath, simulatorKitPath(developerDir: dir)] {
            guard FileManager.default.fileExists(atPath: path) else {
                return .unsupported(reason: "missing framework at \(path)")
            }
            guard dlopen(path, RTLD_LAZY | RTLD_GLOBAL) != nil else {
                let err = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
                return .unsupported(reason: "could not load \(path): \(err)")
            }
        }
        isLoaded = true

        // Feature-detect rather than trusting the version: private classes come
        // and go between Xcode releases, and SimulatorKit went Swift (its classes
        // are module-qualified now), which is exactly the kind of rename that
        // returns nil silently.
        guard NSClassFromString("SimServiceContext") != nil else {
            return .unsupported(reason: "SimServiceContext not found after loading CoreSimulator")
        }
        return .supported
    }

    static func support() -> SimPaneSupport { load() }

    /// Why input forwarding is unavailable, or nil when it should work. Rendering
    /// is unaffected by this, so it is reported separately from `support()`.
    static var inputUnavailableReason: String? {
        if case .unsupported(let reason) = load() { return reason }
        if legacyHIDIsSuppressed {
            return """
                CoreSimulator \(coreSimulatorVersion ?? "?") routes HID through dtuhidd; \
                legacy Indigo events would be accepted and silently discarded
                """
        }
        return nil
    }
}

// MARK: - Devices

/// A live `SimDevice` together with the facts read off it. The public
/// `SimDeviceInfo` deliberately carries no handle, so nothing outside this file
/// ends up holding a private object.
struct SimDeviceHandle {
    let udid: String
    let name: String
    let runtimeName: String
    let object: AnyObject

    /// Re-read on each access rather than cached: a device boots and shuts down
    /// underneath us.
    var state: SimDeviceInfo.State {
        SimDeviceInfo.State(coreSimulatorValue: ObjCSend.int(object, "state") ?? -1)
    }
}

/// The classic failure after an Xcode update: the CoreSimulator framework on
/// disk no longer matches the `com.apple.CoreSimulator.CoreSimulatorService`
/// daemon still running from the previous version.
///
/// It surfaces as an opaque XPC error, so the error alone tells a user nothing.
/// The remedy is well known and is worth putting in front of them instead.
enum CoreSimulatorService {

    static let remedy = """
        This usually means the CoreSimulator service still running is from a         different Xcode than the one installed. Quit Simulator.app and Xcode, then run:

            launchctl remove com.apple.CoreSimulator.CoreSimulatorService

        and try again.
        """

    /// Markers seen when the daemon is stale or the connection to it is dead.
    /// Deliberately broad: a false positive costs a user one extra sentence,
    /// while a false negative costs them an afternoon.
    private static let markers = [
        "coresimulatorservice",
        "connection to service",
        "was invalidated",
        "version mismatch",
        "mismatched versions",
        "xpc_error_connection",
        "could not find or use runtime",
    ]

    static func looksLikeAServiceProblem(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return markers.contains { lowered.contains($0) }
    }

    /// The message with the remedy appended, when it is the kind of failure the
    /// remedy fixes.
    static func annotating(_ message: String) -> String {
        looksLikeAServiceProblem(message) ? "\(message)\n\n\(remedy)" : message
    }

    static func annotating(_ error: Error) -> String {
        annotating(error.localizedDescription)
    }
}

enum SimDevices {

    static func serviceContext() throws -> AnyObject {
        let support = PrivateFrameworks.load()
        guard support.isSupported else {
            throw SimPaneError(support.reason ?? "unsupported")
        }
        guard let cls = NSClassFromString("SimServiceContext") else {
            throw SimPaneError("SimServiceContext missing")
        }
        guard let dir = PrivateFrameworks.developerDir else {
            throw SimPaneError("no developer directory")
        }
        let ctx: Any?
        do {
            ctx = try ObjCSend.callWithErrorOut(
                cls, "sharedServiceContextForDeveloperDir:error:", [dir as NSString])
        } catch {
            throw SimPaneError(CoreSimulatorService.annotating(error))
        }
        guard let ctx = ctx as AnyObject? else {
            // A nil context with no exception is itself the signature of a stale
            // daemon, so the remedy is unconditional here.
            throw SimPaneError(
                "CoreSimulator returned no service context.\n\n\(CoreSimulatorService.remedy)")
        }
        return ctx
    }

    static func deviceSet() throws -> AnyObject {
        let ctx = try serviceContext()
        if let set = try? ObjCSend.callWithErrorOut(ctx, "defaultDeviceSetWithError:") as AnyObject? {
            return set
        }
        guard let set = ObjCSend.object(ctx, "defaultDeviceSet") else {
            throw SimPaneError(
                "CoreSimulator returned no device set.\n\n\(CoreSimulatorService.remedy)")
        }
        return set
    }

    static func all() throws -> [SimDeviceHandle] {
        let set = try deviceSet()
        guard let devices = ObjCSend.call(set, "devices") as? [AnyObject] else {
            throw SimPaneError("device set returned no devices")
        }
        return devices.compactMap { handle(for: $0) }
    }

    static func handle(for device: AnyObject) -> SimDeviceHandle? {
        let udid = (ObjCSend.object(device, "UDID") as? NSUUID)?.uuidString
            ?? ObjCSend.string(device, "UDID")
        guard let udid else { return nil }
        let name = ObjCSend.string(device, "name") ?? "(unnamed)"
        let runtimeObj = ObjCSend.object(device, "runtime")
        let runtime = ObjCSend.string(runtimeObj, "name") ?? "(unknown runtime)"
        return SimDeviceHandle(udid: udid, name: name, runtimeName: runtime, object: device)
    }

    /// Every device, as the public value type.
    ///
    /// Freshly walked, so the states are accurate — unlike a handle that has been
    /// held for a while, whose `state` is a stale cached value.
    static func listAll() throws -> [SimDeviceInfo] {
        try all().map {
            SimDeviceInfo(
                udid: $0.udid, name: $0.name,
                runtimeIdentifier: $0.runtimeName, state: $0.state)
        }
    }

    static func find(udid: String) throws -> SimDeviceHandle? {
        try all().first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
    }
}

// MARK: - Display

/// The main display of one booted device: its IOSurface plus the two callbacks
/// that say when to repaint and when to rebind.
final class SimDisplay {

    /// Descriptor conforming to SimDisplayIOSurfaceRenderable whose state reports
    /// displayClass 0.
    private let descriptor: AnyObject
    private let callbackUUID = UUID()
    /// A distinct UUID per registration: the two are unregistered separately, and
    /// sharing one handle across both is asking for the second to clobber the first.
    private let surfaceCallbackUUID = UUID()

    /// Blocks are handed to the framework and invoked from an arbitrary thread.
    /// Held strongly so they outlive this call stack.
    private var damageBlock: Any?
    private var surfaceBlock: Any?
    private var registered = false

    /// Fired on an arbitrary thread whenever the guest paints. Coalesce before
    /// touching AppKit.
    var onDamage: (() -> Void)?
    /// Fired when the surface itself is replaced (rotation, resize, reboot).
    var onSurfaceChanged: (() -> Void)?

    private init(descriptor: AnyObject) {
        self.descriptor = descriptor
    }

    // MARK: Discovery

    /// displayClass 0 is the built-in screen. A device also exposes an external
    /// display at displayClass 1 that satisfies the protocol check alone, so both
    /// halves of this predicate are load-bearing.
    static func mainDisplay(of device: SimDeviceHandle) throws -> SimDisplay {
        guard let io = ObjCSend.object(device.object, "io") else {
            throw SimPaneError("device has no io client (is it booted?)")
        }
        guard let ports = ObjCSend.call(io, "ioPorts") as? [AnyObject], !ports.isEmpty else {
            throw SimPaneError("device io client exposed no ports")
        }

        for port in ports {
            guard let descriptor = ObjCSend.object(port, "descriptor"),
                  ObjCSend.conforms(descriptor, "SimDisplayIOSurfaceRenderable"),
                  let state = ObjCSend.object(descriptor, "state"),
                  ObjCSend.int(state, "displayClass") == 0
            else { continue }
            return SimDisplay(descriptor: descriptor)
        }
        throw SimPaneError("no display port with SimDisplayIOSurfaceRenderable and displayClass 0")
    }

    // MARK: Surface

    /// The live framebuffer. Re-read rather than cached: the guest can swap it,
    /// and CALayer needs the current one.
    var framebufferSurface: AnyObject? {
        ObjCSend.object(descriptor, "framebufferSurface")
    }

    var displaySize: CGSize? {
        guard let v = ObjCSend.call(descriptor, "displaySize") as? NSValue else { return nil }
        return v.sizeValue
    }

    /// Pixel dimensions of the surface itself, which is what CoreAnimation scales
    /// from. Not the same as displaySize, and the surface is row-padded.
    func surfacePixelSize() -> CGSize? {
        guard let s = framebufferSurface,
              let w = ObjCSend.int(s, "width"), let h = ObjCSend.int(s, "height")
        else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: Callbacks

    func startObserving() {
        guard !registered else { return }

        let damage: @convention(block) (AnyObject?) -> Void = { [weak self] _ in
            self?.onDamage?()
        }
        // Deliberately ignores its argument and re-reads framebufferSurface: the
        // callback is named for *surfaces* plural and its payload shape is not
        // contractual, but the property always reports the current one.
        let surfaces: @convention(block) (AnyObject?) -> Void = { [weak self] _ in
            self?.onSurfaceChanged?()
        }
        damageBlock = damage
        surfaceBlock = surfaces

        _ = ObjCSend.call(descriptor, "registerCallbackWithUUID:damageRectanglesCallback:",
                          [callbackUUID as NSUUID, damage])
        _ = ObjCSend.call(descriptor, "registerCallbackWithUUID:ioSurfacesChangeCallback:",
                          [surfaceCallbackUUID as NSUUID, surfaces])
        registered = true
    }

    func stopObserving() {
        guard registered else { return }
        _ = ObjCSend.call(descriptor, "unregisterDamageRectanglesCallbackWithUUID:",
                          [callbackUUID as NSUUID])
        _ = ObjCSend.call(descriptor, "unregisterIOSurfacesChangeCallbackWithUUID:",
                          [surfaceCallbackUUID as NSUUID])
        damageBlock = nil
        surfaceBlock = nil
        registered = false
    }

    deinit { stopObserving() }
}

// MARK: - HID client

/// Messaging interface for SimulatorKit's runtime-only HID client.
///
/// Declared as an `@objc protocol` and reached with `unsafeBitCast` so no
/// link-time class reference is emitted: the concrete class is Swift, lives in
/// SimulatorKit, and has moved between Xcode releases.
@objc private protocol SimDeviceLegacyHIDClientMessaging {
    @objc(sendWithMessage:freeWhenDone:completionQueue:completion:)
    func send(
        withMessage message: UnsafeMutableRawPointer,
        freeWhenDone: Bool,
        completionQueue: DispatchQueue,
        completion: @escaping @convention(block) (Error?) -> Void)
}

/// Delivers Indigo messages to a device.
///
/// Wire layout ported from facebook/idb (MIT), PrivateHeaders/SimulatorApp/Indigo.h
/// — see docs/simpane/ATTRIBUTIONS.md. The messages themselves are built in
/// `IndigoWire`, in pure Swift: both reference implementations resolve
/// SimulatorKit's `IndigoHIDMessageFor*` C builders with dlsym and call them as
/// raw C function pointers, which this project does not do. Only the send
/// crosses into private API, and it crosses as an ObjC message.
///
/// Sendable by hand rather than by inference: every mutation of `client` happens
/// under `sendLock`, which is the whole reason that lock exists — touches arrive
/// from the main thread while hardware buttons arrive from their own queue.
final class IndigoHIDClient: @unchecked Sendable {

    private static let className = "SimulatorKit.SimDeviceLegacyHIDClient"

    private var client: AnyObject?
    private let queue = DispatchQueue(label: "simpane.hid")
    /// Sends arrive from the main thread (touches, keys) and the button queue at
    /// the same time; the client is not documented as reentrant.
    private let sendLock = NSLock()
    /// Kept so a dropped session can be rebuilt without the caller noticing.
    private let device: AnyObject

    init(device: SimDeviceHandle) throws {
        self.device = device.object
        if let reason = PrivateFrameworks.inputUnavailableReason {
            throw SimPaneError(reason)
        }
        guard let cls = NSClassFromString(Self.className) else {
            throw SimPaneError("\(Self.className) not found — Xcode may have moved it")
        }
        client = try Self.makeClient(cls: cls, device: device.object)
    }

    private static func makeClient(cls: AnyClass, device: AnyObject) throws -> AnyObject {
        guard let allocated = try? SPObjC.send(NSSelectorFromString("alloc"), to: cls, args: []) as AnyObject? else {
            throw SimPaneError("could not allocate \(className)")
        }
        guard let created = try SPObjC.send(
            NSSelectorFromString("initWithDevice:error:"),
            to: allocated, argsPlusNilError: [device]) as AnyObject?
        else {
            throw SimPaneError("initWithDevice:error: returned nil")
        }
        return created
    }

    /// Hands `message` to the guest and waits for the client to acknowledge, so a
    /// rejection surfaces at the call site instead of vanishing into a callback.
    /// Ownership of the malloc'd copy passes to the client via freeWhenDone.
    func send(_ message: [UInt8]) throws {
        sendLock.lock()
        defer { sendLock.unlock() }
        try sendWithRecovery(message)
    }

    /// The guest's HID mach port drops out from under us — after a device
    /// reboot, after the session is reset, and sometimes for no visible reason.
    /// The failure is reported as "Mach port not connected", so a send that hits
    /// it resets the session, rebuilds the client if needed, and tries once more.
    /// Without this, input appears to work and then silently stops forever.
    private func sendWithRecovery(_ message: [UInt8]) throws {
        do {
            try sendRaw(message)
            return
        } catch {
            guard "\(error)".contains("Mach port not connected") else { throw error }
        }

        if let client { _ = ObjCSend.call(client, "resetHIDSession") }
        if (try? sendRaw(message)) != nil { return }

        // Session reset was not enough; the client itself is stale.
        guard let cls = NSClassFromString(Self.className) else {
            throw SimPaneError("\(Self.className) disappeared")
        }
        client = try Self.makeClient(cls: cls, device: device)
        try sendRaw(message)
    }

    private func sendRaw(_ message: [UInt8]) throws {
        guard let client else { throw SimPaneError("HID client disposed") }
        guard let raw = malloc(message.count) else {
            throw SimPaneError("could not allocate \(message.count) bytes for an Indigo message")
        }
        message.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: message.count) }

        let semaphore = DispatchSemaphore(value: 0)
        var completionError: Error?

        try SPObjC.catchingVoid {
            unsafeBitCast(client, to: SimDeviceLegacyHIDClientMessaging.self)
                .send(withMessage: raw, freeWhenDone: true, completionQueue: self.queue) { error in
                    completionError = error
                    semaphore.signal()
                }
        }

        if semaphore.wait(timeout: .now() + 2) == .timedOut {
            throw SimPaneError("HID send timed out waiting for acknowledgement")
        }
        if let completionError {
            throw SimPaneError("HID send rejected: \(completionError.localizedDescription)")
        }
    }

    func disconnect() { client = nil }
    deinit { disconnect() }
}
