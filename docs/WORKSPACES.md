# Terminal workspaces

Named workspaces keep separate groups of terminal tabs, for example Personal for
personal projects and Work for company projects. They organize terminal sessions;
they do not sandbox files, credentials, shell environment variables or networking.

## Use

The upper-left workspace name replaces the vertical sidebar's TABS heading. Click
it to search, switch, create or edit a workspace. Each workspace has a name, symbol
and muted accent color. Collapsing the vertical sidebar also hides its workspace
control; workspace shortcuts remain available. Horizontal tabs use a compact
workspace control above the terminal content.

- `Control-Command-W`: open the searchable switcher. It initially selects the
  current window's previous workspace; Return confirms, arrow keys choose, Escape cancels.
- `Control-Command-1` through `Control-Command-9`: select the corresponding
  workspace in its fixed catalog order.
- **New** in the header opens a name/icon/color form with a live preview.
  **Create & Open** commits the workspace only after its terminal can be displayed.
  The launch configuration follows normal new-tab directory inheritance settings,
  including the local-directory fallback for SSH/runtime panes. Failed operations
  reopen the form with its input preserved and a specific error.
- Each row has **pencil** and **trash** buttons beside its shortcut hint to edit
  or delete that exact workspace, including an inactive workspace. Both have
  hover highlights and tooltips; trash uses a warning color on hover and is
  disabled for the workspace currently active in the invoking window. Hover/search selection does not change the action target.
  The name field receives focus in both create and edit forms; Return saves.
- **Delete…** opens an inline confirmation naming the workspace, tab count and
  actual current-workspace destination. Live and saved tabs move in their own
  windows; running sessions remain open. The current workspace cannot be deleted;
  switch away first. Personal is an ordinary deletable workspace when inactive.
  At least one workspace is retained.
- **Move current tab…** opens a searchable destination page naming the tab being
  moved. Choose a destination to move the complete tab, including its splits and
  live sessions, within the same window. Moving the last tab leaves a new shell.
- The list identifies the current workspace separately from keyboard selection,
  and its counts refer to the current window. Back/Escape returns from management
  pages; Escape on the switcher dismisses the popover.

Configure shortcuts in **Settings > Shortcuts > Workspaces**. Workspace shortcuts
must include Command and apply inside OMG. Conflict captions cover duplicate
workspace shortcuts, OMG panel/composer shortcuts, menu items and detected
Ghostty bindings. Third-party global shortcuts are not exhaustively detectable.
Existing tab and Inspector panel shortcuts retain their meanings.

## Workspace layout

Each workspace remembers sidebar visibility and width, Inspector visibility,
width and selected panel, and Quick Input visibility, pinning and height. Tabs
within a workspace, including tabs in other windows, share these presentation
preferences immediately. Window-local selection, tab order and scroll position
remain independent. New workspaces start
from the global sidebar and composer defaults; changing one workspace does not
change another workspace's saved layout. Quick Input drafts, queues and send
targets remain attached to their original panes. Quick Input changes do not
republish sidebar/Inspector geometry. Theme, fonts and keyboard shortcuts remain
global.

Tab orientation belongs to the logical window host, not to the workspace's shared
panel preferences. Changing horizontal/vertical layout in Settings updates the
last-main terminal host in place, including its parked workspace tabs, and sets
the default for new windows. Window and Surface identities remain intact. In
horizontal layout the workspace control lives in the titlebar when available,
and Inspector navigation lives inside the panel.

## Multiple windows

Each window switches workspaces independently. A stable window identity owns one
tab group per workspace, with its own tab order, selection and sidebar scroll
position. For example, if A shows workspace One with a1/a2 and B shows One with
b1/b2, switching B to Two and back restores b1/b2 in B; A stays unchanged.
Opening a workspace for the first time in B creates B's own terminal rather than
focusing A or moving A's tabs. New windows inherit the current workspace name
but receive a new window identity. Native tab detachment likewise creates an
independent window; explicit tab joins and undo transfer/restore that identity.
Workspace appearance and panel preferences are shared by workspace; terminal
content, drafts and send targets remain pane-owned.

## Session behavior

Switching workspaces keeps existing Surface/PTY objects alive. Background local
commands, Agent sessions and SSH clients continue running and consuming resources.
A network failure can still disconnect SSH independently of workspace switching.
Returning restores the saved tab order and selected tab. Native tab-group changes
during a handoff are not published to the sidebar: each workspace retains its
layout/host, and the destination list and selection appear together after the
handoff. This prevents intermediate mixed lists and selection-driven scrolling.
Only the current window's destination group participates in the switch. Other
windows displaying the same workspace keep their own sessions and selection.

