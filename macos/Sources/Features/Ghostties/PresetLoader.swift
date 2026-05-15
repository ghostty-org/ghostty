import Foundation
import CryptoKit
import OSLog

/// Loads agent presets from `~/.ghostties/presets/` as `.md` files with YAML frontmatter.
///
/// Each preset file has the format:
/// ```
/// ---
/// name: Code Reviewer
/// description: Reviews code for bugs and security issues
/// command: claude
/// model: sonnet
/// permissionMode: plan
/// icon: magnifyingglass
/// access: read-only
/// allowedTools:
///   - Read
///   - Grep
/// ---
///
/// System prompt body goes here...
/// ```
///
/// On first launch, bundled presets are seeded to the presets directory.
/// Community presets can be added by dropping `.md` files in the folder.
struct PresetLoader {
    static let presetsDirectoryPath = ("~/.ghostties/presets" as NSString).expandingTildeInPath

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ghostties",
        category: "PresetLoader"
    )

    // MARK: - Public API

    /// Current seed version. Bump this when bundled presets change to trigger re-seeding.
    static let seedVersion = 1

    /// Seed bundled presets to `~/.ghostties/presets/` using versioned seeding.
    ///
    /// Checks a `.seed-version` marker file to determine if seeding is needed.
    /// Only copies bundled files that don't already exist (additive, never overwrites user edits).
    static func seedIfNeeded() {
        let signpostState = Perf.signposter.beginInterval("presets.seed")
        defer { Perf.signposter.endInterval("presets.seed", signpostState) }
        let fm = FileManager.default
        let dirPath = presetsDirectoryPath
        let versionFilePath = (dirPath as NSString).appendingPathComponent(".seed-version")

        // Check the current seed version.
        let currentVersion: Int
        if let versionData = fm.contents(atPath: versionFilePath),
           let versionString = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let version = Int(versionString) {
            currentVersion = version
        } else {
            currentVersion = 0
        }

        // Skip if already at or above the current seed version.
        guard currentVersion < seedVersion else { return }

        // Create the directory if it doesn't exist.
        if !fm.fileExists(atPath: dirPath) {
            do {
                try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: [
                    .posixPermissions: 0o700,
                ])
            } catch {
                logger.error("Failed to create presets directory: \(error.localizedDescription)")
                return
            }
        }

        // Copy bundled .md files from app Resources/Presets into the user directory.
        // Only copy files that don't already exist — never overwrite user edits.
        if let bundledURLs = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "Presets") {
            for url in bundledURLs {
                let destPath = (dirPath as NSString).appendingPathComponent(url.lastPathComponent)
                if !fm.fileExists(atPath: destPath) {
                    do {
                        try fm.copyItem(at: url, to: URL(fileURLWithPath: destPath))
                    } catch {
                        logger.error("Failed to copy preset \(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        } else {
            logger.warning("No bundled preset files found in app bundle")
        }

        // Write the new seed version marker.
        do {
            try "\(seedVersion)".write(toFile: versionFilePath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to write seed version marker: \(error.localizedDescription)")
        }
    }

    /// Load all preset `.md` files from `~/.ghostties/presets/`.
    ///
    /// Returns an array of `AgentTemplate` objects with `isDefault: true` and `isGlobal: true`.
    /// Templates have deterministic UUIDs generated from the filename so IDs persist across launches.
    static func loadPresets() -> [AgentTemplate] {
        let signpostState = Perf.signposter.beginInterval("presets.load")
        defer { Perf.signposter.endInterval("presets.load", signpostState) }
        let fm = FileManager.default
        let dirPath = presetsDirectoryPath

        // Verify path is a real directory (not a symlink to an attacker-controlled location).
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { return [] }
        let attrs = try? fm.attributesOfItem(atPath: dirPath)
        if let fileType = attrs?[.type] as? FileAttributeType, fileType == .typeSymbolicLink {
            logger.warning("Presets directory is a symlink — refusing to load")
            return []
        }

        do {
            let files = try fm.contentsOfDirectory(atPath: dirPath)
            return files
                .filter { $0.hasSuffix(".md") }
                .sorted()
                .compactMap { filename in
                    let filePath = (dirPath as NSString).appendingPathComponent(filename)
                    let url = URL(fileURLWithPath: filePath)
                    return parsePreset(at: url, filename: filename)
                }
        } catch {
            logger.error("Failed to read presets directory: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Parsing

    /// Parse a single `.md` preset file into an `AgentTemplate`.
    ///
    /// Returns nil if the file can't be read or has invalid frontmatter.
    static func parsePreset(at url: URL, filename: String) -> AgentTemplate? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            logger.warning("Failed to read preset file: \(url.path)")
            return nil
        }

        // Split on "---" boundaries.
        // Expected format: "---\n<frontmatter>\n---\n<body>"
        // The content may or may not start with "---".
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            logger.warning("Preset file missing frontmatter delimiter: \(filename)")
            return nil
        }

        // Remove the leading "---" and find the closing "---"
        let afterFirstDelimiter = String(trimmed.dropFirst(3))
        guard let closingRange = afterFirstDelimiter.range(of: "\n---") else {
            logger.warning("Preset file missing closing frontmatter delimiter: \(filename)")
            return nil
        }

        let frontmatterText = String(afterFirstDelimiter[afterFirstDelimiter.startIndex..<closingRange.lowerBound])
        let bodyText = String(afterFirstDelimiter[closingRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse frontmatter key-value pairs.
        let frontmatter = parseFrontmatter(frontmatterText)

        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            logger.warning("Preset file missing required 'name' field: \(filename)")
            return nil
        }

        // Generate a deterministic UUID from the filename.
        let stableId = deterministicUUID(from: filename)

        // Extract values from frontmatter.
        let description = frontmatter["description"] as? String
        let command = frontmatter["command"] as? String
        let model = frontmatter["model"] as? String

        // Validate the command field contains no whitespace or shell metacharacters.
        if let command = command {
            let invalidChars = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ";&|`$(){}"))
            if command.unicodeScalars.contains(where: { invalidChars.contains($0) }) {
                logger.warning("Rejecting preset with invalid command '\(command)': \(filename)")
                return nil
            }
        }
        let permissionMode = frontmatter["permissionMode"] as? String
        let effort = frontmatter["effort"] as? String
        let icon = frontmatter["icon"] as? String
        let access = frontmatter["access"] as? String
        let allowedTools = frontmatter["allowedTools"] as? [String]

        // Determine the template kind from the command.
        let kind: AgentTemplate.Kind
        switch command {
        case nil: kind = .shell
        case "claude": kind = .claudeCode
        default: kind = .custom
        }

        // Build AgentConfig if there's any agent-related config.
        let agentConfig: AgentTemplate.AgentConfig?
        if model != nil || permissionMode != nil || effort != nil || allowedTools != nil || !bodyText.isEmpty {
            agentConfig = AgentTemplate.AgentConfig(
                systemPrompt: bodyText.isEmpty ? nil : bodyText,
                model: model,
                permissionMode: permissionMode,
                effort: effort,
                allowedTools: allowedTools
            )
        } else {
            agentConfig = nil
        }

        return AgentTemplate(
            id: stableId,
            name: name,
            kind: kind,
            command: command,
            isDefault: true,
            isGlobal: true,
            agent: agentConfig,
            templateDescription: description,
            icon: icon,
            accessLabel: access
        )
    }

    /// Parse YAML-like frontmatter into a dictionary.
    ///
    /// Handles simple `key: value` pairs and list values in both inline `[a, b]`
    /// and multi-line `- item` syntax.
    static func parseFrontmatter(_ text: String) -> [String: Any] {
        var result: [String: Any] = [:]
        let lines = text.components(separatedBy: .newlines)

        var currentListKey: String?
        var currentList: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Check if this is a list item (starts with "- ")
            if trimmedLine.hasPrefix("- "), let key = currentListKey {
                let value = String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    currentList.append(value)
                    result[key] = currentList
                }
                continue
            }

            // If we were collecting a list and this line isn't a list item, finalize.
            if currentListKey != nil {
                currentListKey = nil
                currentList = []
            }

            // Skip empty lines.
            guard !trimmedLine.isEmpty else { continue }

            // Split on first colon.
            guard let colonIndex = trimmedLine.firstIndex(of: ":") else { continue }

            let key = String(trimmedLine[trimmedLine.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmedLine[trimmedLine.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            guard !key.isEmpty else { continue }

            if rawValue.isEmpty {
                // Value is on subsequent lines as a list.
                currentListKey = key
                currentList = []
            } else if rawValue.hasPrefix("[") && rawValue.hasSuffix("]") {
                // Inline list: [Read, Grep, Glob]
                let inner = String(rawValue.dropFirst().dropLast())
                let items = inner.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                result[key] = items
            } else {
                result[key] = rawValue
            }
        }

        return result
    }

    /// Generate a deterministic UUID from a string using SHA-256.
    ///
    /// Uses the first 16 bytes of the SHA-256 hash, with version/variant bits set
    /// for a UUID v5-like result. The same filename always produces the same UUID.
    static func deterministicUUID(from input: String) -> UUID {
        let namespace = "com.ghostties.presets"
        let combined = "\(namespace):\(input)"
        let hash = SHA256.hash(data: Data(combined.utf8))
        var bytes = Array(hash.prefix(16))

        // Set version to 5 (name-based SHA).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // Set variant to RFC 4122.
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

}
