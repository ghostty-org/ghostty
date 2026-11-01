# OMG Settings

Stable OMG preferences are stored in:

```text
~/.config/oh-my-ghostty/settings.json
```

Development builds use an isolated file:

```text
~/.config/oh-my-ghostty-dev/settings.json
```

On first launch, OMG Dev copies the stable file as a starting point when the
Dev file does not exist. The files are independent after that copy, so local
builds and tests cannot rewrite the main terminal's preferences.

The file is a flat, sorted JSON object. Only values explicitly chosen by the user are written. It is safe to edit with a text editor, script, or configuration-management tool.

## Example

```json
{
  "agents.openQuickInputOnStart": true,
  "appearance.backgroundBlur": "enabled",
  "appearance.backgroundOpacity": 0.75,
  "appearance.darkTheme": "Catppuccin Mocha",
  "appearance.lightTheme": "Catppuccin Latte",
  "editor.backgroundMode": "followTerminal",
  "editor.fontFamily": "jetbrainsMono",
  "editor.fontSize": 13,
  "editor.keymapPreset": "idea",
  "editor.fileOpenDestination": "currentPane",
  "editor.directoryOpenDestination": "currentPane",
  "editor.syntaxTheme": "followTerminal",
  "editor.tabWidth": 4,
  "editor.wordWrap": false,
  "general.quitWithoutConfirmation": true,
  "keyboard.quickInput": "shift+command+e",
  "keyboard.quickInputHeight": 252,
  "notifications.taskComplete": false,
  "tabs.grouping": "project",
  "tabs.layout": "vertical",
  "tabs.ordering": "manual",
  "tabs.pathDisplay": "folderName",
  "tabs.sidebarWidth": 300
}
```

Reload the file with **Settings > Advanced > Reload** or Ghostty's **Reload Configuration** command. `tabs.layout` applies to newly created windows because changing the NSWindow/titlebar class of an existing terminal would risk rebuilding its presentation hierarchy.

## Git, SSH and Agent Integration

These are separate Settings sidebar entries. SSH manages registered hosts; Agent
Integration manages CLI/status integration installation and notifications; Plugins
continues to manage plugin packages.

Under **Git > AI Commit Messages**, add a local Claude Code, Pi, Codex or OpenCode Agent and one
or more model IDs at a time. All four load available models from ACP sessions for multi-select;
manual IDs must also match the adapter's advertised catalog. Drag entries (or use their arrow buttons) to change
priority. The first entry is the main model and every entry below it is a fallback.
The list is saved as `git.commitAI.routes`, an array of `{id, agent, model}` objects
with UUID identities. No API keys are stored in OMG settings.
The **Edit commit prompt** button opens a Save/Cancel editor (`git.commitAI.prompt`) for language, format
and style for all models and fallbacks. Leave it blank to follow recent commits.
For example: “Use Conventional Commits, an English subject under 72 characters,
and Chinese body bullets.” Success/model notices appear above the commit editor
and disappear after five seconds; error notices can be dismissed manually.

In Git's Changes tab, **Generate** fills the commit message without committing.
Only staged changes and recent commit subjects are sent. The CLI runs locally even
for an SSH repository. Local CLI does not mean local inference: data may be sent
to any configured model service during fallback. Existing drafts require replacement
confirmation, and a draft edited while generating is never overwritten. Cancel stops
further attempts. Patches exceeding 200 KB must be split rather than silently truncated.
Install local ACP adapters `pi-acp`, `@agentclientprotocol/claude-agent-acp` and
`@agentclientprotocol/codex-acp` as needed; OpenCode provides `opencode acp` itself.
In Add Models, Reload checks the stable Codex ACP npm version. If an update is
available, users can explicitly install it for OMG; the app installs it under its
Application Support directory, removes older OMG-managed versions after activation,
and does not modify a global npm install. Other adapters remain user-managed. There
is no one-shot CLI fallback. An SSH host/new pod does not need any Agent:
only Git reads run remotely, and model calls always use the Mac's ACP adapter.
The model and privacy notes live inside Add Models; prompt guidance lives inside
the prompt editor. There is no dedicated undo-generated-message control.

Session homes and records are under OMG's channel-specific Application Support
`CommitAI/Sessions`, with private directories and 30-day creation-based expiry.
Native auth/provider files are linked to reuse local login; global Agent history
is never swept. External plugins or explicit absolute paths in user config are
outside this cleanup boundary. Cleanup runs on use and while the service is active.
Live contexts are isolated by repository/SSH identity, agent, model and prompt;
reuse stops after five minutes idle, eight turns or 400 KB of input. Reuse can help
provider caching but does not guarantee token savings. Pi extensions/tools remain
disabled, so extension-only providers are not included.

