import AppKit
import Foundation

/// The editor-file protocol is shared by built-in and user-defined agents.
/// Only an explicit, short-lived request copies a draft; other invocations
/// delegate to the original editor. The agent's file is never modified.
@MainActor
final class QuickInputDraftBridge {
    static let shared = QuickInputDraftBridge()
    private let temporaryDirectory: URL
    private let applicationSupportRoot: URL?
    private let homeDirectory: URL?
    private var installedDirectories: Set<URL> = []
    private var configuredSurfaces: [UUID: URL] = [:]
    private let pythonExecutable: () -> String?

    init(
        applicationSupportRoot: URL? = nil,
        homeDirectory: URL? = nil,
        temporaryDirectory: URL? = nil,
        pythonExecutable: @escaping () -> String? = {
            LocalPythonInterpreter.cached()?.executablePath
        }
    ) {
        self.applicationSupportRoot = applicationSupportRoot
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-quick-input-\(UUID().uuidString)", isDirectory: true)
        self.pythonExecutable = pythonExecutable
    }

    static func keys(_ value: String) -> [Ghostty.Input.KeyEvent]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var result: [Ghostty.Input.KeyEvent] = []
        for (index, part) in parts.enumerated() {
            let value = part.trimmingCharacters(in: .whitespaces).lowercased()
            if index > 0, value.range(of: "^[a-z]$", options: .regularExpression) != nil,
               let key = Ghostty.Input.Key(rawValue: value) {
                result.append(.init(key: key, text: value,
                                    unshiftedCodepoint: value.unicodeScalars.first?.value ?? 0))
                continue
            }
            guard let shortcut = OMGKeyboardShortcut(storageValue: value),
                  !shortcut.modifiers.contains(.command),
                  shortcut.key.range(of: "^[a-z0-9]$", options: .regularExpression) != nil,
                  let key = Ghostty.Input.Key(rawValue: shortcut.key.first?.isNumber == true
                                        ? "digit\(shortcut.key)" : shortcut.key) else { return nil }
            var mods: Ghostty.Input.Mods = []
            if shortcut.modifiers.contains(.control) { mods.insert(.ctrl) }
            if shortcut.modifiers.contains(.option) { mods.insert(.alt) }
            if shortcut.modifiers.contains(.shift) { mods.insert(.shift) }
            result.append(.init(key: key, mods: mods,
                                unshiftedCodepoint: shortcut.key.unicodeScalars.first?.value ?? 0))
        }
        return result
    }

    static func shortcut(setting: String, agent: SupportedAgent?) -> String {
        guard setting == "auto" else { return setting }
        return agent == .opencode ? "control+x,e" : "control+g"
    }

    /// Shared by local and SSH imports: custom chords work without a known
    /// agent, while auto mode must never invoke an editor at a shell prompt.
    static func importKeys(
        setting: String, agent: SupportedAgent?, hasAgentActivity: Bool
    ) -> [Ghostty.Input.KeyEvent]? {
        guard setting != "auto" || agent != nil || hasAgentActivity else { return nil }
        return keys(shortcut(setting: setting, agent: agent))
    }

    static func canImportDraft(
        isReadOnly: Bool,
        isRuntime: Bool,
        runtimeState: SessionRuntimeConnectionState?,
        isSSHConnecting: Bool,
        hasPendingSSHRecovery: Bool
    ) -> Bool {
        !isReadOnly && !isSSHConnecting && !hasPendingSSHRecovery
            && (!isRuntime || runtimeState == .ready)
    }

    func configure(
        _ configuration: inout Ghostty.SurfaceConfiguration,
        surfaceID: UUID,
        runtimeDescriptor: SessionRuntimeDescriptor? = nil
    ) {
        if let runtimeDescriptor, !runtimeDescriptor.isLocal {
            for key in ["OMG_QUICK_INPUT_ORIGINAL_EDITOR", "OMG_QUICK_INPUT_BRIDGE", "OMG_QUICK_INPUT_SURFACE"] {
                configuration.environmentVariables[key] = ""
            }
            configuredSurfaces.removeValue(forKey: surfaceID)
            return
        }
        let setting = OhMyGhosttySettings.shared.quickInputImportShortcut
        guard Self.keys(Self.shortcut(setting: setting, agent: nil)) != nil else { return }
        let directory: URL
        if let runtimeDescriptor {
            guard runtimeDescriptor.isLocal,
                  let stableDirectory = try? SessionRuntimeBridgeStorage.directory(
                    for: runtimeDescriptor,
                    pane: surfaceID,
                    purpose: "quick-input",
                    applicationSupportRoot: applicationSupportRoot,
                    homeDirectory: homeDirectory
                  ) else {
                configuredSurfaces.removeValue(forKey: surfaceID)
                return
            }
            directory = stableDirectory
        } else {
            directory = temporaryDirectory
        }
        do {
            if !installedDirectories.contains(directory) {
                guard let pythonExecutable = pythonExecutable() else { return }
                _ = try Self.installHelper(in: directory, pythonExecutable: pythonExecutable)
                installedDirectories.insert(directory)
            }
            let inherited = ProcessInfo.processInfo.environment
            let editor = configuration.environmentVariables["OMG_QUICK_INPUT_ORIGINAL_EDITOR"]
                ?? configuration.environmentVariables["VISUAL"] ?? configuration.environmentVariables["EDITOR"]
                ?? inherited["VISUAL"] ?? inherited["EDITOR"] ?? "nano"
            configuration.environmentVariables["OMG_QUICK_INPUT_ORIGINAL_EDITOR"] = editor
            configuration.environmentVariables["OMG_QUICK_INPUT_BRIDGE"] = directory.path
            configuration.environmentVariables["OMG_QUICK_INPUT_SURFACE"] = surfaceID.uuidString
            configuration.environmentVariables["VISUAL"] = directory.appendingPathComponent("editor").path
            configuration.environmentVariables["EDITOR"] = directory.appendingPathComponent("editor").path
            configuredSurfaces[surfaceID] = directory
        } catch {
            // Leave the terminal's editor environment untouched if installation fails.
        }
    }

    struct Request {
        let id: String
        let input: URL
        let output: URL
    }

    func begin(surfaceID: UUID) throws -> Request {
        guard let directory = configuredSurfaces[surfaceID],
              installedDirectories.contains(directory) else { throw CocoaError(.fileNoSuchFile) }
        let id = UUID().uuidString
        let input = directory.appendingPathComponent("\(surfaceID.uuidString).request")
        let output = directory.appendingPathComponent("\(id).response")
        try? FileManager.default.removeItem(at: input)
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "expires": Date().timeIntervalSince1970 + 4,
        ])
        try data.write(to: input, options: .atomic)
        return Request(id: id, input: input, output: output)
    }

    func receive(_ request: Request) throws -> String? {
        guard FileManager.default.fileExists(atPath: request.output.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: request.output.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else {
            throw CocoaError(.fileReadTooLarge)
        }
        let data = try Data(contentsOf: request.output)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    func finish(_ request: Request) {
        try? FileManager.default.removeItem(at: request.input)
        try? FileManager.default.removeItem(at: request.output)
    }

    static func installHelper(in directory: URL, pythonExecutable: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent("editor.py")
        try SessionRuntimeBridgeStorage.writePrivateFile(at: script, data: Data(helper.utf8), permissions: 0o600)
        // A shell entry point handles spaces in the interpreter path; a shebang cannot.
        let launcher = """
        #!/bin/sh
        unset SDKROOT
        if [ -n "${DEVELOPER_DIR-}" ] && [ ! -d "$DEVELOPER_DIR" ]; then unset DEVELOPER_DIR; fi
        exec \(Ghostty.Shell.quote(pythonExecutable)) \(Ghostty.Shell.quote(script.path)) "$@"

        """
        let executable = directory.appendingPathComponent("editor")
        try SessionRuntimeBridgeStorage.writePrivateFile(at: executable, data: Data(launcher.utf8), permissions: 0o700)
        return executable
    }

    // Python is also used by the bundled agent integrations. No third-party module is required.
    static let helper = #"""
    import json
    import os
    import sys
    import time
    import uuid
    from pathlib import Path

    def main():
        root = Path(os.environ["OMG_QUICK_INPUT_BRIDGE"])
        surface = str(uuid.UUID(os.environ["OMG_QUICK_INPUT_SURFACE"])).upper()
        request = root / (surface + ".request")
        try:
            payload = json.loads(request.read_text())
            identifier = str(uuid.UUID(payload["id"])).upper()
            active = time.time() < float(payload["expires"])
        except (OSError, ValueError, KeyError, TypeError):
            active = False
        if not active:
            editor = os.environ.get("OMG_QUICK_INPUT_ORIGINAL_EDITOR", "nano")
            os.execv("/bin/sh", ["sh", "-c", 'exec ' + editor + ' "$@"', "omg-editor", *sys.argv[1:]])
        if len(sys.argv) != 2:
            raise ValueError("Expected one editor file")
        with open(sys.argv[1], "rb") as source:
            content = source.read(1048577)
        if len(content) > 1048576:
            raise ValueError("Draft exceeds 1 MiB")
        content.decode("utf-8")
        if b"\0" in content:
            raise ValueError("Draft contains a NUL character")
        temporary = root / (identifier + ".tmp")
        with open(temporary, "xb") as destination:
            destination.write(content)
        os.replace(temporary, root / (identifier + ".response"))
        # Returning the unchanged file preserves the agent's original input.

    try:
        main()
    except Exception as error:
        print("OMG Quick Input: " + str(error), file=sys.stderr)
        sys.exit(1)
    """#
}
