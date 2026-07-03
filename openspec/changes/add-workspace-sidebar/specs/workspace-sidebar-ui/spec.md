## ADDED Requirements

### Requirement: Toggle sidebar visibility
The system SHALL provide a `toggle_workspace_sidebar` action, bound by default to Ctrl+Shift+B, that shows the workspace sidebar if it is hidden and hides it if it is shown. Hiding the sidebar SHALL NOT affect workspace or tab state.

#### Scenario: Hiding the sidebar
- **WHEN** the sidebar is visible and the user invokes `toggle_workspace_sidebar`
- **THEN** the sidebar is hidden and the terminal content area expands to use the freed space

#### Scenario: Showing the sidebar
- **WHEN** the sidebar is hidden and the user invokes `toggle_workspace_sidebar`
- **THEN** the sidebar becomes visible again, listing the same workspaces in the same order as before it was hidden

### Requirement: Sidebar lists workspaces in order
The sidebar SHALL display all open workspaces in a window as a vertical list, ordered by workspace position (the same order used by positional navigation, i.e. `goto_workspace`).

#### Scenario: New workspace appears in the sidebar
- **WHEN** a new workspace is created
- **THEN** it appears in the sidebar at the end of the list

#### Scenario: Destroyed workspace disappears from the sidebar
- **WHEN** a workspace is destroyed because its last tab closed
- **THEN** it is removed from the sidebar list

### Requirement: Sidebar indicates the active workspace
The sidebar SHALL visually distinguish whichever workspace is currently active in the window, and SHALL update this indication immediately whenever the active workspace changes (via navigation shortcuts, sidebar clicks, or workspace creation/destruction).

#### Scenario: Active indicator follows navigation
- **WHEN** the user switches to a different workspace via any navigation action
- **THEN** the sidebar updates to indicate the newly active workspace and no longer indicates the previous one

### Requirement: Sidebar entries are clickable
Clicking a workspace's entry in the sidebar SHALL make that workspace the active workspace, equivalent to navigating to it via `goto_workspace`.

#### Scenario: Clicking a sidebar entry switches workspaces
- **WHEN** the user clicks a workspace entry in the sidebar that is not currently active
- **THEN** that workspace becomes active and its previously-focused tab is focused