## Git branch operations and browser links

The AI settings page uses a compact action row: **Add models…** opens a searchable
ACP model multi-select with collapsed help; **Commit style…** opens the styled
Save/Cancel prompt editor. There is no inline model-ID TextEditor and no persistent
three-paragraph disclosure in the settings page.

Commit/file context menus expose **Open in Browser** when `remote.origin.url` is a
parseable GitHub/GitLab-compatible origin; otherwise the item is disabled. SSH and
SCP origins are normalized to HTTPS, credentials are removed, and deleted files use
the first parent commit. GitHub and GitLab URL layouts are selected by host family.

Branches add Merge and Rebase. Commit Cherry-pick opens the same target-branch
flow and supports a mainline parent for merge commits. Merge source → target creates
a merge commit; Rebase target onto source preserves existing messages; Cherry-pick
source → target lets the user edit the new commit message. Each dialog can generate
its operation message through the configured ACP routes from the exact operation diff.
Plans revalidate branch tips and the original branch, require a clean worktree, do
not stash/reset/force-push, and leave conflicts for terminal resolution. Target stays
checked out after success or failure.

**Merge into…** in the pull/push menu opens an in-app source/target and title/
description editor; the target branch is remembered per repository. ACP can generate
the title/description. Creation uses local, already-authenticated `gh pr create` or
`glab mr create`; the target must exist on `origin`, and the source branch is pushed
(with tags via `--follow-tags`) when needed after the user's confirmation. It never
pushes the target and reports missing tools/login or a missing remote target. A remote
request may have been created if a timeout occurs, so retry guidance asks users to
check existing requests.

Commit context menus add **New Tag…**: an annotated-tag dialog whose Generate reads
the branch's merged tag history and suggests the next minor version via ACP (with a
deterministic fallback). Duplicate/invalid names are rejected before writing. Tags are
included in pushes via `--follow-tags`. Operation failures use the same auto-dismissing
bubble style as success notices, and the Git dialogs/settings window follow OMG's theme.

## Appearance synchronization

Application and window appearance share one policy: an explicit light/dark/system
OMG override wins; without an override, the Ghostty-configured appearance applies.
Appearance writes are skipped when the appearance name is unchanged. Config-change
callbacks defer appearance application to the main queue and read the latest config,
not a previously captured theme. Duplicate effective light/dark notifications are
filtered before reporting to libghostty, including synchronous reentrant callbacks.
This prevents appearance changes and conditional-theme config reloads from feeding
back into each other and saturating the main thread when opening Settings.

## Ownership And Precedence

| Layer                | Owns                                                                                                              | Priority |
| -------------------- | ----------------------------------------------------------------------------------------------------------------- | -------- |
| Runtime/window state | Current tab Sidebar visibility/live width, Inspector visibility/width/active pane, collapsed groups, selected tab | Highest  |
| OMG settings         | Optional application and Appearance overrides listed below                                                        | Second   |
| Ghostty config       | Inherited baseline, including `macos-tab-layout`, theme, font, opacity, blur, and cursor                          | Third    |
| Built-in defaults    | Safe values for unset settings                                                                                    | Lowest   |

The fork settings model is the single writer for `settings.json`. Settings UI controls bind directly to that typed model. Runtime code observes the same model; it does not mirror these preferences into a second UserDefaults domain.

Window UI state is intentionally separate: `InspectorPresentationStore` owns last-used Inspector visibility, committed width, and active pane in the application UserDefaults domain. These values are not Ghostty configuration and are not portable user preferences.

## Settings

