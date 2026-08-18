//  SimDump — Phase 0 runtime introspection of CoreSimulator / SimulatorKit.
//
//  Everything private API drifts between Xcode releases, so this tool exists to
//  re-derive the truth on whatever machine it runs on rather than trusting a
//  header dump from someone else's Xcode. Output goes to research/api-dump.txt
//  (and stdout), flushed section by section so a crash still leaves evidence.
//
//  Usage: simdump [--udid <UDID>] [--out <path>]

import Foundation
import MachO
import ObjectiveC.runtime
import SimPaneObjC

// MARK: - Output

final class Report {
    private let handle: FileHandle
    let path: String

    init(path: String) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }

    func line(_ s: String = "") {
        print(s)
        if let d = (s + "\n").data(using: .utf8) { handle.write(d) }
    }

    /// Section headers are loud so the dump stays skimmable at a few thousand lines.
    func section(_ title: String) {
        line()
        line(String(repeating: "=", count: 78))
        line("== \(title)")
        line(String(repeating: "=", count: 78))
    }

    func sub(_ title: String) {
        line()
        line("-- \(title)")
        line(String(repeating: "-", count: 60))
    }
}

// MARK: - Shell

@discardableResult
func sh(_ launch: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

// MARK: - ObjC runtime helpers

func methodList(_ cls: AnyClass) -> [String] {
    var out: [String] = []
    var count: UInt32 = 0
    if let list = class_copyMethodList(cls, &count) {
        for i in 0..<Int(count) {
            let m = list[i]
            let sel = NSStringFromSelector(method_getName(m))
            let types = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
            out.append("\(sel)  ::  \(types)")
        }
        free(list)
    }
    return out.sorted()
}

func propertyList(_ cls: AnyClass) -> [String] {
    var out: [String] = []
    var count: UInt32 = 0
    if let list = class_copyPropertyList(cls, &count) {
        for i in 0..<Int(count) {
            let p = list[i]
            let name = String(cString: property_getName(p))
            let attrs = property_getAttributes(p).map { String(cString: $0) } ?? ""
            out.append("\(name)  ::  \(attrs)")
        }
        free(list)
    }
    return out.sorted()
}

func ivarList(_ cls: AnyClass) -> [String] {
    var out: [String] = []
    var count: UInt32 = 0
    if let list = class_copyIvarList(cls, &count) {
        for i in 0..<Int(count) {
            let iv = list[i]
            let name = ivar_getName(iv).map { String(cString: $0) } ?? "?"
            let type = ivar_getTypeEncoding(iv).map { String(cString: $0) } ?? "?"
            out.append("\(name)  ::  \(type)  @\(ivar_getOffset(iv))")
        }
        free(list)
    }
    return out.sorted()
}

func protocolNames(_ cls: AnyClass) -> [String] {
    var out: [String] = []
    var count: UInt32 = 0
    if let list = class_copyProtocolList(cls, &count) {
        for i in 0..<Int(count) {
            out.append(String(cString: protocol_getName(list[i])))
        }
    }
    return out.sorted()
}

/// Walks the superclass chain up to (but not including) NSObject.
func classChain(_ cls: AnyClass) -> [AnyClass] {
    var out: [AnyClass] = []
    var c: AnyClass? = cls
    while let cur = c, NSStringFromClass(cur) != "NSObject" {
        out.append(cur)
        c = class_getSuperclass(cur)
    }
    return out
}

func dumpClass(_ rep: Report, _ cls: AnyClass, includeIvars: Bool = true) {
    for c in classChain(cls) {
        rep.line("  class \(NSStringFromClass(c))  (super: \(class_getSuperclass(c).map(NSStringFromClass) ?? "nil"))")
        let protos = protocolNames(c)
        if !protos.isEmpty { rep.line("    protocols: \(protos.joined(separator: ", "))") }

        let props = propertyList(c)
        if !props.isEmpty {
            rep.line("    properties:")
            for p in props { rep.line("      \(p)") }
        }
        if includeIvars {
            let ivars = ivarList(c)
            if !ivars.isEmpty {
                rep.line("    ivars:")
                for i in ivars { rep.line("      \(i)") }
            }
        }
        if let meta = object_getClass(c) {
            let cms = methodList(meta)
            if !cms.isEmpty {
                rep.line("    class methods:")
                for m in cms { rep.line("      +\(m)") }
            }
        }
        let ms = methodList(c)
        if !ms.isEmpty {
            rep.line("    instance methods:")
            for m in ms { rep.line("      -\(m)") }
        }
        rep.line()
    }
}

func dumpProtocol(_ rep: Report, _ name: String) {
    guard let p = NSProtocolFromString(name) else {
        rep.line("  protocol \(name): ABSENT")
        return
    }
    rep.line("  protocol \(name):")
    var pcount: UInt32 = 0
    if let inherited = protocol_copyProtocolList(p, &pcount) {
        var names: [String] = []
        for i in 0..<Int(pcount) { names.append(String(cString: protocol_getName(inherited[i]))) }
        if !names.isEmpty { rep.line("    inherits: \(names.joined(separator: ", "))") }
    }
    for (required, instance, label) in [(true, true, "required -"), (false, true, "optional -"),
                                        (true, false, "required +"), (false, false, "optional +")] {
        var count: UInt32 = 0
        if let descs = protocol_copyMethodDescriptionList(p, required, instance, &count) {
            for i in 0..<Int(count) {
                let sel = NSStringFromSelector(descs[i].name!)
                let types = descs[i].types.map { String(cString: $0) } ?? "?"
                rep.line("    \(label)\(sel)  ::  \(types)")
            }
            free(descs)
        }
    }
    var propCount: UInt32 = 0
    if let props = protocol_copyPropertyList(p, &propCount) {
        for i in 0..<Int(propCount) {
            let name = String(cString: property_getName(props[i]))
            let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? ""
            rep.line("    @property \(name) :: \(attrs)")
        }
        free(props)
    }
}

/// Safe accessors. Everything routes through SPObjC, which uses
/// -methodSignatureForSelector: + NSInvocation inside @try/@catch. KVC is never
/// used: CoreSimulator's ROCK XPC proxies raise NSUnknownKeyException for keys
/// they otherwise answer fine over the wire.
func send(_ target: AnyObject?, _ selName: String, _ args: [Any] = []) -> Any? {
    guard let target else { return nil }
    return try? SPObjC.send(NSSelectorFromString(selName), to: target, args: args)
}

/// For the very common `...error:` shape, where the trailing out-parameter must
/// be a real NSError** slot rather than an object argument.
func sendE(_ target: AnyObject?, _ selName: String, _ args: [Any] = []) -> Any? {
    guard let target else { return nil }
    return try? SPObjC.send(NSSelectorFromString(selName), to: target, argsPlusNilError: args)
}

func obj(_ target: AnyObject?, _ selName: String) -> AnyObject? {
    send(target, selName) as AnyObject?
}

/// The trustworthy existence test. ROCK proxies answer -respondsToSelector:
/// optimistically, but only return a method signature for methods that are real.
func encoding(_ target: AnyObject?, _ selName: String) -> String? {
    guard let target else { return nil }
    return SPObjC.typeEncoding(for: NSSelectorFromString(selName), on: target)
}

func responds(_ target: AnyObject?, _ selName: String) -> Bool {
    encoding(target, selName) != nil
}

func kv(_ target: AnyObject?, _ key: String) -> Any? {
    send(target, key)
}

func protoNames(_ target: AnyObject?) -> [String] {
    guard let target else { return [] }
    return SPObjC.protocolNames(of: target)
}

func describe(_ o: AnyObject?) -> String {
    guard let o else { return "nil" }
    return "\(NSStringFromClass(type(of: o)))"
}

// MARK: - Args

var udidArg: String?
var outArg = FileManager.default.currentDirectoryPath + "/research/api-dump.txt"
var argv = Array(CommandLine.arguments.dropFirst())
while let a = argv.first {
    argv.removeFirst()
    switch a {
    case "--udid": udidArg = argv.first; if !argv.isEmpty { argv.removeFirst() }
    case "--out": outArg = argv.first ?? outArg; if !argv.isEmpty { argv.removeFirst() }
    default: break
    }
}

let rep = Report(path: outArg)

// MARK: - Environment

rep.section("ENVIRONMENT")
let devDir = sh("/usr/bin/xcode-select", ["-p"])
rep.line("xcode-select -p        : \(devDir)")
rep.line("xcodebuild -version    : \(sh("/usr/bin/xcodebuild", ["-version"]).replacingOccurrences(of: "\n", with: " | "))")
rep.line("macOS                  : \(ProcessInfo.processInfo.operatingSystemVersionString)")
rep.line("process arch           : \(sh("/usr/bin/uname", ["-m"]))")
rep.line("dump host executable   : \(CommandLine.arguments[0])")
rep.line("file(self)             : \(sh("/usr/bin/file", [CommandLine.arguments[0]]))")

// MARK: - dlopen

rep.section("FRAMEWORK LOADING")

let frameworks: [(String, String)] = [
    ("CoreSimulator", "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"),
    ("SimulatorKit", "\(devDir)/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"),
    // Not required, but loading them widens the class inventory below and tells us
    // whether the HID/indigo symbols live somewhere other than SimulatorKit.
    ("CoreSimulatorUtilities", "\(devDir)/Library/PrivateFrameworks/CoreSimulatorUtilities.framework/CoreSimulatorUtilities"),
    ("SimulatorTrace", "\(devDir)/Library/PrivateFrameworks/SimulatorTrace.framework/SimulatorTrace"),
]

// Enumerate by image with pure C calls. objc_copyClassList / objc_getClassList
// import into Swift as AutoreleasingUnsafeMutablePointer, and subscripting that
// runs a Swift dynamic cast per element, which messages every registered class —
// some unrelated CloudKit class traps in ObjC forwarding when you do that.
// Per-image also tells us which framework each class came from, which is the
// thing we actually want to know.
func loadedImagePaths() -> [String] {
    var out: [String] = []
    for i in 0..<_dyld_image_count() {
        if let n = _dyld_get_image_name(i) { out.append(String(cString: n)) }
    }
    return out
}

func classNames(forImage path: String) -> [String] {
    var count: UInt32 = 0
    guard let names = objc_copyClassNamesForImage(path, &count) else { return [] }
    var out: [String] = []
    out.reserveCapacity(Int(count))
    for i in 0..<Int(count) { out.append(String(cString: names[i])) }
    free(UnsafeMutableRawPointer(mutating: names))
    return out
}

func totalClassCount() -> Int {
    loadedImagePaths().reduce(0) { $0 + classNames(forImage: $1).count }
}

rep.line("ObjC classes registered before dlopen: \(totalClassCount())")

for (name, path) in frameworks {
    let exists = FileManager.default.fileExists(atPath: path)
    guard exists else {
        rep.line("[skip ] \(name): not present at \(path)")
        continue
    }
    if let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL) {
        _ = handle
        rep.line("[ ok  ] \(name): \(path)")
    } else {
        let err = dlerror().map { String(cString: $0) } ?? "unknown"
        rep.line("[FAIL ] \(name): \(path)  ->  \(err)")
    }
}

