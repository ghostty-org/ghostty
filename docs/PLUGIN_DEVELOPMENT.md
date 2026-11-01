# OMG Plugin Development

> **Plugin system maturity: Beta. Public API status:** pre-release / not externally loadable.
>
> Beta describes the evolving host-extension foundation, not a stable public
> plugin runtime. The future development/distribution workflow is still being
> designed; capability-specific Experimental/Internal/Planned labels below remain
> authoritative. It does not promise third-party executable loading or API stability.

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

## Native Session Runtime lifecycle

The internal runtime keeps a single `omgd` host with per-session actor threads.
Explicit pane/tab closure is persisted in `session-runtime/pending-closes.json`
before local removal; detached/network-lost sessions retain their existing TTL
and Agent-completion policy. Completion cleanup is an opt-in Beta feature,
disabled by default in settings and daemon policy. Unsupported Agents follow
ordinary process retention (TTL/deadline/explicit Close), even when completion
cleanup is enabled; verified recoverability remains required. Previously saved
explicit settings and existing Session policies are preserved.
The host heartbeat advertises `durable-close/1`.
Only after this capability does a relay forward the outer `K(stream, UUID)`
request; the host persists a permanent UUID close marker and replies with an
inner `K` containing `pending` or `closed`. Confirmation requires the actor to
finish cleanup. Repeated close requests are idempotent and cannot recreate a
session, including when Close arrives before Create. This revokes the whole
pane UUID across Agent resume generations. Old pinned hosts keep the attached
Close path but cannot confirm durable cleanup; requests remain visible as pending.

On supported Linux hosts, systemd supervises the single host service with
`Delegate=yes` and `KillMode=control-group`. Each Session owns a child cgroup,
joined before shell exec; normal setsid/double-fork descendants stay in it.
Cleanup checks the group is unpopulated. Root uses a transient system service;
non-root requires an existing lingering user manager. No implicit privilege
escalation or linger changes occur. Unsupported hosts retain process-group-only
cleanup. Host crashes terminate contained work rather than preserving its PTY.
Startup reconciliation marks records without actors Lost and removes stale
sockets without signalling historical PIDs. Empty local relays exit after 30
seconds. See `docs/architecture/session-runtime.md` for platform limits.

## Agent history discovery

Agent History paints one authoritative list per open. It does not publish a
disk-cache snapshot before the scan, which previously made the visible session
count change on first open. The disk cache stays a per-file metadata reuse layer
and is reconciled against files that still exist. Manual refresh keeps the
displayed rows, shows progress, and disables the refresh action while running.
Filtering, grouping and ordering live in one popover that stays open while it
is adjusted. Rows keep a fixed checkmark column, icon column and right-aligned
count, so selecting an option never shifts text. Every row carries a glyph
(the Agent's own logo, or a system symbol for scope, grouping and ordering
choices), so the "All Agents" entry and the group/order options line up with
the Agent rows instead of leaving an empty gutter. Agent rows scroll
only when the list exceeds six entries, and a Reset action restores the default
filter, grouping and ordering. The trigger shows the selected Agent's icon plus
a corner badge (an overlay, so the glyph stays centered) whenever any
non-default choice is active.

Folder and time scopes narrow the list before the Agent filter. `This Folder`
matches the presented pane's working directory and every subfolder, so a
session started inside a subproject still counts, while sibling paths such as
`/repository` never match `/repo`. Time scopes are relative windows (24h, 7d,
30d, 3 months, 1 year) evaluated against each session's last update. Agent
counts in the popover reflect the active folder/time scope, so they describe the
rows the choice would actually show, and `This Folder` is disabled when the pane
has no resolved directory.
Discovery falls back to validated header metadata when a transcript file name
does not encode the conversation ID, because stores such as omp keep the ID in
the parent directory and name transcripts freely. Zstandard-compressed
`*.jsonl.zst` rollouts are supported: Codex now compresses both live and
archived sessions, so OMG reads a bounded decompressed prefix (64 KiB locally,
256 KiB remotely) through the `zstd` helper and parses it like plain JSONL.
An agent may declare `additionalRoots` beside its primary root; Codex uses this
for `~/.codex/archived_sessions`. Archive headers are parsed concurrently, and
per-file results are reused from the disk cache, so repeat scans stay fast.
Remote compressed-history command fallback reads at most 256 KiB while streaming,
with a five-second read deadline; it closes the pipe and terminates/reaps the
helper, escalating to kill after 0.5 seconds. It never buffers a whole archive
before truncating. The Python `zstandard` stream reader is also closed explicitly.
Remote discovery uses
Python 3 over SSH, globally sorts file modification timestamps, and transfers
numeric Unix timestamps and bounded JSON metadata instead of parsing `ls` dates.
The configured history limit applies to remote results as well as local results;
remote JSONL candidates are bounded at 20,000 and file traversal at 200,000.
Headers are bounded at 2 MiB per remote file, with a 128 KiB tail for explicit
session names; oversized or malformed records may still lack a title. Remote
discovery has a 60-second transport ceiling because compressed archives add
decompression work.

Antigravity CLI (`agy`) resumes with `--conversation {id}`. Local and SSH history
read its `antigravity-cli/conversation_summaries.db` index. That index is a WAL
database where a read-only SQLite handle cannot prepare statements, so OMG reads
a private temporary copy with a read-write handle and never writes to the
Agent's own files. OMG validates that the corresponding
`conversations/{id}.db` exists. Titles fall back to the
stored preview, workspace URIs provide directories, and index timestamps provide
recency. Its protobuf conversation steps are not decoded: the transcript panel
shows only the available summary preview and marks it truncated.

## Native interactive SSH handoff (Experimental)

Local GUI panes receive a private per-pane capability and request directory.
The existing shell SSH wrapper calls `omg +ssh`, which routes conservative
interactive shell invocations to the bundled `omgd handoff` helper. A private
request file carries exact argv/cwd; OSC 3008 only references its random ID.
The host checks the owning pane capability before replacing that local surface
with the native remote backend. Output alone is insufficient to authorize it.
Remote commands, tunnels and unsupported flags retain standard SSH behavior.
Each local pane overwrites inherited handoff variables, including when its app
bundle lacks the helper; capabilities from the terminal that launched the app
must never be reused. An authenticated request receives `.accepted` only after
native surface construction succeeds, or a private `.failed` response with a
setup error. The helper reports that failure immediately rather than waiting
for its unacknowledged-request timeout. Development installers validate bundled
helpers, dependencies and remote platform manifests before replacing the app.
The local surface is retained during handoff. A confirmed remote process exit
returns to that local shell and records a local pane; transport disconnection
never triggers this transition. Across app restart, the local shell is recreated
at the descriptor's original local working directory. The remote surface has
its own terminal scrollback; the retained local history is not prepended to a
remote snapshot. Handoff replaces the current pane, not its tab/window. Local
history becomes visible again after a normal remote shell exit.

Native SSH splits create an independent remote session on the same exact SSH
connection. The current remote pane directory is sent as optional `cwd` in the
open request, validated as an absolute path (at most 4096 bytes, no NUL), and
applied via the child process working directory only at first creation. Paths
are never evaluated as shell commands. Reattach ignores `cwd`, and Agent resume
uses its recorded recovery directory. New splits use the bundled runtime revision
that understands this field; existing panes remain pinned to their original
revision. A missing/deleted directory produces a connection error rather than
silently opening a local pane or a different directory. Old requests/archives
without `cwd` remain readable and retain the default shell directory behavior.
Runtime remote executable/deployment identity is `omgd`; the remote `omg` draft
CLI remains a separate non-daemon command interface.

## Native Session Runtime hooks (Experimental)

The SSH runtime is an independent PTY owner, not a third-party plugin loader.
Managed hook generation version 11 additionally reports Codex/Claude/Pi activity
through `OMG_RUNTIME_BIN report` when that variable is present. The runtime injects
`OMG_RUNTIME_EVENT_SOCKET`, `OMG_RUNTIME_EVENT_TOKEN` and `OMG_RUNTIME_GENERATION`
into the child environment. Events go to a private Unix datagram socket; the daemon
checks the capability, generation, reporter's OS session and typed Agent recovery
descriptor. Tokens are not terminal output or persistent metadata. Ordinary terminal
OSC 3008 status behavior remains available without this runtime.

A `done` event is task completion, not process exit. Optional completion cleanup
applies only while detached, after a grace period, with an existing conversation
store. New activity/input cancels it. `end` clears completion eligibility but does
not erase the daemon's last durable conversation recovery record. Detached TTL and
UTC deadline decisions are made remotely even while the Mac App is closed.
Recovery launches allowlisted manifest-equivalent arguments for the original
conversation ID and project directory; it does not replay arbitrary hook commands.
Closing a pane/tab explicitly sends the session CLOSE frame and retires only that
owned process group; App termination and detach do not send it. Transport failure
emits an internal disconnected context event, leaves the remote session running,
and presents a clickable reconnect action that rebuilds the relay before attach.
Remote shell exit returns to the retained local shell and is distinct from loss.

The new process gets a new generation and PID. No-ID or unsupported Agents do not
qualify for completion-driven cleanup; process TTL can still end their session.

## Built-in Git review and commit actions

Local Git filesystem events wake the visible Inspector after a short coalescing
window, rather than waiting for the periodic poll. Events received during an
active read remain dirty and trigger a follow-up read; mutations keep their
existing serialized refresh path. The periodic fallback remains enabled.

The built-in Git Inspector accepts `submitCommit(stageAll:amend:)` in addition to
`commitStaged`. These are internal host actions, not new plugin wire messages.
The commit menu offers staged commit, stage all and commit, amend, and stage all
and amend. Operations share the repository mutation queue; amend validates HEAD
before staging, and an empty amend message preserves the previous message.
Failed operations retain the draft; a failed commit after staging leaves the
index staged for retry. Stage-all includes untracked files, respects Git ignores,
and does not push. Category plus/minus controls stage/unstage the entire category,
independent of file-search filtering. The review diff folds unchanged source
ranges while retaining original line numbers and supports unified/split views.

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

## Git AI commit messages and settings navigation

