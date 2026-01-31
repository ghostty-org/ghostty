import AppKit
import Foundation
import os

/// Helper class for uploading images to remote hosts via SSH when pasting.
/// This enables pasting images from the local clipboard into remote SSH sessions
/// by automatically uploading the image and inserting the remote path.
final class SSHImagePaste {
    private static let logger = Logger(
        subsystem: "com.mitchellh.ghostty",
        category: "ssh-image-paste"
    )

    /// Result of attempting to upload an image for SSH paste
    enum UploadResult {
        /// Successfully uploaded, contains the remote path
        case success(remotePath: String)
        /// No SSH session detected or feature disabled
        case notInSSH
        /// Upload failed with error
        case failed(Error)
    }

    /// Attempts to find an active SSH ControlMaster socket.
    /// Looks in common locations: ~/.ssh/sockets/, ~/.ssh/, /tmp/
    /// Returns the path to the most recently modified socket, or nil if none found.
    static func findControlMasterSocket() -> String? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        // Common ControlMaster socket locations
        let searchPaths = [
            "\(homeDir)/.ssh/sockets",
            "\(homeDir)/.ssh",
            "/tmp"
        ]

        var candidates: [(path: String, modDate: Date)] = []

        for searchPath in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: searchPath) else {
                continue
            }

            for item in contents {
                let fullPath = "\(searchPath)/\(item)"

                // Check if it's a socket file
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else {
                    continue
                }

                // Get file attributes to check if it's a socket
                guard let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                      let fileType = attrs[.type] as? FileAttributeType,
                      fileType == .typeSocket else {
                    continue
                }

                // Get modification date for sorting
                if let modDate = attrs[.modificationDate] as? Date {
                    candidates.append((path: fullPath, modDate: modDate))
                }
            }
        }

        // Return most recently modified socket
        return candidates
            .sorted { $0.modDate > $1.modDate }
            .first?.path
    }

    /// Extracts host information from a ControlMaster socket path.
    /// Common formats: user@host:port, host, etc.
    static func parseHostFromSocket(_ socketPath: String) -> String? {
        let filename = (socketPath as NSString).lastPathComponent

        // Try to extract host from common socket naming patterns
        // Pattern: user@host:port or user@host or just host
        if let atIndex = filename.firstIndex(of: "@") {
            let afterAt = filename[filename.index(after: atIndex)...]
            if let colonIndex = afterAt.firstIndex(of: ":") {
                return String(afterAt[..<colonIndex])
            }
            // Remove any trailing socket suffix
            let host = String(afterAt).replacingOccurrences(of: ".sock", with: "")
            return host.isEmpty ? nil : host
        }

        return nil
    }

    /// Uploads image data to a remote host via SCP using an existing ControlMaster socket.
    /// - Parameters:
    ///   - imageData: PNG image data to upload
    ///   - socketPath: Path to the SSH ControlMaster socket
    ///   - remotePath: Directory on remote host to upload to (default: /tmp)
    /// - Returns: The remote file path if successful, nil otherwise
    static func uploadImage(
        _ imageData: Data,
        viaSocket socketPath: String,
        remotePath: String = "/tmp"
    ) -> String? {
        let fileManager = FileManager.default

        // Generate unique filename
        let uuid = UUID().uuidString.prefix(8)
        let filename = "ghostty-paste-\(uuid).png"
        let localTempPath = "/tmp/\(filename)"
        let remoteFilePath = "\(remotePath)/\(filename)"

        // Write image to temp file
        guard fileManager.createFile(atPath: localTempPath, contents: imageData) else {
            logger.error("Failed to create temp file at \(localTempPath)")
            return nil
        }

        defer {
            try? fileManager.removeItem(atPath: localTempPath)
        }

        // Extract host from socket path
        guard let host = parseHostFromSocket(socketPath) else {
            logger.error("Could not parse host from socket path: \(socketPath)")
            return nil
        }

        // Build scp command using ControlMaster
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-o", "ControlPath=\(socketPath)",
            "-o", "ControlMaster=no",
            localTempPath,
            "\(host):\(remoteFilePath)"
        ]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                logger.info("Successfully uploaded image to \(host):\(remoteFilePath)")
                return remoteFilePath
            } else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "unknown error"
                logger.error("SCP failed with status \(process.terminationStatus): \(errorString)")
                return nil
            }
        } catch {
            logger.error("Failed to run scp: \(error.localizedDescription)")
            return nil
        }
    }

    /// Attempts to upload clipboard image data for SSH paste.
    /// - Parameters:
    ///   - imageData: PNG image data from clipboard
    ///   - configuredHost: Optional explicitly configured host (overrides auto-detection)
    ///   - configuredPath: Remote path for uploads (default: /tmp)
    /// - Returns: UploadResult indicating success, not-in-ssh, or failure
    static func attemptUpload(
        imageData: Data,
        configuredHost: String? = nil,
        configuredPath: String = "/tmp"
    ) -> UploadResult {
        // If host is explicitly configured, try direct upload
        if let host = configuredHost, !host.isEmpty {
            // Try to find a socket for this specific host
            if let socket = findSocketForHost(host) {
                if let remotePath = uploadImage(imageData, viaSocket: socket, remotePath: configuredPath) {
                    return .success(remotePath: remotePath)
                }
            }

            // Fall back to direct SSH (might prompt for password)
            if let remotePath = uploadImageDirect(imageData, toHost: host, remotePath: configuredPath) {
                return .success(remotePath: remotePath)
            }

            return .failed(NSError(domain: "SSHImagePaste", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Failed to upload to configured host: \(host)"]))
        }

        // Auto-detect: find most recent ControlMaster socket
        guard let socket = findControlMasterSocket() else {
            logger.info("No ControlMaster socket found, not in SSH session")
            return .notInSSH
        }

        if let remotePath = uploadImage(imageData, viaSocket: socket, remotePath: configuredPath) {
            return .success(remotePath: remotePath)
        }

        return .failed(NSError(domain: "SSHImagePaste", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "Failed to upload via detected socket"]))
    }

    /// Finds a ControlMaster socket for a specific host
    private static func findSocketForHost(_ host: String) -> String? {
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser.path

        let searchPaths = [
            "\(homeDir)/.ssh/sockets",
            "\(homeDir)/.ssh",
            "/tmp"
        ]

        for searchPath in searchPaths {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: searchPath) else {
                continue
            }

            for item in contents {
                if item.contains(host) {
                    let fullPath = "\(searchPath)/\(item)"
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory),
                       let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
                       let fileType = attrs[.type] as? FileAttributeType,
                       fileType == .typeSocket {
                        return fullPath
                    }
                }
            }
        }

        return nil
    }

    /// Uploads image directly via scp (may prompt for password if no key auth)
    private static func uploadImageDirect(
        _ imageData: Data,
        toHost host: String,
        remotePath: String
    ) -> String? {
        let fileManager = FileManager.default

        let uuid = UUID().uuidString.prefix(8)
        let filename = "ghostty-paste-\(uuid).png"
        let localTempPath = "/tmp/\(filename)"
        let remoteFilePath = "\(remotePath)/\(filename)"

        guard fileManager.createFile(atPath: localTempPath, contents: imageData) else {
            return nil
        }

        defer {
            try? fileManager.removeItem(atPath: localTempPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-o", "BatchMode=yes",  // Don't prompt for password
            "-o", "StrictHostKeyChecking=no",
            localTempPath,
            "\(host):\(remoteFilePath)"
        ]

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return remoteFilePath
            }
        } catch {
            logger.error("Direct SCP failed: \(error.localizedDescription)")
        }

        return nil
    }
}