rep.line("ObjC classes registered after dlopen : \(totalClassCount())")

// MARK: - Class inventory

rep.section("CLASS INVENTORY (by image)")

/// The images that actually matter. Matched by suffix because dyld may report a
/// resolved/versioned path.
let simImageSuffixes = [
    "CoreSimulator.framework/CoreSimulator",
    "SimulatorKit.framework/SimulatorKit",
    "CoreSimulator.framework/Versions/A/CoreSimulator",
    "SimulatorKit.framework/Versions/A/SimulatorKit",
]

let images = loadedImagePaths()
var classesByImage: [String: [String]] = [:]
for img in images where simImageSuffixes.contains(where: { img.hasSuffix($0) }) {
    classesByImage[img] = classNames(forImage: img).sorted()
}

for (img, names) in classesByImage.sorted(by: { $0.key < $1.key }) {
    rep.sub("image \(img)  —  \(names.count) classes")
    for n in names { rep.line("  \(n)") }
}

/// Names from every loaded image, for the cross-cutting keyword scan below.
let allNames: [String] = {
    var seen = Set<String>()
    for img in images { for n in classNames(forImage: img) { seen.insert(n) } }
    return Array(seen)
}()

rep.sub("keyword scan across ALL loaded images")
let prefixes = ["Sim", "Indigo", "Purple", "DTU"]
let substrings = ["Indigo", "Digitizer", "Framebuffer", "IOSurface", "HID", "Purple"]