Settings uses task-oriented navigation: **General**, **Shell & Sessions**,
**Input & Controls**, **Editor**, **Views & Tabs**, **Appearance**, **Shortcuts**,
and **Advanced**. The expandable **Integrations** group keeps independent
**Agent**, **Git**, **SSH**, and **Plugins** destinations. Existing
navigation identifiers remain valid. Git auto-fetch and AI commit-message
configuration live under Git; registered hosts live under SSH; Agent hooks, history,
automatic Quick Input behavior and notifications live under Agent (formerly Agent Integration).
Quick Input/history controls live under Input & Controls, with their shortcut under
Shortcuts; startup recovery is under Shell & Sessions. Existing JSON keys are unchanged.

Sidebar search matches English/Chinese labels, aliases and persisted setting IDs,
then navigates to the owning section. Every descriptor has one search destination.
`CoreSetting` exposes a closed list of existing Ghostty behavior options as optional
`core.<ghostty-key>` string values. Empty/unset inherits the user's Ghostty config;
GUI changes use the existing app-owned `appearance.ghostty` final overlay and reload
notification, never rewrite the baseline file. Only catalogued keys and allowed values
reach the overlay; unknown/invalid hand-edited values are preserved in JSON but not
executed. Shell integration, directory/font inheritance affect new terminals. Clipboard
permissions and close confirmation remain inherited until explicitly changed. See
`docs/settings/ORGANIZATION.md` for the navigation/coverage boundaries.

The built-in Git changes composer has a single Generate button before Commit.
`git.commitAI.routes` stores an ordered array of `{id, agent, model}` entries;
`id` is a UUID, `agent` is `claude`, `pi`, `codex` or `opencode`, and `model` is an
opaque model ID advertised by that agent's ACP session. Previously configured CLI
IDs may need re-selection if the adapter uses different IDs. Users can batch-add several models for one
Agent, remove entries, and drag or use arrow buttons to reorder them. Duplicates
are ignored. The first successful route wins; each failed route is attempted once
with a 90-second deadline. Cancellation never advances to the next route.
`git.commitAI.prompt` is an optional user-defined language/format/style instruction
shared by every route, taking precedence over recent subjects. It is edited in a
Save/Cancel sheet with a local draft, not an inline autosaving editor. Prompt help
lives in that sheet; model installation/privacy help lives in the Add Models sheet.
Source patches remain untrusted data. Success/model notices appear above the message editor and expire
after five seconds; failures remain dismissible for diagnosis.

Generation reads only the staged patch and up to five recent subjects through
the repository executor, including SSH when applicable. Inference always runs
locally over ACP JSON-RPC 2.0 (LF-delimited stdio). All four adapters follow the same
initialize/session-new/model-select/session-prompt lifecycle. Claude requires
`claude-agent-acp`, Pi requires `pi-acp`, Codex requires `codex-acp`, and OpenCode
uses `opencode acp`. OMG does not silently install or update adapters, and never
falls back to non-ACP CLI commands. Reloading Codex models checks the stable
`@agentclientprotocol/codex-acp` npm release; installation is opt-in and goes into
an OMG-owned Application Support directory without changing a global npm install.
The update is staged in a version-specific directory, then older OMG-managed Codex
ACP versions are pruned after activation. That managed copy takes precedence for Codex ACP after install;
other adapters remain user-managed. Model discovery supports ACP category=model config options, including
groups, and the older availableModels/set-model variant. Missing adapters, login,
unsupported models and protocol errors fail the route; no default-model substitution
is performed. The client advertises no filesystem or terminal capabilities, rejects
all permission requests, excludes thinking/tool output from the draft and accepts
only end_turn responses. Agent-owned built-in tools are not a client capability;
installed adapters, shell startup and user/admin configuration remain trusted.
Pi runs through a wrapper that disables tools/extensions/context files. Codex starts
read-only with shell/exec/multi-agent features disabled. OpenCode receives deny-all
permissions and reuses auth without importing user config/plugins (avoids fresh-home
plugin dependency installation on each connection). OpenCode custom providers defined
only in user config are therefore not currently included. Claude permissions are rejected at the ACP client boundary.

Remote repository reads use the existing SSH Git executor; the ACP process always
runs on the Mac. No remote Agent installation, ACP server, npm install or inference
command is issued to the SSH host, so a new host/pod needs only a usable Git/SSH
transport. There is currently no automatic remote-ACP preference or remote fallback.

Sessions and generated-message records live in the channel-specific application
support directory `CommitAI/Sessions/<UUID>`, never the repository. Agent home,
XDG data/config/cache/state and native session directories are redirected there;
known credential/provider configuration files are linked from the original home.
OMG never deletes the user's global Agent history. User configurations with explicit
absolute log/session paths and external plugins remain outside this retention boundary.
Owned UUID directories expire 30 days after creation; cleanup runs on use and during
active-service maintenance. No raw ACP/stderr logs or patch copies are written by
OMG. Native Agent transcripts may contain patches and are covered by this directory
policy unless user configuration redirects them elsewhere.

Live sessions are keyed by a hash of repository identity (including SSH endpoint),
Agent, model and custom prompt. Up to four idle/live entries are cached; busy entries
are not shared between concurrent requests. Sessions expire after five minutes idle,
eight turns or 400 KB of input. Each request sends a fresh staged snapshot and says
that earlier snapshots are obsolete. This preserves an opportunity for provider
prefix caching without assuming ACP guarantees token caching or reporting invented
cache savings. Restarting the app starts new ACP sessions rather than replaying old
commit context. Failed/cancelled sessions are closed and removed from the live cache.

The settings disclosure covers sending staged source (including SSH source) to
all configured model services during fallback. Patches over 200,000 bytes are
rejected, not silently truncated; binary files use Git's summary. Output is
bounded and only successful final structured responses are accepted. Raw CLI
errors, prompts and credentials are not exposed in fallback diagnostics. Repository
read errors do not trigger inference fallback. Index entries and patch are checked
again after generation; a changed staging snapshot is rejected. Changing repository,
leaving the composer, or cancelling discards the result. A draft edited during
generation is not overwritten; replacing an existing draft requires confirmation.
There is no dedicated undo-generation control. Generation does not stage, commit,
resume an interactive Agent, or send text to a terminal pane.

## Git branch integration and forge links

The AI settings footer groups Add Models and Commit Style in one compact row.
Add Models contains a searchable multi-select ACP catalog, no manual ID editor;
brief privacy/session help is collapsed by default.

Commit and expanded commit-file context menus expose Open in Browser, disabled
without a parseable origin URL. HTTPS, ssh:// and SCP-style origins are normalized
without embedding credentials. github hosts use /commit and /blob; other supported
enterprise hosts are treated as GitLab and use /-/commit and /-/blob. Deleted files
link to the first parent. This is URL construction, not a remote existence check;
unpushed commits may return a host 404 and unknown non-GitLab hosts may need future
provider configuration.

The upper operation menu and branch context menus expose Merge and Rebase; the
branch search row only retains New Worktree, without duplicate Merge/Rebase icons.
Commit Cherry-pick opens
a target-branch picker (merge commits also require a mainline parent). Merge means
source into local target; Rebase means replay the selected local target onto the
base/source. The target stays checked out, including after a failure. Plans capture
source/target SHAs and the initial branch, revalidate before mutation, require clean
worktrees and use normal Git worktree protections. No auto-stash, reset, force-push
or automatic conflict resolution occurs. Merge creates a merge commit even when a
fast-forward is possible; Cherry-pick applies without committing then commits the
editable message. Conflict/sequencer state remains for terminal resolution/abort.
Rebase is non-interactive and preserves original messages; it has no new message
field to generate. Merge and Cherry-pick support ACP generation from the exact
operation diff, with draft/ref-change protection and the configured style. If the
patch exceeds the 200,000-byte context budget, generation retries with Git's
bounded diffstat (up to 100 file entries), then shortstat if necessary. The context
explicitly identifies omitted patch content; other Git errors still propagate.
This applies to Merge, Cherry-pick and PR/MR generation on local and SSH repositories.

The pull/push menu adds **Merge into…**. Users select local source/target branches and
edit a title (first line) plus description, optionally generated via ACP from the
merge-base diff. The target branch is remembered per repository. Final confirmation
calls local gh/glab even for SSH repositories. The target must exist on origin; the
source branch is pushed (with tags via `--follow-tags`) when out of date, like an IDE
GitHub plugin — this push only happens after the user's explicit dialog confirmation,
never during generation. The target is never pushed. GitHub uses `gh pr create` with an
explicit head and a body file. GitLab uses `glab mr create` with explicit source/target/
title/description and `--yes`, without `--fill`/`--push`. Missing login/CLI and a missing
remote target report errors. Creation is a remote write that may succeed before a client
timeout; errors ask the user to check existing requests before retrying. Tests never
create real PRs/MRs or push user branches.

Commit context menus add **New Tag…**. A dialog edits the annotated tag name and optional
message at the selected commit; Generate reads the branch's merged tag history and asks
the configured ACP routes for the next minor version (e.g. `v1.6.124` → `v1.7.0`),
falling back to a deterministic minor bump. Tag names are validated and duplicates
rejected before any write. Tags are created as annotated tags and are included in
pushes via `--follow-tags` (push, push-to and PR/MR source pushes).

Operation failures use the same floating bubble style as the fetch success notice
(red tint, icon, dismiss) and auto-dismiss after six seconds. The Git operation dialogs
and the settings window follow OMG's appearance and theme color: the settings window
follows `NSApp.effectiveAppearance` (plus explicit light/dark/system override), and
settings/dialogs paint the OPAQUE Display-P3-quantized theme background from the
Ghostty config (e.g. Atom One Dark), so they render the theme color rather than the
default aqua. That color is derived from the config background, never from
`TerminalWindow.backgroundColor`, which on translucent windows is a nearly invisible
white blur backing (using it made settings/dialogs transparent and theme-less).

Terminal chrome (tab sidebar, Inspector, QuickInput) matches the Zig surface
bit-for-bit: opaque windows paint the P3-quantized theme background; translucent
windows paint the P3-quantized color WITH the configured alpha so both stacks
composite over the same blurred backing identically. Using the raw sRGB color for
translucent chrome drifted by one code value (e.g. 73,76,81 vs 73,75,80). Chrome
colors follow the focused surface's background (per-surface/OSC dynamic colors).

## Terminal title updates

The built-in Git Inspector follows pane, directory and connection changes.
Terminal-title-only changes retain its current repository view and do not send
disappeared/appeared lifecycle events or cancel Git work. The latest context is
retained for subsequent lifecycle events. Other panes continue to receive title
changes, including plugins that display the terminal title.

