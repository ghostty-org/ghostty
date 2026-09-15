# OMG Plugin Development

> **Public API status:** pre-release / not externally loadable.

This document is the source of truth for OMG's plugin and host-extension
contracts. It intentionally describes only code that exists. OMG currently has
versioned protocol components and working in-process Inspector/status models,
but it does **not** discover, install, launch, or connect third-party plugin
executables in production.

A directory, manifest, or executable copied beside OMG will not be loaded.
The Experimental `PluginInstallationManager` can download a GitHub repository's
`main` archive, validate `manifest.json`, and store it under the OMG Application
Support Plugins directory, but no installed package is launched or connected to
runtime yet. There is no public SDK, socket listener, or hot reload command.

## Documentation maintenance rule

Plugin behavior is a public compatibility boundary even before the public
runtime ships. Any change to plugin APIs, `PluginManifest`, wire messages,
capabilities, lifecycle, loading/discovery, directory/package layout, Inspector
provider behavior, or plugin permissions **must update this document and the
relevant tests in the same commit**.

Contributor checklist:

```text
[ ] Did this change affect a plugin API, manifest, message, capability,
    lifecycle, loading path, directory layout, or security boundary?
[ ] If yes, were docs/PLUGIN_DEVELOPMENT.md and capability tests updated?
[ ] Are Experimental/Internal/Planned labels still accurate?
```

## Status summary

### Stable application behavior

These are connected to the running app and covered by app-hosted tests, but are
not a third-party SDK:

- host-owned `TabActivityStore` and normalized tab activity rendering;
- Core-owned Right Inspector shell, layout, selection, lifecycle delivery, and
  typed content rendering;
- owner validation and cleanup in `InspectorRegistry`;
- built-in `builtin.files` provider using the plugin-shaped Inspector boundary;
- built-in `builtin.git` provider with frozen-tip, paginated commit history,
  branch scope switching, and native table rendering;
- stable terminal tab identity via `OH_MY_GHOSTTY_SESSION`;
- manifest-driven built-in Agent adapters using bounded OSC 3008 presentation
  events on the owning Surface.

### Experimental protocol components

These compile and have unit tests, but no production transport connects them:

- `PluginProtocolContract` v1;
- length-prefixed JSON `PluginWireCodec`;
- `PluginManifest` data model;
- nonce/version/capability intersection in `PluginAuthorizationPolicy`;
- `PluginMessageRouter` for session status set/clear commands;
- validated status ownership, revisions, TTL, icons, ACK, and failures.

### Internal host extension points

These require compiling code into OMG and are not ABI/API-stable:

- `InspectorRegistry.registerCorePane`;
- `InspectorRegistry.registerPluginPane` and `updatePluginContent`;
- `GhosttyTabMetadataProviding`;
- `GhosttyTabIconProviding`;
- `MockAgentStatusAdapter`;
- `AgentContextSignalReducer` and `AgentHookInstaller`;
- `BuiltInFilesInspectorProvider`;
- `BuiltInInfoInspectorProvider` and its host-owned Info/port-forward lifecycle.

### Not yet supported

- plugin discovery or manifest file loading;
- plugin package build/distribution and runtime loading;
- plugin installation is Experimental and currently only supports a GitHub main
  branch archive; update/enable/disable/uninstall are storage operations only;
- executable launch, Unix socket ingress, peer UID/PID checks, supervision,
  restart, heartbeat, or unload/reload;
- external Inspector registration/update/action messages;
- public commands, settings contributions, Sidebar model, QuickInput, terminal
  control, or raw terminal output;
- filesystem, network, shell, clipboard, settings, or storage APIs for plugins;
- SSH workspace/session integration is an in-tree provider boundary, not an
  installable external plugin yet;
- third-party sandbox/signature/permission UI;
- public SDK artifacts or a Marketplace.

## Architecture and terminology

OMG has two different mechanisms that must not be conflated.

### Process plugin contract

`macos/Sources/Features/Plugins/PluginProtocol.swift` and
`PluginHost.swift` define protocol/authorization/status components intended for
future supervised child processes.

```text
future executable
  -> 4-byte big-endian length + JSON frame
  -> authorization and capability intersection
  -> PluginMessageRouter
  -> host-owned stores and presentation
```

The executable, socket, and process supervisor do not exist yet. Today this
path is instantiated only in tests.

### In-process Inspector provider

`InspectorRegistry` is a Core-owned Swift registry. It accepts declarative data
and callbacks from code compiled into OMG:

```text
in-tree provider
  -> InspectorPaneDescriptor
  -> typed InspectorPaneContent
  -> RightInspectorHost (host rendering)
```

`BuiltInFilesInspectorProvider` uses `.plugin("builtin.files")` to dogfood
owner checks and typed content. It is still trusted application code, not an
out-of-process plugin and not proof of public plugin loading.

Files actions stay data-only. Directory rows toggle disclosure through typed
actions, while file rows only request an editor open on explicit double-click or
the row context menu's `Open in Editor` command. The provider validates that the
path belongs to the current published file tree and is not a directory, then
calls the host-injected `OpenFileHandler` with the absolute path and the current
`InspectorPaneContext`, preserving local versus SSH session context for the
editor controller. Single-click selection does not open files.

The host renders file tree icons using bundled Material Icon Theme artwork and
its filename, compound-extension, and folder associations, shared by local and
SSH trees. Expanded folders and light appearance use the corresponding upstream
variants. The existing `InspectorFileIcon` remains the fallback if an asset is
unavailable; this does not add manifest fields or runtime network access. The
upstream MIT license is included in the application asset catalog.

## Manifest model (Experimental)

`PluginManifest` is `Codable` and currently contains:

| Field                | Type                         | Purpose                              | Enforced today                       |
| -------------------- | ---------------------------- | ------------------------------------ | ------------------------------------ |
| `id`                 | `String`                     | identity matched against hello       | only when policy is manually invoked |
| `version`            | `String`                     | plugin version matched against hello | yes in policy tests                  |
| `executable`         | `String`                     | intended executable path             | no loader resolves it                |
| `capabilities`       | `[PluginCapability]`         | maximum capability allowlist         | yes in policy tests                  |
| `minimumHostVersion` | `String?`                    | intended OMG compatibility floor     | not evaluated                        |
| `settings`           | `[PluginSettingDescriptor]?` | declarative setting metadata         | not rendered/stored                  |

The default Swift `Codable` keys are camelCase. This JSON demonstrates the data
shape only; no filename or directory makes it installable:

```json
{
  "id": "dev.example.status",
  "version": "0.1.0",
  "executable": "bin/status-plugin",
  "capabilities": ["sessionStatus", "tabIcon"],
  "minimumHostVersion": "0.1.0",
  "settings": null
}
```

`PluginSettingDescriptor.ValueType` declares `boolean`, `string`,
`enumeration`, `number`, `path`, and `secret`. There is no settings renderer,
secret store, or permission behavior behind these values.

## API and protocol versioning

The wire API version is:

```swift
PluginProtocolContract.currentVersion == 1
```

A plugin hello carries:

- `pluginID`;
- `pluginVersion`;
- `supportedProtocolVersions`;
- `requestedCapabilities`;
- one-time `nonce`.

The host policy verifies manifest identity/version and nonce, requires protocol
v1 support, and grants the intersection of manifest and requested capabilities.
`PluginWelcome` returns selected protocol version, granted capabilities, and
host version.

There is no separate manifest `apiVersion`; protocol compatibility is already
negotiated through `supportedProtocolVersions`. `minimumHostVersion` exists but
is not enforced because no loader exists. Treat all process protocol types as
Experimental until an end-to-end runtime and compatibility policy ship.

Compatibility rules for future changes:

- additive optional payload fields may remain in the current protocol only when
  old decoders remain valid;
- new required semantics or message kinds require an explicit compatibility
  decision and tests;
- never reinterpret an existing capability as broader access;
- manifest and protocol changes update this guide in the same commit.

## Wire format (Experimental)

`PluginWireCodec` uses:

```text
4-byte unsigned big-endian payload length
UTF-8 JSON payload
```

Maximum payload size is 1,048,576 bytes. Empty and oversized frames fail before
JSON routing. The envelope fields are:

| Field            | Type                  |
| ---------------- | --------------------- |
| `version`        | UInt16                |
| `sequence`       | UInt64                |
| `correlation_id` | optional UInt64       |
| `type`           | message discriminator |
| `payload`        | typed payload         |

Message bodies implemented by the codec:

- `hello`, `welcome`;
- `subscribe`, `sessionEvent`;
- `setSessionStatus`, `clearSessionStatus`;
- `acknowledgement`, `failure`.

Encoding support does not mean every message is routed in production.
`PluginMessageRouter.handle` currently accepts only status set/clear as plugin
commands. Other bodies return `invalidMessage`. The built-in agent adapters do
not pretend this future process transport exists: they normalize agent-native
hooks into a separate bounded, presentation-only OSC path owned by Core.

## Capabilities