var interesting = Set<String>()
for n in allNames {
    if prefixes.contains(where: { n.hasPrefix($0) }) { interesting.insert(n) }
    if substrings.contains(where: { n.contains($0) }) { interesting.insert(n) }
}
rep.line("total classes: \(allNames.count), matched: \(interesting.count)")
rep.line()
for n in interesting.sorted() { rep.line("  \(n)") }

// MARK: - Key class dumps

rep.section("KEY CLASS DUMPS")

// Every class vended by the two private frameworks. It is only ~100 classes, and
// a complete inventory is the whole point of this tool — guessing names is how
// you miss that SimulatorKit went Swift and its classes are module-qualified.
let frameworkClasses = classesByImage.values.flatMap { $0 }.sorted()

let keyClasses = Array(Set(frameworkClasses + [
    "SimServiceContext",
    "SimDeviceSet",
    "SimDevice",
    "SimDeviceIOClient",
    // Present under these names on older Xcode; recorded so their absence is explicit.
    "SimDeviceLegacyClient",
    "SimDeviceLegacyHIDClient",
    "SimDisplayIOSurfaceRenderable",
    "SimDeviceBootInfo",
    "SimRuntime",
    "SimDeviceType",
])).sorted()

for name in keyClasses {
    rep.sub("class \(name)")
    if let cls = NSClassFromString(name) {
        dumpClass(rep, cls)
    } else {
        rep.line("  ABSENT on this machine")
    }
}