| Key                               | Type    | Default                       | Values / Range                                                                                         | GUI                                | Apply                        |
| --------------------------------- | ------- | ----------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------- | ---------------------------- |
| `tabs.layout`                     | enum    | Ghostty `macos-tab-layout`    | `horizontal`, `vertical`                                                                               | Settings > Tabs                    | New windows                  |
| `tabs.sidebarWidth`               | number  | `240`                         | `176...480`                                                                                            | Settings > Tabs                    | Next committed/default width |
| `tabs.grouping`                   | enum    | `none`                        | `none`, `project`, `date`                                                                              | Settings > Tabs                    | Runtime                      |
| `tabs.ordering`                   | enum    | `manual`                      | `manual`, `created`, `recentlyUsed`                                                                    | Settings > Tabs                    | Runtime                      |
| `tabs.pathDisplay`                | enum    | `folderName`                  | `fullPath`, `folderName`                                                                               | Settings > Tabs                    | Runtime                      |
| `tabs.showShortcutLabels`         | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Tabs                    | Runtime                      |
| `tabs.rememberSidebarWidth`       | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Tabs                    | Runtime                      |
| `tabs.sidebarVisible`             | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Tabs                    | Runtime and new windows      |
| `appearance.windowTheme`          | enum    | Ghostty config                | `system`, `light`, `dark`                                                                              | Settings > Appearance              | Live                         |
| `appearance.lightTheme`           | string  | Ghostty config                | Ghostty theme name                                                                                     | Settings > Appearance              | Live                         |
| `appearance.darkTheme`            | string  | Ghostty config                | Ghostty theme name                                                                                     | Settings > Appearance              | Live                         |
| `appearance.fontFamily`           | string  | Ghostty config                | Installed font family                                                                                  | Settings > Appearance              | Live                         |
| `appearance.fontSize`             | number  | Ghostty config                | `6...72`                                                                                               | Settings > Appearance              | Live                         |
| `appearance.backgroundOpacity`    | number  | Ghostty config                | `0.05...1`                                                                                             | Settings > Appearance              | Live                         |
| `appearance.backgroundBlur`       | enum    | Ghostty config                | `disabled`, `enabled`, `macosGlassRegular`, `macosGlassClear`                                          | Settings > Appearance              | Live                         |
| `appearance.cursorStyle`          | enum    | Ghostty config                | `block`, `bar`, `underline`, `block_hollow`                                                            | Settings > Appearance              | Live                         |
| `appearance.tabRowDensity`        | enum    | `compact`                     | `compact`, `comfortable`                                                                               | Settings > Appearance              | Runtime                      |
| `appearance.tabIconSize`          | number  | `16`                          | `12...20`                                                                                              | Settings > Appearance              | Runtime                      |
| `editor.keymapPreset`             | enum    | `idea`                        | `idea`, `vscode`                                                                                       | Settings > Editor                  | Runtime                      |
| `editor.fileOpenDestination`      | enum    | `currentPane`                 | `currentPane`, `newTab`, `splitRight`, `splitDown`, `splitLeft`, `splitUp`                             | Settings > Editor                  | Runtime                      |
| `editor.directoryOpenDestination` | enum    | `currentPane`                 | `currentPane`, `newTab`, `splitRight`, `splitDown`, `splitLeft`, `splitUp`                             | Settings > Editor                  | Runtime                      |
| `editor.backgroundMode`           | enum    | `followTerminal`              | `followTerminal`, `system`                                                                             | Legacy configuration               | Retained, no visual effect   |
| `editor.syntaxTheme`              | enum    | `followTerminal`              | `oneDark`, `oneLight`, `dracula`, `githubDark`, `nord`, `monokai`, `catppuccinMocha`, `followTerminal` | Settings > Editor                  | Runtime                      |
| `editor.fontFamily`               | enum    | `jetbrainsMono`               | `jetbrainsMono`, `sfMono`, `menlo`, `firaCode`, `system`                                               | Settings > Editor                  | Runtime                      |
| `editor.fontSize`                 | number  | `13`                          | `8...36`                                                                                               | Settings > Editor                  | Runtime                      |
| `editor.tabWidth`                 | number  | `4`                           | `1...12`                                                                                               | Settings > Editor                  | Runtime                      |
| `editor.wordWrap`                 | boolean | `false`                       | `true`, `false`                                                                                        | Settings > Editor                  | Runtime                      |
| `git.autoFetchInterval`           | integer | `5`                           | `0...1440` minutes, `0` disables                                                                       | Settings > Git                     | Runtime                      |
| `git.commitAI.prompt`             | string  | `""`                          | User-defined language, format and style                                                                | Settings > Git                     | Next generation              |
| `git.commitAI.routes`             | array   | `[]`                          | Ordered `{id, agent, model}` entries                                                                   | Settings > Git                     | Next generation              |
| `notifications.taskComplete`      | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Agent Integration       | Runtime policy               |
| `notifications.attention`         | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Agent Integration       | Runtime policy               |
| `notifications.sound`             | boolean | `false`                       | `true`, `false`                                                                                        | Settings > Agent Integration       | Runtime policy               |
| `agents.historyLimit`             | number  | `10000`                       | `100...50000`                                                                                          | Settings > General                 | Runtime Agent History reload |
| `agents.statusHooks`              | boolean | `true`                        | `true`, `false`                                                                                        | Settings > Agent Integration       | Runtime ingress policy       |
| `agents.openQuickInputOnStart`    | boolean | `false`                       | `true`, `false`                                                                                        | Settings > Editor > Quick Input    | Next Agent start             |
| `agents.openQuickInputOnComplete` | boolean | `false`                       | `true`, `false`                                                                                        | Settings > Editor > Quick Input    | Next Agent completion        |
| `keyboard.inspectorPanel1`        | string  | `option+1`                    | Modifier combination plus one key                                                                      | Settings > Keyboard                | Runtime                      |
| `keyboard.inspectorPanel2`        | string  | `option+2`                    | Modifier combination plus one key                                                                      | Settings > Keyboard                | Runtime                      |
| `keyboard.inspectorPanel3`        | string  | `option+3`                    | Modifier combination plus one key                                                                      | Settings > Keyboard                | Runtime                      |
| `keyboard.inspectorPanel4`        | string  | `option+4`                    | Modifier combination plus one key                                                                      | Settings > Keyboard                | Runtime                      |
| `keyboard.quickInput`             | string  | `shift+command+e`             | Modifier combination plus one key                                                                      | Settings > Editor > Quick Input    | Runtime                      |
| `keyboard.quickInputImportShortcut` | string | `auto` | `auto`, external-editor chord(s), or empty to disable | Settings > Editor > Quick Input (toggle); JSON (override) | New terminal |
| `keyboard.quickInputHeight`       | number  | `252`                         | `140...480`                                                                                            | Settings > Editor > Quick Input / drag divider | Runtime              |
| `keyboard.quickInputHistoryScope` | enum | `tab` | `pane`, `tab`, `global` | Settings > Editor > Quick Input | Runtime |
| `keyboard.quickInputHistoryInsertionMode` | enum | `append` | `append`, `replace` | Settings > Editor > Quick Input | Runtime |
| `keyboard.quickInputHistoryRetentionDays` | number | `7` | Integer days, `1...365` | Settings > Editor > Quick Input | Runtime |
| `keyboard.quickInputHistoryKeepAfterQuit` | boolean | `true` | `true`, `false` | Settings > Editor > Quick Input | Runtime |
| `sessions.startupMode`            | enum    | `restoreSessions`             | `newTerminal`, `restoreTabs`, `restoreSessions`                                                        | Settings > General                 | Next launch                  |
| `general.language`                | enum    | `system`                      | `system`, `en`, `zh-Hans`                                                                              | Settings > General                 | Live (Settings UI)           |
| `general.quitWithoutConfirmation` | boolean | Release: `false`; Dev: `true` | `true`, `false`                                                                                        | Settings > General                 | Next app quit                |

