import CryptoKit
import Foundation

enum WorktrunkInstallerError: LocalizedError {
    case unsupportedArchitecture
    case downloadFailed
    case integrityCheckFailed
    case extractFailed(stderr: String)
    case missingBinary(name: String)
    case installFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "Unsupported Mac architecture for Worktrunk installation."
        case .downloadFailed:
            return "Failed to download Worktrunk."
        case .integrityCheckFailed:
            return "Downloaded Worktrunk failed the integrity check."
        case .extractFailed(let stderr):
            if stderr.isEmpty { return "Failed to extract Worktrunk." }
            return "Failed to extract Worktrunk: \(stderr)"
        case .missingBinary(let name):
            return "Downloaded Worktrunk archive did not contain \(name)."
        case .installFailed(let message):
            return message
        }
    }
}

enum WorktrunkInstaller {
    private struct Release {
        static let version = "0.22.0"
        static let assetName = "worktrunk-aarch64-apple-darwin.tar.xz"
        static let sha256 = "1fd193d8ed95453dbeadd900035312a6df61ff3fad43dc85eb1a9f7b48895b3c"

        static var url: URL {
            URL(string: "https://github.com/max-sixty/worktrunk/releases/download/v\(version)/\(assetName)")!
        }
    }

    static func installPinnedWorktrunkIfNeeded() async throws {
        guard isSupportedArchitecture() else {
            throw WorktrunkInstallerError.unsupportedArchitecture
        }

        let binDir = AgentStatusPaths.binDir
        let wtDest = binDir.appendingPathComponent("wt", isDirectory: false)
        let gitWtDest = binDir.appendingPathComponent("git-wt", isDirectory: false)
        if FileManager.default.isExecutableFile(atPath: wtDest.path),
           FileManager.default.isExecutableFile(atPath: gitWtDest.path) {
            return
        }

        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev.sidequery.Ghostree", isDirectory: true)
            .appendingPathComponent("worktrunk-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let archiveURL = tmpDir.appendingPathComponent(Release.assetName, isDirectory: false)

        do {
            let (downloaded, _) = try await URLSession.shared.download(from: Release.url)
            try FileManager.default.moveItem(at: downloaded, to: archiveURL)
        } catch {
            throw WorktrunkInstallerError.downloadFailed
        }

        let actual = try sha256Hex(url: archiveURL)
        guard actual == Release.sha256 else {
            throw WorktrunkInstallerError.integrityCheckFailed
        }

        let extractDir = tmpDir.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try extractTarXz(archiveURL: archiveURL, to: extractDir)

        let root = extractDir.appendingPathComponent("worktrunk-aarch64-apple-darwin", isDirectory: true)
        let wtSource = root.appendingPathComponent("wt", isDirectory: false)
        let gitWtSource = root.appendingPathComponent("git-wt", isDirectory: false)

        guard FileManager.default.fileExists(atPath: wtSource.path) else {
            throw WorktrunkInstallerError.missingBinary(name: "wt")
        }
        guard FileManager.default.fileExists(atPath: gitWtSource.path) else {
            throw WorktrunkInstallerError.missingBinary(name: "git-wt")
        }

        try replaceFile(source: wtSource, dest: wtDest)
        try replaceFile(source: gitWtSource, dest: gitWtDest)

        try makeExecutable(url: wtDest)
        try makeExecutable(url: gitWtDest)
        _ = try? removeQuarantine(url: wtDest)
        _ = try? removeQuarantine(url: gitWtDest)
    }

    private static func isSupportedArchitecture() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    private static func sha256Hex(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func extractTarXz(archiveURL: URL, to dir: URL) throws {
        let (exitCode, stderr) = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            args: ["-xJf", archiveURL.path, "-C", dir.path]
        )
        guard exitCode == 0 else {
            throw WorktrunkInstallerError.extractFailed(stderr: stderr)
        }
    }

    private static func replaceFile(source: URL, dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            throw WorktrunkInstallerError.installFailed(message: "Failed to install Worktrunk to \(dest.path).")
        }
    }

    private static func makeExecutable(url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func removeQuarantine(url: URL) throws {
        _ = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            args: ["-d", "com.apple.quarantine", url.path]
        )
    }

    private static func runProcess(executable: URL, args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args

        let stdinPipe = Pipe()
        stdinPipe.fileHandleForWriting.closeFile()
        process.standardInput = stdinPipe

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, stderr)
    }
}

