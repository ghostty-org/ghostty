import Darwin
import Foundation
import GhosttyKit
import OSLog

/// Borrowed C strings remain alive throughout the synchronous, locked VT export.
private final class ShellSnapshotExportKeys {
    let keys: [UInt64: UnsafeMutablePointer<CChar>]

    init(commands: [InspectorHistoryItem]) {
        var keys: [UInt64: UnsafeMutablePointer<CChar>] = [:]
        for command in commands {
            guard case .command(_, let id, _) = command.location else { continue }
            let occurrence = command.replayKey ?? command.id
            guard occurrence.utf8.count <= 256, !occurrence.isEmpty,
                  occurrence.utf8.allSatisfy({ byte in
                      (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) || byte == 45 || byte == 58
                  }), let pointer = strdup(occurrence) else { continue }
            if let old = keys.updateValue(pointer, forKey: id) { free(old) }
        }
        self.keys = keys
    }

    deinit { for pointer in keys.values { free(pointer) } }
}

/// Bounded scrollback and OSC-anchored command metadata for restored local Shell panes.
/// Restored PTYs are new processes; this store never attempts to resume a job.
@MainActor
enum ShellScrollbackRestoreStore {
    static let environmentKey = "OH_MY_GHOSTTY_RESTORE_SCROLLBACK_FILE"
    static let maximumBytes = 2 * 1_024 * 1_024
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private static var restoredSurfaceIDs = Set<UUID>()
    private static var savedCommandCache: [UUID: CommandArchive] = [:]

    struct SavedCommand: Codable, Equatable {
        let text: String
        let timestamp: Date?
        let sourceLabel: String?
        /// Host-owned occurrence identity, never a text-search key.
        let occurrenceID: String?

        init(text: String, timestamp: Date?, sourceLabel: String? = nil,
             occurrenceID: String? = nil) {
            self.text = text
            self.timestamp = timestamp
            self.sourceLabel = sourceLabel
            self.occurrenceID = occurrenceID
        }
    }

