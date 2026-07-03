## ADDED Requirements

### Requirement: Cycle to the previous or next workspace
The system SHALL provide `previous_workspace` and `next_workspace` actions, bound by default to Ctrl+Shift+PgUp and Ctrl+Shift+PgDown respectively, that move the active workspace one position backward or forward in the window's workspace list. Cycling SHALL wrap around: `next_workspace` from the last workspace goes to the first, and `previous_workspace` from the first workspace goes to the last. This mirrors Ghostty's existing `previous_tab`/`next_tab` wraparound behavior.

#### Scenario: Next workspace wraps from the last to the first
- **WHEN** the active workspace is the last one in the list and the user invokes `next_workspace`
- **THEN** the first workspace in the list becomes active

#### Scenario: Previous workspace wraps from the first to the last
- **WHEN** the active workspace is the first one in the list and the user invokes `previous_workspace`
- **THEN** the last workspace in the list becomes active

#### Scenario: Cycling with only one workspace
- **WHEN** there is only one workspace and the user invokes `previous_workspace` or `next_workspace`
- **THEN** the same workspace remains active

### Requirement: Jump directly to a workspace by position
The system SHALL provide a `goto_workspace` action taking a 1-indexed position, bound by default to Ctrl+Shift+1 through Ctrl+Shift+9 for positions 1-9, that switches the active workspace to the workspace at that position. If the requested position exceeds the number of open workspaces, the last workspace SHALL become active instead, mirroring Ghostty's existing `goto_tab` clamping behavior.

#### Scenario: Jump to an existing position
- **WHEN** the user invokes `goto_workspace` with a position that has a corresponding workspace
- **THEN** the workspace at that position becomes active

#### Scenario: Jump to a position beyond the number of workspaces
- **WHEN** the user invokes `goto_workspace` with a position greater than the number of open workspaces
- **THEN** the last workspace becomes active

### Requirement: Jump directly to the last workspace
The system SHALL provide a `last_workspace` action, bound by default to Ctrl+Shift+0, that switches the active workspace to the last (highest-index) workspace in the window's workspace list.

#### Scenario: Jump to the last workspace
- **WHEN** the user invokes `last_workspace` (Ctrl+Shift+0)
- **THEN** the last workspace in the list becomes active

### Requirement: Navigation focuses the target workspace's active tab
Switching the active workspace via any navigation action SHALL focus whichever tab was last active within the newly-selected workspace.

#### Scenario: Switching workspaces restores prior tab focus
- **WHEN** the user navigates to a workspace that was previously active with a specific tab focused
- **THEN** that same tab is focused after the switch