Appearance controls resolve each value as `OMG override > Ghostty config > built-in default`. The UI reports the effective value and source, and **Reset to Ghostty** removes only OMG Appearance keys. The app writes a generated `appearance.ghostty` overlay beside `settings.json`; it never edits the user's Ghostty config. The overlay is loaded last and applied with Ghostty's existing live config update API, so current surfaces keep their PTY, shell, and scrollback.

Vertical tabs and the Right Inspector use the active terminal background color and background opacity. There is no independent Sidebar or Inspector theme. Both sidebars open/close immediately like Quick Input; content width, visibility and right titlebar accessory update together without slide/fade animations or delayed collapse. Inspector native content stays lazily mounted after its first opening, but hidden content cannot receive clicks or appear in accessibility navigation. Transparency is painted only on background layers; window alpha, terminal glyphs, cursors, and icons remain opaque.

Settings > Editor owns the native code editor's local editing behavior. `editor.keymapPreset` defaults to `idea` and may be changed to `vscode`; the setting resolves to the native `EditorKeymap.Profile` consumed by the editor command router. `editor.syntaxTheme` defaults to `followTerminal`, inheriting the resolved OMG colors and background effects. Other presets use independent editor appearance controls. `editor.backgroundMode` is retained only for reading older configuration files. `editor.fontSize`, `editor.tabWidth`, and `editor.wordWrap` are runtime settings consumed by the native editor view.

`tabs.pathDisplay` applies to the path portion of every Vertical Tab label. Local and SSH panes use the same policy: `fullPath` preserves the current full-path presentation, while `folderName` displays only the final folder component. SSH keeps its alias prefix, for example `cloud /home/user/code` becomes `cloud code`.