Pane session metadata retains the latest terminal title, but title-only revisions
do not publish controller-wide view or connection-inventory notifications.
Title consumers observe their own Surface; directory and SSH state changes still
notify the controller and connection observers.
The Surface's title publisher preserves individual title delivery without
invalidating terminal content views. Tab rows redraw only when their displayed
title changes, including path-display and Agent-title normalization.

The local Git Inspector watches its worktree, Git directory and common Git
directory recursively. File events mark its snapshot dirty; the existing
three-second timer coalesces changes into a refresh. Unchanged repositories
receive a full fallback refresh every 30 seconds. If monitoring cannot start,
the original three-second polling remains active. Manual refresh and Git
mutations bypass this gate; SSH retains its ten-second polling interval.
Monitoring ends when a pane disappears or closes, and switches with repository
identity. Git status reads use `--no-optional-locks` to avoid generating index
writes merely from observing the repository.
This includes the per-worktree status reads shown by the Branches pane.
Git fsmonitor daemon cookies and IPC files inside the Git metadata directories
are excluded so read-only status queries do not trigger their own next refresh.
Actual index, HEAD, refs and worktree changes remain observable.

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

The vertical tab sidebar renders those host-owned activities with AppKit
`NSOutlineView` cells and native image views. Providers still supply the existing
icon/activity values; they do not own rows, selection, drag sessions or terminal
windows. A split icon resolves activity per Surface. Remote project grouping uses
the connection and remote directory, never a local filesystem probe of that
remote path. See `macos/NATIVE_SIDEBAR.md` for ownership and validation boundaries.

Horizontal native tabs use the same tab presentation resolver and native
Agent/split icon view through `NSWindowTab.accessoryView`. Providers do not receive
new lifecycle or wire messages when layout orientation changes. Horizontal
Inspector navigation moves inside the panel while the registry remains the sole
owner of pane selection/presentation lifecycle delivery.

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

`RightInspectorHost` is a thin adapter into the Core-owned
`InspectorHostController`. The native controller coalesces model notifications,
reads committed tab/pane context, and publishes presentation only while attached
to a window and explicitly visible. Hiding or detaching stops presentation;
visited content remains cached by tab and provider ID, and removed providers are
evicted even while hidden. SwiftUI appearance callbacks do not own provider
lifecycle. Providers still receive typed snapshots/actions and never receive
`NSView`, `NSViewController`, or `NSWindow` references.

The registry's observable catalog publishes descriptor changes only. Typed
content updates use `contentChanges` after the snapshot has been stored, scoped
to the pane and optional tab ID (a nil tab ID denotes the plugin-wide fallback).
Hosts refresh only their selected pane; unrelated updates must not rebuild the
terminal shell or titlebar. A hidden host reads the latest snapshot when shown.
In-process consumers of pane content must subscribe to this stream rather than
the catalog's `objectWillChange`.
Native loading indicators retain loading intent across cached-pane switches,
but stop animating when hidden, occluded, detached or closed. They use AppKit's
timer mode rather than reserving a worker thread for each loading row.

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

The Host's optional `keyboard.quickInputImportShortcut` integration uses the standard external-editor file convention, independently of agent manifests or plugin wire messages. A user-configured chord triggers the CLI editor; a private helper copies up to 1 MiB of UTF-8 text into the requesting Surface's Quick Input draft without modifying the source file. Custom local agents may participate by honoring `VISUAL`/`EDITOR` and passing one file argument. Ordinary editor calls delegate to the previous editor. The bridge grants no new plugin capability, and it does not clear the CLI's original input; users must clear it before Quick Input submission to avoid duplicate text. See `docs/settings/configuration.md` for configuration and limitations.

The local bridge only overrides `VISUAL`/`EDITOR` when an installed Python
interpreter can be resolved without running Apple's installer shim. A shell
entry point invokes that interpreter by its quoted absolute path, supporting
spaces in both the interpreter and helper paths. If Python is unavailable,
ordinary editor configuration remains intact and draft import is unavailable.
Interpreter selection during terminal creation performs filesystem checks only.

OMG SSH bootstrap provisions one versioned remote OMG command (`~/.local/share/oh-my-ghostty/remote/omg`) for Host-owned remote capabilities. Its initial protocol v1 commands manage session start/end, Quick Input editor draft requests and an internal `exec` entry point for existing Host-owned SSH shell tasks (Git/files/inventory/Hooks); it runs on demand with Python 3 and has no separate daemon. Session-specific editor entry points delegate to the user's original editor unless a matching, unexpired request exists. All built-in Agent commands receive transient remote startup identity wrappers when no user alias/function exists, so draft import can identify newly launched Agents without waiting for Hooks; native Hooks remain authoritative for task state. Before importing, the Host also probes the matching remote TTY's foreground process group over the existing SSH transport and applies the local Agent process detector. This covers user aliases/functions which bypass startup wrappers; background Agents on the same TTY are excluded and the probe validates the session/TTY binding. Local and SSH imports share the same auto-mode eligibility and shortcut resolver (OpenCode `control+x,e`, otherwise the local `control+g` default), including explicit custom chords and disabling. This generic bridge requires the CLI to support external editing through `VISUAL`/`EDITOR`; it does not assert that every CLI implements that capability. The Host uses the exact captured SSH connection, session ID, request UUID and remote TTY before sending editor keys; responses are UTF-8, NUL-free and bounded to 1 MiB. Private runtime directories/files use 0700/0600, executable entry points use 0700, normal shell exit removes session data, and later session startup removes abandoned directories older than seven days. Existing agents must restart or resume to inherit the editor environment. Auxiliary shell tasks preserve their module-specific protocols, stdin and limits; unprepared hosts retain direct SSH execution, and SFTP remains the native OpenSSH subsystem. Unprepared/plain SSH sessions never receive draft-import keys. This transport and editor protocol are internal Host capabilities and grant no plugin filesystem, process or network permissions.

Quick Input presentation and focus remain Host-owned. The built-in composer participates in macOS `Option-Command` directional focus navigation, but this does not grant a plugin focus control. When the user enables `agents.openQuickInputOnStart`, the Host may expand Quick Input on the focused Pane's first Agent activity without changing first responder. `agents.openQuickInputOnComplete` applies the same Host-owned presentation policy to a newly completed focused Agent session. Plugin lifecycle messages cannot force focus or override either preference.

Pin and History keyboard navigation are also Host-owned UI state. Pin only
prevents automatic composer dismissal after a user-confirmed Send/Queue/queued
edit; explicit dismiss still wins. Composer visibility and Pin are process-wide
OMG UI state shared across tabs/windows; targets, drafts and queues remain owned
by their original models/Surfaces. Target removal does not close unrelated tabs.
History visibility defaults
to the current Tab (stored explicit preferences are respected). `Command-Shift-H`
toggles the searchable picker, and guarded composer arrows recall immutable sent
messages without modifying them or sending automatically. Picker insertion may
append or replace the draft according to the user's setting. None of these UI
actions adds process-plugin wire messages, expands focus permissions, or changes
queue dispatch/consent or provider lifecycle semantics.

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

Settings → Plugins → SSH manually registers a concrete Host from OpenSSH config
or an existing OMG connection, or opts into registration after successful connections.
The chooser enumerates user/system config and Include files, deduplicates aliases,
and uses local `ssh -G` output to display `alias · user@hostname[:port]`. Wildcard
rules participate in OpenSSH resolution but are not invented as concrete targets.
Listing configuration does not log into any host; only explicit Register connects.
Automatic registration still requires an existing ready OMG connection. It captures the original executable,
destination, options (including user, port and ProxyJump) and local launch directory.
`SSHHostRegistry` persists registered connections and Agent inventory in the app's
UserDefaults domain under `OMG.SSH.Registry.v1`; identity is derived from the full
connection, not just the display alias. Different launch parameters remain isolated.
Matching live connections are preferred in the chooser. Plain `ssh host` registrations
(from config or a live pane) recognize the same account after a reconnect from another
local directory. Destination, workspace alias and executable must still match and both
option lists must be empty. Explicit options (especially relative `-F`/`-i` paths),
user/port/jump changes retain exact identities. Only the selected matching record is
marked connected; duplicate cached records cannot each schedule maintenance.
No remote helper, cron job, or service is deployed.

Registration collects installed CLI versions and Hook state, without npm registry
queries or install commands. Registered hosts refresh their inventory on reconnect;
failed refreshes preserve the previous snapshot and its timestamp. Cancelling
registration or disconnecting before its result returns cannot publish a late
record. Unregister removes the local record/cache and suppresses automatic
re-registration until explicitly registered again; it does not remove remote Hooks.

Settings → Plugins → Agent Integration selects **This Mac** or a registered host.
Each Agent separates OMG status-extension actions from CLI version/update controls.
Installed extensions always expose a reinstall action, even when CLI updates require
an external installer. Extension changes show an Agent restart / Pi `/reload` notice.
Automatic checks record the successfully inspected OMG app version/build and Hook
revision per host. An app upgrade bypasses the normal check interval for extensions;
when the regular check is not due, this performs no CLI discovery/update and does not
advance the CLI deadline. Remote checks still require a registered connected host
and enabled automatic checks. Updates respect each host's automatic-Hook preference
(default off), affect only existing integrations, and never reinstall removed ones.
Failed inspections leave the revision pending for retry. Manual checks also record
the inspected revision; disabling automatic checks suppresses upgrade checks too.
Switching previously captured hosts (including This Mac) renders cached inventory
immediately, without waiting for CLI discovery or registry version checks. An explicitly
selected, uncaptured target discovers CLIs in the background without checking npm
versions; **Check Now** performs a full version check. The connection state remains
visible and check timestamps are available in **Schedule**. Legacy alias-only update
preferences do not automatically enable updates for newly registered identities.
Hook state and install/update/remove actions are scoped to that selected account;
changing selection never retargets an in-flight operation. The normalized status
events master switch remains an OMG-wide presentation setting. Detector-only
agents are explicitly shown as managed by the local Host, not as remote hooks.
The full-width host card is clickable. Agent rows show an icon, executable path,
status-integration switch and disclosure; installed CLIs sort first. Expanding a row
separates Hook reinstall/update from CLI version/update controls. Help/export and
verbose safety information live behind the help button, not repeated under each row.
A host-level **Enable All Detected** button installs/updates only detected CLIs'
missing/outdated integrations (including local detectors, never remote detectors),
without updating any CLI. Each result is recorded; a failed Agent does not discard
successful installations or hide its error. Progress is adjacent to the action buttons.
Rows adapt to narrow forms.

