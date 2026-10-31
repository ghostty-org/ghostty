import Foundation

enum AgentStatusPlugin {
    @MainActor static var isEnabled: Bool {
        OhMyGhosttySettings.shared.agentStatusHooksEnabled
    }
}

enum LocalAgentProcessDetector {
    static func detect(in commandLines: String) -> SupportedAgent? {
        for line in commandLines.split(separator: "\n") {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let executable = tokens.first else { continue }
            if let agent = exactAgent(executable) { return agent }
            let basename = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
            if ["login", "env", "sh", "bash", "zsh", "fish", "python", "python3"].contains(basename),
               let agent = tokens.dropFirst().compactMap(exactAgent).last {
                return agent
            }
            if ["node", "bun", "deno"].contains(basename) {
                let runtimeArguments = tokens.dropFirst().prefix(4)
                    .map { $0.lowercased() }
                    .joined(separator: " ")
                if let agent = SupportedAgent.allCases.first(where: { candidate in
                    candidate.definition.process.runtimeMarkers.contains {
                        runtimeArguments.contains($0.lowercased())
                    }
                }) { return agent }
            }
        }
        return nil
    }

    private static func exactAgent(_ token: String) -> SupportedAgent? {
        let name = URL(fileURLWithPath: token).lastPathComponent.lowercased()
        return SupportedAgent.allCases.first { agent in
            agent.definition.process.executables.contains {
                $0.lowercased() == name
            }
        }
    }
}

/// Hermes' gateway owns hooks, while the terminal client owns the pane. Resolve
/// identity from a live client and its per-TTY breadcrumb before accepting events.
enum HermesPaneStatus {
    struct Snapshot: Decodable, Equatable, Sendable {
        let pgid: Int
        let conversation: String?
        let cwd: String?
        let state: String
        let revision: String
    }

    static func script(tty: String) throws -> String {
        let data = try JSONEncoder().encode(tty)
        let encoded = data.base64EncodedString()
        return probe + "\nprint(json.dumps(snapshot(json.loads(base64.b64decode(\"\(encoded)\")))))\n"
    }