// MARK: - Key protocol dumps

rep.section("KEY PROTOCOL DUMPS")

let keyProtocols = [
    "SimDeviceIOProtocol",
    "SimDeviceIOPortInterface",
    "SimDeviceIOPortDescriptorState",
    "SimDeviceIOPortConsumer",
    "SimDisplayRenderable",
    "SimDisplayIOSurfaceRenderable",
    "SimDisplayDamageRectangleDelegate",
    "SimDeviceIOPortDescriptor",
    "SimDeviceNotifier",
    "SimDisplayDescriptorState",
    "SimDeviceIOPortConsumerDescriptor",
    "SimDeviceIOPortConsumerProtocol",
]
for n in keyProtocols { dumpProtocol(rep, n); rep.line() }

// Anything the scan found that looks display/consumer shaped and we did not
// hardcode above — dump it too rather than guessing the name.
rep.sub("auto-discovered Sim* protocols")
var protoCount: UInt32 = 0
if let plist = objc_copyProtocolList(&protoCount) {
    var discovered: [String] = []
    for i in 0..<Int(protoCount) {
        let n = String(cString: protocol_getName(plist[i]))
        if n.hasPrefix("Sim") || n.contains("Indigo") || n.contains("Digitizer") || n.contains("IOSurface") {
            discovered.append(n)
        }
    }
    rep.line("  \(discovered.sorted().joined(separator: "\n  "))")
}

// MARK: - Live device walk

rep.section("LIVE DEVICE WALK")

guard let ctxCls = NSClassFromString("SimServiceContext") else {
    rep.line("FATAL: SimServiceContext absent — cannot continue.")
    exit(1)
}

let ctxSel = "sharedServiceContextForDeveloperDir:error:"
rep.line("SimServiceContext responds to \(ctxSel): \(responds(ctxCls, ctxSel))")

guard let ctx = sendE(ctxCls, ctxSel, [devDir as NSString]) as AnyObject? else {
    rep.line("FATAL: sharedServiceContextForDeveloperDir:error: returned nil")
    exit(1)
}
rep.line("service context        : \(describe(ctx))")

// Prefer the default device set; fall back to the enumerated sets.
var deviceSet: AnyObject? = sendE(ctx, "defaultDeviceSetWithError:") as AnyObject?
if deviceSet == nil { deviceSet = obj(ctx, "defaultDeviceSet") }
rep.line("device set             : \(describe(deviceSet))")

guard let devices = obj(deviceSet, "devices") as? [AnyObject] else {
    rep.line("FATAL: could not read devices from device set")
    exit(1)
}
rep.line("devices                : \(devices.count)")
rep.line()

func stateNum(_ d: AnyObject) -> Int {
    (kv(d, "state") as? NSNumber)?.intValue ?? -1
}
// CoreSimulator SimDeviceState: 0 creating, 1 shutdown, 2 booting, 3 booted, 4 shutting down
func stateName(_ n: Int) -> String {
    ["Creating", "Shutdown", "Booting", "Booted", "ShuttingDown"].indices.contains(n)
        ? ["Creating", "Shutdown", "Booting", "Booted", "ShuttingDown"][n] : "Unknown(\(n))"
}

var target: AnyObject?
for d in devices {
    let name = (kv(d, "name") as? String) ?? "?"
    let udid = (obj(d, "UDID") as? NSUUID)?.uuidString ?? (kv(d, "UDID") as? String) ?? "?"
    let st = stateNum(d)
    rep.line("  \(udid)  \(stateName(st).padding(toLength: 13, withPad: " ", startingAt: 0)) \(name)")
    if let want = udidArg, udid.caseInsensitiveCompare(want) == .orderedSame { target = d }
    if udidArg == nil, st == 3, target == nil { target = d }
}