| Capability             | Current behavior                                                                   | Stability                        |
| ---------------------- | ---------------------------------------------------------------------------------- | -------------------------------- |
| `sessionStatus`        | router can set/clear validated status                                              | Experimental component           |
| `tabIcon`              | permits validated icon in a status command                                         | Experimental component           |
| `terminalEvents`       | event/subscription data types only                                                 | Stub                             |
| `tabMetadata`          | enum plus separate in-process provider model                                       | Stub for process plugin          |
| `inspectorPane`        | in-process typed registry works; no wire messages                                  | Internal / process stub          |
| `settingsContribution` | manifest descriptors only                                                          | Stub                             |
| `commands`             | capability name only                                                               | Stub                             |
| `sidebarModel`         | capability name only                                                               | Stub                             |
| `quickInput`           | built-in host composer and per-Surface queue work; no process-plugin wire messages | Internal / process stub          |
| `terminalControl`      | built-in user-confirmed QuickInput writes work; no process-plugin wire messages    | Planned, high risk               |
| `rawTerminalOutput`    | capability name only                                                               | Planned, high risk, default deny |

Quick Input presentation and focus remain Host-owned. The built-in composer participates in macOS `Option-Command` directional focus navigation, but this does not grant a plugin focus control. When the user enables `agents.openQuickInputOnStart`, the Host may expand Quick Input on the focused Pane's first Agent activity without changing first responder. `agents.openQuickInputOnComplete` applies the same Host-owned presentation policy to a newly completed focused Agent session. Plugin lifecycle messages cannot force focus or override either preference.

### Session status API

`setSessionStatus` arguments:

- stable terminal session UUID;
- monotonically increasing per-plugin/session revision;
- agent, state, and optional title/message/detail/progress/icon;
- optional TTL in milliseconds.

Wire states map to host activity:

| Wire        | Host activity    |
| ----------- | ---------------- |
| `running`   | `working`        |
| `waiting`   | `needsAttention` |
| `completed` | `done`           |
| `failed`    | `error`          |

The in-tree OSC adapter can additionally retain an `idle` `TabActivity` so the
agent identity icon remains visible while its TUI is connected but not running a
turn. A `working` activity may carry the internal `background` phase when Pi's
foreground loop is idle but package-owned asynchronous work remains. Neither is
a new v1 process-plugin wire state.

Validation includes session existence, owner, increasing revision, progress
`0...1`, bounded strings, bounded TTL (maximum 24 hours), and safe icon names.
A status is removed on explicit clear, TTL expiry, session deletion, or router
disconnect. Successful commands return an acknowledgement correlated to the
request sequence; failures return a typed `PluginProtocolFailure`.

### Built-in agent hook bridge (Internal)

Settings → Plugins → Agent Integration selects **This Mac** or an OpenSSH alias.
Hook state and install/update/remove actions are scoped to that selected account;
changing selection never retargets an in-flight operation. The normalized status
events master switch remains an OMG-wide presentation setting. Detector-only
agents are explicitly shown as managed by the local Host, not as remote hooks.

`AgentIntegrationManager` checks installed Hooks while OMG runs, including when
Settings is closed. Each account has an independent hourly/daily/weekly interval,
automatic-check preference, optional automatic Hook updates, and per-Agent CLI
auto-update switches. Local checks default to daily; SSH background checks and all
automatic installation default off. Enabling a target does not install missing
Hooks or Agent executables. Policy and check timestamps are stored in the app's
UserDefaults domain under `OMG.AgentIntegration.Policies.v1`, separating Dev and
release. Errors stay attached to their target; the last successful Hook check is
displayed separately from a CLI discovery failure. Failed attempts retry at the
configured interval; per-target operations are serialized.

Remote Hook operations reuse the exported Python installer with typed `status`,
`install`, or `remove` actions and a closed Agent selection. No arguments preserves
the export's install-all-supported-Hooks behavior. The script travels on stdin
through system OpenSSH with BatchMode, connection/keepalive deadlines and bounded
output; it requires Python 3 and existing non-interactive SSH authentication.
Credentials, host keys and ProxyJump remain owned by OpenSSH. No remote install or
remove is performed merely by selecting a host or checking its status.

CLI checks use the account's login/interactive shell PATH. Only an executable
whose resolved path matches a global npm package's declared bin is eligible for
CLI updates. Other installations show their version and an original-installer
hint. Before each update, the installation source and npm registry state are
rechecked, then the selected newer stable version is installed explicitly. OMG
does not downgrade versions, switch prerelease channels, use sudo, or update
unselected Agents. Hook maintenance runs before CLI discovery so registry errors
cannot prevent Hook updates. npm registry semantics follow
[npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated/).

Tests execute the exported script against temporary homes across every Hook
dialect, verify scoped removal preserves third-party Hooks, and exercise npm bin
identity, exact-version updates, downgrade rejection and per-host policy isolation.

`AgentHookInstaller` installs only the closed mechanism selected by each bundled
manifest: nested JSON, Cursor/Copilot/Reasonix flat JSON, Pi-compatible or
OpenCode/Amp plugins, marker-delimited Kimi TOML, and event-named Cline scripts.
It never removes unrelated JSON/TOML entries, never overwrites a non-OMG Cline
script, rejects malformed config rather than replacing it, uses atomic
mode-preserving writes (0600 for new files), and keeps a one-time `.omg-backup`
beside each existing file. Removal deletes only OMG-owned commands or blocks.

Antigravity, Crush, and Hermes do not expose a supported vendor hook path. Their
Install action therefore creates a Host-owned, versioned detector marker under
`~/.config/oh-my-ghostty/agent-detectors/<agent>.json`; the directory is mode
0700 and each exact allowlisted marker is mode 0600. The host enables process and
bounded screen detection for these agents only while the current marker exists.
Remove deletes only a regular marker whose owner/agent fields match OMG, and
Update replaces stale marker content. A one-time global sentinel migrates the
three previously implicit detectors to Installed; after that, a user removal is
never auto-installed again. Conflicting or non-file content fails closed. These
markers are local Host policy and are intentionally excluded from
the exported remote hook installer; OMG does not claim to install a vendor hook
that does not exist.

Adapters emit OSC 3008 contexts with IDs
`omg-agent-<allowlisted-agent>-<numeric-instance-id>`, `type=app`, a bounded
`omg_state`, `omg_scope=local|remote`, `omg_liveness=pid|pgid`, optional
validated `omg_conversation`, optional validated `omg_cwd` (the session's
own project directory, used for directory-scoped resume), optional
`omg_attention=question|permission`, and optional `omg_phase=background` for a
`working` Pi context whose foreground loop is idle while an owned
`pi-subagents` run or `pi-background-tasks` task remains active. Pi-compatible
and other in-process Plugin
adapters use their process PID as the instance/liveness identity; shell/config
hooks and host foreground synthesis use the process-group ID. The host verifies
that ID and metadata name the same built-in agent, then associates the event
with the Surface that parsed it. During migration, missing `omg_liveness`
retains the historical meaning based on the manifest hook kind. Because some
agent versions defer or omit `SessionStart`, the macOS host samples Ghostty's
foreground process-group PID once per second; only when that PID changes does a
utility-queue `ps` lookup apply manifest process markers and synthesize `idle`
for an enabled integration. Local startup then gets a four-second foreground
handoff grace, after which validation keeps the identity while its declared PID
or process group exists and clears it when that identity exits. A Plugin PID is
not compared directly with the foreground process-group ID, so wrappers and
child tool execution cannot create a false `error` while the Agent is alive. In
SSH, the host never guesses a remote Agent from local process names. It does
conservatively recognize a foreground interactive OpenSSH client (`ssh host`,
excluding forwarding/control/no-command modes and explicit remote commands) as
the pane transport. The destination becomes an inferred SSH context, a validated
remote Agent `omg_cwd` can complete its remote workspace, and a foreground
process-group transition back to the local shell atomically clears all remote
Agent presentation and resume state. A matching typed `omg +ssh` end performs
the same cleanup; the next authenticated remote Fish/bash/zsh prompt remains an
additional orphan-recovery signal.
Unique instance IDs prevent an old `end` from clearing a newer same-agent
session. Each Surface keeps one ordered, 32-context reducer; exceeding the bound
evicts the oldest identity while preserving the newest presentation, and later
signals for an evicted identity are ignored. An `end` or failed local liveness
check while the current state is
`working`/`needsAttention` becomes a terminal `error` rather than silently
clearing; normal completion remains `done`. Pi `session_shutdown` first returns
the context to `idle` and then ends it, so Ctrl-D and session replacement clear
identity instead of leaving a false completion badge. Tab selection and pane focus do not
acknowledge either state. Only mouse click or keyboard input delivered to the
owning focused terminal clears `done`/`error`. These events can change
only host-owned tab presentation; they do not authorize terminal input,
filesystem, network, or plugin execution. A process can spoof its own tab badge,
but cannot use this channel to gain capabilities.

Agents that declare `titleStatus` patterns also derive activity from the
terminal title while no typed hook event owns the context. When the title no
longer matches a working pattern the host downgrades that title-derived
`working` state to `idle`, so the ring clears once the agent settles instead of
spinning forever. Agents without `titleStatus` (including the screen-detected
Antigravity/Crush/Hermes) are unaffected by this title path.

