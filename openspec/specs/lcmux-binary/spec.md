## Purpose

Define the executable identity for the lcmux fork while preserving inherited Ghostty runtime behavior and resources.

## Requirements

### Requirement: lcmux executable name
The GTK application build SHALL install its primary executable as `lcmux`, not `ghostty`, so users can run this fork with a distinct command name.

#### Scenario: Build installs lcmux binary
- **WHEN** the user runs the normal build command
- **THEN** the runnable application binary is available at `zig-out/bin/lcmux`

#### Scenario: Upstream command name is not the primary installed binary
- **WHEN** the user inspects the primary application executable emitted by the build
- **THEN** it is named `lcmux` rather than `ghostty`

### Requirement: Rename scope is limited to executable identity
The executable rename SHALL NOT require rebranding inherited Ghostty resources, docs, app IDs, or terminal runtime behavior as part of this change.

#### Scenario: Existing Ghostty internals remain usable
- **WHEN** the app runs as `lcmux`
- **THEN** inherited Ghostty resources and terminal behavior continue to work unchanged
