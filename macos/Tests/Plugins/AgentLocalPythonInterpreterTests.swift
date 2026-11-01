import Foundation
import Testing
@testable import Ghostty

@Suite(.serialized)
struct AgentLocalPythonInterpreterTests {
    private func executable(_ path: URL) throws -> String {
        try Data("interpreter stub for resolver tests".utf8).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: path.path
        )
        return path.path
    }

    @Test func pathInterpreterPrecedesDeveloperToolchainFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pathDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let developerDirectory = root.appendingPathComponent(
            "Xcode/Contents/Developer",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: pathDirectory, withIntermediateDirectories: true)
        let developerBin = developerDirectory.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: developerBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pathInterpreter = try executable(pathDirectory.appendingPathComponent("python3"))
        _ = try executable(developerBin.appendingPathComponent("python3"))

        let selected = LocalPythonInterpreter.candidate(
            executablePaths: [pathInterpreter],
            developerDirectories: [developerDirectory.path],
            appleShimPath: root.appendingPathComponent("usr/bin/python3").path
        )
        #expect(selected == URL(fileURLWithPath: pathInterpreter).resolvingSymlinksInPath().path)
    }

    @Test func standardHomebrewPathsFollowTheUserPath() {
        let candidates = LocalPythonInterpreter.pathCandidates(in: "/custom/bin:/usr/bin") +
            LocalPythonInterpreter.homebrewCandidates()
        #expect(candidates == [
            "/custom/bin/python3",
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ])
    }

    @Test func loginShellFallbackReadsIsolatedPathWithoutExecutingPython() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let dotfiles = home.appendingPathComponent("zsh", isDirectory: true)
        let binaryDirectory = root.appendingPathComponent("login bin", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let marker = root.appendingPathComponent("executed-python")
        let candidate = binaryDirectory.appendingPathComponent("python3")
        try Data("#!/bin/sh\n/bin/touch \(marker.path)\n".utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)
        let zprofile = dotfiles.appendingPathComponent(".zprofile")
        let pathValue = "\(binaryDirectory.path):/usr/bin:/bin"
        try "export PATH='\(pathValue)'\n".write(to: zprofile, atomically: true, encoding: .utf8)

        let interpreter = try await LocalPythonInterpreter.resolveFromLoginShell(
            shellPath: "/bin/zsh",
            loginShell: true,
            environment: [
                "HOME": home.path,
                "ZDOTDIR": dotfiles.path,
                "PATH": "/usr/bin:/bin",
                "SDKROOT": "/stale/sdk",
                "DEVELOPER_DIR": "/missing/developer",
            ]
        )
        #expect(interpreter.executablePath == URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().path)
        #expect(interpreter.environment["SDKROOT"] == nil)
        #expect(interpreter.environment["DEVELOPER_DIR"] == nil)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func exactSymlinkAndHardlinkAliasesOfAppleShimAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shim = root.appendingPathComponent("system/python3")
        let aliases = root.appendingPathComponent("aliases", isDirectory: true)
        try FileManager.default.createDirectory(at: shim.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: aliases, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try executable(shim)
        let symlink = aliases.appendingPathComponent("python3-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: shim)
        let hardlink = aliases.appendingPathComponent("python3-hardlink")
        try FileManager.default.linkItem(at: shim, to: hardlink)
        let independent = try executable(aliases.appendingPathComponent("python3-real"))

        let selected = LocalPythonInterpreter.candidate(
            executablePaths: [shim.path, symlink.path, hardlink.path, independent],
            developerDirectories: [],
            appleShimPath: shim.path
        )
        #expect(selected == URL(fileURLWithPath: independent).resolvingSymlinksInPath().path)
    }

    @Test func candidateSelectionNeverRunsTheInterpreter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("executed")
        let candidate = directory.appendingPathComponent("python3")
        let body = "#!/bin/sh\n/bin/touch \(marker.path)\n"
        try Data(body.utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: candidate.path)

        #expect(LocalPythonInterpreter.candidate(
            executablePaths: [candidate.path],
            developerDirectories: [],
            appleShimPath: "/usr/bin/python3"
        ) == URL(fileURLWithPath: candidate.path).resolvingSymlinksInPath().path)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func noSafeCandidateReturnsNilForStubOnlyAndExecutableDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shimURL = root.appendingPathComponent("system/python3")
        try FileManager.default.createDirectory(
            at: shimURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let shim = try executable(shimURL)
        let developer = root.appendingPathComponent("Developer", isDirectory: true)
        let pythonDirectory = developer.appendingPathComponent("usr/bin/python3", isDirectory: true)
        try FileManager.default.createDirectory(at: pythonDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: pythonDirectory.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LocalPythonInterpreter.candidate(
            executablePaths: [shim],
            developerDirectories: [developer.path],
            appleShimPath: shim
        ) == nil)
    }

    @Test func appBundleDeveloperOverrideUsesContentsDeveloperWithoutChangingToolchain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Custom Xcode.app", isDirectory: true)
        let developer = app.appendingPathComponent("Contents/Developer", isDirectory: true)
        let developerBin = developer.appendingPathComponent("usr/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: developerBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try executable(developerBin.appendingPathComponent("python3"))
        let originalEnvironment = [
            "PATH": "",
            "SDKROOT": "/stale/SDKs/MacOSX.sdk",
            "DEVELOPER_DIR": app.path,
        ]

        let interpreter = try #require(LocalPythonInterpreter.cached(environment: originalEnvironment))
        #expect(interpreter.executablePath == URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        #expect(interpreter.environment["SDKROOT"] == nil)
        #expect(interpreter.environment["DEVELOPER_DIR"] == developer.path)
    }

    @Test func childEnvironmentDropsBuildSDKAndInvalidDeveloperDirectory() throws {
        let source = [
            "PATH": "/opt/homebrew/bin:/usr/bin:/bin",
            "SDKROOT": "/stale/SDKs/MacOSX.sdk",
            "DEVELOPER_DIR": "/missing/Xcode/Contents/Developer",
        ]

        let sanitized = LocalPythonInterpreter.sanitizedEnvironment(
            source,
            developerDirectory: nil
        )
        #expect(sanitized["PATH"] == source["PATH"])
        #expect(sanitized["SDKROOT"] == nil)
        #expect(sanitized["DEVELOPER_DIR"] == nil)
    }

    @Test func shellPreamblePreservesValidProfileDeveloperDirAndQuotesExecutablePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let developerDirectory = root.appendingPathComponent("Developer Dir", isDirectory: true)
        try FileManager.default.createDirectory(at: developerDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = root.appendingPathComponent("Python's Tools/Python 3/bin/python3").path
        let interpreter = LocalPythonInterpreter(
            executablePath: path,
            environment: [:]
        )
        let command = """
        SDKROOT='/stale/SDK'; DEVELOPER_DIR='\(developerDirectory.path)'
        \(interpreter.shellEnvironmentPreamble)
        printf '%s\\n' "${SDKROOT-}" "${DEVELOPER_DIR-}" \(interpreter.shellQuotedExecutable)
        """
        let validResult = try await GitProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", command],
            workingDirectory: "/",
            environment: ["PATH": "/usr/bin:/bin"],
            maxOutputBytes: 4_096,
            timeout: 2
        )
        #expect(validResult.isSuccess)
        #expect(validResult.stdoutString.components(separatedBy: "\n") == [
            "",
            developerDirectory.path,
            path,
            "",
        ])

        let invalidCommand = """
        SDKROOT='/stale/SDK'; DEVELOPER_DIR='/missing/Developer'
        \(interpreter.shellEnvironmentPreamble)
        printf '%s\\n' "${SDKROOT-}" "${DEVELOPER_DIR-}" \(interpreter.shellQuotedExecutable)
        """
        let invalidResult = try await GitProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", invalidCommand],
            workingDirectory: "/",
            environment: ["PATH": "/usr/bin:/bin"],
            maxOutputBytes: 4_096,
            timeout: 2
        )
        #expect(invalidResult.isSuccess)
        #expect(invalidResult.stdoutString.components(separatedBy: "\n") == [
            "",
            "",
            path,
            "",
        ])
    }
}