Settings > Editor > Quick Input combines composer and sent-history preferences in one section. Existing `keyboard.*` and `agents.*` configuration keys are unchanged for compatibility. The shortcut control records `keyboard.quickInput`; the default is `⌘⇧E`. While the composer is open, it participates in the default `⌥⌘` directional focus navigation: `⌥⌘↓` moves from the lowest terminal split into the composer, `⌥⌘↑` returns to the terminal, and left/right can move from the composer to an adjacent split. `agents.openQuickInputOnStart` optionally expands the composer when a focused Pane first enters an Agent activity context, while `agents.openQuickInputOnComplete` optionally expands it on a new normalized `done` transition. Both default to `false`, apply only to the focused Pane, and never steal terminal keyboard focus. The composer is a real bottom dock: opening or resizing it reduces the terminal presentation height, so rows displaced from the visible grid remain reachable through normal terminal scrollback. Its 8pt drag target and 1pt divider reuse the same resize interaction and renderer-derived divider color as the left and right Sidebars. All three hit targets overlap inward over adjacent content while consuming only the 1pt divider in layout, avoiding a transparent resize gutter; `keyboard.quickInputHeight` remembers the last committed height. For a normal draft, `⌘↩` sends the text plus a real Enter key event, `⌥⌘↩` appends it to the current Pane's in-memory FIFO queue, and Escape closes the composer while preserving the draft. While editing a queued item, `⌘↩` saves it in place without sending, `⌥⌘↩` saves and moves it to the queue end, and Escape keeps the original message. The composer is backed by a native AppKit `NSTextView`, so `⌘A/C/V/X/Z/⇧⌘Z`, selection, undo, and IME marked text use standard macOS behavior. Option+left/right is explicitly mapped to word movement, Option+up/down to paragraph movement, and adding Shift extends the selection. Escape first cancels active Pinyin/IME composition; otherwise the editor consumes it to close the composer without exiting macOS fullscreen. Image-only Command-V reuses OMG's private PNG temporary-file adapter and inserts the generated path, while text/file pasteboards keep native behavior. One queued message is written only when that Pane reports a new normalized `done` Agent transition; `needsAttention` and `idle` do not drain the queue. Queued drafts appear in a dedicated 60pt bottom lane that reduces terminal presentation height instead of covering terminal text. Its 44pt cards flow left-to-right with content-aware 136–420pt widths and horizontal overflow follows the newest item. The left Enter control sends that queued message immediately; Enter, edit, and remove controls use 30×30pt hit targets plus a pointing-hand cursor. Only the central message region opens the complete-message popover after 300ms; hovering any action button never triggers it. Edit/remove actions retain spring insertion/removal transitions. Composer open/close is immediate, like terminal splits, and terminal layout reserves the final accessory height once. Only Queue lane/card presentation keeps its own compositor-friendly spring; there is no 0.34-second dock animation or resize wait. Editor text and Placeholder prefer the active Terminal's Regular font family and point size, with 1pt additional line spacing; an unavailable family falls back to the regular system monospaced font. The CJK fallback is explicitly Regular, and input/caret color follows the terminal's configured foreground rather than bright system-label white. Footer Send, Queue, Cancel, Pin and History are buttons sharing 12pt labels, 8pt shortcut symbols (10pt Pin/History icons), 6pt icon-to-label spacing, 4pt between actions and hover/pressed feedback. Pin and History are icon-only, with help/accessibility labels; the complete padded action rectangle is clickable. The composer and queue lane paint the active Terminal background at its configured opacity instead of forcing an opaque backing, so Control Center thumbnails preserve the same transparency as the Terminal and Sidebars. Placeholder placement is derived from the real AppKit caret geometry rather than `textContainerOrigin` alone. In a real window the editor converts `firstRect(forCharacterRange:)` from screen to local coordinates and draws after `caretRect.maxX + 1 device pixel`; the no-window fallback uses `textContainerOrigin + lineFragmentPadding`. The caret itself is never repositioned. Marked text hides the placeholder immediately, the cursor is clamped to the font size, and the Queue total uses only a static tray icon plus its numeric count. Queue contents move with an in-process Pane move but are cleared when the Pane closes or OMG exits. Every write revalidates the Surface identity, the 1 MiB limit, and Secure Input before writing to the PTY.