Because the event is written to the owning TTY, the same hook works through
OpenSSH. Shell hooks resolve the target TTY from the parent process with
`ps -o tty=` and keep the process-group ID for the instance context; when that
lookup yields no usable TTY they fall back to `/dev/tty` rather than silently
exiting, which is what Pi-compatible extensions already use. Hooks must be
installed in the account where the agent executable runs.
Settings can export an auditable Python 3 installer for explicit transfer and
execution on that account; OMG does not log in or silently modify remote dotfiles.

Agent glyphs use MIT-licensed assets from LobeHub `lobe-icons` 1.94.0,
Termio, OMP/oh-my-pi, and Reasonix. Product names and marks remain trademarks
of their respective owners; the assets do not imply vendor endorsement.

### Built-in agent manifests and restoration (Internal)

Bundled `Agent*Manifest.dataset` JSON files are the single data source for each
allowlisted agent's command, icon, optical scale, process markers, hook
kind/dialect/path/events/identity fields, status rules, resume argv, and on-disk
store/discovery mechanism. The roster covers Codex, Claude Code, Pi, Qoder CLI,
Reasonix, OMP, OpenCode, Amp, Antigravity, Cline, Copilot, Crush, Cursor Agent,
Droid, Grok, Hermes, Kimi, and Qwen Code. Manifests can select only closed host
mechanisms; they cannot inject Swift, shell, or arbitrary remote commands. Hook
`dialect` is a closed, decoded enum (`amp`, `cline`, `copilot`, `cursor`, `flat`,
`kimi`, `nested`, `opencode`, or `pi`); unknown values reject the bundled
manifest instead of silently falling through to another hook shape. Local hook
installation and the exported remote installer derive JSON hook entries from
the same typed builder.

`AgentResumeDescriptor` persists only a version, allowlisted agent, bounded ASCII
conversation ID, local/remote scope, cwd, and validated `SSHReplayDescriptor`.
Terminal restoration v9 stores this descriptor on its owning Surface. Local
restore builds only allowlisted resume argv such as `codex resume <id>`,
`claude --resume <id>`, or `pi --session-id <id>`. Ghostty's outer `/bin/sh`
does not inherit shell-managed PATH entries, so the argv is executed by the
user's login+interactive shell; this resolves Homebrew/mise/npm-installed Agent
binaries without storing arbitrary PATH or command data. The pane falls back to
the login shell when the Agent exits. macOS wraps every Surface command as
`exec -l <command>`, so restored commands are grouped inside a
`/bin/sh -c '<command>; exec -l <login shell>'` survival wrapper. The inner
login exec matches a normal terminal launch and reloads login-only prompt setup;
without the inner shell the outer exec discards the post-Agent command and the pane closes
the moment the Agent exits.
Remote restore replays original OpenSSH argv and passes only typed
`--remote-agent` / `--remote-agent-session` options to `+ssh`; the detected
Fish/bash/zsh shell restores cwd, emits a ready context, runs the allowlisted
resume command, then returns to its interactive prompt. When the conversation
ID is absent (the Agent exited back to a remote shell), the restore command
reconnects `+ssh` without `--remote-agent` so the pane lands in the remote
shell instead of spawning a fresh Agent session.

Each Surface also persists an `SSHResumeDescriptor` (validated SSH replay argv,
last ready remote cwd, and pre-SSH local cwd) whenever an `omg +ssh` connection
is active, independent of any Agent session. On restore, panes without a
usable Agent resume descriptor replay `+ssh` with the recorded remote cwd and
survival wrapper, so agent-free `omg +ssh` tabs reconnect instead of degrading
to a local shell. The descriptor clears when the connection ends, matching the
split replay lifecycle. A directly typed ordinary `ssh host` is recognized at
runtime from its foreground process group but has no validated replay argv, so
it is deliberately not made restorable or silently rewritten through `+ssh`.

Conversation identity comes from hook stdin (`session_id`), Pi-compatible
`sessionManager.getSessionId()`, OpenCode events, Reasonix's bounded machine JSON
command, or bounded cwd+creation-time JSONL discovery.
Multiple candidates are ambiguous and never resolved using `--last` or
`--continue`. Agent end or the first resumed SSH prompt clears the descriptor,
so a tab whose user explicitly ran `/quit` restores as a shell.