    static let reporter = #"""
import hashlib, json, os, re, stat, sys, tempfile, time
from pathlib import Path

def report():
    state = sys.argv[1] if len(sys.argv) == 2 else ""
    if state not in {"idle", "working", "done", "error", "needsAttention", "end"}:
        return
    payload = json.loads(sys.stdin.read(65537))
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", sid):
        return
    if sid.startswith("test-"):
        return
    directory = Path.home() / ".config/oh-my-ghostty/agent-status/hermes"
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid != os.getuid():
        return
    directory.chmod(0o700)
    key = hashlib.sha256(sid.encode()).hexdigest()
    fd, temporary = tempfile.mkstemp(prefix=".event-", dir=directory)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as stream:
            json.dump({"session_id": sid, "state": state, "time": time.time()}, stream)
        os.replace(temporary, directory / (key + ".json"))
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

try:
    report()
except (ValueError, OSError, TypeError):
    pass
"""#

    // Executed locally or through the existing bounded SSH transport. Never infer
    // ownership from cwd or from the latest event on the host (both are ambiguous).
    static let probe = #"""
import base64, hashlib, json, os, re, stat, subprocess, time
from pathlib import Path

def read_object(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > 4096:
        raise ValueError("invalid metadata file")
    with path.open() as stream:
        obj = json.load(stream)
    if not isinstance(obj, dict): raise ValueError("invalid object")
    return obj

def elapsed_seconds(text):
    days, _, rest = text.rpartition("-")
    values = [int(part) for part in rest.split(":")]
    seconds = sum(value * (60 ** index) for index, value in enumerate(reversed(values)))
    return seconds + (int(days) * 86400 if days else 0)

def snapshot(tty):
    try:
        if not re.fullmatch(r"/dev/(?:ttys[0-9]+|pts/[0-9]+)", tty): return {}
        result = subprocess.run(["ps", "-t", tty[5:], "-o", "pid=,pgid=,stat=,args="],
                                capture_output=True, text=True, timeout=2)
        candidates = []
        for line in result.stdout.splitlines():
            fields = line.split(None, 3)
            if len(fields) != 4: continue
            pid, pgid, flags, command = fields
            if "+" not in flags: continue
            # Match the actual TUI entry, never an arbitrary mention of Hermes in
            # a Python -c string, a shell argument, or a background gateway process.
            argv = command.split()
            if not argv: continue
            runtime = Path(argv[0]).name.lower()
            node_client = runtime in {"node", "bun"} and any(
                re.search(r"/(?:ui-tui/(?:dist|src)|hermes_cli/tui_dist)/entry\.(?:js|tsx?)$", arg)
                and "hermes" in arg.lower() for arg in argv[1:6])
            python_client = (runtime.startswith("python") and "/.hermes/" in argv[0]
                             and "from hermes_cli.main import main" in command
                             and "sys.exit(main())" in command)
            if not (node_client or python_client): continue
            candidates.append((int(pid), int(pgid)))
        groups = {pgid for _, pgid in candidates}
        if len(groups) != 1: return {}
        pid, pgid = candidates[0]
        age = subprocess.run(["ps", "-p", str(pid), "-o", "etime="],
                             capture_output=True, text=True, timeout=2).stdout.strip()
        started = time.time() - elapsed_seconds(age)
        output = {"pgid": pgid, "state": "idle", "revision": "client:" + str(pid)}
        home = Path(os.environ.get("HERMES_HOME") or (Path.home() / ".hermes"))
        key = "tty-" + re.sub(r"[^A-Za-z0-9._-]", "-", tty.strip("/"))[:120]
        crumb = read_object(home / "terminal-sessions" / key)
        sid, timestamp = crumb.get("session_id"), crumb.get("ts")
        if (not isinstance(sid, str) or sid.startswith("test-")
            or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", sid)
            or not isinstance(timestamp, (int, float)) or timestamp < started - 5):
            return output
        output["conversation"] = sid
        cwd = crumb.get("cwd")
        if isinstance(cwd, str) and cwd.startswith("/") and len(cwd) <= 4096 and "\0" not in cwd:
            output["cwd"] = cwd
        output["revision"] += ":" + sid
        status_path = Path.home() / ".config/oh-my-ghostty/agent-status/hermes"
        event = read_object(status_path / (hashlib.sha256(sid.encode()).hexdigest() + ".json"))
        stamp = event.get("time")
        state = event.get("state")
        if (event.get("session_id") == sid and isinstance(stamp, (int, float))
            and started - 5 <= stamp <= time.time() + 5
            and state in {"idle", "working", "done", "error", "needsAttention"}):
            output["state"] = state
            output["revision"] += ":" + str(stamp)
        return output
    except (ValueError, OSError, TypeError, subprocess.SubprocessError):
        return locals().get("output", {})
"""#
}

enum AgentHookInstallerError: LocalizedError {
    case invalidConfiguration
    case invalidHooks(String)
    case invalidDetectorMarker(String)
    case duplicateCodexHooksSetting

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The existing agent configuration is not a JSON object."
        case .invalidHooks(let event):
            "The existing hooks configuration for \(event) is not an array."
        case .invalidDetectorMarker(let agent):
            "The existing detector marker for \(agent) is not owned by OMG."
        case .duplicateCodexHooksSetting:
            "Codex config.toml contains more than one hooks setting in [features]."
        }
    }
}

enum AgentHookInstallationState: String, Codable, Equatable, Sendable {
    case missing
    case updateAvailable
    case current

    var isInstalled: Bool { self != .missing }
}

enum AgentHookRemoteAction: String {
    case status
    case install
    case remove
}

struct AgentHookInstaller {
    static let marker = "_omg_agent_status"
    static let hookVersion = 11
    static let detectorMarkerVersion = 1
    static let didChangeNotification = Notification.Name(
        "com.oh-my-ghostty.agentIntegrationDidChange"
    )
    static let changedAgentUserInfoKey = "agent"

    private struct DetectorMarker: Codable, Equatable {
        let owner: String
        let version: Int
        let agent: String
    }

    let homeURL: URL

    init(homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeURL = homeURL
    }

    func isInstalled(_ agent: SupportedAgent) -> Bool {
        // A stale YAML integration is still installed. Runtime detection must
        // not revalidate every event/helper version just to establish presence.
        if agent.definition.hook.kind == .yaml { return Self.yamlBlockPresent(at: hookURL(for: agent)) }
        return installationState(agent).isInstalled
    }

    /// Whether the user explicitly removed this Agent's detector integration.
    ///
    /// Automatic adoption consults this so a removed detector is never silently
    /// reinstalled; an explicit Install clears the record and re-enables it.
    func isDetectorRemovedByUser(_ agent: SupportedAgent) -> Bool {
        Self.supportsDetector(for: agent) && hasTombstone(agent)
    }

    /// Reconciles detector-only Agent markers on every launch.
    ///
    /// Detector-only agents (`hook.kind == .none`) were implicitly enabled before
    /// explicit Install/Remove controls existed. A single global sentinel used to
    /// record that one-time migration and then short-circuit forever, which meant
    /// a detector-only Agent bundled after the sentinel was written could never be
    /// installed, and a detector version bump could never reach existing users.
    /// Reconciliation is per Agent and idempotent instead:
    ///
    /// - a current marker is left untouched;
    /// - a missing marker is installed unless the user explicitly removed it;
    /// - a stale OMG-owned marker is refreshed;
    /// - a marker that is not OMG-owned is never overwritten.
    ///
    /// An explicit Remove writes a per-Agent tombstone, so reconciliation can never
    /// resurrect a detector the user turned off. Removals recorded by the legacy
    /// global sentinel cannot be distinguished from detectors that simply did not
    /// exist yet, so those are not carried over: a detector removed before this
    /// version is re-enabled once and can be removed again, whereas guessing would
    /// permanently hide every detector-only Agent added since the sentinel.
    /// `supportsDetector(for:)` is the capability check; detectors that grew a real
    /// vendor Hook adapter are skipped.
    func migrateImplicitDetectorsIfNeeded() throws {
        for agent in SupportedAgent.allCases where Self.supportsDetector(for: agent) {
            guard !hasTombstone(agent) else { continue }
            let url = detectorMarkerURL(agent)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try installDetectorMarker(agent)
                continue
            }
            // Content that is not an OMG marker (or is malformed) is left alone so
            // reconciliation can never clobber a file it does not own.
            guard let marker = validDetectorMarker(
                at: url,
                expectedAgent: agent.rawValue
            ) else { continue }
            if marker.version != Self.detectorMarkerVersion {
                try installDetectorMarker(agent)
            }
        }
    }

    /// Whether a detector marker is the only way to observe this Agent.
    ///
    /// Kept as a single predicate so reconciliation, install and status agree on
    /// which Agents are detector-only as manifests migrate to real Hook adapters.
    static func supportsDetector(for agent: SupportedAgent) -> Bool {
        agent.definition.hook.kind == .none
    }

    func installationState(
        _ agent: SupportedAgent
    ) -> AgentHookInstallationState {
        let definition = agent.definition
        switch definition.hook.kind {
        case .json:
            let url = hookURL(for: agent)
            guard containsMarker(in: url, agent: agent) else { return .missing }
            guard hasCurrentJSONHooks(at: url, agent: agent) else {
                return .updateAvailable
            }
            if agent == .codex, !codexHooksEnabled() {
                return .updateAvailable
            }
            return .current
        case .plugin:
            guard let expected = Self.pluginSource(for: agent),
                  let source = try? String(
                      contentsOf: hookURL(for: agent),
                      encoding: .utf8
                  ), source.contains("marker: \(Self.marker)") else {
                return .missing
            }
            return source == expected ? .current : .updateAvailable
        case .toml:
            guard let source = try? String(
                contentsOf: hookURL(for: agent),
                encoding: .utf8
            ), source.contains(Self.tomlBlockBegin) else { return .missing }
            return source.contains("_omg_agent_status_v\(Self.hookVersion)")
                ? .current : .updateAvailable
        case .scripts:
            let directory = hookURL(for: agent)
            let current = agent.definition.hook.events.allSatisfy { event in
                let url = directory.appendingPathComponent(event.name)
                return (try? String(contentsOf: url, encoding: .utf8))?
                    .contains("_omg_agent_status_v\(Self.hookVersion)") == true
            }
            return current ? .current : .missing
        case .yaml:
            let url = hookURL(for: agent)
            guard yamlHooksCurrent(at: url, agent: agent),
                  FileManager.default.fileExists(
                      atPath: yamlHookScriptURL(agent).path
                  ) else {
                return Self.yamlBlockPresent(at: url) ? .updateAvailable : .missing
            }
            return .current
        case .none:
            return detectorInstallationState(agent)
        }
    }

    static func remoteInstallerScript(
        action: AgentHookRemoteAction = .install,
        agents: [SupportedAgent]? = nil
    ) throws -> String {
        let selected = agents ?? SupportedAgent.allCases.filter { $0.definition.hook.kind != .none }
        guard selected.allSatisfy({ $0.definition.hook.kind != .none }) else {
            throw AgentHookInstallerError.invalidConfiguration
        }
        let selectionData = try JSONEncoder().encode(selected.map(\.rawValue))
        let jsonAgents = SupportedAgent.allCases.filter {
            $0.definition.hook.kind == .json
        }
        let spec = Dictionary(uniqueKeysWithValues: jsonAgents.map { agent in
            let entries = hookEvents(agent).map { event, state, matcher in
                [
                    "event": event,
                    "entry": jsonHookEntry(
                        agent: agent,
                        event: event,
                        state: state,
                        matcher: matcher
                    ),
                ]
            }
            return (agent.rawValue, [
                "path": agent.definition.hook.path,
                "dialect": (
                    agent.definition.hook.dialect ?? .nested
                ).rawValue,
                "entries": entries,
            ] as [String: Any])
        })
        let specData = try JSONSerialization.data(
            withJSONObject: spec,
            options: [.sortedKeys]
        )
        let specBase64 = specData.base64EncodedString()
        let auxiliaryPairs: [(String, [String: Any])] =
            SupportedAgent.allCases.compactMap { agent in
                let hook = agent.definition.hook
                switch hook.kind {
                case .plugin:
                    guard let source = pluginSource(for: agent) else { return nil }
                    return (agent.rawValue, [
                        "kind": "plugin", "path": hook.path, "source": source,
                    ])
                case .toml, .scripts, .yaml:
                    let entries = hook.events.map { event in
                        let cmd: String = if hook.kind == .yaml {
                            yamlHookCommand(agent: agent, state: event.state)
                        } else {
                            hookCommand(
                                agent: agent,
                                state: event.state,
                                attentionKind: attentionKind(
                                    event: event.name,
                                    matcher: event.matcher,
                                    state: event.state
                                )
                            )
                        }
                        var item: [String: Any] = [
                            "event": event.name,
                            "command": cmd,
                        ]
                        if let matcher = event.matcher { item["matcher"] = matcher }
                        return item
                    }
                    var payload: [String: Any] = [
                        "kind": hook.kind.rawValue,
                        "path": hook.path,
                        "entries": entries,
                    ]
                    if hook.kind == .yaml {
                        payload["script"] = Self.yamlHookScriptPath(agent)
                        payload["source"] = Self.yamlHookScriptSource(for: agent)
                    }
                    return (agent.rawValue, payload)
                case .none, .json:
                    return nil
                }
            }
        let auxiliaryPayload = Dictionary(uniqueKeysWithValues: auxiliaryPairs)
        let auxiliaryData = try JSONSerialization.data(
            withJSONObject: auxiliaryPayload,
            options: [.sortedKeys]
        )
        let auxiliaryBase64 = auxiliaryData.base64EncodedString()
        return #"""
#!/usr/bin/env python3
# Auditable OMG Agent Status installer for an SSH account.
import base64
import json
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile

MARKER = "_omg_agent_status"
VERSION = \#(hookVersion)
SPEC = json.loads(base64.b64decode("\#(specBase64)").decode("utf-8"))
AUXILIARY = json.loads(base64.b64decode("\#(auxiliaryBase64)").decode("utf-8"))
HOME = Path.home()
ACTION = "\#(action.rawValue)"
SELECTED = json.loads(base64.b64decode("\#(selectionData.base64EncodedString())"))


def backup(path):
    if not path.exists():
        return
    destination = path.with_name(path.name + ".omg-backup")
    if not destination.exists():
        shutil.copy2(path, destination)


def atomic_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    descriptor, temporary = tempfile.mkstemp(prefix=".omg-agent-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def is_legacy_omg(command):
    return isinstance(command, dict) and ": " + MARKER + ";" in str(command.get("command", ""))


def remove_omg(entry):
    if MARKER in entry or (": " + MARKER + ";") in str(entry.get("command", "")):
        return None
    commands = entry.get("hooks")
    if not isinstance(commands, list):
        return entry
    remaining = [command for command in commands if not is_legacy_omg(command)]
    if len(remaining) == len(commands):
        return entry
    if not remaining:
        return None
    result = dict(entry)
    result["hooks"] = remaining
    return result


def load_hooks(path, agent):
    if path.exists():
        root = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(root, dict):
            raise ValueError(str(path) + " is not a JSON object")
    else:
        root = {}
    key = "omg-agent-status" if SPEC[agent].get("dialect") == "antigravity" else "hooks"
    hooks = root.get(key, {})
    if not isinstance(hooks, dict):
        raise ValueError(str(path) + " hooks is not an object")
    return root, hooks


def validate_json(path, agent):
    root, hooks = load_hooks(path, agent)
    if SPEC[agent].get("dialect") == "antigravity" and "omg-agent-status" in root:
        if not any(event != "enabled" for event in hooks):
            raise ValueError(str(path) + " omg-agent-status is owned by another hook")
        for event, entries in hooks.items():
            if event == "enabled": continue
            if not isinstance(entries, list) or not entries or not all(
                    isinstance(entry, dict) and remove_omg(entry) is None for entry in entries):
                raise ValueError(str(path) + " omg-agent-status is owned by another hook")
    for item in SPEC[agent]["entries"]:
        existing = hooks.get(item["event"], [])
        if not isinstance(existing, list):
            raise ValueError(str(path) + " " + item["event"] + " is not an array")
        if not all(isinstance(entry, dict) for entry in existing):
            raise ValueError(str(path) + " " + item["event"] + " contains a non-object")


def install_json(path, agent):
    root, hooks = load_hooks(path, agent)
    named = SPEC[agent].get("dialect") == "antigravity"
    if named: hooks["enabled"] = True
    for item in SPEC[agent]["entries"]:
        event = item["event"]
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            raise ValueError(str(path) + " " + event + " is not an array")
        hooks[event] = [entry for entry in (remove_omg(value) for value in existing) if entry is not None]
        hooks[event].append(item["entry"])
    root["omg-agent-status" if named else "hooks"] = hooks
    if SPEC[agent].get("dialect") in ("cursor", "copilot") and "version" not in root:
        root["version"] = 1
    backup(path)
    atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")


def enable_codex_hooks(path):
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    lines = text.split("\n")
    try:
        section = next(index for index, line in enumerate(lines) if line.strip() == "[features]")
    except StopIteration:
        if lines and lines[-1]:
            lines.append("")
        lines.extend(["[features]", "hooks = true"])
    else:
        end = next((index for index in range(section + 1, len(lines)) if lines[index].strip().startswith("[")), len(lines))
        assignments = [index for index in range(section + 1, end) if re.match(r"^\s*hooks\s*=", lines[index])]
        if len(assignments) > 1:
            raise ValueError("Codex config.toml contains duplicate hooks settings")
        if assignments:
            indentation = lines[assignments[0]][:len(lines[assignments[0]]) - len(lines[assignments[0]].lstrip())]
            lines[assignments[0]] = indentation + "hooks = true"
        else:
            lines.insert(section + 1, "hooks = true")
    backup(path)
    atomic_write(path, "\n".join(lines))


def strip_toml_block(text):
    begin = "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    end = "# <<< OMG agent-status hooks <<<"
    start = text.find(begin)
    finish = text.find(end, start + len(begin)) if start >= 0 else -1
    return text if start < 0 or finish < 0 else text[:start] + text[finish + len(end):]


def strip_yaml_block(text):
    return strip_toml_block(text)


def install_auxiliary(item):
    path = expand(item["path"])
    kind = item["kind"]
    if kind == "plugin":
        backup(path)
        atomic_write(path, item["source"])
        return
    if kind == "toml":
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        base = strip_toml_block(existing).strip("\n")
        lines = ["# >>> OMG agent-status hooks (managed; do not edit) >>>"]
        for entry in item["entries"]:
            lines.extend(["[[hooks]]", 'event = "' + entry["event"] + '"'])
            if entry.get("matcher") is not None:
                lines.append('matcher = "' + entry["matcher"] + '"')
            lines.extend(["command = '''" + entry["command"] + "'''", "timeout = 5", ""])
        if lines[-1] == "": lines.pop()
        lines.append("# <<< OMG agent-status hooks <<<")
        backup(path)
        atomic_write(path, (base + "\n\n" if base else "") + "\n".join(lines) + "\n")
        return
    if kind == "yaml":
        existing = path.read_text(encoding="utf-8") if path.exists() else ""
        base = strip_yaml_block(existing).strip("\n")
        if any(line.startswith("hooks:") for line in base.split("\n")):
            raise ValueError(str(path) + " already has a hooks: key")
        # The hook command delegates to a helper script: Hermes may run shell hooks
        # from a headless daemon that owns no TTY, so the script records the state
        # instead of writing OSC from the hook process.
        script_path = expand(item["script"])
        script_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            script_path.parent.chmod(0o700)
        except OSError:
            pass
        backup(script_path)
        atomic_write(script_path, item["source"])
        script_path.chmod(0o700)
        lines = [
            "# >>> OMG agent-status hooks (managed; do not edit) >>>",
            "hooks_auto_accept: true",
            "hooks:",
        ]
        for entry in item["entries"]:
            lines.append("  " + entry["event"] + ":")
            lines.append("    - command: >-")
            lines.append("        " + entry["command"].replace("\n", " "))
            lines.append("      timeout: 5")
        lines.append("# <<< OMG agent-status hooks <<<")
        backup(path)
        atomic_write(path, (base + "\n\n" if base else "") + "\n".join(lines) + "\n")
        return
    if kind == "scripts":
        path.mkdir(parents=True, exist_ok=True)
        for entry in item["entries"]:
            target = path / entry["event"]
            if target.exists() and (": " + MARKER + ";") not in target.read_text(encoding="utf-8"):
                raise ValueError(str(target) + " is owned by another hook")
            backup(target)
            atomic_write(target, "#!/bin/sh\n" + entry["command"] + "\n")
            target.chmod(0o700)


def expand(raw):
    return HOME / raw[2:] if raw.startswith("~/") else Path(raw)


def state(agent):
    if agent in SPEC:
        item = SPEC[agent]
        path = expand(item["path"])
        if not path.exists(): return "missing"
        root, hooks = load_hooks(path, agent)
        owned = any(remove_omg(entry) != entry for entries in hooks.values()
                    if isinstance(entries, list) for entry in entries if isinstance(entry, dict))
        if not owned: return "missing"
        current = all(item_entry["entry"] in hooks.get(item_entry["event"], [])
                      for item_entry in item["entries"])
        if item.get("dialect") == "antigravity":
            current = current and hooks.get("enabled", True) is not False
        if agent == "codex":
            config = HOME / ".codex/config.toml"
            text = config.read_text(encoding="utf-8") if config.exists() else ""
            section = re.search(r"(?ms)^\s*\[features\]\s*\n(.*?)(?=^\s*\[|\Z)", text)
            current = current and section is not None and re.search(
                r"(?m)^\s*hooks\s*=\s*true\s*(?:#.*)?$", section.group(1)) is not None
        return "current" if current else "updateAvailable"
    if agent in AUXILIARY:
        item = AUXILIARY[agent]
        path = expand(item["path"])
        if item["kind"] == "scripts":
            texts = [(path / entry["event"]).read_text(encoding="utf-8")
                     if (path / entry["event"]).exists() else "" for entry in item["entries"]]
            if not any(MARKER in text for text in texts): return "missing"
            return "current" if all("_omg_agent_status_v" + str(VERSION) in text for text in texts) else "updateAvailable"
        text = path.read_text(encoding="utf-8") if path.exists() else ""
        if item["kind"] == "yaml":
            if "# >>> OMG agent-status hooks" not in text: return "missing"
            script = expand(item["script"]) if item.get("script") else None
            if script is None or not script.is_file(): return "missing"
            script_text = script.read_text(encoding="utf-8", errors="replace")
            current = ("_omg_agent_status v" + str(VERSION)) in script_text and all(
                (entry["event"] + ":") in text for entry in item["entries"])
            return "current" if current else "updateAvailable"
        if MARKER not in text and "# >>> OMG agent-status hooks" not in text: return "missing"
        current = text == item["source"] if item["kind"] == "plugin" else "_omg_agent_status_v" + str(VERSION) in text
        return "current" if current else "updateAvailable"
    raise ValueError("No remote hook for this agent")


def remove(agent):
    if agent in SPEC:
        path = expand(SPEC[agent]["path"])
        if not path.exists(): return
        root, hooks = load_hooks(path, agent)
        if SPEC[agent].get("dialect") == "antigravity":
            if "omg-agent-status" not in root: return
            validate_json(path, agent)
            del root["omg-agent-status"]
            backup(path)
            atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")
            return
        for event, entries in hooks.items():
            if not isinstance(entries, list) or not all(isinstance(entry, dict) for entry in entries):
                raise ValueError(str(path) + " invalid hooks")
            hooks[event] = [entry for entry in (remove_omg(value) for value in entries) if entry is not None]
        root["hooks"] = hooks
        backup(path)
        atomic_write(path, json.dumps(root, indent=2, sort_keys=True) + "\n")
    elif agent in AUXILIARY:
        item = AUXILIARY[agent]
        path = expand(item["path"])
        if item["kind"] == "scripts":
            for entry in item["entries"]:
                target = path / entry["event"]
                if target.exists() and (": " + MARKER + ";") in target.read_text(encoding="utf-8"):
                    backup(target)
                    target.unlink()
        elif path.exists():
            text = path.read_text(encoding="utf-8")
            if item["kind"] == "toml":
                backup(path)
                atomic_write(path, strip_toml_block(text))
            elif item["kind"] == "yaml":
                if "# >>> OMG agent-status hooks" in text:
                    backup(path)
                    atomic_write(path, strip_yaml_block(text).strip("\n") + ("\n" if strip_yaml_block(text).strip() else ""))
                for extra in (item.get("script"), (item.get("script") or "").replace("-hook.sh", ".status")):
                    if not extra: continue
                    target = expand(extra)
                    try:
                        if target.is_file(): target.unlink()
                    except OSError:
                        pass
            elif "marker: " + MARKER in text:
                backup(path)
                path.unlink()


if ACTION == "status":
    print(json.dumps({agent: state(agent) for agent in SELECTED}))
elif ACTION == "remove":
    for agent in SELECTED: remove(agent)
elif ACTION == "install":
    for agent in SELECTED:
        if agent in SPEC: validate_json(expand(SPEC[agent]["path"]), agent)
    for agent in SELECTED:
        if agent in SPEC:
            if agent == "codex": enable_codex_hooks(HOME / ".codex/config.toml")
            install_json(expand(SPEC[agent]["path"]), agent)
        elif agent in AUXILIARY:
            install_auxiliary(AUXILIARY[agent])
    print("Installed current OMG agent hooks.")
else:
    raise ValueError("Unknown OMG integration action")
"""#
    }

    func install(_ agent: SupportedAgent) throws {
        let url = hookURL(for: agent)
        switch agent.definition.hook.kind {
        case .json:
            try validateJSONHooks(at: url, agent: agent)
            if agent == .codex { try ensureCodexHooksEnabled() }
            try installJSONHooks(at: url, agent: agent)
        case .plugin:
            guard let source = Self.pluginSource(for: agent) else {
                throw AgentHookInstallerError.invalidConfiguration
            }
            try backupIfNeeded(url)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeText(source, to: url)
        case .toml:
            try installTOMLHooks(at: url, agent: agent)
        case .scripts:
            try installScriptHooks(at: url, agent: agent)
        case .yaml:
            try installYAMLHooks(at: url, agent: agent)
            try installYAMLHookScript(for: agent)
        case .none:
            // An explicit Install overrides an earlier explicit Remove.
            try removeTombstone(agent)
            try installDetectorMarker(agent)
        }
        notifyChanged(agent)
    }

    func uninstall(_ agent: SupportedAgent) throws {
        let url = hookURL(for: agent)
        switch agent.definition.hook.kind {
        case .json:
            try removeJSONHooks(at: url, agent: agent)
        case .plugin:
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        case .toml:
            try removeTOMLHooks(at: url)
        case .scripts:
            try removeScriptHooks(at: url, agent: agent)
        case .yaml:
            try removeYAMLHooks(at: url)
            let scriptURL = yamlHookScriptURL(agent)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                try FileManager.default.removeItem(at: scriptURL)
            }
            let statusURL = agentStatusURL(agent)
            if FileManager.default.fileExists(atPath: statusURL.path) {
                try FileManager.default.removeItem(at: statusURL)
            }
        case .none:
            try removeDetectorMarker(agent)
        }
        notifyChanged(agent)
    }

    private func notifyChanged(_ agent: SupportedAgent) {
        let post = {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: nil,
                userInfo: [Self.changedAgentUserInfoKey: agent.rawValue]
            )
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    private func detectorInstallationState(
        _ agent: SupportedAgent
    ) -> AgentHookInstallationState {
        let url = detectorMarkerURL(agent)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let marker = validDetectorMarker(
            at: url,
            expectedAgent: agent.rawValue
        ) else { return .updateAvailable }
        return marker.version == Self.detectorMarkerVersion
            ? .current : .updateAvailable
    }

    private func installDetectorMarker(_ agent: SupportedAgent) throws {
        try writeDetectorMarker(agent: agent.rawValue, to: detectorMarkerURL(agent))
    }

    private func writeDetectorMarker(agent: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var data = try JSONEncoder().encode(DetectorMarker(
            owner: Self.marker,
            version: Self.detectorMarkerVersion,
            agent: agent
        ))
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func removeDetectorMarker(_ agent: SupportedAgent) throws {
        let url = detectorMarkerURL(agent)
        if FileManager.default.fileExists(atPath: url.path) {
            guard validDetectorMarker(
                at: url,
                expectedAgent: agent.rawValue
            ) != nil else {
                throw AgentHookInstallerError.invalidDetectorMarker(agent.rawValue)
            }
            try FileManager.default.removeItem(at: url)
        }
        // Record the removal before returning so reconciliation cannot reinstall it.
        try writeTombstone(agent.rawValue)
    }

    private func writeTombstone(_ agent: String) throws {
        try writeDetectorMarker(agent: agent, to: detectorTombstoneURL(agent))
    }

    private func hasTombstone(_ agent: SupportedAgent) -> Bool {
        validDetectorMarker(
            at: detectorTombstoneURL(agent.rawValue),
            expectedAgent: agent.rawValue
        ) != nil
    }

    private func removeTombstone(_ agent: SupportedAgent) throws {
        let url = detectorTombstoneURL(agent.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard validDetectorMarker(
            at: url,
            expectedAgent: agent.rawValue
        ) != nil else {
            throw AgentHookInstallerError.invalidDetectorMarker(agent.rawValue)
        }
        try FileManager.default.removeItem(at: url)
    }

    private func validDetectorMarker(
        at url: URL,
        expectedAgent: String
    ) -> DetectorMarker? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        ((attributes[.size] as? NSNumber)?.intValue ?? 4_097) <= 4_096,
        (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
        let data = try? Data(contentsOf: url),
        let marker = try? JSONDecoder().decode(DetectorMarker.self, from: data),
        marker.owner == Self.marker,
        marker.agent == expectedAgent else { return nil }
        return marker
    }

    private var detectorDirectoryURL: URL {
        homeURL.appendingPathComponent(".config/oh-my-ghostty/agent-detectors")
    }

    private func detectorMarkerURL(_ agent: SupportedAgent) -> URL {
        detectorDirectoryURL.appendingPathComponent("\(agent.rawValue).json")
    }

    /// Path of the status line a YAML-hook Agent's helper script writes.
    func agentStatusURL(_ agent: SupportedAgent) -> URL {
        homeURL
            .appendingPathComponent(".config/oh-my-ghostty/agent-status")
            .appendingPathComponent("\(agent.rawValue).status")
    }

    /// Per-Agent record of an explicit removal. Dot-prefixed so it cannot collide
    /// with any `SupportedAgent.rawValue` marker file.
    private func detectorTombstoneURL(_ agent: String) -> URL {
        detectorDirectoryURL.appendingPathComponent(".removed-\(agent).json")
    }

    private static let tomlBlockBegin =
        "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    private static let tomlBlockEnd = "# <<< OMG agent-status hooks <<<"

    private static let yamlBlockBegin =
        "# >>> OMG agent-status hooks (managed; do not edit) >>>"
    private static let yamlBlockEnd = "# <<< OMG agent-status hooks <<<"

    /// Marker-delimited YAML block: the commands OMG owns inside a YAML config.
    /// Kept free of anchors and nested user content so a plain block replace is
    /// safe and unrelated configuration is preserved byte-for-byte.
    private func installYAMLHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        try validateYAMLHooks(existing)
        let base = Self.removingYAMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        var lines = [
            Self.yamlBlockBegin,
            "hooks_auto_accept: true",
            "hooks:",
        ]
        for event in agent.definition.hook.events {
            // Hermes reads `hooks: { <event>: [ {command, timeout}, ... ] }`.
            // The nested list form keeps unrelated hooks on the same event intact.
            lines.append("  \(event.name):")
            lines.append("    - command: >-")
            let command = Self.yamlFoldedScalar(
                Self.yamlHookCommand(agent: agent, state: event.state)
            )
            lines.append("        \(command)")
            lines.append("      timeout: 5")
        }
        lines.append(Self.yamlBlockEnd)
        let block = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText(base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n", to: url)
    }

    /// Generates the command for a YAML-embedded hook (Hermes).
    ///
    /// Hermes runs shell hooks from its long-lived gateway process when one is
    /// active: the hook's parent is that daemon, which owns no TTY and belongs to
    /// its own process group. An OSC write from there reaches no pane, and any pgid
    /// it reports is unrelated to the pane's foreground process group. The command
    /// therefore records the event in a status file; the host resolves which pane
    /// owns the session and writes the OSC itself.
    private static func yamlHookCommand(
        agent: SupportedAgent,
        state: TabActivityState?
    ) -> String {
        let stateArg = state?.rawValue ?? "end"
        // A single stable script keeps the YAML scalar short and free of quoting
        // hazards; the script is rewritten on every install.
        return "\(yamlHookScriptPath(agent)) \(stateArg)"
    }

    /// Absolute path of the helper script a YAML-hook Agent's config invokes.
    private static func yamlHookScriptPath(_ agent: SupportedAgent) -> String {
        "~/.config/oh-my-ghostty/agent-status/\(agent.rawValue)-hook.sh"
    }

    /// Resolves `yamlHookScriptPath` against this installer's home, so a test or
    /// alternate home never writes into the real user's home directory.
    private func yamlHookScriptURL(_ agent: SupportedAgent) -> URL {
        homeURL
            .appendingPathComponent(".config/oh-my-ghostty/agent-status")
            .appendingPathComponent("\(agent.rawValue)-hook.sh")
    }

    /// Writes the helper script invoked from the Agent's YAML config.
    ///
    /// The script reads the hook payload from stdin for the conversation id and
    /// writes one status line, so it never needs a TTY and behaves the same when
    /// the Agent runs it from a pane-attached process or from its daemon.
    private func installYAMLHookScript(for agent: SupportedAgent) throws {
        let url = yamlHookScriptURL(agent)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try writeText(Self.yamlHookScriptSource(for: agent), to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    /// Body of the helper script a YAML-hook Agent invokes instead of an inline
    /// command, shared by the local installer and the exported SSH installer.
    static func yamlHookScriptSource(for agent: SupportedAgent) -> String {
        "#!/usr/bin/env python3\n# marker: \(marker) v\(hookVersion)\n" +
            HermesPaneStatus.reporter
    }

    /// Renders `command` as the single continuation line of a YAML block scalar.
    /// YAML folds newlines into spaces, so an embedded newline would silently
    /// corrupt the command; the generated commands never contain one.
    private static func yamlFoldedScalar(_ command: String) -> String {
        command.replacingOccurrences(of: "\n", with: " ")
    }

    private func removeYAMLHooks(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let base = Self.removingYAMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        try writeText(base.isEmpty ? "" : base + "\n", to: url)
    }

    private func yamlHooksCurrent(at url: URL, agent: SupportedAgent) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              text.range(of: Self.yamlBlockBegin, options: .literal) != nil,
              text.range(of: "hooks_auto_accept: true", options: .literal) != nil else { return false }
        // Every declared event must delegate to the helper script.
        guard agent.definition.hook.events.allSatisfy({ text.range(of: "\($0.name):", options: .literal) != nil }),
              text.range(of: "\(agent.rawValue)-hook.sh", options: .literal) != nil else { return false }
        // The helper script carries the hook version; a stale script means the
        // integration needs rewriting even when the YAML block looks current.
        guard let script = try? String(
            contentsOf: yamlHookScriptURL(agent),
            encoding: .utf8
        ) else { return false }
        return script.contains("_omg_agent_status v\(Self.hookVersion)")
    }

    private static func yamlBlockPresent(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        return text.range(of: yamlBlockBegin, options: .literal) != nil
    }

    private func validateYAMLHooks(_ text: String) throws {
        // Refuse an unbalanced OMG block: removal would leave half a block behind.
        let begins = text.components(separatedBy: Self.yamlBlockBegin).count - 1
        let ends = text.components(separatedBy: Self.yamlBlockEnd).count - 1
        guard begins == ends else {
            throw AgentHookInstallerError.invalidHooks("yaml")
        }
        // A top-level `hooks:` owned by the user cannot be merged without
        // re-serializing their YAML, which would rewrite unrelated content.
        let base = Self.removingYAMLBlock(from: text)
        let foreignHooksKey = base
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                line.hasPrefix("hooks:")
            }
        guard !foreignHooksKey else {
            throw AgentHookInstallerError.invalidHooks("hooks")
        }
    }

    private static func removingYAMLBlock(from text: String) -> String {
        guard let begin = text.range(of: yamlBlockBegin),
              let end = text.range(
                  of: yamlBlockEnd,
                  range: begin.upperBound..<text.endIndex
              ) else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }

    private func installTOMLHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        let base = Self.removingTOMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        var lines = [Self.tomlBlockBegin]
        for event in agent.definition.hook.events {
            lines.append("[[hooks]]")
            lines.append("event = \"\(event.name)\"")
            if let matcher = event.matcher {
                lines.append("matcher = \"\(matcher)\"")
            }
            let command = Self.hookCommand(
                agent: agent,
                state: event.state,
                attentionKind: Self.attentionKind(
                    event: event.name,
                    matcher: event.matcher,
                    state: event.state
                )
            )
            lines.append("command = '''\(command)'''")
            lines.append("timeout = 5")
            lines.append("")
        }
        if lines.last == "" { lines.removeLast() }
        lines.append(Self.tomlBlockEnd)
        let block = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText(base.isEmpty ? block + "\n" : base + "\n\n" + block + "\n", to: url)
    }

    private func removeTOMLHooks(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let base = Self.removingTOMLBlock(from: existing)
            .trimmingCharacters(in: .newlines)
        try writeText(base.isEmpty ? "" : base + "\n", to: url)
    }

    private static func removingTOMLBlock(from text: String) -> String {
        guard let begin = text.range(of: tomlBlockBegin),
              let end = text.range(
                  of: tomlBlockEnd,
                  range: begin.upperBound..<text.endIndex
              ) else { return text }
        var result = text
        result.removeSubrange(begin.lowerBound..<end.upperBound)
        return result
    }

    private func installScriptHooks(
        at directory: URL,
        agent: SupportedAgent
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for event in agent.definition.hook.events {
            let url = directory.appendingPathComponent(event.name)
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                guard existing.contains(": \(Self.marker);") else {
                    throw AgentHookInstallerError.invalidHooks(event.name)
                }
                try backupIfNeeded(url)
            }
            let source = "#!/bin/sh\n" + Self.hookCommand(
                agent: agent,
                state: event.state,
                attentionKind: Self.attentionKind(
                    event: event.name,
                    matcher: event.matcher,
                    state: event.state
                )
            ) + "\n"
            try writeText(source, to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
        }
    }

    private func removeScriptHooks(
        at directory: URL,
        agent: SupportedAgent
    ) throws {
        for event in agent.definition.hook.events {
            let url = directory.appendingPathComponent(event.name)
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  source.contains(": \(Self.marker);") else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func hookURL(for agent: SupportedAgent) -> URL {
        let path = agent.definition.hook.path
        if path.hasPrefix("~/") {
            return homeURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func containsMarker(in url: URL, agent: SupportedAgent) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let hooks = dictionary[agent == .antigravity ? Self.antigravityHookName : "hooks"] as? [String: Any] else {
            return false
        }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains(where: Self.containsOMGCommand)
        }
    }

    private func hasCurrentJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data),
              let dictionary = root as? [String: Any],
              let hooks = dictionary[agent == .antigravity ? Self.antigravityHookName : "hooks"] as? [String: Any] else {
            return false
        }
        if agent == .antigravity, hooks["enabled"] as? Bool == false { return false }
        return Self.hookEvents(agent).allSatisfy { event, _, _ in
            guard let entries = hooks[event] as? [[String: Any]] else {
                return false
            }
            return entries.contains(where: Self.isCurrentOMGEntry)
        }
    }

    private func codexHooksEnabled() -> Bool {
        let url = homeURL.appendingPathComponent(".codex/config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let section = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[features]"
        }) else { return false }
        let end = lines[(section + 1)...].firstIndex {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        } ?? lines.endIndex
        let values = lines[(section + 1)..<end].filter(Self.isHooksAssignment)
        guard values.count == 1 else { return false }
        return values[0].trimmingCharacters(in: .whitespaces)
            .range(
                of: #"^hooks\s*=\s*true\s*(?:#.*)?$"#,
                options: .regularExpression
            ) != nil
    }

    private func validateJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        let root = try loadJSONObject(at: url)
        let hooks = try hooksDictionary(root[agent == .antigravity ? Self.antigravityHookName : "hooks"])
        if agent == .antigravity, root[Self.antigravityHookName] != nil {
            // Refuse a same-named third-party hook rather than taking ownership.
            guard hooks.keys.contains(where: { $0 != "enabled" }) else {
                throw AgentHookInstallerError.invalidHooks(Self.antigravityHookName)
            }
            for (event, value) in hooks where event != "enabled" {
                let entries = try hookEntries(value, event: event)
                guard !entries.isEmpty, entries.allSatisfy({ Self.removingOMGCommands($0) == nil }) else {
                    throw AgentHookInstallerError.invalidHooks(Self.antigravityHookName)
                }
            }
        }
        for (event, _, _) in Self.hookEvents(agent) {
            _ = try hookEntries(hooks[event], event: event)
        }
    }

    private func installJSONHooks(
        at url: URL,
        agent: SupportedAgent
    ) throws {
        var root = try loadJSONObject(at: url)
        let key = agent == .antigravity ? Self.antigravityHookName : "hooks"
        var hooks = try hooksDictionary(root[key])
        if agent == .antigravity { hooks["enabled"] = true }
        for (event, state, matcher) in Self.hookEvents(agent) {
            let existing = try hookEntries(hooks[event], event: event)
            var entries = existing.compactMap(Self.removingOMGCommands)
            entries.append(Self.jsonHookEntry(
                agent: agent,
                event: event,
                state: state,
                matcher: matcher
            ))
            hooks[event] = entries
        }
        root[key] = hooks
        if Self.jsonHookUsesRootVersion(agent.definition.hook.dialect),
           root["version"] == nil {
            root["version"] = 1
        }
        try writeJSONObject(root, to: url)
    }

    private func removeJSONHooks(at url: URL, agent: SupportedAgent) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try loadJSONObject(at: url)
        if agent == .antigravity {
            guard root[Self.antigravityHookName] != nil else { return }
            try validateJSONHooks(at: url, agent: agent)
            root.removeValue(forKey: Self.antigravityHookName)
            try writeJSONObject(root, to: url)
            return
        }
        guard root["hooks"] != nil else { return }
        var hooks = try hooksDictionary(root["hooks"])
        for key in Array(hooks.keys) {
            let entries = try hookEntries(hooks[key], event: key)
            let remaining = entries.compactMap(Self.removingOMGCommands)
            if remaining.isEmpty {
                hooks.removeValue(forKey: key)
            } else {
                hooks[key] = remaining
            }
        }
        root["hooks"] = hooks
        try writeJSONObject(root, to: url)
    }

    private func hooksDictionary(_ value: Any?) throws -> [String: Any] {
        guard let value else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw AgentHookInstallerError.invalidHooks("hooks")
        }
        return hooks
    }

    private func hookEntries(
        _ value: Any?,
        event: String
    ) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw AgentHookInstallerError.invalidHooks(event)
        }
        return entries
    }

    private func loadJSONObject(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw AgentHookInstallerError.invalidConfiguration
        }
        return dictionary
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        data.append(0x0A)
        try writeData(data, to: url)
    }

    private func ensureCodexHooksEnabled() throws {
        let url = homeURL.appendingPathComponent(".codex/config.toml")
        var text: String
        if FileManager.default.fileExists(atPath: url.path) {
            text = try String(contentsOf: url, encoding: .utf8)
        } else {
            text = ""
        }
        var lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        let section = lines.firstIndex { $0.trimmingCharacters(
            in: .whitespaces
        ) == "[features]" }
        if let section {
            let end = lines[(section + 1)...].firstIndex {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            } ?? lines.endIndex
            let assignments = lines[(section + 1)..<end].indices.filter {
                Self.isHooksAssignment(lines[$0])
            }
            guard assignments.count <= 1 else {
                throw AgentHookInstallerError.duplicateCodexHooksSetting
            }
            if let hooks = assignments.first {
                let indentation = lines[hooks].prefix { $0.isWhitespace }
                lines[hooks] = "\(indentation)hooks = true"
            } else {
                lines.insert("hooks = true", at: section + 1)
            }
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append(contentsOf: ["[features]", "hooks = true"])
        }
        text = lines.joined(separator: "\n")
        try backupIfNeeded(url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeText(text, to: url)
    }

    private func writeText(_ text: String, to url: URL) throws {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writeData(data, to: url)
    }

    private func writeData(_ data: Data, to url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let permissions = attributes?[.posixPermissions] as? NSNumber ??
            NSNumber(value: 0o600)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func isHooksAssignment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: #"^hooks\s*="#, options: .regularExpression) != nil
    }

    private static func containsOMGCommand(_ entry: [String: Any]) -> Bool {
        if entry[marker] != nil || isLegacyOMGCommand(entry) { return true }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains(where: isLegacyOMGCommand)
    }

    private static func isCurrentOMGEntry(_ entry: [String: Any]) -> Bool {
        let versionMarker = "_omg_agent_status_v\(hookVersion)"
        if (entry["command"] as? String)?.contains(versionMarker) == true {
            return true
        }
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        let commandMatches = hooks.contains {
            ($0["command"] as? String)?.contains(versionMarker) == true
        }
        if entry[marker] != nil {
            return entry[marker] as? Int == hookVersion && commandMatches
        }
        return commandMatches
    }

    private static func removingOMGCommands(
        _ entry: [String: Any]
    ) -> [String: Any]? {
        if entry[marker] != nil || isLegacyOMGCommand(entry) { return nil }
        guard let commands = entry["hooks"] as? [[String: Any]] else {
            return entry
        }
        let remaining = commands.filter { !isLegacyOMGCommand($0) }
        guard remaining.count != commands.count else { return entry }
        guard !remaining.isEmpty else { return nil }
        var result = entry
        result["hooks"] = remaining
        return result
    }

    private static func isLegacyOMGCommand(_ command: [String: Any]) -> Bool {
        guard let value = command["command"] as? String else { return false }
        return value.contains(": \(marker);")
    }

    private func backupIfNeeded(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("omg-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private static func hookEvents(
        _ agent: SupportedAgent
    ) -> [(String, TabActivityState?, String?)] {
        agent.definition.hook.events.map { event in
            (event.name, event.state, event.matcher)
        }
    }

    private static func jsonHookEntry(
        agent: SupportedAgent,
        event: String,
        state: TabActivityState?,
        matcher: String?
    ) -> [String: Any] {
        let command = hookCommand(
            agent: agent,
            state: state,
            attentionKind: attentionKind(
                event: event,
                matcher: matcher,
                state: state
            )
        )
        switch agent.definition.hook.dialect ?? .nested {
        case .antigravity:
            let handler: [String: Any] = ["type": "command", "command": command, "timeout": 5]
            if event == "PostToolUse" {
                return ["matcher": "*", "hooks": [handler]]
            }
            return handler
        case .flat, .cursor, .copilot:
            var entry: [String: Any] = ["command": command]
            if agent.definition.hook.dialect == .flat {
                entry["description"] = "OMG Agent Status"
            } else if agent.definition.hook.dialect == .copilot {
                entry["type"] = "command"
            }
            if let matcher { entry["match"] = matcher }
            return entry

        default:
            var entry: [String: Any] = [
                marker: hookVersion,
                "hooks": [["type": "command", "command": command]],
            ]
            if let matcher { entry["matcher"] = matcher }
            return entry
        }
    }

    private static func jsonHookUsesRootVersion(
        _ dialect: AgentDefinition.HookSpec.Dialect?
    ) -> Bool {
        dialect == .cursor || dialect == .copilot
    }

    private static func attentionKind(
        event: String,
        matcher: String?,
        state: TabActivityState?
    ) -> TabAttentionKind? {
        guard state == .needsAttention else { return nil }
        let value = "\(event) \(matcher ?? "")".lowercased()
        if value.contains("permission") || value.contains("approval") {
            return .permission
        }
        if value.contains("question") || value.contains("prompt") {
            return .question
        }
        return nil
    }

    private static func hookCommand(
        agent: SupportedAgent,
        state: TabActivityState?,
        attentionKind: TabAttentionKind? = nil
    ) -> String {
        if agent == .antigravity { return antigravityHookCommand(state: state) }
        let action = state == nil ? "end" : "start"
        var metadata = "type=app;omg_agent=\(agent.rawValue);" +
            "omg_scope=%s;omg_liveness=pgid"
        if let state { metadata += ";omg_state=\(state.rawValue)" }
        if let attentionKind {
            metadata += ";omg_attention=\(attentionKind.rawValue)"
        }
        var setup = ""
        var arguments = "\"$omg_pgid\" \"$omg_scope\""
        if let field = agent.definition.hook.conversationField {
            setup = "omg_conversation=$(python3 -c 'import json,sys,urllib.parse; " +
                "value=json.load(sys.stdin).get(\"\(field)\",\"\"); " +
                "print(urllib.parse.quote(str(value)[:128],safe=\"._~-\"),end=\"\")' " +
                "2>/dev/null || true); "
            metadata += ";omg_conversation=%s"
            arguments += " \"$omg_conversation\""
        }
        let runtimeReport: String = if agent == .codex || agent == .claude {
            "if [ -n \"${OMG_RUNTIME_BIN-}\" ] && [ -n \"${omg_conversation-}\" ]; then " +
                "\"$OMG_RUNTIME_BIN\" report \(agent.rawValue) \(state?.rawValue ?? "end") \"$omg_conversation\" \"$PWD\" >/dev/null 2>&1 || true; fi; "
        } else { "" }
        return ": \(marker); : _omg_agent_status_v\(hookVersion); " + setup + runtimeReport +
            "omg_tty=$(ps -o tty= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "omg_pgid=$(ps -o pgid= -p \"$PPID\" 2>/dev/null | tr -d ' '); " +
            "case \"$omg_pgid\" in ''|*[!0-9]*) exit 0;; esac; " +
            "case \"$omg_tty\" in ''|*[!A-Za-z0-9/._-]*) omg_tty=tty;; esac; " +
            "omg_scope=local; test -n \"${SSH_CONNECTION-}${OMG_RUNTIME_REMOTE-}\" && omg_scope=remote; " +
            "printf '\\033]3008;\(action)=omg-agent-\(agent.rawValue)-%s;" +
            "\(metadata)\\007' \(arguments) > \"/dev/$omg_tty\" " +
            "2>/dev/null || true"
    }

    private static let antigravityHookName = "omg-agent-status"

    /// agy stdout is a JSON protocol channel; OSC goes only to the controlling TTY.
    private static func antigravityHookCommand(state: TabActivityState?) -> String {
        let script = #"""
import json, os, re, subprocess, sys, urllib.parse
response = {"decision": "allow"} if sys.argv[1] == "done" else {}
try:
    payload = json.loads(sys.stdin.read(1048576))
    state = sys.argv[1]
    if state == "done":
        if payload.get("error") or payload.get("terminationReason") == "error": state = "error"
        elif payload.get("fullyIdle") is False: state = "working"
    pgid = os.getpgid(os.getppid())
    scope = "remote" if os.environ.get("SSH_CONNECTION") else "local"
    conversation = payload.get("conversationId", "")
    if not isinstance(conversation, str): conversation = ""
    conversation = urllib.parse.quote(conversation[:128], safe="._~-")
    sequence = "\033]3008;start=omg-agent-antigravity-%d;type=app;omg_agent=antigravity;omg_scope=%s;omg_liveness=pgid;omg_state=%s;omg_conversation=%s\007" % (pgid, scope, state, conversation)
    try:
        fd = os.open("/dev/tty", os.O_WRONLY | os.O_NOCTTY)
    except OSError:
        tty = subprocess.run(["ps", "-o", "tty=", "-p", str(os.getppid())], capture_output=True, text=True, timeout=2).stdout.strip()
        if not re.fullmatch(r"(?:pts/[0-9]+|tty[A-Za-z0-9._-]+)", tty): raise OSError("No controlling terminal")
        fd = os.open("/dev/" + tty, os.O_WRONLY | os.O_NOCTTY)
    try: os.write(fd, sequence.encode())
    finally: os.close(fd)
except (ValueError, OSError, TypeError, AttributeError, subprocess.SubprocessError):
    pass
print(json.dumps(response))
"""#
        let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return ": \(marker); : _omg_agent_status_v\(hookVersion); python3 -c \(quoted) \(state?.rawValue ?? "done")"
    }

    private static func pluginSource(for agent: SupportedAgent) -> String? {
        switch agent.definition.hook.dialect {
        case .pi: agent == .omp ? ompExtension : piExtension
        case .opencode: openCodeExtension
        case .amp: ampExtension
        default: nil
        }
    }

    private static let piExtension = #"""
// OMG agent status integration for Pi.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";
import { spawnSync } from "node:child_process";

const contextId = `omg-agent-pi-${process.pid}`;
const scope = process.env.SSH_CONNECTION || process.env.OMG_RUNTIME_REMOTE ? "remote" : "local";
function report(state?: string, end = false, context?: any, attention?: string, phase?: string) {
  let fd: number | undefined;
  try {
    const raw = context?.sessionManager?.getSessionId?.();
    const conversation = raw && /^[A-Za-z0-9._-]{1,128}$/.test(String(raw))
      ? `;omg_conversation=${encodeURIComponent(String(raw))}` : "";
    // The session's own project directory can differ from the shell's cwd
    // (for example when `pi resume` picks a session from another project).
    // Restoring the conversation requires resuming it in this directory.
    const rawCwd = context?.sessionManager?.getCwd?.();
    const sessionCwd = rawCwd && String(rawCwd).startsWith("/") &&
        String(rawCwd).length <= 4096 && !String(rawCwd).includes("\0")
      ? `;omg_cwd=${encodeURIComponent(String(rawCwd))}` : "";
    if (process.env.OMG_RUNTIME_BIN && conversation && sessionCwd) {
      spawnSync(process.env.OMG_RUNTIME_BIN,
        ["report", "pi", end ? "end" : String(state), String(raw), String(rawCwd)],
        { stdio: "ignore", timeout: 1000 });
    }
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    const activityPhase = phase ? `;omg_phase=${phase};message=Background%20work%20running` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=pi;omg_scope=${scope};omg_liveness=pid${conversation}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=pi;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${conversation}${sessionCwd}${attentionKind}${activityPhase}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (pi: any) {
  let currentContext: any;
  let closing = false;
  let requestSequence = 0;
  let completionPending = false;
  const subagentRuns = new Set<string>();
  const backgroundTasks = new Set<string>();
  const backgroundToolNames = new Set([
    "bg_run", "bg_run_pi_attested", "bg_delegate",
    "fusion_reason", "fusion_investigate", "fusion_research", "fusion_validate",
  ]);

  const activeBackgroundCount = () => subagentRuns.size + backgroundTasks.size;
  const updateSettledStatus = (context = currentContext) => {
    currentContext = context ?? currentContext;
    if (closing || !currentContext?.isIdle?.()) return;
    if (activeBackgroundCount() > 0) {
      completionPending = true;
      report("working", false, currentContext, undefined, "background");
    } else if (completionPending) {
      completionPending = false;
      report("done", false, currentContext);
    }
  };
  const validID = (value: any) => typeof value === "string" && value.length > 0 && value.length <= 256;
  const refreshBackgroundTasks = () => {
    const requestId = `omg-agent-status-${process.pid}-${++requestSequence}`;
    const unsubscribe = pi.events.on("pi-background-tasks:response:v1", (response: any) => {
      if (response?.request_id !== requestId) return;
      unsubscribe?.();
      if (!response.ok || !Array.isArray(response.result?.tasks)) return;
      backgroundTasks.clear();
      for (const task of response.result.tasks) {
        if (task?.status === "running" && validID(task.id)) backgroundTasks.add(task.id);
      }
      updateSettledStatus();
    });
    pi.events.emit("pi-background-tasks:request:v1", {
      schema_version: "pi-background-tasks.extension-request.v1",
      request_id: requestId,
      operation: "status",
      payload: {},
    });
  };
  const refreshSubagents = () => {
    const requestId = `omg-agent-status-${process.pid}-${++requestSequence}`;
    const replyEvent = `subagents:rpc:v1:reply:${requestId}`;
    const unsubscribe = pi.events.on(replyEvent, (reply: any) => {
      unsubscribe?.();
      const runs = reply?.success ? reply.data?.asyncSnapshot?.runs : undefined;
      if (!Array.isArray(runs)) return;
      subagentRuns.clear();
      for (const run of runs) {
        if ((run?.state === "queued" || run?.state === "running") && validID(run.id)) {
          subagentRuns.add(run.id);
        }
      }
      updateSettledStatus();
    });
    pi.events.emit("subagents:rpc:v1:request", {
      version: 1,
      requestId,
      method: "status",
      params: {},
    });
  };

  pi.events.on("subagent:async-started", (event: any) => {
    if (!validID(event?.id)) return;
    subagentRuns.add(event.id);
    updateSettledStatus();
  });
  pi.events.on("subagent:async-complete", (event: any) => {
    const id = event?.runId ?? event?.id;
    if (validID(id)) subagentRuns.delete(id);
    updateSettledStatus();
  });
  pi.events.on("subagents:rpc:v1:ready", () => refreshSubagents());
  pi.events.on("pi-background-tasks:terminal:v1", (event: any) => {
    if (validID(event?.task?.id)) backgroundTasks.delete(event.task.id);
    updateSettledStatus();
  });

  pi.on("session_start", async (_event: any, context: any) => {
    closing = false;
    completionPending = false;
    currentContext = context;
    report("idle", false, context);
    refreshBackgroundTasks();
  });
  pi.on("before_agent_start", async (_event: any, context: any) => {
    completionPending = true;
    currentContext = context;
    report("working", false, context);
  });
  pi.on("agent_start", async (_event: any, context: any) => {
    completionPending = true;
    currentContext = context;
    report("working", false, context);
  });
  pi.on("tool_execution_start", async (event: any, context: any) => {
    currentContext = context;
    const waitingTools = new Set(["ask_user_question", "ask_question", "question", "confirm"]);
    const waiting = waitingTools.has(String(event.toolName));
    report(waiting ? "needsAttention" : "working", false, context, waiting ? "question" : undefined);
  });
  pi.on("tool_execution_end", async (event: any, context: any) => {
    currentContext = context;
    const task = event?.result?.details?.task;
    if (!event?.isError && task?.status === "running" && validID(task.id)) {
      backgroundTasks.add(task.id);
    }
    if (!event?.isError && backgroundToolNames.has(String(event?.toolName))) {
      refreshBackgroundTasks();
    }
    report("working", false, context);
  });
  pi.on("agent_settled", async (_event: any, context: any) => {
    // A previous run can settle after Esc just as a resumed prompt starts.
    // Never let that stale completion overwrite the newer working state.
    if (!context.isIdle()) return;
    updateSettledStatus(context);
  });
  pi.on("session_shutdown", async (_event: any, context: any) => {
    closing = true;
    subagentRuns.clear();
    backgroundTasks.clear();
    // Session shutdown is lifecycle cleanup, not task completion. Clear Pi's
    // identity so Ctrl-D, /new, /resume, /fork and /reload leave no done badge.
    report("idle", false, context);
    report(undefined, true, context);
  });
}
"""#

    private static let ampExtension = #"""
// OMG agent status integration for Amp.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";

const contextId = `omg-agent-amp-${process.pid}`;
const scope = process.env.SSH_CONNECTION ? "remote" : "local";
function report(state, end = false) {
  let fd;
  try {
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=amp;omg_scope=${scope};omg_liveness=pid\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=amp;omg_scope=${scope};omg_liveness=pid;omg_state=${state}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (amp) {
  amp.on("agent.start", () => report("working"));
  amp.on("agent.end", () => report("done"));
}
"""#

    private static let ompExtension = #"""
// OMG agent status integration for OMP.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";

const contextId = `omg-agent-omp-${process.pid}`;
const scope = process.env.SSH_CONNECTION ? "remote" : "local";
function report(state?: string, end = false, context?: any, attention?: string) {
  let fd: number | undefined;
  try {
    const raw = context?.sessionManager?.getSessionId?.();
    const conversation = raw && /^[A-Za-z0-9._-]{1,128}$/.test(String(raw))
      ? `;omg_conversation=${encodeURIComponent(String(raw))}` : "";
    // Report the session's project directory so restoration resumes the
    // conversation in the directory that owns it, not the shell's cwd.
    const rawCwd = context?.sessionManager?.getCwd?.();
    const sessionCwd = rawCwd && String(rawCwd).startsWith("/") &&
        String(rawCwd).length <= 4096 && !String(rawCwd).includes("\0")
      ? `;omg_cwd=${encodeURIComponent(String(rawCwd))}` : "";
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=omp;omg_scope=${scope};omg_liveness=pid${conversation}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=omp;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${conversation}${sessionCwd}${attentionKind}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export default function (omp: any) {
  omp.on("session_start", async (_event: any, context: any) => report("idle", false, context));
  omp.on("agent_start", async (_event: any, context: any) => report("working", false, context));
  omp.on("tool_call", async (event: any, context: any) => {
    const waitingTools = new Set(["ask_user_question", "ask_question", "question", "confirm"]);
    const waiting = waitingTools.has(String(event.toolName));
    if (waiting) report("needsAttention", false, context, "question");
  });
  omp.on("agent_end", async (_event: any, context: any) => report("done", false, context));
  omp.on("session_shutdown", async (_event: any, context: any) => report(undefined, true, context));
}
"""#

    private static let openCodeExtension = #"""
// OMG agent status integration for OpenCode.
// marker: _omg_agent_status
import { closeSync, openSync, writeSync } from "node:fs";

const contextId = `omg-agent-opencode-${process.pid}`;
const scope = process.env.SSH_CONNECTION ? "remote" : "local";
const roots = new Set();
function report(state, conversation, end = false, attention) {
  let fd;
  try {
    const safe = conversation && /^[A-Za-z0-9._-]{1,128}$/.test(String(conversation))
      ? `;omg_conversation=${encodeURIComponent(String(conversation))}` : "";
    const attentionKind = attention ? `;omg_attention=${attention}` : "";
    fd = openSync("/dev/tty", "w");
    const sequence = end
      ? `\u001b]3008;end=${contextId};type=app;omg_agent=opencode;omg_scope=${scope};omg_liveness=pid${safe}\u0007`
      : `\u001b]3008;start=${contextId};type=app;omg_agent=opencode;omg_scope=${scope};omg_liveness=pid;omg_state=${state}${safe}${attentionKind}\u0007`;
    writeSync(fd, sequence);
  } catch {
  } finally {
    if (fd !== undefined) {
      try { closeSync(fd); } catch {}
    }
  }
}

export const OmgAgentStatus = async () => ({
  event: async ({ event }) => {
    const info = event.properties?.info;
    if (event.type === "session.created" || event.type === "session.updated") {
      if (info?.id) {
        if (info.parentID) roots.delete(info.id); else roots.add(info.id);
      }
      return;
    }
    if (event.type === "session.deleted") {
      if (info?.id && roots.delete(info.id)) report(undefined, info.id, true);
      return;
    }
    const id = event.properties?.sessionID;
    if (!id || !roots.has(id)) return;
    if (event.type === "permission.updated") return report("needsAttention", id, false, "permission");
    if (event.type === "session.status") {
      if (event.properties?.status?.type === "busy") return report("working", id);
      if (event.properties?.status?.type === "idle") return report("done", id);
    }
  },
});
"""#
}

enum AgentActivityUpdate: Equatable, Sendable {
    case set(TabActivity)
    case clear
}

struct AgentSessionSignal: Equatable, Sendable {
    let contextID: String
    let agent: SupportedAgent
    let scope: AgentExecutionScope
    let conversationID: AgentConversationID?
    /// The session's own project directory reported by the agent hook via
    /// `omg_cwd`, when the hook supports it. Resuming a conversation is
    /// directory-scoped for agents such as Pi, so restoration must prefer
    /// this over the pane's shell working directory.
    let workingDirectory: String?
}

struct AgentActivityCandidate: Sendable {
    let activity: TabActivity
    let isFocused: Bool
}

enum AgentActivitySelection {
    static func preferred(
        _ candidates: [AgentActivityCandidate]
    ) -> TabActivity? {
        candidates.max { lhs, rhs in
            let lhsPriority = priority(lhs.activity.state)
            let rhsPriority = priority(rhs.activity.state)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.isFocused != rhs.isFocused {
                return !lhs.isFocused && rhs.isFocused
            }
            return false
        }?.activity
    }

    private static func priority(_ state: TabActivityState) -> Int {
        switch state {
        case .needsAttention: 5
        case .error: 4
        case .working: 3
        case .done: 2
        case .idle: 1
        }
    }
}

enum AgentLivenessIdentity: Equatable, Sendable {
    case process(Int)
    case processGroup(Int)

    func matchesProcessGroup(_ value: Int?) -> Bool {
        guard case .processGroup(let processGroupID) = self else { return false }
        return processGroupID == value
    }
}

struct AgentContextSignalReducer: Sendable {
    private enum Scope: String, Sendable {
        case local
        case remote
        case legacy
    }

    private struct Identity: Sendable {
        let value: Int?
    }

    private struct Record: Sendable {
        let id: String
        let activity: TabActivity
        let scope: Scope
        let liveness: AgentLivenessIdentity?
        let updatedAt: Date
        let terminated: Bool
    }

    static let maximumTrackedContexts = 32
    private static let startupValidationGrace: TimeInterval = 4
    private var activities: [Record] = []

    var trackedContextCount: Int { activities.count }
    var currentContextID: String? { currentRecord?.id }
    var hasRemoteActivity: Bool { activities.contains { $0.scope == .remote } }

    var validationIdentity: AgentLivenessIdentity? {
        guard let current = currentRecord,
              current.scope == .local else { return nil }
        return current.liveness
    }

    var requiresForegroundValidation: Bool {
        validationIdentity != nil
    }

    static func sessionSignal(
        from signal: Ghostty.ContextSignal
    ) -> AgentSessionSignal? {
        guard signal.action == .start else { return nil }
        let metadata = metadata(signal.metadata)
        guard metadata["type"] == "app",
              let rawAgent = metadata["omg_agent"],
              let agent = SupportedAgent(rawValue: rawAgent),
              identity(signal.id, agent: agent) != nil,
              let rawScope = metadata["omg_scope"],
              let scope = AgentExecutionScope(rawValue: rawScope) else { return nil }
        let conversationID = metadata["omg_conversation"]?
            .removingPercentEncoding
            .flatMap(AgentConversationID.init)
        let workingDirectory = metadata["omg_cwd"]?
            .removingPercentEncoding
            .flatMap(Self.validatedSessionWorkingDirectory)
        return .init(
            contextID: signal.id,
            agent: agent,
            scope: scope,
            conversationID: conversationID,
            workingDirectory: workingDirectory
        )
    }

    /// Validates a session working directory reported via `omg_cwd`. The
    /// value must be an absolute POSIX path with bounded length and no NUL
    /// bytes; anything else is treated as absent so restoration falls back
    /// to the pane's shell working directory.
    private static func validatedSessionWorkingDirectory(
        _ value: String
    ) -> String? {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              value.utf8.count <= 4_096 else { return nil }
        return value
    }

    mutating func consume(_ signal: Ghostty.ContextSignal) -> AgentActivityUpdate? {
        guard signal.id.hasPrefix("omg-agent-") else { return nil }
        switch signal.action {
        case .end:
            return consumeEnd(signal.id)

        case .start:
            let metadata = Self.metadata(signal.metadata)
            guard metadata["type"] == "app",
                  let rawAgent = metadata["omg_agent"],
                  let agent = SupportedAgent(rawValue: rawAgent),
                  let identity = Self.identity(signal.id, agent: agent),
                  let rawState = metadata["omg_state"],
                  let state = Self.state(rawState) else { return nil }
            let scope = metadata["omg_scope"].flatMap(Scope.init) ?? .legacy
            let liveness = Self.liveness(
                identity: identity,
                agent: agent,
                scope: scope,
                metadata: metadata
            )
            let progress = metadata["progress"].flatMap(Double.init).flatMap {
                (0...1).contains($0) ? $0 : nil
            }
            let attentionKind = state == .needsAttention
                ? metadata["omg_attention"].flatMap(TabAttentionKind.init)
                : nil
            let phase = state == .working
                ? metadata["omg_phase"].flatMap(TabActivityPhase.init)
                : nil
            let activity = TabActivity(
                source: agent.rawValue,
                state: state,
                phase: phase,
                attentionKind: attentionKind,
                label: agent.displayName,
                message: metadata["message"]?.removingPercentEncoding,
                detail: nil,
                progress: progress,
                icon: agent.icon
            )
            activities.removeAll { $0.id == signal.id }
            if activities.count >= Self.maximumTrackedContexts {
                activities.removeFirst(
                    activities.count - Self.maximumTrackedContexts + 1
                )
            }
            activities.append(Record(
                id: signal.id,
                activity: activity,
                scope: scope,
                liveness: liveness,
                updatedAt: Date(),
                terminated: false
            ))
            return .set(activity)
        }
    }

    mutating func reconcileLocalForegroundProcess(
        _ foregroundPID: Int?,
        livenessIsAlive: Bool? = nil,
        now: Date = Date()
    ) -> AgentActivityUpdate? {
        var removedCurrent = false
        while let current = currentRecord,
              current.scope == .local,
              let liveness = current.liveness {
            if livenessIsAlive == true || liveness.matchesProcessGroup(foregroundPID) {
                break
            }
            guard livenessIsAlive != nil else { return nil }
            guard now.timeIntervalSince(current.updatedAt) >=
                    Self.startupValidationGrace else { return nil }
            if current.activity.state == .working ||
                current.activity.state == .needsAttention {
                return markUnexpectedInterruption(record: current, now: now)
            }
            activities.removeLast()
            removedCurrent = true
        }
        guard removedCurrent else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    mutating func acknowledgeTerminalState() -> AgentActivityUpdate? {
        guard let current = currentRecord,
              current.activity.state == .done ||
                current.activity.state == .error else { return nil }
        if current.terminated {
            activities.removeLast()
            return currentRecord.map { .set($0.activity) } ?? .clear
        }
        let idle = TabActivity(
            source: current.activity.source,
            state: .idle,
            label: current.activity.label,
            message: nil,
            detail: nil,
            progress: nil,
            icon: current.activity.icon
        )
        activities[activities.count - 1] = Record(
            id: current.id,
            activity: idle,
            scope: current.scope,
            liveness: current.liveness,
            updatedAt: current.updatedAt,
            terminated: false
        )
        return .set(idle)
    }

    mutating func consumeRemotePrompt(
        _ signal: Ghostty.ContextSignal
    ) -> AgentActivityUpdate? {
        guard signal.action == .start,
              signal.id.hasPrefix("omg-ssh-"),
              Self.metadata(signal.metadata)["cwd"] != nil ||
                Self.metadata(signal.metadata)["cwdhex"] != nil else { return nil }
        return clearRemoteActivities()
    }

    /// Removes all remote-owned presentation after the local SSH transport is
    /// known to have ended. Local nested contexts, if any, become visible
    /// again instead of being discarded with the remote connection.
    mutating func clearRemoteActivities() -> AgentActivityUpdate? {
        let previousID = currentRecord?.id
        activities.removeAll { $0.scope == .remote }
        guard previousID != currentRecord?.id else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private var currentRecord: Record? { activities.last }

    private mutating func consumeEnd(_ id: String) -> AgentActivityUpdate? {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let current = activities[index]
        guard index == activities.count - 1 else {
            activities.remove(at: index)
            return nil
        }
        if current.activity.state == .working ||
            current.activity.state == .needsAttention {
            return markUnexpectedInterruption(record: current)
        }
        if current.activity.state == .done {
            return remove(id)
        }
        if current.activity.state == .error,
           current.terminated {
            return nil
        }
        return remove(id)
    }

    private mutating func markUnexpectedInterruption(
        record: Record,
        now: Date = Date()
    ) -> AgentActivityUpdate {
        let error = TabActivity(
            source: record.activity.source,
            state: .error,
            label: record.activity.label,
            message: "Agent process exited unexpectedly.",
            detail: nil,
            progress: nil,
            icon: record.activity.icon
        )
        if let index = activities.firstIndex(where: { $0.id == record.id }) {
            activities[index] = Record(
                id: record.id,
                activity: error,
                scope: record.scope,
                liveness: nil,
                updatedAt: now,
                terminated: true
            )
        }
        return .set(error)
    }

    private mutating func remove(_ id: String) -> AgentActivityUpdate? {
        guard let index = activities.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let wasActive = index == activities.count - 1
        activities.remove(at: index)
        guard wasActive else { return nil }
        return currentRecord.map { .set($0.activity) } ?? .clear
    }

    private static func identity(
        _ id: String,
        agent: SupportedAgent
    ) -> Identity? {
        let prefix = "omg-agent-\(agent.rawValue)"
        if id == prefix { return Identity(value: nil) }
        guard id.hasPrefix(prefix + "-") else { return nil }
        let raw = id.dropFirst(prefix.count + 1)
        guard !raw.isEmpty,
              raw.count <= 20,
              raw.allSatisfy(\.isNumber),
              let value = Int(raw),
              value > 0 else { return nil }
        return Identity(value: value)
    }

    private static func liveness(
        identity: Identity,
        agent: SupportedAgent,
        scope: Scope,
        metadata: [String: String]
    ) -> AgentLivenessIdentity? {
        guard scope == .local, let value = identity.value else { return nil }
        switch metadata["omg_liveness"] {
        case "pid": return .process(value)
        case "pgid": return .processGroup(value)
        case nil:
            // Hook plugins historically used their process PID in the context
            // suffix, while shell/config hooks and foreground synthesis used a
            // process-group ID. Preserve both old formats during hook upgrades.
            return agent.definition.hook.kind == .plugin
                ? .process(value)
                : .processGroup(value)
        default: return nil
        }
    }

    private static func state(_ raw: String) -> TabActivityState? {
        switch raw {
        case "idle": .idle
        case "working", "processing", "active": .working
        case "waiting", "awaiting", "blocked", "needsAttention": .needsAttention
        case "done", "completed": .done
        case "error", "failed": .error
        default: nil
        }
    }

    private static func metadata(_ raw: String) -> [String: String] {
        raw.split(separator: ";").reduce(into: [:]) { result, field in
            let parts = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  !parts[0].isEmpty,
                  !parts[1].isEmpty,
                  parts[0].count <= 64,
                  parts[1].count <= 512 else { return }
            result[String(parts[0])] = String(parts[1])
        }
    }
}

@MainActor
final class MockAgentStatusAdapter {
    static let pluginID = "dev.oh-my-ghostty.mock-agent"

    private let store: TabActivityStore
    private var revisions: [UUID: UInt64] = [:]

    init(store: TabActivityStore) {
        self.store = store
    }

    @discardableResult
    func report(
        sessionID: UUID,
        state: TabActivityState,
        message: String? = nil
    ) -> PluginProtocolFailure? {
        let revision = (revisions[sessionID] ?? 0) + 1
        revisions[sessionID] = revision

        if state == .idle {
            return store.clear(
                .init(sessionID: sessionID, revision: revision),
                pluginID: Self.pluginID
            )
        }

        let wireState: PluginSessionStatus.State = switch state {
        case .idle: .completed
        case .working: .running
        case .done: .completed
        case .needsAttention: .waiting
        case .error: .failed
        }
        return store.set(
            .init(
                sessionID: sessionID,
                revision: revision,
                status: .init(
                    agent: "mock",
                    title: "Mock Agent",
                    state: wireState,
                    message: message,
                    icon: .init(kind: .systemSymbol, name: "bolt.fill")
                ),
                ttlMilliseconds: state == .done ? 15_000 : nil
            ),
            pluginID: Self.pluginID,
            sessionExists: { $0 == sessionID }
        )
    }
}

extension TabActivityState {
    var titleMarker: String {
        switch self {
        case .idle: ""
        case .working: "⏳"
        case .done: "✓"
        case .needsAttention: "⚠️"
        case .error: "✕"
        }
    }
}

extension PluginSessionStatus.State {
    var titleMarker: String {
        switch self {
        case .running: "⏳"
        case .waiting: "⚠️"
        case .completed: "✓"
        case .failed: "✕"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "hourglass"
        case .waiting: "exclamationmark.triangle.fill"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }
}
