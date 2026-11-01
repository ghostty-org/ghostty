import Darwin
import Foundation

enum LocalPythonInterpreterError: Error, Equatable, LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? {
        "No local Python 3 interpreter was found. " +
            "Add one to PATH or set DEVELOPER_DIR to an installed Xcode toolchain."
    }
}

/// Selects an already-installed interpreter without executing candidates.
struct LocalPythonInterpreter: Sendable {
    let executablePath: String
    let environment: [String: String]

    private static let appleShimPath = "/usr/bin/python3"
    private static let commonDeveloperDirectories = [
        "/Library/Developer/CommandLineTools",
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer",
    ]
    private static let shellEnvironmentCleanup =
        "unset SDKROOT; if [ -n \"${DEVELOPER_DIR-}\" ] && [ ! -d \"$DEVELOPER_DIR\" ]; then unset DEVELOPER_DIR; fi"
    private static let developerDirectoryMemo = DeveloperDirectoryMemo()
    private static let activeDeveloperDirectory = ActiveDeveloperDirectory()

    var shellQuotedExecutable: String {
        Self.shellQuote(executablePath)
    }

    /// Run after a login shell has loaded its profile to clear build-only state.
    var shellEnvironmentPreamble: String {
        Self.shellEnvironmentCleanup
    }

    static func cached(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LocalPythonInterpreter? {
        let memoizedDirectory = developerDirectoryMemo.value().map { [$0] } ?? []
        let explicitDirectories = developerDirectoryCandidates(in: environment)
        let candidates = pathCandidates(in: environment["PATH"]) +
            pythonCandidates(in: explicitDirectories) +
            homebrewCandidates()
        guard let path = candidate(
            executablePaths: candidates,
            developerDirectories: memoizedDirectory + commonDeveloperDirectories,
            appleShimPath: appleShimPath
        ) else { return nil }
        return .init(
            executablePath: path,
            environment: sanitizedEnvironment(
                environment,
                developerDirectory: validDeveloperDirectory(in: environment)
            )
        )
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> LocalPythonInterpreter {
        let memoizedDirectory = developerDirectoryMemo.value().map { [$0] } ?? []
        let explicitDirectories = developerDirectoryCandidates(in: environment)
        let preferredCandidates = pathCandidates(in: environment["PATH"]) +
            pythonCandidates(in: explicitDirectories)
        if let path = candidate(
            executablePaths: preferredCandidates,
            developerDirectories: [],
            appleShimPath: appleShimPath
        ) {
            return .init(
                executablePath: path,
                environment: sanitizedEnvironment(
                    environment,
                    developerDirectory: validDeveloperDirectory(in: environment)
                )
            )
        }

        let cleaned = sanitizedEnvironment(
            environment,
            developerDirectory: validDeveloperDirectory(in: environment)
        )
        let developerDirectory = await activeDeveloperDirectory.resolve(environment: cleaned)
        if let developerDirectory {
            rememberDeveloperDirectory(developerDirectory)
        }
        let directories = developerDirectoryCandidates(in: environment) +
            [developerDirectory].compactMap { $0 } +
            memoizedDirectory +
            commonDeveloperDirectories
        guard let path = candidate(
            executablePaths: homebrewCandidates(),
            developerDirectories: directories,
            appleShimPath: appleShimPath
        ) else {
            throw LocalPythonInterpreterError.unavailable
        }
        return .init(
            executablePath: path,
            environment: sanitizedEnvironment(
                environment,
                developerDirectory: validDeveloperDirectory(in: environment)
            )
        )
    }

    /// Re-read only the login shell's PATH when the app environment has no interpreter.
    /// The shell prints the path; it never runs `python3`.
    static func resolveFromLoginShell(
        shellPath: String,
        loginShell: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> LocalPythonInterpreter {
        let cleaned = sanitizedEnvironment(
            environment,
            developerDirectory: validDeveloperDirectory(in: environment)
        )
        let command = "\(shellEnvironmentCleanup); printf '%s\\n%s\\n' '__OMG_LOCAL_PYTHON_PATH_V1__' \"$PATH\""
        let result = try await GitProcessRunner().run(
            executablePath: shellPath,
            arguments: [loginShell ? "-lic" : "-lc", command],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            environment: cleaned,
            maxOutputBytes: 8_192,
            timeout: 10
        )
        let markerLine = "__OMG_LOCAL_PYTHON_PATH_V1__\n"
        guard result.isSuccess,
              let marker = result.stdoutString.range(of: markerLine, options: .backwards) else {
            throw LocalPythonInterpreterError.unavailable
        }
        let loginPath = String(result.stdoutString[marker.upperBound...])
            .components(separatedBy: .newlines)
            .first ?? ""
        var mergedEnvironment = cleaned
        mergedEnvironment["PATH"] = loginPath
        return try await resolve(environment: mergedEnvironment)
    }

    /// Pure candidate selection for tests and synchronous UI setup.
    static func candidate(
        executablePaths: [String],
        developerDirectories: [String],
        appleShimPath: String,
        fileManager: FileManager = .default
    ) -> String? {
        var seen = Set<String>()
        let shim = standardizedPath(appleShimPath)
        let resolvedShim = URL(fileURLWithPath: shim).resolvingSymlinksInPath().path
        let candidates = executablePaths + developerDirectories.map {
            URL(fileURLWithPath: normalizedDeveloperDirectory($0) ?? $0, isDirectory: true)
                .appendingPathComponent("usr/bin/python3").path
        }

        for candidate in candidates {
            guard candidate.hasPrefix("/") else { continue }
            let standardized = standardizedPath(candidate)
            guard seen.insert(standardized).inserted,
                  standardized != shim,
                  fileManager.isExecutableFile(atPath: standardized) else { continue }
            let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
            guard resolved != shim, resolved != resolvedShim,
                  isRegularFile(resolved, fileManager: fileManager),
                  !isSameFile(resolved, resolvedShim) else { continue }
            return resolved
        }
        return nil
    }

    static func pathCandidates(in path: String?) -> [String] {
        let userDirectories: [String] = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: true)
            .compactMap { directory -> String? in
                let path = String(directory)
                guard path.hasPrefix("/") else { return nil }
                return path
            }
        var seen = Set<String>()
        return userDirectories.compactMap { directory -> String? in
            guard seen.insert(directory).inserted else { return nil }
            return URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("python3").path
        }
    }

    static func homebrewCandidates() -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .appendingPathComponent("python3").path
        }
    }