`keyboard.quickInputImportShortcut` defaults to `auto`: explicitly opening Quick Input copies the current agent's unsent plain-text input without shortcut setup. Pi, Codex and Claude Code use `control+g`; OpenCode uses `control+x,e`. Other agent activity contexts use the generic `control+g` default. Ordinary shell prompts open Quick Input immediately without sending editor keys. Settings exposes an enabled-by-default toggle. For custom keybindings, JSON can override the value (for example `control+x,control+e`); an explicit override also permits invoking a custom agent that OMG does not yet recognize. Empty disables import. New terminal processes receive the editor bridge automatically; existing processes must be restarted in a new terminal. This is an editor-file bridge, independent of the built-in agent catalog: custom agents work when they honor `VISUAL`/`EDITOR` and pass a UTF-8 file to that editor. Up to four comma-separated chords using Control/Option/Shift plus a letter or digit are supported; subsequent chords may be an unmodified letter, for leader sequences such as `control+x,e`. The Host installs a private helper and injects its path as `VISUAL` and `EDITOR` for new surfaces. Persistent local sessions use a stable, channel-scoped helper directory so surviving shells can import after an app restart; ordinary PTYs retain process-scoped ownership. The helper delegates ordinary editor invocations to the previous configured editor (or `nano`); only a four-second import request captures the file. Files are capped at 1 MiB and routed by Surface UUID and request UUID. Imported text appends to an existing Quick Input draft, except when it is empty, identical to the draft, or an exact prefix or suffix of the draft; those snapshots leave text and focus unchanged. Opening history, automatic presentation and closing the composer do not request imports. The composer opens immediately; draft import runs in the background and a timeout only sets a status message. Closing the composer cancels the pending import, and arriving text never reopens it or steals focus. The agent's file is never changed: **its original input remains present**. The Host tracks the imported prefix per Pane; sending a message beginning with that prefix writes only the suffix and then Enter, while sent history records the full message. An unchanged imported draft sends Enter only. Editing the original prefix blocks submission with guidance to clear the Agent input and reopen Quick Input. Do not edit the CLI input independently between import and send; reopen Quick Input to refresh its snapshot. Sending waits for an in-flight import to finish. Explicitly opening Quick Input captures the pane before dock layout changes, for both local and SSH sessions. A temporary image above the renderer covers resize/editor screen transitions without stretching the captured glyphs or intercepting input. PTY processing continues; removal follows import completion/failure/cancellation with a short redraw grace interval, or a six-second fallback deadline. Attachments and structured mentions are not transferred. Agents that override the editor themselves, existing processes, and SSH agents are not configured by this local bridge. New OMG SSH sessions provision the unified remote OMG command and configure a session-specific editor entry point after shell startup. For those sessions, the Host arms a short-lived draft request over the exact captured SSH connection, checks the session identity and TTY, and only then sends the external-editor shortcut. UTF-8 drafts return through the same SSH transport with the local 1 MiB limit. Remote Python 3 is required. Local and SSH imports use one shared shortcut and eligibility policy; SSH startup identity wrappers cover every built-in Agent command without replacing user functions/aliases, so newly launched Agents do not need to wait for a Hook before import. The Host also checks the remote TTY's foreground process group with the local Agent detector, covering Agents launched through user aliases/functions without a startup Hook. This is a generic external-editor bridge, not a Pi-specific integration: the CLI must support external editing through `VISUAL`/`EDITOR`, and a default shortcut does not guarantee every CLI supports it. Reconnect and restart or resume existing agents to inherit the editor entry point. Plain SSH and unprepared sessions open the composer without sending editor keys. The remote command delegates ordinary editor calls to the user's previous editor, removes session files on normal shell exit, and expires abandoned session directories after seven days on subsequent session startup. Repeated imports append repeated text. Disabling the setting stops new requests immediately; new terminals restore normal editor environment handling.

Pin (left of History) keeps Quick Input open and focused after successful Send, Queue or queued-edit Save. It does not prevent explicit Cancel/Escape or the composer-toggle shortcut from closing the dock, and does not prevent a removed target Pane from losing its local target. Composer visibility and Pin are process-wide OMG state, synchronized across existing and newly created tabs/windows, and are not saved across app restarts. Explicit close (or unpinned automatic close) applies globally; closing/removing a Pane does not change other tabs' visibility. Drafts, queues, history ownership and current targets remain independent, and a new/focused Pane binds the globally visible composer to its own target. A failed send/queue still leaves the draft intact.

The Sent History subsection of Settings > Editor > Quick Input controls history. The popover shows sent date/time and compact separated message previews in a lazy list, with a 480pt maximum list height. `⌘⇧H` is the fixed History shortcut: it opens the composer if necessary and restores the last selected visible/matching record, falling back to the most recent only if the selection is unavailable;  pressing it again closes only History and preserves search text/mode. `↑`/`↓` move the highlighted selection (and scroll it into view). Mouse hover and keyboard navigation share the same subtle highlight and selection cursor; hovering a row moves that cursor, so the next arrow/Enter operates on the hovered item. Hover does not auto-scroll under the pointer; reopening scrolls to the remembered selection. This applies equally to mouse-opened History. Enter applies the selected full message without sending or changing the queue. Search is collapsed by default. Clicking the magnifier expands search; typing directly in list mode starts a fresh search through the same mounted native input client, retaining the first character and IME composition. In search mode, Escape first cancels IME composition if active, otherwise exits search without discarding the query; a further Escape closes History. Exiting search shows the unfiltered list. Outside dismissal and keyboard toggling also retain the query for reopening. `keyboard.quickInputHistoryInsertionMode` defaults to `append` (newline-separated from a nonempty draft); `replace` replaces the current draft. This applies to popup clicks/Enter, not arrow browsing.

