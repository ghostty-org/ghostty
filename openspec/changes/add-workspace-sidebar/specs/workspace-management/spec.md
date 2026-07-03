## ADDED Requirements

### Requirement: Workspace as a tab container
A workspace SHALL be a container that owns zero or more Ghostty tabs (each tab may itself contain splits, unchanged from stock Ghostty behavior). Every open tab in a window SHALL belong to exactly one workspace, and a window SHALL show exactly one workspace's tabs in its content area at a time (the active workspace).

#### Scenario: Tab belongs to its creating workspace
- **WHEN** a new tab is opened while a given workspace is active
- **THEN** the new tab is added to that active workspace

### Requirement: Create a new workspace
The system SHALL provide a `new_workspace` action, bound by default to Ctrl+Shift+N, that creates a new workspace containing exactly one new tab, appends it after the current last workspace, and switches the window's active workspace to it.

#### Scenario: User creates a workspace
- **WHEN** the user invokes `new_workspace` (Ctrl+Shift+N)
- **THEN** a new workspace is created containing one new tab, the new workspace becomes the active workspace, and the new tab is focused

### Requirement: Destroy workspace when empty
A workspace SHALL be automatically destroyed the moment its last tab is closed.

#### Scenario: Closing the only tab in a workspace
- **WHEN** the user closes the last remaining tab in a workspace
- **THEN** that workspace is destroyed and removed from the workspace list

#### Scenario: Closing one of several tabs in a workspace
- **WHEN** the user closes a tab in a workspace that has other tabs remaining
- **THEN** the workspace is not destroyed and continues to hold its remaining tabs

#### Scenario: Destroying the active workspace focuses a neighbor
- **WHEN** the active workspace is destroyed because its last tab closed, and at least one other workspace remains
- **THEN** the window's active workspace becomes the workspace that was adjacent to the destroyed one (preferring the next workspace, falling back to the previous one if the destroyed workspace was last)

### Requirement: Zero-workspace guarantee
The application SHALL never reach a state with zero workspaces in a window. If destroying a workspace (per the "Destroy workspace when empty" requirement) would leave the window with no workspaces, a fresh workspace containing one new tab SHALL be created automatically and made active.

#### Scenario: Closing the last tab of the last workspace
- **WHEN** the user closes the last tab in the only remaining workspace in a window
- **THEN** that workspace is destroyed, and a new workspace containing one new tab is immediately created and made active