guard let device = target else {
    rep.line()
    rep.line("FATAL: no booted device found (and --udid not matched). Boot one with:")
    rep.line("  xcrun simctl boot <udid>")
    exit(1)
}

rep.sub("target device")
rep.line("  name  : \((kv(device, "name") as? String) ?? "?")")
rep.line("  udid  : \((obj(device, "UDID") as? NSUUID)?.uuidString ?? "?")")
rep.line("  state : \(stateName(stateNum(device)))")
rep.line("  class : \(describe(device))")
if let rt = obj(device, "runtime") {
    rep.line("  runtime: \(describe(rt))  name=\((kv(rt, "name") as? String) ?? "?")  version=\((kv(rt, "versionString") as? String) ?? "?")  build=\((kv(rt, "buildVersionString") as? String) ?? "?")")
}
if let dt = obj(device, "deviceType") {
    rep.line("  deviceType: \((kv(dt, "name") as? String) ?? "?")  identifier=\((kv(dt, "identifier") as? String) ?? "?")")
}

// MARK: - IO walk

rep.section("IO PORT WALK")

let io = obj(device, "io")
rep.line("device.io              : \(describe(io))")
if let io, let cls = object_getClass(io) {
    rep.sub("io object class")
    dumpClass(rep, cls, includeIvars: false)
}

var ports: [AnyObject] = []
for sel in ["ioPorts", "ports"] {
    if let p = obj(io, sel) as? [AnyObject] {
        rep.line("io.\(sel) -> \(p.count) ports")
        ports = p
        break
    }
}
if ports.isEmpty { rep.line("WARNING: no ports found via ioPorts/ports") }

// Selectors we care about, probed on every object we touch so we learn the real
// names instead of assuming idb's.
let surfaceSelectors = [
    // Confirmed present on Xcode 26.5 (SimDisplayIOSurfaceRenderable / SimDisplayRenderable / SimScreen).
    "framebufferSurface", "maskedFramebufferSurface",
    "registerCallbackWithUUID:ioSurfacesChangeCallback:",
    "unregisterIOSurfacesChangeCallbackWithUUID:",
    "registerCallbackWithUUID:damageRectanglesCallback:",
    "unregisterDamageRectanglesCallbackWithUUID:",
    "registerCallbackWithUUID:displayPropertiesChanged:",
    "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:",
    "unregisterScreenCallbacksWithUUID:",
    "screenProperties", "displaySize", "displayPitch", "displaySizeInBytes",
    "setPowerState:completionQueue:completionHandler:",
    // HID.
    "legacyHIDEventPort", "registerCallbackWithUUID:legacyHIDEventPortCallback:",
    // Older spellings, kept so their absence is recorded rather than assumed.
    "ioSurface", "IOSurface", "surface",
    "attachConsumer:withUUID:framebufferQueue:errorQueue:errorHandler:",
    "registerCallbackWithUUID:ioSurfaceChangeCallback:",
    // Identity.
    "displayClass", "defaultWidthForDisplay", "defaultHeightForDisplay", "defaultPixelFormat",
    "state", "descriptor", "port", "platformResourcesPath",
]

/// Protocols already dumped, so a protocol shared by 13 ports is only printed once.
var dumpedProtocols = Set<String>()

func dumpProxy(_ rep: Report, _ label: String, _ o: AnyObject?) {
    guard let o else { rep.line("  \(label): nil"); return }
    rep.line("  \(label): \(describe(o))")

    let protos = protoNames(o)
    rep.line("    conforms to: \(protos.isEmpty ? "(none)" : protos.joined(separator: ", "))")

    // The proxy class only exposes ROCK forwarding machinery; the real API lives
    // in the protocols it advertises, so that is what we dump.
    for p in protos where !dumpedProtocols.contains(p) {
        dumpedProtocols.insert(p)
        if p.hasPrefix("ROCK") { continue }
        rep.line("    ~~ protocol \(p) ~~")
        dumpProtocol(rep, p)
    }

    let hits = surfaceSelectors.compactMap { sel -> String? in
        guard let enc = encoding(o, sel) else { return nil }
        return "\(sel)  ::  \(enc)"
    }
    if hits.isEmpty {
        rep.line("    probe: (no probe selector present)")
    } else {
        rep.line("    probe hits:")
        for h in hits { rep.line("      \(h)") }
    }

    // Read every scalar/object that might identify this port.
    for key in ["displayClass", "displayIdentifier", "identifier", "defaultWidth", "defaultHeight",
                "defaultScale", "unclampedDefaultWidth", "paused", "portClass", "name"] {
        if let v = kv(o, key) { rep.line("    .\(key) = \(v)") }
    }
}