In the composer, unmodified `↑`/`↓` browse sent history in the configured visibility scope. Away from the first/last **visual** line (including wrapped lines and trailing empty lines), arrows retain native caret movement. At a boundary, the first extra press is consumed and a second distinct press in the same direction starts navigation. Key repeat cannot satisfy this initial confirmation. Once browsing, arrows—including repeats—switch records directly without repeating confirmation or requiring traversal of each historical message's lines. The latest unsent draft and UTF-16 selection are restored by going newer past the most recent record. Sent records are immutable: editing a recalled message promotes it to the latest draft and re-arms confirmation; moving the caret also re-arms confirmation without losing the saved latest draft. Browse-only content does not overwrite the latest Pane draft during dismissal or Pane transfer. If expiry, clearing, or a scope change removes a record from the browsing snapshot, navigation returns to the saved latest draft instead of recalling an unavailable record. IME marked text, modified arrows, text selections and queued-item editing keep native behavior. Only successful submission to the terminal is recorded, including manual/automatic queue sends; this does not imply the Agent accepted or executed the message.

`keyboard.quickInputHistoryScope` selects `pane`, `tab` (default, all split panes of the current tab), or `global` (all tabs/windows). Existing explicit scope preferences are retained; the new default applies only when no valid preference is stored. Scope is a visibility filter, not a separate storage partition. History follows the Surface UUID on Pane moves and joins the destination tab; restored Surface/tab-session UUIDs recover ownership after relaunch. Newly created panes/tabs do not inherit closed identities; retained records from closed panes remain discoverable with the global filter until expiry. `keyboard.quickInputHistoryRetentionDays` defaults to 7 and expires records after that many elapsed 24-hour periods, in memory and on disk. Expired records are excluded from results immediately and cleaned at launch, on writes/settings changes, on opening History, every minute while running, and on normal quit. When OMG is not running, disk cleanup waits until the next launch.

`keyboard.quickInputHistoryKeepAfterQuit` defaults to `true`. History is stored locally as unencrypted JSON under the channel-specific Application Support directory's `quick-input-history/history.json` (directory mode 0700, file mode 0600). It may contain secrets or private prompts. Turning retention off deletes the saved copy and keeps only current-process history; re-enabling saves unexpired in-memory records. Clear All Quick Input History removes every scope and the saved copy after confirmation without affecting drafts/queues. Records are bounded to 50 per Pane, 1,000 overall and 8 MiB of prompt text; individual messages are limited to 1 MiB. Consecutive identical sends within a Pane refresh the timestamp instead of adding a duplicate. The history stores pasted-image paths, not image files, so a recalled path may no longer exist. Storage errors are shown in History/Settings without preventing terminal sends.

Settings > Agent Integration installs the versioned, removable JSON/plugin/TOML/script/YAML integration declared by each bundled Agent manifest. Hermes uses a marker-delimited YAML block in `~/.hermes/config.yaml` and a helper that records bounded per-session state files. OMG matches a live foreground client to its per-TTY session breadcrumb before displaying status or saving restoration identity; synthetic hook-test sessions are ignored. SSH Hermes discovery requires remote TTY metadata from a fresh `omg +ssh` bootstrap. Detector-only Crush uses an explicit Host-owned Install/Update/Remove marker instead of pretending a vendor hook exists; its process/screen fallback is disabled when the marker is removed, and detector markers are reconciled per Agent each launch so a detector bundled after an upgrade is still adopted while an explicit Remove stays removed. Automatic Hook maintenance also integrates Agent CLIs it discovers but has not integrated yet, so installing an Agent CLI is enough for OMG to recognize it. `agents.statusHooks` controls both normalized event ingress and the bounded local foreground-PID fallback used when an agent does not emit `SessionStart`. Vertical Tabs use the focused pane's bundled Agent glyph/title/ring and keep other panes' attention/error/done as trailing alerts; idle has no ring. Normal `done` and unexpected-interruption `error` remain visible even on the currently focused pane; Tab selection/focus does not clear them, and only mouse click or keyboard input in the owning focused terminal acknowledges the terminal state. Horizontal Tabs keep Ghostty's native presentation. **Export SSH Installer…** writes an auditable Python 3 script that the user can explicitly transfer and run in a remote account. Remote hooks work through SSH because they write the bounded event to that remote TTY; OMG does not log in or alter remote accounts automatically.