Resume lookup is directory-scoped for agents such as Pi (`pi --session-id <id>`
searches only the current project's sessions), and `pi resume` can start a
conversation owned by a directory other than the shell's current one. Hooks
that can observe the session's own project directory report it as validated
`omg_cwd` on the session signal (Pi-compatible adapters read
`sessionManager.getCwd()`); the resume descriptor prefers that directory over
the pane's shell cwd for both local and remote restoration, so the resumed
agent lands in the directory that owns the conversation instead of creating a
new one. When `omg_cwd` is absent (older hook, or an agent that cannot report
it), restoration keeps using the pane cwd.

### Terminal events

The following general process-plugin data kinds exist but no running external
event bridge publishes them:

- opened/closed;
- title changed;
- progress changed;
- foreground process changed;
- focus changed.

The planned public status CLI and authenticated app IPC are not implemented.
`OH_MY_GHOSTTY_SESSION` remains the stable Tab identity for the future process
plugin path; the built-in hook bridge is correlated directly by Surface.

## Workspace and SSH provider (Experimental)

`WorkspaceDescriptor` and `WorkspaceFilesystem` are generic boundaries for
local and remote workspace providers. `LocalWorkspaceFilesystem` is the local
implementation used by the Files provider. `SSHPlugin` reads non-wildcard
aliases from the user's `~/.ssh/config` without owning private keys, passwords,
known_hosts, ProxyJump, or ssh-agent state. `SSHWorkspaceFilesystem` uses the
system `/usr/bin/sftp` client and the user's OpenSSH configuration for bounded
remote directory operations, file/folder creation, and editor file transfers.

The internal `readFile(at:)` and `writeFile(_:at:replacing:)` operations power
the same editor document model for local files and SSH files. Reads accept
text files up to 10 MiB; SSH checks the downloaded temporary file before
loading it into memory. Saves compare the last-read bytes before writing and
report external changes instead of silently overwriting them. Local saves
replace the resolved target atomically and preserve its POSIX permissions;
SSH saves reuse SFTP get/put and require an already usable OpenSSH connection.
These are internal host operations, not new extension wire capabilities.

Tab presentation is a zero-I/O consumer of this boundary: remote folder names
are derived with pure POSIX string handling, and `WorkspaceDescriptor` identity
comes directly from the validated `sshReady` alias/cwd. It does not call
`URL(fileURLWithPath:)`, `lstat`, or parse `~/.ssh/config` from a SwiftUI row
body. OpenSSH configuration is resolved only when `WorkspaceFilesystemFactory`
actually creates the Files provider; a missing alias yields an unavailable SSH
filesystem and never falls back to local I/O.

The production path does not infer active SSH ownership from a GUI-process
environment variable or a human-readable terminal title. Each Surface has one
`PaneSessionContext` with these transient states:

```text
local
  -> sshConnecting(connection ID, alias)
  -> sshReady(connection ID, alias, remote cwd)
  -> local
```

Tab title, Tab icon, `InspectorPaneContext`, and the Files filesystem target all
consume this same state. `WorkspaceDescriptor` remains data identity and does
not own connection lifecycle. A new connection ID supersedes an older one, and
an end event only clears the matching active ID, preventing late host-A events
from clearing host B.

The lifecycle transport is typed OSC 3008 hierarchical context signalling. For
a simple interactive Fish, bash, or zsh destination, OMG's existing `+ssh`
action emits a `type=remote` start immediately before launching the final
OpenSSH child. That local start includes the percent-encoded pre-SSH cwd as
`localcwd`, so the snapshot does not depend on the ordering of asynchronous pwd
and context callbacks. Surface restoration explicitly injects
`OH_MY_GHOSTTY_CHANNEL` into each reconstructed PTY configuration. Restored
split trees therefore retain the correct `OMG` versus `OMG Dev` replay-storage
boundary even though they do not receive the fresh tab's per-Surface session
configuration. The transient remote prompt updates that same context ID
with `targethost` and a bounded cwd (`cwd` percent encoding for Fish or `cwdhex`
for shell-neutral startup hooks), and also emits standard OSC 7. Bash and zsh use a
mode-0600 temporary rc file/directory that sources the user's normal rc, installs
one prompt callback, and deletes itself before the first prompt; no persistent
remote file or service is installed. Shell selection happens inside the final
OpenSSH child, so multi-hop aliases do not incur a separate shell-detection
login. After `childExec` returns
for normal `exit`, Ctrl-D, authentication/network failure, or remote close,
`+ssh` emits the matching end from the actual child-process wait path and then
re-emits the inherited local cwd as OSC 7. It never parses `Connection closed`
or other terminal output. This is an in-process first-party lifecycle bridge,
not a new external plugin wire capability and not authorization for arbitrary
filesystem/network access.

On begin, `PaneSessionContext` snapshots the local cwd/title. On a matching end,
it atomically clears remote identity and restores that local snapshot before
Files refreshes. Connecting contexts continue to use the known local target;
only `sshReady` may construct `SSHWorkspaceFilesystem`. A ready context whose
SSH alias is unavailable returns an unavailable filesystem and never falls back
to local IO at a remote-looking path.

While an interactive SSH connection is active, `+ssh` also writes a bounded,
mode-0600 replay descriptor under
`~/Library/Application Support/OMG/SSHReplay/<connection-id>.json` for Release
or `~/Library/Application Support/OMG Dev/SSHReplay/<connection-id>.json` for
Debug. Replay writing requires either a per-tab `OH_MY_GHOSTTY_SESSION` or the
process-level channel marker, so restored Surfaces remain eligible without
making arbitrary standalone `+ssh` invocations part of app session state. It contains
the original OpenSSH executable, wrapper policy flags, and exact argv. The
validated descriptor is captured on the matching `PaneSessionContext.SSH` when
the lifecycle starts, so later Agent contexts and descriptor-file timing cannot
turn an active SSH split into a local shell. A split created from that Surface
uses only this matching active lifecycle and launches a new `omg +ssh` child
through `SurfaceConfiguration.command`; it does not inject keystrokes,
reconstruct options from `~/.ssh/config`, or connect to the resolved IP. The
ready remote cwd is passed as a separately shell-quoted wrapper option so the
independent remote shell starts in the same folder. On macOS the replay and its
post-disconnect interactive shell are grouped inside `/bin/sh -c`, because the
platform command launcher prepends an outer `exec -l`. After SSH disconnects,
the inner shell uses `exec -l` as well so fish/zsh login prompt setup is restored;
without that inner shell, the outer exec discards the post-SSH command and the
split exits. Embedded
surface commands now honor `wait_after_command` independently instead of
forcing it on whenever `command` is present. SSH replay splits leave it off, so
the first EOF returns to the local survival shell and a second EOF closes the
split normally rather than showing a terminal `Process exited` hold screen.
Therefore config aliases retain ProxyJump and other OpenSSH configuration, and
explicit direct invocations retain their original arguments. A new split uses
this replay path, while a new tab remains a local session: when tab cwd
inheritance is enabled it replaces the remote pwd with the `localcwd` snapshot;
when inheritance is disabled it leaves the directory unset so Ghostty applies
the configured home/custom/default working directory.
The descriptor is removed when the owning OpenSSH child exits and stale files
older than 24 hours are rejected. The same validated replay snapshot is
persisted on the Surface as `SSHResumeDescriptor` (with the ready remote cwd and
the pre-SSH local cwd) so app restoration can reconnect plain SSH tabs after a
relaunch, not only Agent and split panes. This is an internal first-party launch handoff,
not plugin storage or a public plugin API.

The installed/enabled official SSH entry registers `builtin.info` beside Files
in the Right Inspector. Info is an extensible host-rendered surface with
optional machine-status and typed machine/session sections (both currently
hidden) plus the SSH port-forwarding section. The forwarding header uses the
antenna/radio-tower symbol and reports its active port count.

For an `sshReady` Pane, users can enter either a port (shorthand for
`127.0.0.1:<port>` on the SSH server) or an explicit `host:port` reachable from
the SSH server, including bracketed IPv6. Targets are bounded/validated before
forming `ssh -L`; persisted v1 entries without `remoteHost` migrate to loopback.
The Host first tries the same local port, matching VS Code's default, and asks
the OS for an available ephemeral port only when that port is occupied. It launches
`/usr/bin/ssh -N` with `ExitOnForwardFailure` and waits for the local listener
before reporting the forward active. Rows render remote port and forwarded
address as separate columns only when at least one forward exists. A bounded
five-second refresh resolves a loopback target's remote listener PID through
fixed `lsof`/`ss`/`fuser` probes, then reports the executable from `ps`; no
process subtitle is rendered when nothing is listening. Arbitrary `host:port`
targets omit process discovery because the process may belong to another
machine. The probe is explicitly wrapped
in `/bin/sh -c` so Fish or another configured login shell cannot reinterpret its
POSIX syntax. Hover actions explicitly open
`http://127.0.0.1:<local-port>`, copy `localhost:<local-port>`, or stop the
forward; clicking the row itself does not open a browser. SSH stderr is captured
to a mode-0600 bounded temporary file and normalized into actionable failures
such as local-port collision, authentication failure, host-key failure, DNS
failure, refusal, and timeout. The forwarding command uses the validated
OpenSSH alias, so user configuration continues to own HostName, User, Port,
ProxyJump, keys, agent, and host verification.

The remote bootstrap derives a bounded stable `serverid` from the remote
sshd public host-key fingerprint (`ssh-keygen -lf ... -E sha256`). If the
public key is unavailable it falls back to the remote OS machine ID. It never
uses destination IP, resolved HostName, user-provided alias, ProxyJump route, or
remote hostname as server identity. This groups config aliases and direct-IP or
jump-host routes that terminate at the same SSH server while keeping distinct
servers separate. If neither authenticated-host material nor a machine ID is
readable, forwarding is disabled for that Pane instead of guessing from alias.

Forward intent is stored per application channel under the SSH Plugin data
directory as stable server ID plus remote port; it contains no credentials or
route. One forwarding process is shared by every ready Pane/Tab reporting that
server ID. It stops after the final matching connection ends and starts again,
using whichever current alias reached that identity, after a restored Pane
reaches `sshReady`. Normal app termination stops every process. The forwarding subprocess is also
wrapped by a parent-PID monitor, so a forcibly killed OMG process cannot leave a
long-lived standalone SSH forwarding process. No browser is opened when a
forward is created; opening is an explicit row action.

This first provider does not install a remote service and does not manage
credentials. It depends on the system SSH/SFTP client and configured
`ssh-agent`/known_hosts. Shells other than Fish, bash, and zsh do not yet publish
a ready remote cwd and remain Experimental. Remote `sftp ls -la` parsing is
bounded and is not yet a general remote file protocol.

## Inspector API (Internal)

### Descriptor

`InspectorPaneDescriptor` contains:

- stable `id` (1...128 safe characters);
- title and SF Symbol name;
- owner source (`coreFeature` or `plugin`);
- preferred/minimum width, constrained to 176...640 points.

Duplicate IDs, invalid identifiers, invalid width, and owner mismatches fail.

### Content

Host-rendered `InspectorPaneContent` supports:

- empty title/message;
- label/value fields;
- lists with optional subtitle/system image;
- recursive typed file trees;
- bounded Agent session lists and readable user/assistant transcripts;
- extensible Info snapshots with an optional status, typed fields, and SSH
  port-forward rows containing remote/local ports, remote process, and bounded
  status/failure detail;
- native Git views presenting repository context, status, and
  history/changes/branches.

The built-in Git history graph is computed from `--topo-order` commit rows and
parent object IDs only. `GitGraphLayout` retains active parent lanes across
incremental appends, so paged history loading can continue the graph without
rewriting rows that were already emitted. Merge and octopus commits connect to
existing parent lanes when present and add only missing parents; branch names or
ref decorations do not influence topology. Host-rendered Git cells draw the
resulting nodes and colored lane segments with native AppKit views.

A provider supplies data only. It cannot inject a SwiftUI `View`, `NSView`,
window, controller, material, or arbitrary icon path.

### Context, actions, and lifecycle

`InspectorPaneContext` contains tab/session presentation identity, title,
optional working directory, workspace identity, and the canonical
`PaneSessionContext`. Providers can therefore distinguish local,
`sshConnecting`, and `sshReady` changes without parsing titles. After a typed
SSH disconnect, the last validated server identity/cwd remains as dormant
reconnect metadata. If a replay survival shell no longer has the shell wrapper,
the Host's bounded foreground-process poll recognizes only a matching `ssh`
command for that previous alias and temporarily restores `sshReady`; process
exit returns it to local. A connection begin, remote cwd update, matching
disconnect, focused Pane change, or local cwd
change produces a new context/lifecycle appearance for the selected provider;
the previous appearance is discarded and its asynchronous work must not
publish afterward. Supported action values are disclosure toggle, refresh,
Agent-history selection/back/exact-resume/native-fork, collapse all, create
file/folder, create/open/copy/remove SSH port forwarding, and typed Git actions;
whether they make sense is provider-specific. The built-in Git provider asks
Git for absolute worktree, Git-directory, and common-directory paths, keeping
repository identity consistent when the focused terminal enters a subdirectory.
Agent-history resume accepts only a host-discovered,
`AgentConversationID`-validated local session whose manifest declares
allowlisted resume arguments; it focuses a matching live Surface or creates a
new typed resume tab. Agent-history metadata uses a versioned mtime cache and
bounded configurable count. When focused on a Pane with an active SSH session,
Agent History automatically switches scope to the remote host using batch SSH
queries and displays remote agent conversations; focusing a local Pane returns
to local history. Registration starts no scan, timer, watcher, or
helper process; appeared loads cached rows and runs one cancellable refresh,
while disappearing from every tab cancels outstanding work. Search emits
metadata matches, cached previews, and then progressive full-body matches;
transcript parsing streams in background tasks, while the host renders rows
through a reusable AppKit table. Port creation accepts only a valid 1...65535 port or bounded `host:port` and is
rejected outside an `sshReady` context. Info/port UI, hover help, empty states,
connection messages, and normalized Host failures resolve live from
`general.language` (English or Simplified Chinese).

Git terminal actions carry a `GitRepositoryIdentity` and are formatted as
`git -C <worktree> ...`, so they remain bound to the inspected worktree even
when the host process has another current directory. The bridge resolves both
`InspectorPaneContext.tabID` and `surfaceID` before writing the command to the
live Surface. It focuses that Surface and calls `sendText` once; it does not
send an Enter key event. Local intents are accepted only by local sessions,
and remote intents only by a matching SSH host. Commit messages are shell
quoted as one argument, preserving spaces, single quotes, and newlines.

Actual in-process lifecycle:

```text
registerCorePane / registerPluginPane
  -> host selects and calls presentationDidChange
  -> lifecycle appeared(context)
  -> host requests typed content
  -> provider updates content / receives typed actions
  -> selection/context hides pane: disappeared(previousContext)
  -> unregister or disconnectPlugin: cleanup and disappeared
```

The Core owns Inspector visibility, width, chrome, focus, persistence, and
rendering. Hiding the Inspector does not unload a provider; it receives
`disappeared(previousContext)` so it can cancel work owned by that exact tab and
session. `disconnectPlugin` removes every pane owned by
that plugin ID and clears typed content/actions.

## Minimal working example (in-tree only)

There is no runnable third-party package example because no external loader
exists. The smallest **working** example is an app-hosted test of the internal
registry. Place this in the test target (or use the existing equivalent in
`InspectorRegistryTests`) and run the command below:

```swift
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct HelloInspectorProviderTests {
    @Test func helloPane() throws {
        let registry = InspectorRegistry()
        let pluginID = "dev.example.hello"
        let paneID = "dev.example.hello.pane"

        try registry.registerPluginPane(.init(
            id: paneID,
            title: "Hello",
            systemImage: "hand.wave",
            source: .plugin(pluginID),
            preferredWidth: 320,
            minimumWidth: 176
        ))

        try registry.updatePluginContent(
            paneID: paneID,
            pluginID: pluginID,
            content: .fields([
                .init(id: "message", label: "Message", value: "Hello from OMG")
            ])
        )

        let context = InspectorPaneContext(
            tabID: UUID(),
            surfaceID: nil,
            title: "Terminal",
            workingDirectory: nil
        )
        #expect(registry.content(for: paneID, context: context) != nil)

        registry.disconnectPlugin(pluginID)
        #expect(registry.isEmpty)
    }
}
```

Run:

```bash
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  "SYMROOT=$PWD/macos/build" \
  -parallel-testing-enabled NO \
  -only-testing:GhosttyTests/HelloInspectorProviderTests \
  test
```

This verifies registration, owner-scoped content, and cleanup. It does not
create an installable plugin.

### Current contributor workflow

The only end-to-end pane workflow today is an in-tree Core contribution:

```text
macos/Sources/Features/Inspector/HelloInspectorProvider.swift
macos/Tests/Inspector/HelloInspectorProviderTests.swift
```

1. Implement a provider that owns only typed data/actions.
2. Register it with the Core-owned `InspectorRegistry`.
3. Add a lazy provider property and launch-time `register()` call in
   `AppDelegate`, following `BuiltInFilesInspectorProvider`.
4. Add owner, lifecycle, content, action, disconnect, and invalid-data tests.
5. Build/relaunch OMG; there is no hot reload.

This changes and rebuilds the application. There is no manifest packaging,
installation, or enable command for an external developer yet.

## Development and debugging

Protocol component tests:

```bash
xcodebuild \
  -project macos/Ghostty.xcodeproj \
  -scheme Ghostty \
  -configuration Debug \
  "SYMROOT=$PWD/macos/build" \
  -parallel-testing-enabled NO \
  -only-testing:GhosttyTests/PluginProtocolTests \
  -only-testing:GhosttyTests/PluginHostTests \
  -only-testing:GhosttyTests/InspectorRegistryTests \
  test
```

Relevant sources:

- `macos/Sources/Features/Plugins/PluginProtocol.swift`;
- `macos/Sources/Features/Plugins/PluginHost.swift`;
- `macos/Sources/Features/Plugins/AgentStatusPlugin.swift`;
- `macos/Sources/Features/Plugins/AgentHistoryStore.swift`;
- `macos/Sources/Features/Inspector/InspectorRegistry.swift`;
- `macos/Sources/Features/Inspector/BuiltInFilesInspectorProvider.swift`;
- `macos/Sources/Features/Inspector/BuiltInAgentHistoryInspectorProvider.swift`;
- `macos/Sources/Features/Inspector/RightInspectorHost.swift`.

Files-specific diagnostics are available in Debug builds:

```bash
log stream --level debug --predicate 'category == "files-inspector"'
```

There is no plugin hot reload. Rebuild/relaunch OMG after changing in-tree
providers. Protocol unit tests are the only supported way to exercise process
messages today.

## Permissions and security

No public plugin sandbox exists because no external runtime exists.

| Resource                            | Public plugin API today          |
| ----------------------------------- | -------------------------------- |
| filesystem                          | none                             |
| terminal Surface / PTY / scrollback | none                             |
| shell/process execution             | none                             |
| raw terminal output                 | none                             |
| network                             | none                             |
| clipboard                           | none                             |
| OMG/Ghostty settings                | none                             |
| persistent plugin storage           | none                             |
| arbitrary AppKit/SwiftUI UI         | prohibited by Inspector boundary |

The manifest capability intersection restricts future host IPC only. It would
not sandbox an ordinary child process from macOS filesystem or network access.
Before third-party executables ship, OMG still needs restrictive discovery,
ownership/signature validation, peer UID/PID validation, process supervision,
installation/update policy, and user-facing permissions.

`builtin.files` can access the filesystem because it is trusted in-process app
code. Its asynchronous, bounded, cancellable IO is not a permission granted to
third-party plugins.

## Failure handling

Implemented component behavior:

- empty/oversized frames fail;
- unsupported protocol versions fail;
- identity, nonce, and manifest-version mismatch fail;
- ungranted capability, missing session, stale revision, foreign ownership, and
  invalid data return typed failures;
- router disconnect removes owned ephemeral statuses;
- Inspector owner disconnect removes owned panes and lifecycle state.

Not implemented:

- child process crash detection/isolation;
- handshake timeout/heartbeat;
- bounded socket send queues;
- restart/backoff/disable policy;
- persistent diagnostics for external plugins.

Do not claim process isolation until those runtime pieces exist.

## Packaging and installation (Experimental storage only)

The first storage contract is channel-specific:

```text
~/Library/Application Support/OMG/       # Release
~/Library/Application Support/OMG Dev/   # Debug
├── Plugins/<plugin-id>/manifest.json + plugin code
└── PluginData/<plugin-id>/              user data/config boundary
```

Debug and Release never update each other's plugin packages, disabled state,
data, or SSH replay descriptors. Global vendor Agent hooks are intentionally
outside this directory because they belong to each Agent's own configuration;
they must remain backward-compatible across OMG channels.

`PluginInstallationManager` provides `install(from:)`, `update(_:from:)`,
`disable(_:)`, `enable(_:)`, `uninstall(_:removeData:)`, and `dataURL(for:)`.
The source currently must be an HTTPS GitHub repository URL. Installation
fetches the repository's `main.tar.gz`, finds `manifest.json`, validates the
plugin ID/version/relative executable path, copies code to `Plugins/<id>`, and
creates a separate data directory. Disabled state is stored in
`Plugins/disabled.json`.

Settings → Plugins exposes the official catalog and an Install from GitHub
URL field backed by this manager. The SSH official entry installs the in-tree
provider marker and enables the generic workspace provider; it does not
download private keys or a remote helper. External installed packages remain
inert. There is no signature/ownership verification, semver host compatibility
enforcement, executable launch, process supervision, or automatic update
service. Do not distribute executable plugins until those security/runtime
pieces are implemented.

When runtime loading changes, this document must add a copyable directory
layout, manifest, build/package/install commands, compatibility checks,
uninstall/data migration behavior, and end-to-end tests in the same commit.

## Planned design notes (not API)

The next runtime block described by the architecture is a private Application
Support runtime directory, per-plugin Unix socket, peer UID/PID checks, manifest
loader, enabled-plugin persistence, supervised process, bounded queues, and
status CLI. Terminal control and raw output remain high-risk and default-deny.

These notes are planning context only. They must not be used by plugins until
implementation, tests, and a stability designation land.

## Built-in Git editor diff

Editor diff requests have persistent, closable tabs alongside ordinary files.
Switching files preserves each diff's selected file, scroll state and view mode;
next/previous editor shortcuts include diff tabs. Reopening the same repository,
target and initial file selects its existing tab. Closing the pane releases both
file and diff tabs.

Typed `openGitFile(file, directory:)` actions open the working-tree file in the
current editor pane or its parent directory in a new terminal tab, using the
source session's local/SSH destination. Changes, History file rows and the diff
file-name context menu expose these actions with Files-style names.
Changes context menus apply stage/unstage and `discardSelectedChanges(batch)` to
all selected rows when the clicked file belongs to the selection; clicking outside
the selection targets only that file. Mixed index/worktree selections stage the
whole selection. Batch discard confirms every target once, validates all targets
and protects all affected editor documents before the first mutation. Duplicate
paths selected in both sections restore from HEAD once. The batch shares one
worktree mutation gate; a failure stops remaining operations and refreshes status.
`discardChanges(file, staged:)` requires a file-specific confirmation and a fresh
Git file-list check. Unstaged tracked files restore from the index; staged files
restore both index and working tree from HEAD (or the empty tree before the first
commit). Added/untracked files are removed only within the selected literal
pathspec; unrelated files and ignored directories are retained. Renames restore
both paths. Conflicted files are rejected. This operation shares the worktree
mutation gate, protects unsaved editor documents, suspends editing/autosave for
open clean documents, and reloads or closes those documents after restoration.

The terminal seeds its initial absolute working directory from its launch
configuration, including restored agent commands, before shell directory reports
arrive. Inspector providers consume this shared context rather than waiting for
the agent to exit. Subsequent shell reports remain authoritative.

Closing a terminal tab releases its registry snapshots and built-in Git, Files
and Agent History derived presentation state. Nonempty authored Git commit
drafts remain available for tab restoration without retaining full history or
file snapshots. Late asynchronous content updates for a closed tab are ignored. Closing or hiding an Inspector view does not terminate
managed port forwards. Identical plugin snapshots do not broadcast another UI
revision; Agent History reuses one decorated session array per host and active
session set instead of allocating it separately for every tab.

The trailing Inspector retains visited native pane views within the current tab,
so Files/Agent History/Git/Info switches hide and reveal existing views rather
than rebuilding large trees. Only the selected pane receives provider lifecycle;
hidden views cannot receive input or automatically paginate. Cache entries are
removed when their pane is unregistered or the owning tab changes. This cache
does not own or rebuild terminal surfaces or PTYs.

Native editors defer layout-manager geometry callbacks until the active layout
pass finishes. Resizing or revealing a sidebar must not synchronously re-enter
line layout through scroll-position compensation; word wrapping and stored text
remain unchanged.

Git sidebar tab switches retain the native History table and its scroll position.
Re-entering a ready Git pane uses its cached snapshot; normal polling refreshes
it without launching and cancelling full SSH reads on every pane switch.
They display the current snapshot immediately; normal polling refreshes branch and
worktree information. Hidden History views do not automatically paginate. Unchanged
content is not republished, and background snapshot checks do not show a loading
indicator when history is already available.

Changes, Branches, History ref badges and the History ref picker share `GitCollectionView`: one
virtualized native table, row renderer, category header, search field and compact
List/Tree mode control. Only visible cells are instantiated. Row insertions,
removals and state changes apply incrementally, preserving surviving visible
rows; the table is not reloaded for a single index update. The commit composer
stays outside the scrolling collection.

Changes row IDs include the index side and filesystem path, and exclude mutable
status letters. A partially staged path therefore has two distinct rows. Cells
always derive checked state from their current item, including after reuse.
List rows show a single-line filename and a truncated secondary directory; Tree
rows use filesystem folders. Folders are presentation groups, not Git objects.
Folder expansion, selection and viewport anchors are stored separately from Git
status and survive refresh and List/Tree switches.

Changes keeps transient hover, navigation selection, batch selection and index
state separate. Each table owns one hovered row identity, reconciled on scrolling,
reuse and snapshot updates. Cmd-click toggles a selection and Shift-click selects
visible file rows from the anchor without opening a diff. Ordinary file clicks
select and navigate; blank-space clicks and Escape clear selection. Space toggles
the selected files only when the table owns keyboard focus; search and commit
editors retain ordinary text entry.

A selected checkbox operates on the complete selection. Changes starts with its
Staged and Unstaged sections, without a duplicate master-checkbox heading.
Folder checkboxes aggregate all descendants across both index sides. All-staged batches unstage; every other
batch stages. Chevron, checkbox and name hit targets remain separate. Bulk writes
use one NUL-delimited stdin pathspec command and one complete status refresh,
then reconcile affected rows, remap selection across index sides and preserve
viewport, expansion, draft and focus. Git 2.25+ supports these bulk pathspec flags.

Ref badge popovers and the scope picker use the same ref browser and popover
style, including search, tree/list rows and selected state. Scope icons distinguish
all-history, local, remote and tag refs; long labels truncate. Tag browsing resolves
the complete tag ref to its commit and does not check out the working tree.
List/Tree buttons have full 32-by-28-point targets. Search and commit inputs share
theme-derived normal, hover, focus and disabled fills and borders.

Trees share a 16-point indentation step and reserve a disclosure column before
checkbox/icon/name columns. Consecutive directory-only chains are compacted into
one slash-separated label in Changes, Branches/ref browsing and Files. Git rows
retain their represented folder IDs for collapse/selection reconciliation and
operate on the deepest real folder's descendants. Branch refs remain unchanged.
Files uses `WorkspaceFilesystem.listTreeDirectory` separately from ordinary
listings: local and SSH implementations inspect at most 24 directory levels,
stop at files, siblings, symlinks or unreadable directories, and retain the real
terminal path for opening, copying, renaming and expanding. SSH resolves the
listing and compact chains in one remote query, with the existing SFTP listing
as fallback on hosts without Python. Tooltips show complete paths.

Git subprocesses have a 60-second deadline covering both process exit and pipe
drain, including SSH sessions whose descendants retain inherited pipe handles.
Cancellation/timeout closes IO channels and settles the mutation queue; pending
checkboxes recover and the error reports that a remote write may already have
completed. Writes are never automatically retried. A bulk status failure keeps
the last snapshot and reports the error rather than launching repeated fallback
queries. Users refresh before retrying a timed-out write.

Source diff overlays register their viewport observer after the native editor
has created its scroll view. Scroll and resize invalidations are coalesced until
lazy wrapped-line layout settles, then highlights are redrawn from the current
visible source lines. This applies equally to local/SSH and inline/side-by-side
snapshots; patch parsing and line identities remain transport-independent.

History pagination is the last row of the scrollable native table, including its
loading indicator. Appending commits moves that row to the new document end
while retaining the viewport anchor; it is never a permanently pinned footer.

Git UI text comes from `GitStrings.json` through `GitL10n`, following the existing
application language preference (system, English or Simplified Chinese). Language
changes update visible Git chrome. Branch/tag/remote names, author data, paths,
SHAs, commit messages and raw Git command output are never translated.

Working-tree refresh reads staged and unstaged paths together with one NUL-delimited
porcelain status command, falling back to independent reads on failure so one
unreadable side does not disable the other. Rename origins, conflicts, untracked paths and partially
staged files are preserved. Single-path index success reads only affected literal paths
and merges that patch into the latest snapshot without reloading history or
unrelated rows. A failed scoped read falls back to the regular status reader.
Path-only reset unstages files, including before the first commit, without
an extra HEAD probe. Diff layout automatically persists the last Side by Side or
Inline selection in app preferences; no separate settings control is exposed.

The built-in Git diff surface is host-owned Swift code. `GitDiffService` first
lists paths for a `GitDiffTarget` (`commit`, `staged`, or `unstaged`) and only
loads a selected file's unified diff. Working-tree file lists use Git's NUL-delimited
`--name-status -z` output. Committed files use combined `--raw --numstat -z`
records to obtain statuses, rename pairs and line statistics in one command,
without another SSH round trip. Tabs, newlines and Unicode in paths remain
intact. Binary files contribute to a separate count, not invented line totals;
untracked working-tree files are represented as additions.

History keeps the subject first, followed by two secondary metadata lines:
Author and Email, then Time and Short SHA, separated by whitespace rather
than dot labels. Clicking a metadata field selects and highlights its complete
value without changing the clipboard; Command-C copies that selected field
(including the full SHA behind a short hash). Only one field owns keyboard focus,
and changing focus clears its selection highlight. Copy feedback preserves the
original text. Double-clicking a summary, including metadata and blank space,
toggles the commit without copying or waiting on a single-click timer.
The trailing 7-point chevron remains available; the graph gutter is topology only.
Subjects and bodies use row selection/whole-value copying without word selection.

HEAD/branch/remote/tag badges remain compact even while a commit is expanded.
They occupy one 17-point row, cap each name at 104 points, and aggregate local
branches, remote branches and tags separately when needed. Clicking a badge
opens References. That popover separates HEAD, Branches, Remote Branches and
Tags; branches use slash-delimited folders while leaves retain exact ref names.
Clicking a ref leaf copies its full name with light feedback. Folder clicks do
not copy; folder double-clicks toggle expansion. Keyboard/context-menu copying
and the selectable full-name footer remain available. No permanent
copy-icon column or expanded inline ref list is added to the timeline.

Expanding a commit adds changed-file count and line statistics, clickable file
rows, then the optional message body without repeating metadata or the subject.
Short bodies default to expanded and long bodies to collapsed. Their disclosure
header stays above the text with a line count; clicking the text selects it
for whole-body copy and never toggles the section. Changed Files stays before the body.
Presentation folds update only affected rows and heights without implicit
animations. Unchanged graph layouts and unrelated native cells stay intact.
Body extraction and text measurements are reused, and collapsed long bodies do
not need full text layout to decide their default state. Successful commit
details have a bounded 32-entry per-worktree cache; collapse/reopen does not
repeat Git reads, and explicit refresh invalidates that cache. Initial expansion
reuses already-loaded parent IDs, avoiding a redundant parent query.
Presentation folds do not refetch Git data. The commit rail spans child rows,
including root commits; forks and lane compaction occur at the block end.
Lane changes finish near nodes/boundaries, with adequate parallel spacing.
The first-parent spine remains lane zero, including shared ancestors queued by
side branches. Only actual active continuations create incoming edges; the first
visible node has no artificial line above it. Explicit seeded continuations keep
their incoming edges. This applies to folded and expanded commits alike.
Each commit reserves its rightmost occupied lane using the same node-outline
clearance for nodes and passing lines, plus a 3-point content gap. Lane centers are 10 points apart, starting at
8 points; a single-lane commit's content starts at 16 points. Merge edges and
passing lanes participate in that row's extent, without a global maximum gutter
or shared text column. Detail rows use their owning commit's content origin and
measurement width. Adjacent graph-edge coordinates match even as widths shrink.
Within a commit summary, subject glyphs, metadata groups and the refs row share
that one content origin. Subject drawing omits the native text-field inset, and
history badges omit leading spacer characters. These controls add no separate
leading offset; different commits still use their own graph-dependent origins.

Inspector native copy routing precedes terminal shortcuts. The bounded branch
scope picker displays compact titles but dispatches original ref IDs. Repository
headers show selectable worktree/origin addresses and every current branch/HEAD
tag by name. Header refs wrap onto additional lines instead of truncating or
collapsing into count badges; history-row badges remain compact. Origin is read
on initial/forced refresh rather than each poll; HTTP credentials are omitted.

Commit disclosure or double-click loads metadata/files on demand,
independently of history pagination; collapsing cancels that pending request.
Only clicking a changed file routes to
`EditorWorkspaceStore.openGitDiff(repository:target:file:context:)`, honoring the
editor pane destination setting and exact commit/file selection. The editor binds each preview to its original
repository and target. Regular document views remain mounted underneath a
selected diff, just as they do when another document is selected, preserving
native undo, selection, scroll position and Markdown edit/preview mode. Source comparison uses bounded, read-only before/after snapshots with
the editor's syntax highlighting and added/deleted line tints. Side by Side and
Inline modes share the same snapshots and one parsed hunk/line mapping.
Both side-by-side highlighting and inline rows are derived from that mapping.
Patch lines split on LF code units, including CRLF source patches, so deleted
CRLF files use the same source comparison as other text files.
Inline interleaves removed/added source lines, retaining unchanged source context. Linked scrolling is on by default
in Side by Side mode and maps source line positions through Git's hunks in both
directions, including insertion/deletion offsets; it can be disabled.
Binary and size-limit states remain explicit, and a raw patch is the fallback
when complete source snapshots are unavailable or changed during loading. Commit diffs compare against the first parent, or the empty tree for a
root commit; staged diffs compare HEAD/index, unstaged diffs index/worktree.
The file list retains its resolved commit base for patch and source reads;
switching files does not repeat the same parent lookup. Tracked and untracked
working-tree lists load concurrently.
Diff source views forward the host editor's hide, open, close, adjacent-document,
focus and Save All callbacks. Shift+Escape hides the editor without discarding
the diff preview, display mode or scroll position, as with ordinary editor
documents. Loading, binary and error states retain the same workspace shortcuts
through a focused-surface fallback; hidden previews do not consume keys.
Diff refresh re-enumerates files before resolving the selected path and loading
its latest status/sources. A file moved from untracked to the index is no longer
shown as an unstaged addition. Selection and refresh share one cancellable
loader; an obsolete result cannot overwrite a newer selection. The raw patch
view is retained as a fallback, without a separate detail-window lifecycle.

Changes lists staged and unstaged/untracked paths separately. Changes derives
foreground, accent, selection and status colors from Ghostty's resolved theme
tokens, including custom palettes. Status letters have less visual weight than
filenames; untracked `?` uses the secondary foreground rather than bright green.
History retains its semantic status colors. Letters and
accessible status labels remain available independently of color. Checkboxes reflect
the real index: checking an unstaged row stages that whole file; unchecking a
staged row unstages it without deleting the working file (including unborn
repositories). The pinned Commit composer submits the index via stdin commit message, never
implicitly stages other files, and preserves the draft on failure. A file with
both index and working-tree edits can appear in both sections. Staged,
unstaged and branch queries keep independent results and errors. A failed
query retains its last successful values for display and disables only actions
that depend on those stale values; it does not hide other successful sections.
Stage/unstage requests are queued and serialized per worktree. Only affected
checkboxes show a small pending indicator; unrelated files remain actionable and
can enter the queue. Successful status patches move rows and update both counts
in the current page. A failed write preserves the previous state, clears its
pending flag and reports the error while other queued files can complete. No
optimistic index contents are invented. Index updates never enter global loading,
insert an operation banner, or rebuild history. The composer stays outside the file-list
scroll view; its native text view preserves focus, selection and undo state when
status updates. It grows from 44 to 112 points, then scrolls internally. The
footer reserves space for index progress without moving the Commit action.


History's ref picker embeds the same `GitRefBrowser` as Branches. Search and the
List/Tree control live inside the popover on one row. Categories are Branches,
Remote Branches and Worktrees, plus current/all-history scope choices. Search is
case-insensitive and reuses the command palette's matching helper. Up/Down move
through matching entries, Enter activates the full ref/worktree identity and Esc
closes the popover. Background ref refreshes and mode switches preserve the
keyboard candidate. Browsing a worktree reads its HEAD (including detached HEAD)
without opening a terminal or changing Git refs. Ref selection refreshes history
only. Worktrees remain physical checkout rows with visible paths; branch rows
mark associated worktrees.

Changes has its own remembered mode; Branches and the picker share the remembered
ref mode. Ref Tree grouping splits full branch names on `/`, with the remote as
the first remote-branch level (`origin/feature/foo`, not `feature/origin/foo`).
Grouping never changes the complete ref passed to Git or actions.

History/Changes/Branches form one compact, 28-point navigation
bar with full rectangular hit regions, a thin selected underline and subtle
hover feedback. Font weight and geometry stay fixed across selection and use
semantic dark/light colors. Branches supports List and Tree with stable ref IDs.
Single click selects; folder disclosure or double-click toggles expansion,
while branch double-click opens its worktree if checked out, otherwise history.
Checked-out branches show a worktree label and prioritize Open Worktree over
checkout. Leaf context
menus offer switching, creating and switching a branch from that ref, pushing
a selected local branch, and setting its upstream. Remote refs can create local
tracking branches. Push explicitly selects a configured remote/destination
and uses a normal non-force refspec for the selected branch, even if it is not
checked out. These host-owned actions add no external plugin wire capabilities.

Branches also lists Worktrees with branch, visible path, current, dirty and
detached HEAD state. Lock/prune reasons remain available in tooltips; double-click
or Open in New Tab opens that directory in a new local or replayed SSH terminal.
No command is injected into the existing shell. Branch menus offer New Worktree
from Here and Open Worktree for checked-out branches; the pane also has a New
Worktree button. Creation supports a new branch, an existing local branch, or
a detached HEAD and requires an absolute destination path. A creation option
opens the new worktree in a new OMG tab after Git succeeds. Remove Worktree asks
for confirmation, keeps the branch, and refuses main/current/locked/prunable
entries, dirty/failed status and unsaved editor buffers. The service re-reads
the list and status before removing and never passes force. Dirty checks include
untracked files and run with at most four concurrent processes when Branches is
active or explicitly refreshed; failures remain visible and disable removal.
Worktrees use `git worktree list --porcelain -z`, preserving spaces, newlines and
lock/prune reasons in paths/fields. Their refresh results and errors are
independent of branch/status queries and use the same local/SSH executor.
The host-only create/open/remove actions do not extend the external plugin wire
protocol. See the [Git worktree contract](https://git-scm.com/docs/git-worktree).

History commit context menus group creation, inspection, mutations and copying.
Create Branch adds a ref at the selected commit without switching the worktree;
Branch + Worktree and Detached Worktree reuse the worktree creation dialog.
Details opens changed files in-place. Compare with HEAD captures the current HEAD
ID once and reuses the existing bounded diff/file/source viewer for that pair.
Cherry-pick/Revert ask for confirmation (and an explicit mainline parent for
merges), require a clean worktree and preserve Git stderr on failure. Conflicts
remain available for normal Git continue/abort; no automatic reset or abort runs.
Mutation entries are disabled while another operation runs. Subject and metadata right-clicks route to this same commit menu. Menu actions
retain the clicked commit ID even if selection changes; Copy Commit Hash is direct and
other existing copy actions live in Copy More. These are host-only actions.


Mutations are serialized per worktree and are separate from cancellable polling
tasks. Git's refusal to overwrite dirty files, non-fast-forward rejection,
hooks, signing and authentication errors are shown in a dismissible pane banner;
no forced checkout/push, automatic stash, worktree reset, hook bypass or terminal injection is performed.
Unstaging before the first commit removes only the selected index entries with
path-only `git reset --quiet -- <paths>`, preserving working files even if edited
after staging.
Switch/create and cherry-pick/revert also refuse unsaved editor buffers in that worktree.
Index-only success refreshes changes locally; other mutations refresh status,
changes, refs and history. Failed commits retain the
draft and index. The header reports configured upstream tracking against local
cached refs, and routine refresh never fetches. Current branch, tag and remote
decorations use distinct native SF Symbols, colors and accessible descriptions.
Branch badges precede tags, with main branches first, and aggregate at narrow
widths instead of flowing into additional rows. The commit graph uses a compact lane-dependent gutter;
the actual HEAD marker is independent of table selection.
Expanded child rows continue the commit rail without introducing commit nodes.

History fetches another frozen-snapshot page when scrolling near the bottom,
deduplicates pending requests, and stops at Git's true end of history. A failed
page retains existing commits, the snapshot and has-more state for manual retry.
Refreshing refs preserves the already-loaded depth. Row heights track explicitly expanded bodies; inserting child rows does not affect Git page
offsets, and an append preserves the current viewport anchor. Repository refresh
and history pagination have independent cancellation/generation ownership, so
paging or changing scope cannot interrupt a Changes/Branches refresh. A ref
refresh waits for an in-flight page and preserves its loaded depth. History
records use six NUL-delimited fields and Git's NUL record terminator rather
than a text control character that may occur in a legal commit subject.

### SSH Git parity and transport

A ready SSH pane uses the same Git provider, History/branch tree, commit
expansion, stage/unstage, commit, branch actions, and editor diff as a local
pane. Connecting sessions remain non-actionable. A repository has one execution
target, either local or a complete SSH connection; there is no incomplete
host-only fallback or second mutable transport field. Repository identity, read
caches, commit drafts, expanded state and mutation locks include the SSH
destination/options as well as the worktree path; reconnect/host changes cannot
reuse a local or another host's same-path state. SSH failures are errors, never
an instruction to run Git locally. The SSH destination remains visible during
loading and errors.

`SSHGitExecutor` uses OpenSSH batch mode with the session's replayed destination,
port, user, identity, config and jump host options. One OpenSSH
argv parser serves both foreground detection and replay, including combined
flags such as `-4vp2222`; unknown options fail closed. Foreground
OpenSSH sessions capture argv boundaries via `KERN_PROCARGS2` (not a whitespace
split of ps output); if exact options cannot be recovered, Git asks for a
reconnection rather than guessing a port. Existing SSH config and
agent authentication apply. Git commands use a private OpenSSH master with
`ControlMaster=auto` and a 60-second idle `ControlPersist`, instead of a fresh
connection per query. Its socket key includes the full connection identity,
executable, original cwd and application-session salt. The short socket directory
is owned by the current user with mode 0700; interactive terminal control sockets
are not reused or modified. OpenSSH owns concurrent channels and idle expiry;
mutations are never retried automatically after a transport failure. Auxiliary commands disable terminal
allocation, port forwards, LocalCommand and RemoteCommand side effects.
Configured agent forwarding, including explicit `-A`, is preserved.
Auxiliary execution retains the original local launch directory, so relative
`-F`, `-i`, config options and ProxyCommand values keep their meaning without
per-option path rewriting. Foreground capture records executable and cwd;
replay v1 adds optional `local_working_directory` while older records remain
readable. Replaying a captured cwd uses a subshell so its caller's cwd is kept.
Older typed records with a bare executable use the host application's explicit
PATH because those records did not preserve the original executable/PATH.

The transport requires a Unix SSH host with Git 2.25+ and standard `/bin/sh`,
`base64 -d`, `head` utilities for full parity. A base64-encoded POSIX command
argument avoids login-shell quoting differences (including fish), while SSH
stdin stays independent for commit messages. An output marker removes shell
startup banners without losing NUL-delimited Git paths. Local Git and SSH both
compose `GitProcessRunner`, which owns stdin and separate stdout/stderr channels,
cancellation and combined output limits. Normal results are published only
after streams drain; excess output terminates the spawned process (with a
bounded termination grace period), instead of waiting forever for it to exit.
The executor interface has no implicit local-file read: each transport owns
its working-file reader. Output is bounded,
connection liveness is checked, repository roots with line breaks are rejected,
and remote working-file reads are bounded and
validated on the server rather than through local FileManager. Symlinks and
non-regular files retain the patch fallback. A lost connection during a write
reports an uncertain outcome and keeps the draft for refresh/reconciliation.

Remote polling is throttled to ten seconds; explicit refresh and completed
mutations refresh immediately. No fetch, force-push, stash, or host-key bypass
is added. Remote branch switching also protects unsaved editor documents in
the SSH workspace conservatively, since symlink aliases cannot be resolved
through the Mac filesystem. Tests run an isolated loopback sshd with private
temporary keys and a pinned known_hosts file, covering real SSH reads, writes,
diff source versions, local bare-remote pushes and endpoint-state isolation.

### Editor appearance settings

The built-in editor follows the resolved OMG/Ghostty theme by default (`editor.syntaxTheme = followTerminal`). Independent editor themes may override `editor.opacity` and `editor.blur`; these values are ignored while following OMG. These settings do not add plugin capabilities or change the Files provider opening contract. See [settings configuration](settings/configuration.md#shared-omg-and-editor-appearance).

### Built-in Files context actions

The trusted `builtin.files` provider offers Copy Path, Copy Relative Path (relative
to the displayed root), Rename, and Open in… for tree entries. Rename uses the
workspace filesystem boundary for local and SSH files and folders, refuses an
existing destination, and requires closing open editor documents below the item
first. SSH rename uses Python 3 over SSH with Linux `renameat2(RENAME_NOREPLACE)`
or macOS `renamex_np(RENAME_EXCL)`; unsupported hosts fail without a fallback that
could overwrite a target. File transfers continue to use SFTP. Errors are presented by the host. Open in… uses the macOS application
chooser; SSH files are downloaded as read-only temporary copies and edits in the
external application are not uploaded. Remote folders cannot be opened locally.
These host-owned actions do not grant external plugins filesystem capabilities.

### Terminal file links and default destinations

The macOS host routes OSC 8 `file:` links and detected paths to the built-in
editor using the clicked surface's workspace/session. Relative candidates such
as `README.md` and bare directory names are checked through `WorkspaceFilesystem`
before opening; missing candidates do not launch external applications. Web
links retain the existing URL-opening policy. Files and Command-clicked
directories have independent default destinations (`editor.fileOpenDestination`
and `editor.directoryOpenDestination`): current pane, new tab, or four split
directions. An explicit Files menu destination overrides the file default.
The directory default applies only to Command-click navigation, not Files tree
expansion. Current-pane directory navigation changes the existing shell's cwd;
new panes start in the requested directory, using the existing SSH replay path
for remote sessions. These host-owned actions add no external plugin permission.

Relative terminal links now carry the cwd recorded at their output position,
using OSC 7 transitions anchored to tracked screen pins. Changing directories
does not reinterpret older filenames against the new cwd. Each screen retains
at most 1024 transitions with paths up to 4096 bytes; unknown/expired metadata
does not fall back to guessing the current directory. Quoted names containing
spaces are matched as one path. Absolute links are independent of this history.
The additional native `open_url` cwd fields are not plugin wire capabilities.

Known non-text formats (including DMG, PDF and images) use the system default
application before creating an editor pane. Binary/unsupported-encoding and
oversized text failures also fall back to the default application. Remote
external files reuse the bounded read-only temporary download used by Open in…;
external changes are not uploaded. Markdown Live Preview uses offline CodeMirror 6
with Markdown source as the sole document state. Ordinary lines use live
decorations; complex blocks reuse the existing sanitized markdown-it renderer as
widgets mapped to source ranges. Reference link/image definitions remain source
and contribute to the rendering context even when they produce no visible block.
Widgets do not own a second rich-text document or serialize the whole file.

CodeMirror transactions update the same native editor document through the
version-checked `{type: "edit", text, baseText}` bridge. Matching native text
acknowledgements preserve selection and undo history; opening or rendering alone
does not rewrite source. Save continues through the existing native document
boundary, without granting web content direct filesystem write access. Complex
blocks are edited through their source ranges; this is a source-based live
preview, not a claim of complete Typora-style rich-text editing. The internal
`window.omgLiveEditorView()` test hook returns a CodeMirror `EditorView`; it is
not a plugin API or a ProseMirror view.

### Git collection navigation

Inspector visibility is independent of its native view lifetime. After the
first opening, the sidebar retains its pane deck until its host is removed.
Hiding still sends `disappeared` immediately and showing sends `appeared`;
hidden context updates must not reactivate providers. Slide transitions move
the fixed-width shell without animating layout inside provider content.

The built-in Git sidebar shares one search and List/Folder toolbar below its
History, Changes and Branches tabs. Search text is independent per tab; the
`git.collection.viewMode` preference is shared by all three. History's mode
changes only expanded commit files, using the Git Collection folder builder.
The internal `searchHistory` action searches subject, full message, author,
email and hash within the current history scope, including unloaded commits.
Reads are bounded and cancellable, results are paginated, and filtered commits
are displayed without implying direct ancestry between search hits. Clearing
search restores the cached unfiltered history unless its scope was invalidated.
