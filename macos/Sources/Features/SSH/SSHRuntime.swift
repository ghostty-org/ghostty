import Darwin
import Foundation

/// Only metadata and Keychain references cross process boundaries.
struct SSHLaunchSpecification: Codable {
    var profile: SSHProfile
    var expiresAt: Date
    var launcherPID: Int32 = 0
    var policy: SSHAuthenticationPolicy?
    var manual = false
}

enum SSHRuntime {
    private static let childLock = NSLock()
    private static var activeChild: pid_t?

    private static let askpassMarker = "GHOSTTY_INTERNAL_SSH_ASKPASS"
    private static let specificationKey = "GHOSTTY_INTERNAL_SSH_SPEC"

    /// Called before ghostty_init/NSApplicationMain. The same signed binary is the helper.
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--ghostty-ssh-launch" {
            exit(launch(URL(fileURLWithPath: args[2])))
        }
        if ProcessInfo.processInfo.environment[askpassMarker] == "1" {
            guard args.count == 2,
                  let path = ProcessInfo.processInfo.environment[specificationKey] else { exit(1) }
            exit(SSHAuthentication.respond(specURL: URL(fileURLWithPath: path), prompt: args[1]))
        }
    }

    static func prepare(_ profile: SSHProfile) throws -> URL {
        try profile.validate()
        for path in requiredFiles(profile) where !FileManager.default.isReadableFile(atPath: path) {
            throw SSHError.message("The selected SSH file cannot be read: \(path)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("launch.json")
        do {
            try writeSpecification(SSHLaunchSpecification(profile: profile,
                                                         expiresAt: Date().addingTimeInterval(120)), to: url)
            return url
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func discard(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    static func readSpecification(_ url: URL) throws -> SSHLaunchSpecification {
        let directory = url.deletingLastPathComponent()
        for path in [directory.path, url.path] {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
                  info.st_mode & S_IFMT != S_IFLNK else {
                throw SSHError.message("The SSH launch file is not private to this user.")
            }
        }
        let spec = try JSONDecoder().decode(SSHLaunchSpecification.self, from: Data(contentsOf: url))
        try spec.profile.validate()
        return spec
    }

    private static func writeSpecification(_ spec: SSHLaunchSpecification, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EACCES) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(spec))
    }

    private static func requiredFiles(_ profile: SSHProfile) -> [String] {
        switch profile.authentication {
        case .configuration, .password: return []
        case .privateKey: return [profile.identityFile]
        case .certificate: return [profile.identityFile, profile.certificateFile]
        }
    }

    private static func launch(_ url: URL) -> Int32 {
        // Claim this launch once, so command restoration cannot replay an authenticated launch.
        let claim = open(url.deletingLastPathComponent().appendingPathComponent("launched").path,
                         O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard claim >= 0 else { return 1 }
        close(claim)
        defer { discard(url) }
        do {
            var original = try readSpecification(url)
            guard original.expiresAt > Date(), let executable = Bundle.main.executableURL else { return 1 }
            original.launcherPID = getpid()
            // The launcher stays in the foreground group with SSH. Ignore interactive
            // interrupts here; the spawned SSH resets them to their default dispositions.
            signal(SIGINT, SIG_IGN)
            signal(SIGQUIT, SIG_IGN)
            let signalSources = [SIGHUP, SIGTERM].map { value -> DispatchSourceSignal in
                signal(value, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
                source.setEventHandler {
                    childLock.lock()
                    if let pid = activeChild { kill(pid, value) }
                    childLock.unlock()
                    discard(url)
                    _exit(128 + value)
                }
                source.resume()
                return source
            }
            defer { for source in signalSources { source.cancel() } }
            // Child setup is isolated from the Ghostty app's process environment.
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: askpassMarker)
            environment.removeValue(forKey: specificationKey)
            if original.profile.terminalType != .inherited {
                environment["TERM"] = original.profile.terminalType.rawValue
            }
            // Keep the user's character locale intact. Only authentication prompt
            // language must be stable; LC_ALL=C would break multibyte shell editing.
            environment.removeValue(forKey: "LC_ALL")
            environment["LC_MESSAGES"] = "C"
            environment["SSH_ASKPASS"] = executable.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment[askpassMarker] = "1"
            environment["DISPLAY"] = environment["DISPLAY"] ?? "ghostty:0"
            while true {
                var spec = original
                // Each explicit reconnect gets a fresh single-use credential claim.
                let attempt = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: attempt, withIntermediateDirectories: false,
                                                       attributes: [.posixPermissions: 0o700])
                let attemptURL = attempt.appendingPathComponent("auth.json")
                let arguments = try SSHInvocation.arguments(for: spec.profile, manual: spec.manual)
                spec.policy = try effectivePolicy(profile: spec.profile, arguments: arguments, environment: environment)
                spec.expiresAt = Date().addingTimeInterval(24 * 60 * 60)
                try writeSpecification(spec, to: attemptURL)
                environment[specificationKey] = attemptURL.path
                let status = try runSSH(arguments, environment: environment, encoding: spec.profile.encoding)
                try? FileManager.default.removeItem(at: attempt)
                print("\r\nSSH exited with status \(status).")
                print("Press R then Enter to reconnect, M then Enter for manual authentication, or Enter to finish.")
                fflush(stdout)
                guard let response = readLine()?.lowercased(), response == "r" || response == "m" else { return status }
                original.manual = response == "m"
            }
        } catch {
            // SSHError messages never include secrets; underlying errors concern file/process operations.
            fputs("SSH could not start: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func effectivePolicy(profile: SSHProfile, arguments: [String],
                                        environment: [String: String]) throws -> SSHAuthenticationPolicy {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-G"] + arguments
        var configEnvironment = environment
        configEnvironment.removeValue(forKey: askpassMarker)
        configEnvironment.removeValue(forKey: specificationKey)
        task.environment = configEnvironment
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = FileHandle.standardError
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SSHError.message("OpenSSH could not resolve this connection's configuration.") }
        var config: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { config[String(parts[0])] = String(parts[1]) }
        }
        let hasProxy = ["proxyjump", "proxycommand"].contains { key in
            guard let value = config[key] else { return false }
            return value != "none"
        }
        return SSHAuthenticationPolicy(profile: profile, hostname: config["hostname"] ?? profile.destination,
                                       username: config["user"] ?? NSUserName(), hasProxy: hasProxy)
    }

    private static func runSSH(_ arguments: [String], environment: [String: String],
                               encoding: SSHProfile.Encoding) throws -> Int32 {
        let onSpawn: (pid_t?) -> Void = { pid in
            childLock.lock()
            activeChild = pid
            childLock.unlock()
        }
        if encoding == .utf8 {
            return try SSHChildProcess.run(executable: "/usr/bin/ssh", arguments: arguments,
                                           environment: environment, onSpawn: onSpawn)
        }
        return try SSHEncodingRelay.run(executable: "/usr/bin/ssh", arguments: arguments,
                                        environment: environment, encoding: encoding, onSpawn: onSpawn)
    }
}