Settings > General > Sessions controls `sessions.startupMode`. `newTerminal` disables old-window restoration and opens a fresh local Shell. `restoreTabs` restores window/tab/split layout and each pane's local working directory, but opens a fresh local Shell without saved output, command anchors, Agent resume or SSH reconnect. `restoreSessions` keeps the existing best-effort behavior: saved Shell scrollback/validated anchors, SSH reconnect using original OpenSSH argv, and exact validated Agent conversation resume for eligible running sessions. Runtime-backed sessions reconnect the original process when it is still alive. Ordinary legacy Ghostty PTYs instead start a new Shell and restore saved context; those PTYs do not keep jobs alive after quitting OMG. `sessions.localRuntimeEnabled` defaults to `true`: newly created local windows, tabs and splits use persistent sessions prepared with the existing Ghostty command, environment, cwd and shell integration. Persistent history is limited to 4 MiB of logical terminal storage, including the active screen; lower configured byte limits (including zero) and line limits are preserved. This is lower than the native Ghostty default of 50,000,000 bytes. Disable this option for larger ordinary PTY histories. Disabling it affects only new local terminals. Closing a window or quitting detaches runtime sessions; explicitly closing a tab/pane ends them. The Session Library in Shell & Sessions lists a selected local/SSH endpoint on demand and can attach or end a background session. `restoreTabs` always creates fresh local identities, including when its saved panes used SSH, and `newTerminal` skips saved workspace tabs. The legacy `sessions.restoreOnLaunch` boolean is migrated once (`false` → `newTerminal`, `true` → `restoreSessions`) and removed from the saved settings. Switching modes takes effect on the next launch.

Settings > General > Quit controls `general.quitWithoutConfirmation`. When enabled, an app-level quit terminates running terminal processes without showing the close confirmation; closing an individual tab or window still uses Ghostty's normal confirmation policy. The safe Release default is `false`; OMG Dev defaults to `true` so replacement installs do not block on an interactive dialog. An explicitly saved value overrides the channel default.

Settings > General > Language controls `general.language`. `system` (the default) follows the macOS preferred language; `en` pins English and `zh-Hans` pins Simplified Chinese. The language applies live to the Settings window and the app-owned static macOS main-menu hierarchy. Dynamic window names, Services entries, terminal content, titles, and Agent events are not translated.

## Machine-readable Schema

[`schema.json`](schema.json) contains stable keys, types, allowed values, ranges, descriptions, categories, and apply requirements. Automation should read that file rather than inspect Swift source.

A future CLI should expose the same registry:

```text
omg +oh-my-config get tabs.layout
omg +oh-my-config set tabs.layout vertical
omg +oh-my-config list --json
```

The configuration action is designed but not implemented in this iteration. It will extend the existing `omg` executable rather than introduce another CLI binary, must call the typed settings registry, and must not introduce another config store.

## Validation Captures

- [`settings-appearance.png`](../images/settings-appearance.png): Dark Appearance, inherited values, source labels, optional overrides, and Reset to Ghostty.
- [`settings-appearance-light.png`](../images/settings-appearance-light.png): the same native Settings hierarchy under explicit Light Appearance.
- [`appearance-transparency-vertical.png`](../images/appearance-transparency-vertical.png): Vertical Tabs and terminal content using the same 58% Ghostty background alpha.
- [`appearance-transparency-horizontal.png`](../images/appearance-transparency-horizontal.png): native Horizontal presentation under the same Ghostty opacity/blur configuration.

### Shared OMG and editor appearance

Settings > Appearance uses the existing Ghostty theme catalog. Window appearance and theme selection share one section. Switch with System Appearance enables separate light/dark theme choices; otherwise a fixed light/dark appearance and one theme preset are shown. Background opacity and blur/glass continue to use Ghostty appearance overrides.

The editor defaults to `editor.syntaxTheme = followTerminal` (Follow OMG), using the resolved Ghostty palette, background, opacity and effect. Editor opacity/effect controls are hidden while following OMG; adjust them in OMG Appearance instead. An explicit editor theme enables independent `editor.opacity` (0.05–1, default 1) and `editor.blur` (`disabled`, `enabled`, `macosGlassRegular`, `macosGlassClear`, default `disabled`); switching back preserves these independent values. Existing explicitly selected editor themes are retained. The older `editor.backgroundMode` key remains readable for configuration compatibility but no longer controls theme resolution.

The editor toolbar uses a vertically collapsing rectangle button to hide the editor. Save All and Reload are no longer shown in its overflow menu; save and document keyboard actions remain available.

### Editor completion and typing

Completion stays open while a text transaction refines its prefix, preserves the selected candidate where possible, and uses current-buffer identifiers including short names and identifiers after the first 100,000 UTF-16 units. Buffer candidates are lexical suggestions, not LSP type-aware completion.

`editor.autoClosePairs` defaults to `true`. Typing quotes or brackets inserts a matching partner and places carets inside, including multiple carets; a matching closing character advances past the existing partner. The setting can be disabled in Settings > Editor. Pasted text is not expanded into pairs.

Appearance theme and font controls are selection lists. `editor.themeName` optionally selects an independent theme from the same Ghostty catalog; it overrides the older built-in `editor.syntaxTheme` preset. Theme colors include background, syntax categories, selection and caret, not source-code formatting. Follow OMG clears the independent theme name. Settings windows support Command-W.
