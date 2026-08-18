//  Whether a booted device is still alive.
//
//  Nothing here is private API. A booted simulator runs exactly one
//  `launchd_sim` whose arguments contain the device's data directory, and that
//  process exits when the device shuts down — by `simctl`, by Simulator.app, or
//  by crashing. Watching it exit is instant and costs nothing while it lives.
//
//  This exists because the obvious signals lie. `SimDevice.state` is a value
//  cached on the XPC proxy and keeps reporting `Booted` long after the device is
//  gone, and the framebuffer surface stays readable because we still hold a
//  reference to its last frame. See DEVLOG, Phase 5.

import Foundation

enum DeviceProcess {

    /// The `launchd_sim` process for a booted device, or nil when it is not
    /// running.
    static func pid(forUDID udid: String) -> pid_t? {
        // Matching the data path rather than the bare UDID keeps this from
        // finding our *own* process, whose command line may well contain the
        // UDID — the pane is often launched with it as an argument.
        guard let output = Shell.run("/usr/bin/pgrep", ["-f", "Devices/\(udid)/data"]) else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for line in output.split(separator: "\n") {
            guard let candidate = pid_t(line.trimmingCharacters(in: .whitespaces)),
                  candidate != ownPID
            else { continue }
            return candidate
        }
        return nil
    }

    static func isRunning(udid: String) -> Bool { pid(forUDID: udid) != nil }

    /// Whether a pid found earlier is still a live process.
    ///
    /// `kill(pid, 0)` is not good enough and was the first thing tried: when a
    /// device shuts down its `launchd_sim` becomes a **zombie** until whoever
    /// spawned it reaps it, and signalling a zombie succeeds. The pane therefore
    /// believed the device was alive indefinitely. Asking the kernel for the
    /// process state instead is the same order of cost — one syscall, no
    /// subprocess — and actually true.
    ///
    /// A recycled pid could in principle read as alive after the device is gone.
    /// The cost of that is a late detection, not a wrong one, and the reboot path
    /// re-derives the pid from scratch anyway.
    static func isAlive(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, UInt32(pointer.count), &info, &size, nil, 0)
        }
        // No entry at all means the process is gone and reaped.
        guard result == 0, size > 0 else { return false }
        // SZOMB: exited, waiting to be reaped. Not alive for our purposes.
        return info.kp_proc.p_stat != SZOMB
    }
}