for (idx, port) in ports.enumerated() {
    rep.sub("port[\(idx)]")
    dumpProxy(rep, "port", port)

    let desc = obj(port, "descriptor")
    dumpProxy(rep, "descriptor", desc)

    // The descriptor's `state` object is where displayClass usually lives.
    if let st = obj(desc, "state") {
        dumpProxy(rep, "descriptor.state", st)
    }

    // Try to actually reach a surface, on the port, the descriptor, and the
    // consumer-ish objects hanging off either.
    for host in [("port", port), ("descriptor", desc)] {
        guard let h = host.1 else { continue }
        for sel in ["ioSurface", "IOSurface", "surface", "displayDescriptorState", "state"] {
            if responds(h, sel) {
                rep.line("  >>> \(host.0).\(sel) = \(describe(obj(h, sel)))  [enc \(encoding(h, sel) ?? "?")]")
            }
        }
    }
}

// MARK: - HID surface

rep.section("HID SURFACE")

for name in ["SimDeviceLegacyClient", "SimDeviceLegacyHIDClient", "SimulatorKitHIDClient"] {
    rep.sub("class \(name)")
    if let cls = NSClassFromString(name) {
        dumpClass(rep, cls)
    } else {
        rep.line("  ABSENT")
    }
}

rep.sub("classes matching HID / Indigo / Digitizer")
for n in allNames.sorted() where n.contains("HID") || n.contains("Indigo") || n.contains("Digitizer") || n.contains("Purple") {
    rep.line("  \(n)")
    if let cls = NSClassFromString(n), let meta = object_getClass(cls) {
        for m in methodList(meta).prefix(40) { rep.line("      +\(m)") }
        for m in methodList(cls).prefix(60) { rep.line("      -\(m)") }
    }
}

rep.sub("device-level HID-ish selectors")
for sel in ["sendEvent:", "postEvent:", "hid", "HID", "sendIndigoMessage:", "legacyClient",
            "bootstrapPort", "lookup:", "portForServiceNamed:error:", "registerPortForServiceNamed:port:error:"] {
    rep.line("  device responds to \(sel): \(responds(device, sel))")
}

// MARK: - Acquisition test
//
// The whole feature stands or falls on actually getting a live IOSurface out of
// the main display, so prove it here rather than assuming the selectors work.

rep.section("ACQUISITION TEST (main display)")

/// Main display = the descriptor that can vend an IOSurface and whose state
/// reports displayClass 0. Both halves matter: port[1] satisfies the first and
/// is the *external* display.
func findMainDisplay(_ ports: [AnyObject]) -> AnyObject? {
    for port in ports {
        guard let desc = obj(port, "descriptor") else { continue }
        guard protoNames(desc).contains("SimDisplayIOSurfaceRenderable") else { continue }
        guard let st = obj(desc, "state") else { continue }
        guard let cls = kv(st, "displayClass") as? NSNumber, cls.intValue == 0 else { continue }
        return desc
    }
    return nil
}

