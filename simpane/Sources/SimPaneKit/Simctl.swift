//  Device lifecycle and capture via `xcrun simctl`.

import Foundation

enum Simctl {

    private static let xcrun = "/usr/bin/xcrun"

    // MARK: Listing

    private struct RawDevice: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
    }

    private struct DeviceList: Decodable {
        let devices: [String: [RawDevice]]
    }

    static func devices() -> [SimDeviceInfo] {
        guard let json = Shell.run(xcrun, ["simctl", "list", "-j", "devices", "available"]),
              let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode(DeviceList.self, from: data)
        else { return [] }

        var out: [SimDeviceInfo] = []
        for (runtime, raw) in list.devices {
            for device in raw where device.isAvailable ?? true {
                out.append(SimDeviceInfo(
                    udid: device.udid,
                    name: device.name,
                    runtimeIdentifier: runtime,
                    state: SimDeviceInfo.State(simctlName: device.state)))
            }
        }
        // Newest runtime first, then by name, so a picker reads sensibly and
        // `preferredTarget` gets a stable answer.
        return out.sorted {
            $0.runtimeIdentifier == $1.runtimeIdentifier
                ? $0.name < $1.name
                : $0.runtimeIdentifier > $1.runtimeIdentifier
        }
    }

    static func device(udid: String) -> SimDeviceInfo? {
        devices().first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
    }

    static func state(udid: String) -> SimDeviceInfo.State {
        device(udid: udid)?.state ?? .unknown
    }

    /// A reasonable default target: an already-booted device, else the first
    /// iPhone on the newest iOS runtime.
    static func preferredTarget() -> SimDeviceInfo? {
        if let booted = devices().first(where: { $0.isBooted }) { return booted }
        return devices().first {
            $0.runtimeIdentifier.contains("iOS") && $0.name.hasPrefix("iPhone")
        }
    }

    // MARK: Lifecycle

    static func boot(udid: String) throws {
        // Already-booted is success, not failure.
        guard state(udid: udid) != .booted else { return }
        let result = Shell.capture(xcrun, ["simctl", "boot", udid])
        guard result.succeeded else {
            throw SimPaneError("simctl boot failed: \(result.failureMessage)")
        }
    }

    static func shutdown(udid: String) throws {
        guard state(udid: udid) != .shutdown else { return }
        let result = Shell.capture(xcrun, ["simctl", "shutdown", udid])
        guard result.succeeded else {
            throw SimPaneError("simctl shutdown failed: \(result.failureMessage)")
        }
    }

    /// Polls until the device reaches `target`. `simctl boot` returns before the
    /// guest is actually up, and the IO ports do not exist until it is.
    static func wait(udid: String, for target: SimDeviceInfo.State, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if state(udid: udid) == target { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SimPaneError(
            "device \(udid) did not reach \(target.label) within \(Int(timeout))s "
                + "(currently \(state(udid: udid).label))")
    }

    // MARK: Capture and apps

    /// An exact, unscaled PNG of the device screen. This is the canonical
    /// screenshot: it is what a user would get from Simulator.app, unaffected by
    /// how the pane happens to be scaled.
    static func screenshotPNG(udid: String) throws -> Data {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("simpane-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: path) }

        let result = Shell.capture(
            xcrun, ["simctl", "io", udid, "screenshot", "--type=png", path.path])
        guard result.succeeded else {
            throw SimPaneError("simctl screenshot failed: \(result.failureMessage)")
        }
        guard let data = try? Data(contentsOf: path) else {
            throw SimPaneError("simctl screenshot wrote nothing to \(path.path)")
        }
        return data
    }

    static func launch(udid: String, bundleIdentifier: String) throws {
        let result = Shell.capture(xcrun, ["simctl", "launch", udid, bundleIdentifier])
        guard result.succeeded else {
            throw SimPaneError("simctl launch \(bundleIdentifier) failed: \(result.failureMessage)")
        }
    }
}
