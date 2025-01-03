# Subcommand Actions

This is the cli specific code. It contains cli actions and tui definitions and
argument parsing.

This README is meant as developer documentation and not as user documentation.
For user documentation, see the main README or [ghostty.org](https://ghostty.org/docs).

## Updating documentation

Each cli action is defined in it's own file. Documentation for each action is defined
in the doc comment associated with the `run` function. For example the `run` function
in `list_keybinds.zig` contains the help text for `ghostty +list-keybinds`.