    private static func pythonCandidates(in developerDirectories: [String]) -> [String] {
        developerDirectories.map {
            URL(fileURLWithPath: normalizedDeveloperDirectory($0) ?? $0, isDirectory: true)
                .appendingPathComponent("usr/bin/python3").path
        }
    }

    private static func developerDirectoryCandidates(in environment: [String: String]) -> [String] {
        guard let value = environment["DEVELOPER_DIR"] else { return [] }
        let directory = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized = normalizedDeveloperDirectory(directory) else { return [] }
        return [normalized]
    }

    private static func validDeveloperDirectory(in environment: [String: String]) -> String? {
        developerDirectoryCandidates(in: environment).first
    }

    private static func normalizedDeveloperDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let embeddedDeveloper = URL(fileURLWithPath: normalized, isDirectory: true)
            .appendingPathComponent("Contents/Developer", isDirectory: true).path
        if normalized.hasSuffix(".app"),
           isDirectory(embeddedDeveloper, fileManager: .default) {
            return embeddedDeveloper
        }
        if isDirectory(normalized, fileManager: .default) { return normalized }
        if isDirectory(embeddedDeveloper, fileManager: .default) { return embeddedDeveloper }
        return nil
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) &&
            isDirectory.boolValue
    }

    private static func isRegularFile(_ path: String, fileManager: FileManager) -> Bool {
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true && !isDirectory(path, fileManager: fileManager)
    }

    static func sanitizedEnvironment(
        _ environment: [String: String],
        developerDirectory: String?
    ) -> [String: String] {
        var result = environment
        result.removeValue(forKey: "SDKROOT")
        if let developerDirectory {
            result["DEVELOPER_DIR"] = developerDirectory
        } else {
            result.removeValue(forKey: "DEVELOPER_DIR")
        }
        return result
    }

    fileprivate static func rememberDeveloperDirectory(_ path: String?) {
        developerDirectoryMemo.store(path)
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isSameFile(_ lhsPath: String, _ rhsPath: String) -> Bool {
        var lhs = stat()
        var rhs = stat()
        guard Darwin.lstat(lhsPath, &lhs) == 0, Darwin.lstat(rhsPath, &rhs) == 0 else { return false }
        return lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private actor ActiveDeveloperDirectory {
    private var task: Task<String?, Never>?
    private var didResolve = false
    private var resolvedPath: String?

    func resolve(environment: [String: String]) async -> String? {
        if didResolve { return resolvedPath }
        if let task { return await task.value }

        let queryEnvironment = environment
        let query = Task.detached(priority: .utility) { () -> String? in
            let result = try? await GitProcessRunner().run(
                executablePath: "/usr/bin/xcode-select",
                arguments: ["-p"],
                workingDirectory: "/",
                environment: queryEnvironment,
                maxOutputBytes: 4_096,
                timeout: 2
            )
            guard let result, result.isSuccess else { return nil }
            let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        task = query
        resolvedPath = await query.value
        didResolve = true
        task = nil
        if let resolvedPath {
            LocalPythonInterpreter.rememberDeveloperDirectory(resolvedPath)
        }
        return resolvedPath
    }
}

private final class DeveloperDirectoryMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?

    func value() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    func store(_ path: String?) {
        guard let path else { return }
        lock.lock()
        self.path = path
        lock.unlock()
    }
}
