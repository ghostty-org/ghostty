# Subcommand Actions

This is the CLI-specific code. It contains CLI actions, TUI definitions, and
argument parsing.

This README is developer documentation, not end-user documentation. For
user-facing install and release information, see the root [README](../../README.md)
and GitHub Releases.

## Updating documentation

Each CLI action is defined in its own file. Documentation for each action is
defined in the doc comment associated with the `run` function. For example, the
`run` function in `list_keybinds.zig` contains the help text for
`winghostty +list-keybinds`.