`AgentIntegrationManager` checks installed Hooks while OMG runs, including when
Settings is closed. Each account has an independent hourly/daily/weekly interval,
automatic-check preference, optional automatic Hook updates, and one unified CLI
auto-update switch for all supported, detected CLIs on that account. Existing legacy
per-Agent update choices remain limited to their original scope until the user explicitly
switches to the unified policy; migration never broadens permission. Local checks
default to daily; SSH background checks and all
automatic installation default off. Enabling a target does not install missing
Hooks or Agent executables. Policy and check timestamps are stored in the app's
UserDefaults domain under `OMG.AgentIntegration.Policies.v1`, separating Dev and
release. Errors stay attached to their target; the last successful Hook check is
displayed separately from a CLI discovery failure. Failed attempts retry at the
configured interval; per-target operations are serialized. The optional launch/SSH
reconnect check performs full enabled maintenance once per app run/connection in
addition to the interval; it is off for existing policies unless explicitly enabled.
**Schedule** shows trigger settings and check/maintenance timestamps; the summary
shows the next due check or a disconnected pause. A minute timer evaluates deadlines.
Updates never delay quitting, kill an Agent session or install a remote updater daemon.
Hook maintenance only updates existing integrations, never reinstalls a disabled one.

SSH automatic work additionally requires a matching **ready SSH pane in OMG**.
The scheduler reads `TerminalController.paneSessionContexts`, observes connection
changes/window closure, and cancels background transport when the last matching
connection goes away. Each remote command checks eligibility again before launch.
Unconnected hosts are skipped without advancing their check deadline, so an
overdue check can run when a connection becomes ready. A connection to a different
connection identity does not qualify. Manual foreground checks remain available without an open
SSH pane. All scheduling stays in the Mac app: no cron job, timer, or persistent
Agent updater is installed on the remote host. `SSHSessionTransport` shares the
existing exact-connection OpenSSH socket namespace across Git, Agent inventory and
SFTP. It uses bounded `GitProcessRunner` IO and captured connection options. SFTP
uses a private, temporary local adapter to preserve SSH arguments while selecting
the subsystem correctly. UTF-8 filenames remain UTF-8 in its listing output.
The registry closes a connection's shared master after its last ready pane closes;
OpenSSH also bounds idle masters to 60 seconds. Short-lived Git/SFTP/Python command
processes are still expected; this is connection reuse, not a single-process server.

Remote Hook operations reuse the exported Python installer with typed `status`,
`install`, or `remove` actions and a closed Agent selection. No arguments preserves
the export's install-all-supported-Hooks behavior. The script travels on stdin
through system OpenSSH with BatchMode, connection/keepalive deadlines and bounded
output; it requires Python 3 and existing non-interactive SSH authentication.
Credentials, host keys and ProxyJump remain owned by OpenSSH. No remote install or
remove is performed merely by selecting a host or checking its status.

A ready, focused SSH pane shows a non-blocking Agent Hook onboarding banner when
its inventory is unknown/failed, or an installed CLI has a missing/outdated Hook.
Detector-only Agents and CLIs absent from PATH do not trigger a missing-Hook hint.
The banner is hidden when normalized status events are disabled. Merely presenting it
performs no SSH work or remote writes. **Enable All Detected** authorizes Hook setup
for detected Agents; **Customize** authorizes only inventory discovery and navigation.
Both reserve the pane's exact target locally (including plain-host mapping).
**Enable All Detected** immediately queues a manager-owned job and stays in the terminal:
it waits for any in-flight inventory, discovers CLIs when needed, installs missing/stale
Hooks and shows progress, completion or retryable failure in the initiating banner.
It neither opens Settings nor requires a second click. Repeated clicks coalesce into
one job. **Customize** alone opens Settings immediately, before any SSH round trip.
Transient completion feedback does not reappear in newly opened/reconnected panes.
Settings also shows queued/progress status and explains when all Hooks are already ready.
The choice (including dismissal) and known CLI IDs persist per account in
`OMG.AgentIntegration.Onboarding.v1`. Reconnects, app restarts, Hook upgrades,
manual removal and partial failures do not re-prompt; only a newly detected CLI does.
When inventory was unknown at the click, the first successful CLI inventory becomes
the baseline. Local inventory is cached in `OMG.AgentIntegration.LocalSnapshot.v1`.
The UI explains that local Hooks are not copied to SSH accounts and affected Agents
must restart after installation. Choosing setup does not enable automatic updates.
Hook/check errors and `cliError` are independently recorded in the account snapshot.
CLI upgrade failures are shown next to maintenance, not as Hook installation failures;
long technical output is collapsed, with authentication/package-manager guidance.
OMG does not log into vendor accounts or bypass updater authentication. “Not connected
in OMG” describes the lack of a matching ready pane, not a failed network reachability
probe; manual checks remain available and never unlock disconnected automatic work.

CLI checks use the account's login/interactive shell PATH. An executable whose
resolved path matches a global npm package's declared bin records npm metadata.
Discovery uses an explicit native update policy when the executable exists in
PATH; this policy takes precedence over npm updates, including npm-installed Pi.
Agents without a native policy retain the existing verified npm update path. It never probes `update --help`
or parses help text to infer update support. The policy is:

| Agent | Native update command |
| --- | --- |
| Codex | `codex update` |
| Claude | `claude update` |
| OMP | `omp update` |
| Qoder | `qodercli update` |
| OpenCode | `opencode upgrade` |
| Pi | `pi update --all` |
| Reasonix | `reasonix upgrade` (non-npm installations only) |
| Antigravity | `agy update` |
| Cursor | `cursor-agent update` |
| Amp | `amp update` |
| Copilot | `copilot update` |
| Droid | `droid update` (standalone only) |
| Kimi | `kimi upgrade --yes` |
| Hermes | `hermes update --yes --no-gateway-restart` |
| Grok | `grok update` (script/native only) |
| Cline | `cline update` |
| Qwen | `qwen update` (standalone only) |