    private struct CommandArchive: Codable {
        let version: Int
        let surfaceID: UUID
        let commands: [SavedCommand]
        let allowsAnchorReconciliation: Bool?
        /// Current core entries in export order. Absent in v1/v2 snapshots.
        let replayCommands: [SavedCommand]?
    }
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "oh-my-ghostty",
                                       category: "shell-scrollback-restore")

    static func directory(baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()) -> URL {
        baseURL.appendingPathComponent("shell-scrollback", isDirectory: true)
    }

    /// Leaving full-session mode must not leave a stale VT file that could be
    /// replayed if the user later changes settings externally between launches.
    static func discardPendingSnapshots(
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) {
        let root = directory(baseURL: baseURL)
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: nil
              ) else { return }
        for file in files where ["vt", "json", "partial"].contains(file.pathExtension) {
            guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func captureOpenSurfaces(
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) {
        captureOpenSurfaces(controllers: TerminalController.all, baseURL: baseURL)
    }

    static func captureOpenSurfaces(
        controllers: [TerminalController],
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) {
        guard OhMyGhosttySettings.shared.startupMode.restoresSessions else { return }
        let root = directory(baseURL: baseURL)
        guard secureDirectory(root) else { return }
        removeExpired(in: root)

        for controller in controllers where controller.window?.isRestorable == true {
            for view in controller.surfaceTree {
                guard view.agentResumeDescriptor == nil,
                      controller.agentActivity(for: view) == nil,
                      let context = controller.paneSessionContext(for: view),
                      let surface = view.surface else { continue }
                // A plain SSH transport can be restored only when it has an
                // exact replay descriptor. Otherwise the pane would reopen as
                // a local Shell while displaying remote output as live state.
                if case .sshConnecting = context.state { continue }
                if case .sshReady = context.state, view.sshResumeDescriptor == nil { continue }
                let commands = TerminalHistoryService.shared.commands(for: view.id)
                let keys = ShellSnapshotExportKeys(commands: commands)
                if !save(surfaceID: view.id, baseURL: baseURL, commands: commands,
                         export: { temporary in
                    temporary.path.withCString { path in
                        ghostty_surface_omg_export_scrollback_vt(
                            surface, path, maximumBytes - 256,
                            Unmanaged.passUnretained(keys).toOpaque()
                        ) { context, id in
                            guard let context else { return nil }
                            let keys = Unmanaged<ShellSnapshotExportKeys>.fromOpaque(context).takeUnretainedValue()
                            return keys.keys[id].map { UnsafePointer($0) }
                        }
                    }
                }) {
                    logger.warning("failed to capture shell scrollback for surface \(view.id.uuidString, privacy: .public)")
                }
            }
        }
    }

    @discardableResult
    static func save(
        surfaceID: UUID,
        baseURL: URL,
        commands: [InspectorHistoryItem] = [],
        export: (URL) -> Bool
    ) -> Bool {
        let root = directory(baseURL: baseURL)
        guard secureDirectory(root) else { return false }
        let temporary = root.appendingPathComponent("\(UUID().uuidString).partial")
        let metadata = root.appendingPathComponent("\(UUID().uuidString).partial")
        let target = root.appendingPathComponent("\(surfaceID.uuidString).vt")
        let metadataTarget = root.appendingPathComponent("\(surfaceID.uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: metadata)
        }
        // A failed new capture must not replay an older snapshot for the same
        // restored UUID on the next launch.
        func invalidateOldCapture() {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: metadataTarget)
        }
        guard export(temporary), appendQuitMarker(to: temporary), validFile(temporary) else {
            invalidateOldCapture()
            return false
        }
        // Keep every exportable Pin's metadata, even when older read-only
        // rows (or changed clocks) sort ahead of it in the UI.
        let liveCommands = commands.filter { $0.location.isAvailable }
        guard liveCommands.count <= 100 else {
            invalidateOldCapture()
            return false
        }
        let retained = (liveCommands + commands.filter { !$0.location.isAvailable }
            .prefix(100 - liveCommands.count)).sorted {
                ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }
        let saved = retained.map { item in
            SavedCommand(text: item.text, timestamp: item.timestamp, sourceLabel: item.sourceLabel,
                         occurrenceID: item.replayKey ?? item.id)
        }
        // Export order comes from core execution IDs, never timestamps or
        // text. It includes the still-valid local and remote historical Pins.
        let replay = liveCommands.sorted { lhs, rhs in
            if case .command(_, let first, _) = lhs.location,
               case .command(_, let second, _) = rhs.location { return first < second }
            return false
        }.map { item in
            SavedCommand(text: item.text, timestamp: item.timestamp,
                         sourceLabel: item.sourceLabel, occurrenceID: item.replayKey ?? item.id)
        }
        let archive = CommandArchive(version: 4, surfaceID: surfaceID, commands: saved,
                                     allowsAnchorReconciliation: false,
                                     replayCommands: replay)
        guard let data = try? JSONEncoder().encode(archive),
              data.count <= maximumBytes,
              FileManager.default.createFile(atPath: metadata.path, contents: data,
                  attributes: [.posixPermissions: 0o600]), validFile(metadata) else {
            invalidateOldCapture()
            return false
        }
        guard rename(temporary.path, target.path) == 0 else {
            invalidateOldCapture()
            return false
        }
        guard rename(metadata.path, metadataTarget.path) == 0 else {
            invalidateOldCapture()
            return false
        }
        return true
    }

    static func sshReplayCommand(_ command: String, snapshot: URL?) -> String {
        guard let snapshot else { return command }
        let path = Ghostty.Shell.quote(snapshot.path)
        // Replay through the owning local PTY before starting the new SSH
        // transport. Never pass this path to the remote process/environment.
        let marker = "/usr/bin/printf '" +
            "\\033[0;2m\\r\\n  ──────  Session restored · %s  ──────\\033[0m\\r\\n' " +
            "\"$(/bin/date '+%Y-%m-%d %H:%M:%S')\""
        return "if [ -f \(path) ] && [ -r \(path) ]; then " +
            "/bin/cat -- \(path) 2>/dev/null; \(marker); " +
            "/bin/rm -f -- \(path) 2>/dev/null; fi; \(command)"
    }

    /// A restored Surface UUID is the only key. Do not accept a caller-supplied
    /// path, symlink, directory, oversized file, or stale snapshot.
    static func replayFile(
        for surfaceID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL(),
        now: Date = Date(),
        restoreEnabled: Bool? = nil
    ) -> URL? {
        guard restoreEnabled ?? OhMyGhosttySettings.shared.startupMode.restoresSessions else { return nil }
        let root = directory(baseURL: baseURL)
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return nil }
        let file = root.appendingPathComponent("\(surfaceID.uuidString).vt")
        guard validFile(file, now: now) else { return nil }
        restoredSurfaceIDs.insert(surfaceID)
        savedCommandCache.removeValue(forKey: surfaceID)
        return file
    }

    /// An old timestamp is attached only when the command text and occurrence
    /// order exactly match the replayed OSC 133 records on this same Surface.
    static func savedCommands(
        for surfaceID: UUID,
        baseURL: URL = OMGApplicationEnvironment.applicationSupportURL()
    ) -> [SavedCommand]? {
        guard restoredSurfaceIDs.contains(surfaceID) else { return nil }
        if let cached = savedCommandCache[surfaceID] { return cached.commands }
        let root = directory(baseURL: baseURL)
        // The shell removes the VT file only after replay. A missing shell
        // integration must never make later, coincidentally equal commands
        // inherit old timestamps or identities.
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "\(surfaceID.uuidString).vt").path) else { return nil }
        let file = root.appendingPathComponent("\(surfaceID.uuidString).json")
        guard validFile(file), let data = try? Data(contentsOf: file),
              let archive = try? JSONDecoder().decode(CommandArchive.self, from: data),
              (1...4).contains(archive.version), archive.surfaceID == surfaceID,
              archive.commands.count <= 100,
              archive.commands.allSatisfy({
                  $0.text.utf8.count <= 16_384 && ($0.occurrenceID?.utf8.count ?? 0) <= 256
              }),
              (archive.replayCommands?.count ?? 0) <= 100,
              archive.replayCommands?.allSatisfy({
                  $0.text.utf8.count <= 16_384 &&
                      ($0.occurrenceID?.utf8.count ?? 0) > 0 &&
                      ($0.occurrenceID?.utf8.count ?? 0) <= 256
              }) ?? true else { return nil }
        savedCommandCache[surfaceID] = archive
        return archive.commands
    }

    static func replayCommands(for surfaceID: UUID) -> [SavedCommand]? {
        guard let archive = savedCommandCache[surfaceID], archive.version >= 3,
              archive.allowsAnchorReconciliation == false else { return nil }
        return archive.replayCommands
    }

    static func allowsAnchorReconciliation(for surfaceID: UUID) -> Bool {
        savedCommandCache[surfaceID]?.allowsAnchorReconciliation ?? true
    }

    private static func appendQuitMarker(to file: URL) -> Bool {
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let marker = "\u{001B}]8;;\u{001B}\\\u{001B}[0;2m\r\n  ──────  Session ended · \(formatter.string(from: Date()))  ──────\u{001B}[0m\r\n"
            try handle.write(contentsOf: Data(marker.utf8))
            return true
        } catch {
            return false
        }
    }

    private static func validFile(_ file: URL, now: Date = Date()) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
            let size = values.fileSize, size > 0, size <= maximumBytes,
            let modified = values.contentModificationDate,
            now.timeIntervalSince(modified) >= -60,
            now.timeIntervalSince(modified) <= lifetime,
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
            let mode = attributes[.posixPermissions] as? NSNumber,
            mode.intValue & 0o077 == 0,
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner.uint32Value == geteuid() else { return false }
        return true
    }

    private static func secureDirectory(_ root: URL) -> Bool {
        let files = FileManager.default
        do {
            if !files.fileExists(atPath: root.path) {
                try files.createDirectory(at: root, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
            }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return false }
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            return true
        } catch {
            logger.error("unable to prepare scrollback directory: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func removeExpired(in root: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for file in files where ["vt", "json", "partial"].contains(file.pathExtension) {
            if file.pathExtension == "partial" || !validFile(file) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