Workspace metadata and terminal descriptors are checkpointed together to
`workspaces/state.json` while the app runs. Each version-2 generation contains
one complete catalog, window/group graph and session snapshot. A valid nonempty
checkpoint takes precedence over AppKit restoration and resumes supported
Agent/SSH descriptors. An explicitly emptied version-2 checkpoint also takes
precedence, so closing every tab does not resurrect an older AppKit archive.
Closing a window retains its saved tabs; explicitly closing a tab removes it.
Undo restores both the tab and its eligibility for future checkpoints.
If the current window's group has no usable presentation when selected again,
OMG reconstructs that group's saved tabs and splits, preserving their order and
selected tab. Records belonging to another window are not merged or claimed. It does not re-show closed windows whose content views have been
torn down. Explicitly removed tabs stay removed; a workspace without a restorable
record opens a fresh terminal. Reconstructing a closed workspace uses the same
supported session descriptors as startup, not arbitrary live process recovery.
Checkpoints preserve native window grouping, selected tabs, window frames and
fullscreen state and mode, stable window/group IDs and each window's current and
previous workspace. Legacy checkpoints migrate each saved native group to an
independent window identity; unrelated parked groups are not guessed to share
one window. The oldest records without any group field fall back to one group
per workspace. Startup validates pure session data and all ownership references
before creating surfaces, then assembles groups before showing selected tabs.
Quit freezes workspace metadata before window teardown begins. A damaged latest
generation falls back to `state.json.previous`; an empty or unusable legacy
checkpoint does not suppress AppKit restoration. Unknown legacy workspace IDs
migrate to the default workspace. If restoration leaves every window hidden,
it reveals an existing workspace.
Structural changes request a coalesced checkpoint; directory/title/resume data
is checked once per second. Unchanged state does not write a file. Encoding and
atomic file replacement run on a private serial queue. A forced kill restores the last successful
checkpoint; changes not yet written at the instant of termination may be lost.
This is process reconstruction, not a process checkpoint: arbitrary running
commands and remote jobs cannot be resurrected by OMG.

Without a named-workspace checkpoint, legacy recovery follows **Settings > Sessions > Startup Mode**:

- Restore Sessions uses existing supported Agent and SSH resume descriptors and
  shell restoration behavior.
- Restore Tabs recovers layout and directories without resuming those processes.
- New Terminal starts fresh; the named workspace catalog remains available.

Restarting the application does not preserve arbitrary running processes. Agent
resume requires a supported exact conversation descriptor. SSH reconnect and
remote process persistence retain their existing limitations.

The checkpoint lives inside the channel-specific Application Support directory
(`OMG` or `OMG Dev`). The directory uses mode 0700 and checkpoint files use mode
0600. It records names, appearance, shortcuts, ownership, selected tabs/order/
scroll positions, window presentation, layout preferences, split trees and typed
session descriptors. It does not contain terminal output, SSH credentials or
Agent transcripts. Legacy `workspaces/catalog.json` and `workspaces/sessions.json`
are migration inputs; they are not independent writers after the session store
starts. The original files remain available for migration diagnosis.

## Native presentation and implementation

`TerminalWorkspaceState` is the committed ownership/order graph. The coordinator
owns commands and a live controller registry; native tab groups and controller
identity fields are projections. Checkpoint sampling never reconciles ownership.
Switch, move and delete preflight every affected host, retain the previous graph,
apply native changes, and publish only after success. Failed attachment/show
operations restore the previous arrangement. Delete merges each window's groups
without hiding other windows' currently visible workspace.

`TerminalWorkspaceNativeAdapter` keeps the existing fullscreen stack alive by
joining incoming members before parking outgoing ones. It publishes final
membership and selection together, restores the workspace sidebar host, prepares
the correctly sized terminal frame and restores focus. Fullscreen transition
notifications defer switches until the transition completes; delayed presentation
callbacks carry a generation so rapid subsequent switches supersede them.
The latest valid request replaces an older queued switch for that window.
Selecting the current workspace cancels its pending switch. Both successful
and failed native fullscreen transitions drain requests after the callback
returns, and only if another transition has not started.
Native transitions are tracked by the actual NSWindow identity, so logical group
reassignment cannot leave a stale transition blocking future operations.
Non-native (borderless) fullscreen has no native tab stack: inside the same
presentation transaction the adapter normalizes the outgoing window, assembles
the destination group, then enters the same fullscreen mode on its selected tab.
The committed logical group continues to drive its sidebar while AppKit detaches
the borderless selected window. Exiting fullscreen restores the native group.
The workspace popover is opened by the controller command; SwiftUI registers
its anchor but does not own the open event. Keyboard commands fall back to the
window content anchor when the sidebar is collapsed.

New workspace shells use the same launch-configuration path as new tabs, so a
known inherited directory is available for the first row before shell title
notifications arrive. Ordinary Quick Input presentation does not cover the pane
with a screenshot. Only an actual external-editor draft handshake may retain a
short-lived TUI image, and resizing the pane immediately invalidates that image.
The native composer takes first responder when ready; the controller's selected
pane continues to own the split highlight during the handoff.

The workspace regression suites cover the state graph, close/undo, cross-window
delete, rollback and checkpoint migration. `VerticalTabFullscreenTests` additionally
checks horizontal and vertical native fullscreen, repeated workspace switches,
multiple tabs/splits, moving the last tab, deletion, framebuffer size and focus.
`TerminalWorkspaceManagementDesktopTests` exercises creation through actual
popover controls in both native and non-native fullscreen. These desktop tests
require an unlocked desktop with the test process foregrounded.
The test plan sets `OMG_TESTING=1` before application launch, disabling shared
workspace disk reads/writes even before XCTest classes are loaded. Explicit
session-store fixtures use temporary paths. Existing user catalogs are never
cleaned by matching test-like workspace names.
