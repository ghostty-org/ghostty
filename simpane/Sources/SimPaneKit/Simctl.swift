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

    static func devices(scrubEnvironment: Bool = false) -> [SimDeviceInfo] {
        let result = Shell.capture(
            xcrun, ["simctl", "list", "-j", "devices", "available"],
            scrubEnvironment: scrubEnvironment)
        guard result.succeeded,
              let data = result.stdout.data(using: .utf8),
              let list = try? JSONDecoder().decode(DeviceList.self, from: data)
        else {
            if ProcessInfo.processInfo.environment["SIMPANE_DEBUG_SIMCTL"] != nil {
                let line = "simctl list failed: status=\(result.status) "
                    + "stdout=\(result.stdout.prefix(120)) stderr=\(result.stderr.prefix(200))\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            return []
        }

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

    static func device(udid: String, scrubEnvironment: Bool = false) -> SimDeviceInfo? {
        devices(scrubEnvironment: scrubEnvironment)
            .first { $0.udid.caseInsensitiveCompare(udid) == .orderedSame }
    }

    static func state(udid: String, scrubEnvironment: Bool = false) -> SimDeviceInfo.State {
        device(udid: udid, scrubEnvironment: scrubEnvironment)?.state ?? .unknown
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

    /// Starts recording the device's display and returns the running process.
    ///
    /// Long-lived, so it deliberately bypasses `Shell.capture`: recording ends
    /// when the process is sent SIGINT, and only then does simctl finalise the
    /// movie. Killing it any harder truncates the file.
    static func startRecording(udid: String, to url: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcrun)
        process.arguments = [
            "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SimPaneError("could not start recording: \(error.localizedDescription)")
        }
        return process
    }

    /// Ends a recording and waits for the movie to be finalised.
    static func stopRecording(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()          // SIGINT: simctl's documented way to stop
        process.waitUntilExit()
    }

    /// Hands the device to Simulator.app, which opens it in its own window.
    static func openInSimulatorApp(udid: String) throws {
        let result = Shell.capture(
            "/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])
        guard result.succeeded else {
            throw SimPaneError("could not open Simulator.app: \(result.failureMessage)")
        }
    }

    static func launch(udid: String, bundleIdentifier: String) throws {
        let result = Shell.capture(xcrun, ["simctl", "launch", udid, bundleIdentifier])
        guard result.succeeded else {
            throw SimPaneError("simctl launch \(bundleIdentifier) failed: \(result.failureMessage)")
        }
    }
}
