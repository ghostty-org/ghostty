import Darwin
import Foundation
import Security

/// Do not let arbitrary callers use the signed askpass executable as a Keychain oracle.
enum SSHHelperTrust {
    static func validateCaller(launcherPID: pid_t) -> Bool {
        let sshPID = getppid()
        var info = proc_bsdinfo()
        guard proc_pidinfo(sshPID, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0,
              info.pbi_ppid == UInt32(launcherPID),
              processPath(sshPID) == "/usr/bin/ssh",
              processPath(launcherPID) == Bundle.main.executableURL.flatMap({ canonicalPath($0.path) }) else { return false }
        var sshRequirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple and identifier \"com.apple.ssh\"" as CFString,
                                             [], &sshRequirement) == errSecSuccess,
              check(sshPID, requirement: sshRequirement) else { return false }
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var ownRequirement: SecRequirement?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &ownRequirement) == errSecSuccess else { return false }
        return check(launcherPID, requirement: ownRequirement)
    }

    private static func canonicalPath(_ path: String) -> String? {
        // Foundation intentionally preserves /var aliases on macOS; proc_pidpath does not.
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func check(_ pid: pid_t, requirement: SecRequirement?) -> Bool {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}