Sources: [Amp CLI](https://ampcode.com/docs/markdown/cli),
[Copilot CLI reference](https://docs.github.com/en/copilot/reference/cli-command-reference),
[Droid CLI reference](https://docs.factory.com/droid-cli/cli-reference.md),
[Kimi command reference](https://moonshotai.github.io/kimi-code/en/reference/kimi-command.md),
[Hermes update parser](https://github.com/NousResearch/hermes-agent/blob/main/hermes_cli/subcommands/update.py),
[Grok installation/self-management](https://github.com/superagent-ai/grok-cli#install),
[Cline command registration](https://github.com/cline/cline/blob/main/apps/cli/src/main.ts)
and [updater](https://github.com/cline/cline/blob/main/apps/cli/src/commands/update.ts),
and [Qwen updater](https://github.com/QwenLM/qwen-code/blob/main/packages/cli/src/commands/update.ts).
Kimi's flag skips its update confirmation, not Agent tool permissions. Hermes
updates without interactive config prompts or restarting gateway services.
Droid's npm builds intentionally pin their version; Grok documents self-update
for script installs only; Qwen's updater only replaces standalone binaries and
prints manual instructions for package-manager installs. Reasonix refuses native
self-upgrade when installed by a package manager. Verified npm installations of these
four use the npm update path from the outset; this is not a fallback after native failure. Other unsupported installation forms
remain owned by the vendor updater, which may require manual installation.
Cline's native updater selects its own package manager and may also update Kanban
according to vendor defaults. OMG does not execute vendor install scripts to
migrate sources. [Crush](https://github.com/charmbracelet/crush#installation)
remains on its verified npm/original-installer path: `update-providers` updates
provider metadata, not the CLI binary.

Pi's `--all` also updates its installed extensions. Supported native installations
expose CLI auto-update independently of npm package metadata. Native commands own
their version/channel checks and run only on an explicit update or enabled schedule;
the manual button says Check & Update rather than claiming a newer version is known.
A native update succeeds only with exit code 0; failures are reported without
falling back to npm or another installer. Older CLIs lacking the policy command
report an execution error rather than being classified through help output.
Other installations show their version and an original-installer hint.
Before each update, the executable and, for npm updates, registry state are
rechecked, then the selected newer stable version is installed explicitly. OMG
does not downgrade versions, switch prerelease channels, use sudo, or update
unselected Agents. Hook maintenance runs before CLI discovery so registry errors
cannot prevent Hook updates. npm registry semantics follow
[npm outdated](https://docs.npmjs.com/cli/v11/commands/npm-outdated/).

Tests execute the exported script against temporary homes across every Hook
dialect, verify scoped removal preserves third-party Hooks, and exercise npm bin
identity, exact-version updates, downgrade rejection and per-host policy isolation.
Native policy tests cover every allowlisted command, Pi's `--all`, absence of help
probes during discovery, and nonzero update failures.

`AgentHookInstaller` installs only the closed mechanism selected by each bundled
manifest: Antigravity named JSON, nested JSON, Cursor/Copilot/Reasonix flat JSON, Pi-compatible or
OpenCode/Amp plugins, marker-delimited Kimi TOML, event-named Cline scripts, and
marker-delimited Hermes YAML.
It never removes unrelated JSON/TOML/YAML entries, never overwrites a non-OMG
Cline script, rejects malformed config rather than replacing it, uses atomic
mode-preserving writes (0600 for new files), and keeps a one-time `.omg-backup`
beside each existing file. Removal deletes only OMG-owned commands or blocks.

Hermes exposes lifecycle shell hooks in `~/.hermes/config.yaml` (`hooks: { <event>:
[{ command, timeout }] }`) rather than a plugin API, so its manifest selects the
`yaml` mechanism. Hooks may execute in Hermes' headless shared gateway, so OMG
installs a Python reporter instead of writing OSC from the hook process. It stores
bounded metadata (`session_id`, state, timestamp) in separate SHA-256-named JSON
files under `~/.config/oh-my-ghostty/agent-status/hermes/` (directory 0700, files
0600). Synthetic `test-*` sessions are ignored. The local and SSH installers ship
the same reporter; an OMG-owned YAML block is replaced without changing unrelated
configuration, and an existing user-owned top-level `hooks:` key fails closed.

Local pollers share a background hook-presence cache across windows and panes,
with a five-second freshness interval. Install/remove notifications invalidate it
immediately, including reads already in flight. An initial pending read defers the
probe until a later polling tick. This presence check accepts stale installed
hooks; complete hook-version auditing remains part of integration maintenance.
It never reads or scans the YAML configuration on the UI thread during polling.

Application quit has a separate confirmed termination phase. Pending quit
confirmation remains cancellable; only `applicationWillTerminate` stops native
terminal/sidebar presentation updates. Final tab teardown still releases
Editor, Inspector and Agent activity state, while the durable session checkpoint
prepared for restart is retained. Background status polling is not disabled
merely because a workspace is parked.
After the final checkpoint, runtime shutdown and scrollback capture, confirmed
termination closes background native tabs before each group's selected window.
The selected windows remain for AppKit's final close pass, avoiding repeated
successor selection and fullscreen promotion. This ordering does not apply to
a pending quit, individual Close actions, or remote session Close requests.

Local Hermes probing and the local Agent CLI manager resolve an already
installed Python interpreter before launching it. They skip the Apple
`/usr/bin/python3` shim, including aliases to the same file, remove inherited
`SDKROOT` and invalid developer-directory overrides, and fail without opening an
installer when no interpreter is available. The CLI manager still uses the
user's login shell for CLI environment setup, with an explicitly quoted Python
executable. SSH probes continue to resolve Python on the remote account.

Local panes share one in-flight Hermes status probe and a two-second snapshot
cache across all windows and workspaces, including parked tabs. A single Python
process reads the local process table once, selects foreground Hermes clients by
exact TTY and process group, then reads only those TTYs'
`~/.hermes/terminal-sessions/tty-*` breadcrumbs and matching session events.
Ordinary terminal panes do not launch separate Python/`ps` probes or read Hermes
session files. Cancelling one pane's request does not cancel the shared probe.
Process, timeout, and decoding failures propagate as failures with a two-second
retry backoff; they never masquerade as an empty snapshot or clear live Agent
state. A successful scan without a client on a pane's TTY can end its old state.
Each pane still revalidates its existence, session context and foreground process
before applying a result. A stale breadcrumb from before the client's start,
a background/exited client, and a synthetic test session cannot supply restoration
identity. A live client appears idle even before the first hook runs. No prompt or
message content is recorded. `on_session_end` is turn-scoped and must not be treated
as client exit; `on_session_finalize` reports finalization, while client liveness is
validated separately.

For SSH, `omg +ssh` prompt metadata includes a validated `/dev/pts/N` or
`/dev/ttysN` terminal name. OMG reads the same metadata through its existing exact
SSH connection with a bounded five-second probe and revalidates pane/connection
identity after the result arrives. Existing panes need a fresh SSH prompt from the
updated `+ssh` bootstrap to supply their remote TTY. Plain SSH panes without this
metadata do not guess ownership by working directory or most-recent session.
The executable reporter and multi-pane isolation contract is checked with
`python3 -m unittest discover -s dist -p 'test_hermes_pane_status.py'`.

Crush remains detector-only: OMG has no vendor Hook adapter for it. Its
Install action therefore creates a Host-owned, versioned detector marker under
`~/.config/oh-my-ghostty/agent-detectors/<agent>.json`; the directory is mode
0700 and each exact allowlisted marker is mode 0600. The host enables process and
bounded screen detection for these agents only while the current marker exists.
Screen activity requires manifest status patterns: arbitrary redraws or quiet
periods never imply task start/completion. Settings explicitly identifies these
agents as having no separate status Hook: detection fixes ship with the OMG app,
while reinstalling a detector only enables its local marker. Agents without patterns retain idle
identity until their process exits.

Detector markers are reconciled per Agent on every launch instead of once. Each
launch installs a marker for every detector-only Agent that has none, and refreshes
an OMG-owned marker whose version is stale. An explicit Remove writes a per-Agent
tombstone (`.removed-<agent>.json`, mode 0600, same owner/agent validation) so
reconciliation never resurrects a detector the user turned off; an explicit Install
deletes that tombstone. Content that is not an OMG-owned regular marker is never
overwritten, and conflicting content fails closed. Because a global sentinel could
not distinguish "removed by the user" from "bundled later", removals recorded by
the earlier one-shot migration are not carried over: such a detector is re-enabled
once and can be removed again. These markers are local Host policy and are
intentionally excluded from the exported remote hook installer.

Automatic Hook maintenance installs an integration for any Agent CLI it discovers
but has not integrated yet, in addition to repairing stale integrations, so
installing an Agent CLI is enough for OMG to recognize it. This runs only while
`updateHooksAutomatically` is enabled (the default; a one-time migration enables it
for policies stored before adoption existed, and a later opt-out is preserved).
Detector-only adoption is local-only because those markers are Host policy, and a
tombstoned detector is skipped.

The locally inspected `agy` 1.2.17 binary includes a Hooks Guide documenting
named hooks in a customization root's `hooks.json` (for example,
`.agents/hooks.json`). Events include `PreInvocation`, `PostInvocation`,
`PreToolUse`, `PostToolUse`, and `Stop`; payloads use camelCase
`conversationId`, and stdout is a JSON response channel. This is evidence of
vendor Hook support. The bundled
Antigravity manifest now selects a named JSON Hook adapter under
`~/.gemini/config/hooks.json`, the global customization root documented in the
binary's Customizations Guide. The `antigravity` dialect owns only the
`omg-agent-status` top-level named hook, preserving all other named hooks.
`PreInvocation` and `PostToolUse` report working; `Stop` reports done only when
background work is not explicitly active (`fullyIdle: false` retains working),
and reports error for an error termination. `PostInvocation` is not completion.
There is no supported permission-wait event in this adapter: it never invents
attention from tool activity or emits permission grants. Tool hooks use grouped
matcher/handler arrays; invocation/stop handlers are flat arrays. Stdout always
contains a JSON response (`{}` or a non-blocking Stop decision); OSC 3008 goes
only to the controlling TTY. Conversation identity is escaped and bounded.
Without a TTY the hook safely returns JSON without emitting status.

Local and exported SSH installers share generated handlers, preserve unrelated
hooks, refuse a same-named unowned hook, back up existing JSON, and support
status/update/removal. A previously installed Antigravity detector marker is
inert; it is not sufficient to report Hooks Installed and does not cause silent
Hook installation. Install the new Hook explicitly on each selected host.
SSH bootstrap identity wrappers remain a fallback before the first model turn;
native Hook events provide working/completion signals. Reconnect an SSH pane
or restart agy after installing to reload configuration.

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
for an enabled integration. A newly detected process-group context supersedes
an older terminated Agent activity, including an interruption retained between
samples; only an already-current matching context suppresses synthesis.
Local startup then gets a four-second foreground handoff grace, after which
validation keeps the identity while its declared PID
or process group exists and clears it when that identity exits. A Plugin PID is
not compared directly with the foreground process-group ID, so wrappers and
child tool execution cannot create a false `error` while the Agent is alive. In
SSH, the host never guesses a remote Agent from local process names. It does
conservatively recognize a foreground interactive OpenSSH client (`ssh host`,
excluding forwarding/control/no-command modes and explicit remote commands) as
the pane transport. The destination becomes an inferred SSH context, a validated
remote Agent `omg_cwd` can complete its remote workspace, and a foreground
process-group transition back to the local shell atomically clears live remote
Agent presentation and resume state. Recoverable disconnects first retain an
exact conversation in the separate, inactive SSH recovery descriptor. A matching
typed `omg +ssh` end performs the same cleanup; the next authenticated remote Fish/bash/zsh prompt remains an
additional orphan-recovery signal (`cwd` and bash/zsh `cwdhex` are both accepted).
The transient `+ssh` Fish/bash/zsh startup installs identity-only wrappers for
`agy` and `codex` unless a user function or alias already owns that name. Normal
command-name invocation (including restored sessions) emits remote idle identity;
returning to the shell clears remote contexts while preserving command exit status.
Native hooks supply task progress and completion. The outer OpenSSH command
quotes both apostrophes and backslashes outside single-quoted segments so Fish,
bash, and zsh login shells deliver identical bootstrap bytes to `/bin/sh -c`.
Regression coverage executes the complete generated bootstrap through all three
login shells, in addition to testing the inner Agent wrappers.
Absolute executable paths,
`command codex`/`command agy`, existing user wrappers, and plain OpenSSH sessions
bypass this fallback and require native integration. No remote dotfiles are changed.
Pi starts idle; an empty background snapshot cannot announce completion. A real
foreground turn or observed running background task arms a single completion,
which repeated empty snapshots cannot re-emit after user acknowledgement.
Unique instance IDs prevent an old `end` from clearing a newer same-agent
session. Each Surface keeps one ordered, 32-context reducer; exceeding the bound
evicts the oldest identity while preserving the newest presentation, and later
signals for an evicted identity are ignored. An `end` or failed local liveness
check while the current state is
`working`/`needsAttention` becomes a terminal `error` rather than silently
clearing; an `end` after normal completion clears the Agent identity and restores
the underlying shell icon. Pi `session_shutdown` first returns
the context to `idle` and then ends it, so Ctrl-D and session replacement clear
identity instead of leaving a false completion badge. Programmatic tab selection
and pane focus do not acknowledge either state. Mouse clicks (including a click
that transfers focus), scrolling, or keyboard input delivered to the owning
terminal clear `done`/`error`, without clearing another Pane's state. These events can change
only host-owned tab presentation; they do not authorize terminal input,
filesystem, network, or plugin execution. A process can spoof its own tab badge,
but cannot use this channel to gain capabilities.

Agents that declare `titleStatus` patterns also derive activity from the
terminal title while no typed hook event owns the context. When the title no
longer matches a working pattern the host downgrades that title-derived
`working` state to `idle`, so the ring clears once the agent settles instead of
spinning forever. Agents without `titleStatus` (including the screen-detected
Crush/Hermes) are unaffected by this title path.

A typed hook owns the context once it reported, so its title is not used to
start work. That leaves a gap when a hook never delivers its terminal event:
Claude Code, for example, does not deliver `Stop` when a turn ends in an error,
so the tab would stay `working` forever. The title is therefore also watched as
an independent idle channel for hook-owned contexts. Two signals clear the
stale state: the title shows the idle form continuously for two seconds, or the
title stopped changing for twenty seconds. Claude Code animates its title
between `✳ Claude Code` and `◐ Claude Code` while a turn runs, so the idle
glyph alone is not enough and the animation may end on its working frame. The
second signal requires a long stall so a long tool call cannot clear a real
working state.

Because the event is written to the owning TTY, the same hook works through
OpenSSH. Shell hooks resolve the target TTY from the parent process with
`ps -o tty=` and keep the process-group ID for the instance context; when that
lookup yields no usable TTY they fall back to `/dev/tty` rather than silently
exiting, which is what Pi-compatible extensions already use. Hooks must be
installed in the account where the agent executable runs.
Settings can export an auditable Python 3 installer for explicit transfer and
execution on that account; OMG does not log in or silently modify remote dotfiles.

Agent glyphs use assets from LobeHub `lobe-icons` (MIT) plus the projects' own
published marks, including Termio, OMP/oh-my-pi, Reasonix, Charm Crush, Factory
Droid, and Nous Research Hermes. The Copilot glyph is the GitHub Copilot CLI
robot head: a solid head with the goggle lenses, mouth band and nostrils cut
out, traced from the published marketplace app icon. Xcode ignores a root
`fill-rule`, so the sub-paths are wound by nesting depth (outer clockwise,
holes counter-clockwise) and the shape renders correctly under both even-odd
and non-zero rules. Agent glyphs are template images, so those cut-outs show
the tab background instead of the marketplace icon's white disc. Product names
and marks remain trademarks of
their respective owners; the assets do not imply vendor endorsement.

An agent manifest declares icons in two roles:

- `iconAsset` is the agent's identity mark, rendered by Settings and the
  Inspector. It must be a monochrome template so those surfaces follow the
  system foreground colour; a raster brand image on an opaque background would
  render as a fixed colour block and break the uniform identity treatment.
- `iconGlyph` is an optional additional silhouette used only for tab
  presentation. Tab icons tint the glyph's alpha channel with the activity
  colour (accent, orange, green, red), overlaid through `.mask(_:)`.

Both roles resolve to bundled vector assets with
`template-rendering-intent: template`, so the host supplies all colour. An agent
whose identity mark is already a template reuses it for tabs; one that needs a
separate tab silhouette declares `iconGlyph` and keeps `iconAsset` for identity
surfaces. A raster asset is never valid in either role: its alpha channel covers
the whole square, so masking tints the entire tile into a solid colour block and
erases the mark.

### Built-in agent manifests and restoration (Internal)

Bundled `Agent*Manifest.dataset` JSON files are the single data source for each
allowlisted agent's command, icon assets, optical scale, process markers, hook
kind/dialect/path/events/identity fields, status rules, resume argv, and on-disk
store/discovery mechanism. The roster covers Codex, Claude Code, Pi, Qoder CLI,
Reasonix, OMP, OpenCode, Amp, Antigravity, Cline, Copilot, Crush, Cursor Agent,
Droid, Grok, Hermes, Kimi, and Qwen Code. Manifests can select only closed host
mechanisms; they cannot inject Swift, shell, or arbitrary remote commands. Hook
`dialect` is a closed, decoded enum (`amp`, `cline`, `copilot`, `cursor`, `flat`,
`antigravity`, `kimi`, `nested`, `opencode`, or `pi`); unknown values reject the bundled
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
to a local shell. A typed exit with status 255 retains an inactive recovery
descriptor; other typed exit statuses clear it. This is an OpenSSH error signal,
not proof of a network outage (authentication/configuration errors also use 255).
Ordinary interactive `ssh host` can supply exact argv through the foreground
process observer. When available, those panes also retain a recovery offer after
the process exits; inference cannot distinguish intentional logout from failure.
Without validated argv no replay command is invented.

The optional `awaitingReconnect` and `interruptedAgent` fields remain compatible
with existing archives. In Sessions startup mode, saved SSH panes get one fresh
connection attempt before manual recovery, including panes marked `awaitingReconnect`
by the previous app process. The launch clears that marker and seeds the one-shot
replay handoff before lifecycle callbacks; a fresh status-255 failure restores the
recovery banner. There is no periodic retry. Tabs startup mode opens local shells
without launching SSH. A saved local Agent retains priority over offline SSH intent. **Reconnect in New Tab** launches the original argv, last known remote
cwd and, when available, exact interrupted Agent conversation in a fresh PTY;
the old pane keeps its output and any local processes. The destination receives
the recovery descriptor before lifecycle callbacks and owns subsequent retries.
**Keep Local** discards pending recovery. Failed attempts before a remote prompt
retain cwd/conversation across repeated app restarts. A new host never inherits
another host's directory or Agent. Inactive recovery does not authorize Files,
Git, background remote work, or plugin terminal input. No remote daemon, workspace
UI, credential store, or automatic retry loop is introduced. SSH reconnection and
Agent conversation resume do not preserve arbitrary remote processes; those need
a separately managed remote multiplexer such as tmux.

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

Named terminal workspaces (Personal, Work, etc.) are host-owned collections of
native terminal tabs. They are distinct from the filesystem `WorkspaceDescriptor`
below. Switching preserves the original Surface/PTY objects. Vertical layout
retains the host's workspace windows in one native tab group and projects only
the active workspace into the sidebar and tab actions; native group membership
alone does not mean a provider is presented. Parked-workspace Inspector instances
remain inactive. Horizontal layout and borderless fullscreen use separate
workspace groups; window close and mode changes isolate those groups before
native operations. Agent and SSH state stays attached to the original Surface
identity. Moving a whole tab
between named workspaces preserves its tab and Surface IDs and does not grant new
plugin capabilities or change the pane's local/remote filesystem context. Inspector
providers continue consuming the selected pane's existing context. No public
workspace-control wire message or plugin permission is introduced.

Parked tab sidebars defer catalog-driven list and header refreshes and read
the latest metadata when activated. Workspace switching prepares only the
selected terminal's geometry; other tabs retain their existing Surface and
image until selected. Plugins must not use native attachment or background
sidebar redraws as a signal to start work.

The host stores names, symbol/color choices, shortcut slots, tab membership and
parked-group order in the channel-specific `workspaces/catalog.json` under
Application Support (0700 directory, 0600 file, atomic writes). Terminal output,
SSH credentials and Agent transcripts are not stored in this catalog. Restart
restoration uses a host-owned runtime `workspaces/sessions.json` checkpoint when
available, with existing typed SSH/Agent resume policies. The checkpoint records
serialized tab/split state and resume descriptors during runtime, independently
of AppKit's clean-exit archive. Window close retains records; explicit tab close
removes them. The last successfully written snapshot survives forced termination,
but unsaved changes and arbitrary process memory do not. Legacy restoration without
a checkpoint follows `sessions.startupMode`. This adds no plugin control capability.

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
re-emits the inherited local cwd as OSC 7. At both local session start and end,
`+ssh` disables mouse tracking and extended mouse encodings left behind by an
interrupted remote TUI; it does not reset the screen or unrelated terminal modes.
This cleanup also runs on a failed OpenSSH child launch. It never parses `Connection closed`
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

The application always registers `builtin.info` as a core feature in the fourth
Right Inspector slot (Option-4 by default). It does not depend on an installed or
enabled SSH plugin; disconnecting or uninstalling that plugin does not remove
Info or stop its forwards. Info owns `Info/port-forwards.json` in channel-specific
Application Support and copies the legacy `PluginData/builtin.ssh/port-forwards.json`
on first use when the new file does not exist. Core pane content, actions and
localized titles use ownership-checked core registry APIs.
Info is a host-rendered surface with
optional machine-status and typed machine/session sections (both currently
hidden), a Shell-only command timeline with exact jump-to-position actions, and
the SSH port-forwarding section. The forwarding header uses the antenna/radio-tower
symbol and reports its active port count. A pane with an Agent descriptor or
activity (including `done`/`error`) continues to show that Surface's Shell
command history in Info; only Agent Prompt rows are suppressed. Its Shell jump
anchors remain available, and SSH port-forwarding controls remain visible.
Info does not poll the Agent transcript or present unanchored prompts as
navigable entries. The separate Agent History Inspector,
Agent status, and resume actions are unaffected. Shell history timestamps
include date and time. Single click selects an entry; Cmd+C copies its full command. The native table sizes its
scrolling document to the inspector width and computes row heights from wrapped
text. Prompts show up to four preview lines without expand/collapse controls.
The table explicitly uses AppKit's plain style to avoid automatic sidebar insets.
Horizontal padding is eight points with a faint row separator. Shell rows use a
monospaced font; prompts use the system font. Preview height is measured using
the same wrapping NSTextField cell and four-line limit as rendering, plus 36
points for metadata and spacing (eight points above and below, six between text
and date, fourteen for the date); the timestamp appears below the command/Prompt,
not above it, and short prompts do not reserve the maximum height.
Display previews are additionally bounded to 2,000 characters, but Cmd+C copies
the retained original text, preserving whitespace and literal markup. Reusable
cells and cached heights avoid repeated measurement on unchanged snapshots.
On append, selection follows occurrence identity and a scrolled list retains its
reading position; removal of the selected occurrence clears selection rather
than selecting another row at the same index. Text, timestamp and the jump
button occupy separate bounded frames so long prompts cannot paint across rows.
Double click or the row's jump button uses the command's tracked input anchor.
Navigation is represented by typed `HistoryLocation`, never inferred from an ID
prefix. Available jump buttons appear on hover/selection. The retained Agent
history table/model code is dormant in Info until message identities can be
bound to verified terminal anchors; no text search or ordinal marker matching
is exposed as a jump. A submission/status hook's cursor is not a verified render position.
Settings > General > Sessions has three startup modes: `newTerminal` starts a
fresh local Shell without restoring windows/tabs; `restoreTabs` restores the
window/tab/split tree and safe local cwd (including windows originally
running custom commands, which reopen as fresh local Shells) but intentionally
ignores old VT output, Agent/SSH resume descriptors and old command anchors; and
`restoreSessions` enables the best-effort full behavior below. No mode keeps
old Shell processes running. Legacy `sessions.restoreOnLaunch=false/true`
migrates to `newTerminal`/`restoreSessions`, respectively, without changing
existing users' startup behavior. AppKit selected-tab restoration applies to
the latter two modes only. Quick Terminal state follows the same tab gate.

For SSH panes the port-forwarding section stays above history. Empty ports occupy
64 points rather than a fixed 220-point panel; populated ports grow to a maximum
of 180 points, with their own scroll area. The add-port control remains in the
header, disabled with an identity explanation when the SSH server is unresolved.
History belongs to the current Surface and connection epoch, never global shell
history. The local epoch is initialized when each Surface registers, even if
Info has never opened; moving that Surface between controllers does not reset
its existing epoch. On a host-observed connection-ID change (including return to local),
Info retains the previous epoch's valid tracked Pins with their original
`Local` or `SSH · alias` origin (plus a short server-ID suffix once ready).
An ordinary Local → SSH → another host → Local transition does not clear the
core command records. New commands receive the new epoch; retained executions
are excluded from new-epoch labeling by their core execution IDs. The list
interleaves all segments by timestamp. A retained old-epoch location is allowed
only for its owning Surface and known historical record, and the core still
checks its Pin on every jump. Overwritten/pruned/reset pins become read-only;
unknown initial remote state or an unverifiable replay still fails closed.
IDs are not reused. Repeated text does not deduplicate different executions.
Connecting-to-ready or CWD changes within one connection do not clear records.
The transition is conservative: records captured before the host identifies a
new connection may be discarded rather than attributed to the wrong host.
Only host-observed SSH transitions are covered; unrecognized nested transports
cannot be reliably attributed using OSC 133 alone.

For a simple interactive `omg +ssh` destination, the **local** OMG CLI already
constructs a one-shot remote Fish `-C` command or temporary Bash/Zsh startup
file to report authenticated SSH context, cwd and Agent status. It now adds
OSC 133 A/B/C/D Shell integration to that *same* startup path. There is no
second, simplified remote implementation: `ssh_shell_integration.zig` packages
the actual local `ghostty.bash` (including its version-aware PS0/bash-preexec
paths), Zsh `ghostty-integration`, and the shared Fish
`ghostty-command-markers.fish` module. The temporary Bash/Zsh directory contains
these files only until startup has sourced them; Fish embeds the shared module
in `-C`. Remote loading disables the local-only PATH/sudo/ssh-wrapping feature
flags and does not require a remote OMG executable. Existing initialized
integration is not registered twice. The command passed to sshd uses an opaque
base64 bootstrap envelope: the remote login Shell parses only a small quoted
`/bin/sh` decoder, not embedded Bash/Zsh syntax. This avoids Fish 3.1 parsing
`${BASH_SOURCE[0]}` as its own command substitution before /bin/sh starts.
Remote `base64 -d` is required (missing decoder produces a clear error, not
partial execution); the decoder pipe never consumes interactive PTY input.

Fish emits A in a status-isolated prompt event, invokes the original prompt
**before** writing B, and uses the submitted line in bounded `cmdline_url`;
this preserves both `$status` and `$pipestatus` seen by themes. Empty preexec
events from older Fish do not emit C. Bash captures
the command status before user prompt callbacks, then marks their final PS1
and PS2; its legacy preexec dispatcher retains prior DEBUG handlers. Zsh
uses the local implementation's PS1/PS2 wrapping, deferred setup and redraw
handling. Remote cwd callbacks do not compete for Bash's PROMPT_COMMAND
sentinel: they run at the shared prompt boundary. This runs only in the
owning interactive SSH transport, does not persist a new remote dotfile, and
does not reconstruct per-pane history from a global history file.
Noninteractive SSH, unsupported login Shells and nested transports continue
to opt out; commands already output without semantic markers cannot be
reconstructed from their text. `omg +ssh` only owns the transient remote
startup script, not a long-running remote service. Inspector Option+1…4
shortcuts are consumed by the local NSEvent monitor; a handled nil must never
be replaced with the original event and written to the PTY. Plain digits and
unmatched shortcuts continue to the terminal.

`python3 dist/test_ssh_shell_integration.py --omg
macos/build/Debug/OMG.app/Contents/MacOS/omg` verifies the generated +ssh
payload using a fake transport with **separate local and remote controlling
PTYs**, including the target login Shell's `-c` parsing before /bin/sh. This
keeps signal/input behavior faithful to SSH and avoids testing only a direct
/bin/sh shortcut or retyped copy of the hooks. `--shell /path/to/fish` can test
older versions; the compatibility matrix includes Fish 3.1.2, 3.3.1 and 3.7.1
as well as modern Fish. The matrix compares local/remote/existing-integration startup
for available Fish, Zsh, Bash 3 and modern Bash, covering repeated commands,
failed-command status, Fish pipeline status, multiline/dynamically changed
PS2, empty Enter, cancelled input, resize/redraw without new execution,
preservation of user hooks/rc files, quoted paths and temporary-file cleanup.
No real host or user's shell configuration is touched by this test.

Keyboard interception is not a supported command source. The temporary typed-input
collector has been removed: it could capture password/TUI input and caused duplicate
PTY dispatch. Shell commands are captured at OSC 133 B/C boundaries in a bounded per-screen
store (100 records, 16 KiB capture budget). Every execution has its own ID, even
when its text repeats. Fish sends its submitted command via the standard
`OSC 133;C;cmdline_url=` option from `fish_preexec` (URL-percent-encoded and
bounded), so Starship's late prompt redraw cannot pollute the recorded command
text. No keyboard event interception is involved. Within the *current OSC 133
execution only*, the core verifies the reported command as a suffix of the
rendered input cells and anchors its actual first cell rather than Starship's
late prompt decoration. It never searches the scrollback or matches another
execution. If the option is absent, invalid or not verifiable against cells,
the core falls back to the semantic B/C input region; each execution retains
its own tracked Pin. The host copies a snapshot through the internal
`ghostty_surface_omg_commands` API and navigates with
`ghostty_surface_omg_jump_command`; callbacks must not reenter terminal APIs.
Snapshots enumerate primary-screen command records even while an alternate
screen is visible, so a temporary TUI does not erase their origin metadata;
actual navigation still requires the primary screen to be active.
Successful jumps also return the anchored viewport row and grid top padding;
AppKit overlays a non-interactive translucent highlight that pulses twice over
that specific row, without modifying selection, terminal cells, or invoking
Cmd+F. Failed/expired jumps do not flash. Tracked input pins follow reflow;
pruned pins and alternate-screen navigation
are rejected. Reset drops records without reusing IDs. Command timestamps use host wall-clock seconds recorded at OSC 133 C, not
snapshot refresh time (also for SSH panes). Anchors whose input cell has been
overwritten as output are rejected as well as garbage/pruned pins. Starting a new
semantic input at an existing record's coordinate permanently supersedes that
record, even when the replacement input is identical. Shells without semantic input
markers show no command records rather than reading global history.
AppKit's insertText accumulator must return before the direct committed-text path.
After OSC 133 C commits the command record, the core sends the internal
`command_history_changed` host action through the existing Surface mailbox.
macOS maps it to a Surface-scoped history notification; visible Info refreshes
without waiting for OSC 133 D, process exit, or a timer. Command-finished callbacks
also refresh independently of desktop notification preferences. Hosts that do
not implement OMG history may ignore the payload-free action.

For a normal app quit with `sessions.startupMode=restoreSessions`, OMG saves the
selected tab in each native window group and the foreground terminal tab by
stable `tabSessionID`, not tab index. Selection is frozen before quit dialogs
or teardown and unfrozen if quit is cancelled. At startup, only restored tabs
in the matching reconstructed group may be selected; a short bounded retry
allows AppKit grouping/SwiftUI attachment to finish. User keyboard/mouse input
cancels any pending retry so restoration does not steal focus. Background
Surface focus callbacks cannot raise a different tab after selection restore.

OMG also saves a bounded VT rendering of each restorable, local, non-Agent/non-SSH Shell Surface
in its channel-specific Application Support `shell-scrollback` directory.
Plain ready SSH panes with an exact `SSHResumeDescriptor` (without an active
Agent) are marked restorable even if launched with a custom `+ssh` command,
and capture their current Surface's VT output plus both archived local
and remote command records. Connecting or non-replayable remote panes are
skipped rather than reopening a local Shell with misleading remote output. On app restore,
the validated local replay wrapper consumes the snapshot and prints the same
`Session restored` boundary **before** restarting the SSH transport; it prints
no boundary when the snapshot is absent, and the snapshot path is never sent
to the remote process.
Snapshot sidecar v4 uses one protocol for local and SSH panes: it records
host-owned occurrence IDs and a separate ordered list of the core's valid
entries across **all retained epochs**, including the local `ssh host`
command that opened the connection. Valid anchors take retention priority
over expired read-only rows when the 100-record metadata budget is reached. The VT exporter
adds `OSC 133;B;aid=omg:<occurrence-id>` before each eligible input region;
the core retains that ID only for that execution. On restart, the owning
Surface must replay the *entire* marked sequence with unique IDs, exact
command text and sidecar metadata before Info binds any old SSH record to its
new tracked Pin. Both local and SSH restoration verify marked entries once
replay completes, without matching new unmarked input against old text.
Connection transitions then retain those verified locations with their original
source and start a separate epoch for new commands. Missing, reordered,
invalidated or mismatched marker identities never grant a jump target.
V3 SSH snapshots remain readable and can restore the markers they actually
contain. V1/v2 SSH snapshots and any older local entries whose pins were
already discarded remain read-only; the new behavior cannot reconstruct
those missing identities retroactively.
The host-only `ghostty_surface_omg_export_scrollback_vt` API writes an exclusive
mode-0600 file without occupying the clipboard; its formatter avoids baking
old default colors into a new theme. Snapshot-only formatting drops styled,
textless cells at the end of non-wrapped rows (including Starship/powerline
redraw fill). Soft-wrapped trailing blanks retain their width but render with
default styling; otherwise repeated recovery into narrower panes turns that
fill into colored bars. Real colored text and interior styled spaces are
preserved, and no live cell is mutated. This is a rendered-cell snapshot, not
a re-execution of the prompt theme: soft-wrapped complete prompt text can
reflow to a wider pane, but text already abbreviated by Fish/Starship before
capture (such as a literal ellipsis) cannot be expanded from missing cells. Tests cover multiple capture/replay
cycles at different widths with distinct repeated-command anchors. Export is capped at 2 MiB per pane and
fails closed when it cannot represent all retained valid command anchors.
The directory is mode 0700; snapshots older than seven days, symlinks,
non-owner files and oversized files are not replayed. A failed fresh capture
invalidates the previous snapshot for that Surface rather than showing stale
output after the next restart. The snapshot contains
old terminal output, which may include secrets, and is not a recording of a
live PTY. The newly restored local Shell is a new process. Its one-shot shell
integration replays the saved VT file before the first prompt, removes that
file, and prints a dim `──────  Session ended/restored · date  ──────`
timeline boundary rather than ASCII dash banners. zsh, bash and fish have
small adapters to a fork-owned restore script. SSH/Agent session restoration
retains its separate existing behavior. Alternate-screen content is not saved.
A crash before the normal termination capture has no new scrollback snapshot.

The export uses tracked start and end pins to insert OSC 133 B/C around each
surviving Shell command, including retained earlier epochs, as it reconstructs display output. Its
host callback supplies borrowed occurrence IDs under the renderer lock and
must not reenter terminal APIs; untrusted or absent IDs are never used to
grant restored navigation. Its C marker
also carries the already-recorded command in `cmdline_url`, so replay cannot
turn an early Fish B/Starship redraw into a bogus combined command. On replay these
create *new*, Surface-owned command IDs and exact tracked anchors; Info matches
the ordered command text against a versioned owner-only sidecar **only to
restore original timestamps**, not to find terminal coordinates. If count or
text differs or no valid tracked records survive, Info still lists the saved
commands as distinct **read-only** entries with their original times. Their
jump controls are disabled with an explicit expired-anchor explanation; new
commands remain navigable. This avoids silently dropping visible history or
pretending that old text is a precise coordinate. A missing shell integration
does not consume the snapshot file and therefore cannot label later coincidental
commands as restored. Executions repeated verbatim remain distinct records;
pruned, overwritten, or oversized records are never represented as exact
anchors. The command history remains bounded to 100 entries after replay and
subsequent activity.

The retained (currently disabled in Info) Agent history reader is owned by
`PaneAgentHistoryService`, not the SSH forwarding provider. While disabled,
Info creates no Agent transcript subscriptions and never starts its polling or
remote reads. If re-enabled after reliable anchor support, subscriptions are
keyed by Surface and a binding containing agent, conversation, remote target
and connection ID. Changing binding, hiding the pane
or disabling the provider cancels its task; token checks reject late results.
Discovery resolves a session file once per subscription (unresolved bindings retry).
Every three seconds only that file is checked, never a global store rescan after
resolution. Local JSONL reads are incremental; replacement/truncation resets the
reader. SSH checks a file revision and transfers a bounded recent tail only when
it changed. The dedicated `PanePromptReader` does not reuse the transcript-preview
reader's 500-message/16,000-character truncation or semantic text cleaning.
It retains the latest 100 user messages (up to 8 MiB of text), ignores assistants
and typed tool-result blocks, and preserves complete text for each retained row.
A single user text over 1 MiB or JSONL record over 8 MiB is skipped, never offered
as silently truncated copy text. Initial/backlogged reads inspect at most the
latest 8 MiB; an incomplete leading record is discarded. Incomplete trailing
JSONL records wait for their newline. When enabled, a limited-history notice explains
omitted older/oversized records. Loading and read failures have distinct states;
failed refreshes retain already-loaded text and retry. Source-generation plus
byte-offset IDs distinguish repeated prompts and file replacement. Reading a
conversation transcript does not imply its messages were rendered in this pane.

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
command for that previous alias and enters `sshConnecting`; it must not promote
that connection to `sshReady` using the previous login's cwd. Only a fresh remote
prompt or validated remote Agent cwd can make the new workspace ready. Until
then providers must not display either the dormant repository or a local
repository as the active remote workspace. Process exit returns it to local. A connection begin, remote cwd update, matching
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
bounded configurable count. The default time range is the last three calendar
months. Local and SSH discovery skip older file timestamps before reading or
decompressing transcript headers; local enumeration still checks file metadata.
Local parsing uses at most two workers and checks cancellation between batches.
Choosing All or Year sends the built-in `setAgentHistoryTimeRange` action and
expands the shared host cache once; narrower ranges and search filter that cache.
A limited scan preserves older valid metadata cache entries for later expansion.
When focused on a Pane with an active SSH session,
Agent History automatically switches scope to the remote host using batch SSH
queries and displays remote agent conversations; focusing a local Pane returns
to local history. Registration starts no scan, timer, watcher, or
helper process; appearance reuses the host cache or starts one cancellable scan.
An already-started metadata scan may finish into the shared cache after hiding.
Transcript reads are cancelled on disappearance and resumed on return when needed;
loaded transcripts and selection remain tab-owned until close or scope change.
Search emits
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

The host's [persistent self-signed release identity](RELEASING.md#4-signing)
maintains code identity across updates; it does not grant filesystem access,
add plugin capabilities, or replace macOS user consent. The old ad-hoc to
persistent-signature migration can require users to authorize once. Actual
folder-permission retention is not an end-to-end validated plugin guarantee.

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
managed port forwards. Remote listener process-name probes are independent of
those tunnels: only active loopback forwards belonging to a presented Info
server are probed. Hiding the last Info presentation for a server stops its
periodic probes; re-presenting it refreshes immediately. Multiple presentations
share the same probe demand. Visible probes refresh every 30 seconds. Each
SSH alias receives one batch for all eligible ports, with at most one probe
subprocess active across aliases. `lsof`/`ss` scan listeners once per batch;
`fuser` remains a per-port fallback within that same SSH connection. Probe
execution uses the shared asynchronous process runner, a six-second deadline,
and a 64 KiB combined output limit. Cancellation terminates the query SSH (not
the forwarding tunnel), settles before a replacement starts, and ignores late
results using generation and forward tokens. Transport, tool and malformed-output
failures retain cached process names and retry after 60 then 120 seconds;
successful queries with no listener clear the cached name. Batch records must
cover exactly the requested ports, end with a completion marker, and contain
process names of at most 128 characters without control characters.
Identical plugin snapshots do not broadcast another UI
revision; Agent History reuses one decorated session array per host and active
session set instead of allocating it separately for every tab.

The trailing Inspector retains visited native pane views within the current tab,
so Files/Agent History/Git/Info switches hide and reveal existing views rather
than rebuilding large trees. Only the selected pane receives provider lifecycle;
hidden views cannot receive input or automatically paginate. Only a visible
window selected in its native tab group can present an Inspector provider;
attached views in inactive tabs and parked workspaces do not start provider work.
Files and Git preserve their lifecycle on title-only updates at
the same location. Switching panes prepares the incoming view before hiding the
outgoing view, without disabling screen updates for the whole application.
Cache entries are
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
Foundation process launch/termination operations are ordered on a dedicated
serial queue, outside the result-state lock. Synchronous process spawning does
not occupy the MainActor/cooperative executor; termination callbacks never need
to acquire a lock held around Foundation Process APIs. Signals target only the
spawned process, never the user's terminal foreground group. Cancellation before
launch and launch failures settle their continuations explicitly. This does not
claim recursive cleanup of unrelated login shells or descendant processes.
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
expansion. Current-pane directory navigation changes the existing shell's cwd.
When the source has an active agent activity or resume descriptor, a current-pane
preference instead opens a right-hand sibling shell: shell commands must never
be submitted into the agent's chat input. Explicit new-tab/split choices are
unchanged. New panes start in the requested directory, using the existing SSH
replay path for remote sessions. These host-owned actions add no external plugin permission.

Local relative terminal links carry the cwd recorded at their output position,
using OSC 7 transitions anchored to tracked screen pins. Changing directories
locally does not reinterpret older filenames against the new cwd. Each screen retains
at most 1024 transitions with paths up to 4096 bytes; unknown/expired metadata
does not fall back to guessing the current directory. Quoted names containing
spaces are matched as one path. Absolute links are independent of this history.
SSH relative links instead use the source pane's known remote working directory:
core OSC 7 history is local-only and must never supply a Mac directory to a
remote filesystem. Historical remote cwd is not reconstructed; use absolute
links when referring to files from an earlier remote directory. Hover previews,
existence checks, and opening share the same host resolver, including relative
OSC 8 targets and Chinese filenames. Native `open_url` and `mouse_over_link`
cwd fields are host/core interfaces, not plugin wire capabilities.

Plain long `ls` listings can expose directory and extensionless filenames
without icon prefixes; metadata columns are not candidates. SSH `itemType`
checks the exact quoted target with POSIX shell file/directory tests (following
symlinks), rather than classifying the first child of an SFTP directory listing.
These read-only checks reuse the established SSH transport; no connection to a
host named by terminal link text is created.

The internal `WorkspaceFilesystem.itemTypes` batch operation omits missing
paths. Cmd-link checks coalesce requests for 12 ms, deduplicate resolved paths,
and allow only one active batch per surface. SSH batches contain at most 128
paths and 32 KiB of shell command text, with a strictly validated one-byte type
response per path; local batches run off the main actor. Both present and absent
results are cached for three seconds, keyed by surface/session revision,
filesystem identity, directory and resolved path. Transport failures are not
negative-cached. Cache expiry or a context change causes a new check. Clicking
still rechecks the target through the opener. The host applies answers before
one native `ghostty_surface_omg_link_checks_flush` call, instead of scheduling
an entire screen rebuild for each filename. The renderer reuses link cells only
when content/row identity, cwd, dimensions, configuration and check revision
match; scroll/reflow/content changes invalidate the match cache.

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

Mermaid widgets distinguish DOM construction from mounting. Detached widgets wait
outside the serialized renderer queue, live remounts can retry discarded results,
and widget destruction cancels mount observation. Changed source cannot accept
stale SVGs; completed widgets do not rerender merely because their DOM moves.
Renderer/load errors are visible and terminal, not silently retried. These are
Host-owned editor lifecycle details and do not expand plugin APIs or permissions.

### Git collection navigation

Inspector visibility is independent of its native view lifetime. After the
first opening, the sidebar retains its pane deck until its host is removed.
Hiding still sends `disappeared` immediately and showing sends `appeared`;
hidden context updates must not reactivate providers. Sidebar open/close is
immediate, matching Quick Input: visibility, shell width and native titlebar
accessory width update together, without slide/fade animations or a delayed
collapse. Retained hidden content cannot receive pointer events or appear in
accessibility navigation. This does not change provider lifecycle semantics.

The built-in Git sidebar shares one search and List/Folder toolbar below its
History, Changes and Branches tabs. Search text is independent per tab; the
`git.collection.viewMode` preference is shared by all three. History's mode
changes only expanded commit files, using the Git Collection folder builder.
The internal `searchHistory` action searches subject, full message, author,
email and hash within the current history scope, including unloaded commits.
Reads are bounded and cancellable, results are paginated, and filtered commits
are displayed without implying direct ancestry between search hits. Clearing
search restores the cached unfiltered history unless its scope was invalidated.