if let display = findMainDisplay(ports) {
    rep.line("main display descriptor: \(describe(display))")
    for sel in ["displaySize", "displayPitch", "displaySizeInBytes"] {
        rep.line("  \(sel) = \(String(describing: kv(display, sel)))")
    }

    let surface = obj(display, "framebufferSurface")
    rep.line("  framebufferSurface = \(describe(surface))")
    if let surface {
        // IOSurface is toll-free-ish here: SimulatorKit vends the ObjC IOSurface
        // class, which is exactly what CALayer.contents wants.
        for sel in ["width", "height", "bytesPerRow", "pixelFormat", "allocationSize", "seed"] {
            if let v = kv(surface, sel) { rep.line("    surface.\(sel) = \(v)") }
        }
        rep.line("  >>> SURFACE ACQUIRED OK")
    } else {
        rep.line("  >>> FAILED to acquire framebufferSurface")
    }

    // Damage callbacks are how we drive repaint; confirm registration is accepted
    // and that frames actually arrive.
    let uuid = UUID()
    var damageCount = 0
    var surfaceChangeCount = 0
    let lock = NSLock()

    let damageBlock: @convention(block) (AnyObject?) -> Void = { _ in
        lock.lock(); damageCount += 1; lock.unlock()
    }
    let surfaceBlock: @convention(block) (AnyObject?) -> Void = { _ in
        lock.lock(); surfaceChangeCount += 1; lock.unlock()
    }

    let dmgSel = "registerCallbackWithUUID:damageRectanglesCallback:"
    if responds(display, dmgSel) {
        let r = send(display, dmgSel, [uuid as NSUUID, damageBlock])
        rep.line("  registered damage callback: \(r == nil ? "returned nil (void)" : "\(r!)")")
    } else {
        rep.line("  MISSING \(dmgSel)")
    }

    let surfSel = "registerCallbackWithUUID:ioSurfacesChangeCallback:"
    if responds(display, surfSel) {
        _ = send(display, surfSel, [uuid as NSUUID, surfaceBlock])
        rep.line("  registered ioSurfacesChange callback")
    } else {
        rep.line("  MISSING \(surfSel)")
    }

    rep.line("  sampling callbacks for 3s (wiggle the simulator to generate damage)...")
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    lock.lock()
    let d = damageCount, s = surfaceChangeCount
    lock.unlock()
    rep.line("  damage callbacks in 3s        : \(d)  (\(String(format: "%.1f", Double(d) / 3.0))/s)")
    rep.line("  ioSurfacesChange callbacks    : \(s)")

    _ = send(display, "unregisterDamageRectanglesCallbackWithUUID:", [uuid as NSUUID])
    _ = send(display, "unregisterIOSurfacesChangeCallbackWithUUID:", [uuid as NSUUID])
    rep.line("  unregistered callbacks")
} else {
    rep.line("FAILED: no descriptor with SimDisplayIOSurfaceRenderable + displayClass==0")
}

// MARK: - HID client test + struct layout
//
// SimDeviceLegacyClient (what idb used) is gone on this Xcode. Its replacement
// lives in SimulatorKit, which is now a Swift framework, so the class is
// module-qualified. The send selector's ObjC type encoding carries the complete
// IndigoHIDMessageStruct layout, which is the authoritative definition — better
// than any checked-in header.

rep.section("HID CLIENT + INDIGO STRUCT LAYOUT")

let hidClassNames = [
    "SimulatorKit.SimDeviceLegacyHIDClient",
    "_TtC12SimulatorKit24SimDeviceLegacyHIDClient",
    "SimDeviceLegacyClient",
]

var hidClass: AnyClass?
for n in hidClassNames {
    if let c = NSClassFromString(n) {
        rep.line("[found]  \(n) -> \(NSStringFromClass(c))")
        if hidClass == nil { hidClass = c }
    } else {
        rep.line("[absent] \(n)")
    }
}

let sendSel = "sendWithMessage:freeWhenDone:completionQueue:completion:"
var indigoEncoding: String?

if let hidClass {
    rep.sub("HID client selectors")
    for sel in ["initWithDevice:error:", "initWithDevice:sessionResetQueue:error:sessionResetHandler:",
                "resetHIDSession", sendSel] {
        let m = class_getInstanceMethod(hidClass, NSSelectorFromString(sel))
        let enc = m.flatMap { method_getTypeEncoding($0) }.map { String(cString: $0) }
        rep.line("  \(sel)")
        rep.line("      \(enc ?? "ABSENT")")
        if sel == sendSel, let enc { indigoEncoding = enc }
    }

    // Existence proof: can we actually construct one against the live device?
    rep.sub("instantiation test")
    let allocated = send(hidClass, "alloc") as AnyObject?
    rep.line("  alloc -> \(describe(allocated))")
    if let allocated {
        var err: NSError?
        let client: Any?
        do {
            client = try SPObjC.send(NSSelectorFromString("initWithDevice:error:"),
                                     to: allocated, argsPlusNilError: [device])
        } catch let e {
            err = e as NSError
            client = nil
        }
        if let client = client as AnyObject? {
            rep.line("  >>> HID CLIENT CONSTRUCTED OK: \(describe(client))")
        } else {
            rep.line("  >>> HID client init FAILED: \(err?.localizedDescription ?? "nil return")")
        }
    }
}

// MARK: Struct layout decoding

/// Walks an ObjC struct/union type encoding and reports each member's size,
/// alignment and byte offset. NSGetSizeAndAlignment is the authority for
/// primitive and nested sizes, so the numbers here match what the compiler
/// would have produced for the real header.
func splitMembers(_ body: Substring) -> [String] {
    var out: [String] = []
    var depth = 0
    var cur = ""
    var i = body.startIndex
    while i < body.endIndex {
        let ch = body[i]
        cur.append(ch)
        switch ch {
        case "{", "(", "[": depth += 1
        case "}", ")", "]": depth -= 1
        default: break
        }
        // A member ends when we are at depth 0 and the token is complete.
        if depth == 0 {
            let isOpen = (ch == "}" || ch == ")" || ch == "]")
            let isPointerOrModifier = "^rnNoORV".contains(ch)
            let isQuotedName = ch == "\""
            if isQuotedName {
                // Skip a quoted field name: it annotates the *next* member.
                var j = body.index(after: i)
                while j < body.endIndex, body[j] != "\"" { cur.append(body[j]); j = body.index(after: j) }
                if j < body.endIndex { cur.append(body[j]); i = j }
                i = body.index(after: i)
                continue
            }
            if !isPointerOrModifier {
                if isOpen || cur.count >= 1 {
                    out.append(cur)
                    cur = ""
                }
            }
        }
        i = body.index(after: i)
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

func sizeAlign(_ enc: String) -> (size: Int, align: Int)? {
    var size = 0, align = 0
    enc.withCString { _ = NSGetSizeAndAlignment($0, &size, &align) }
    // A type it cannot parse leaves size untouched at 0.
    return size > 0 ? (size, align) : nil
}

func describeLayout(_ rep: Report, _ enc: String, indent: String = "  ", depth: Int = 0) {
    guard depth < 4 else { return }
    // Strip the leading pointer marker and qualifiers.
    var e = enc
    while let f = e.first, "^rnNoORV".contains(f) { e.removeFirst() }
    guard let open = e.first, open == "{" || open == "(" else { return }
    let close: Character = (open == "{") ? "}" : ")"
    guard e.last == close else { return }

    let inner = e.dropFirst().dropLast()
    guard let eq = inner.firstIndex(of: "=") else { return }
    let name = String(inner[inner.startIndex..<eq])
    let body = inner[inner.index(after: eq)...]

    let total = sizeAlign(e)
    let kind = (open == "{") ? "struct" : "union"
    rep.line("\(indent)\(kind) \(name.isEmpty ? "(anon)" : name)  size=\(total?.size ?? -1) align=\(total?.align ?? -1)")

    var offset = 0
    for (i, m) in splitMembers(body).enumerated() {
        guard let sa = sizeAlign(m) else {
            rep.line("\(indent)  [\(i)] \(m)  <unsized>")
            continue
        }
        if open == "{" {
            if sa.align > 0 { offset = (offset + sa.align - 1) / sa.align * sa.align }
            rep.line("\(indent)  [\(i)] @\(offset)  size=\(sa.size) align=\(sa.align)  \(m.count > 90 ? String(m.prefix(90)) + "..." : m)")
            offset += sa.size
        } else {
            rep.line("\(indent)  [\(i)] @0  size=\(sa.size) align=\(sa.align)  \(m.count > 90 ? String(m.prefix(90)) + "..." : m)")
        }
        if m.hasPrefix("{") || m.hasPrefix("(") {
            describeLayout(rep, m, indent: indent + "    ", depth: depth + 1)
        }
    }
}

if let enc = indigoEncoding {
    rep.sub("IndigoHIDMessageStruct layout (decoded from the live method signature)")
    rep.line("  full send encoding:")
    rep.line("    \(enc)")
    // Isolate the first argument's struct encoding: everything between the first
    // '^{' and its matching '}'.
    if let start = enc.range(of: "^{IndigoHIDMessageStruct") {
        var depth = 0
        var end = start.lowerBound
        var i = enc.index(after: start.lowerBound) // at '{'
        while i < enc.endIndex {
            if enc[i] == "{" || enc[i] == "(" || enc[i] == "[" { depth += 1 }
            if enc[i] == "}" || enc[i] == ")" || enc[i] == "]" {
                depth -= 1
                if depth == 0 { end = enc.index(after: i); break }
            }
            i = enc.index(after: i)
        }
        let structEnc = String(enc[start.lowerBound..<end])
        rep.line()
        rep.line("  isolated struct encoding:")
        rep.line("    \(structEnc)")
        rep.line()
        if let sa = sizeAlign(structEnc.replacingOccurrences(of: "^", with: "")) {
            rep.line("  IndigoHIDMessageStruct: size=\(sa.size) align=\(sa.align)")
        }
        rep.line()
        describeLayout(rep, structEnc)
    }
}

rep.section("DONE")
rep.line("dump written to: \(rep.path)")
