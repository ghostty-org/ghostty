# Contributing to Ghostty

This repository is maintained as a Windows-only Ghostty fork. The workflow here
is local and branch-based, not upstream issue/PR driven.

If you are changing code in this repo:

1. Understand the change end to end before you call it done.
2. Prefer Windows-native behavior when it conflicts with upstream
   cross-platform behavior.
3. Keep the scope tight and validate with the lightest reliable Zig command
   before running broader checks.
4. Preserve `libghostty-vt`; the retained VT library is still part of this fork.

## Workflow

- Do not open issues from this fork.
- Do not open pull requests from this fork.
- Make changes locally, validate them, and share the resulting diff or branch.

## Before You Change Code

- Read [HACKING.md](HACKING.md) for the current build and runtime commands.
- Read any applicable `AGENTS.md` files before editing.
- If you use AI assistance, you are still responsible for understanding the
  final change.

## Required Validation

Prefer the narrowest command that covers your change:

- `zig build test -Dtest-filter=win32`
- `zig build test -Dtest-filter=scroll`
- `zig build test -Dtest-filter=keybind`
- `zig build`
- `zig build -Demit-exe=true`

If the change touches input, rendering, chrome, or process startup, do a manual
Windows check as well:

1. Launch `zig-out/bin/ghostty.exe`.
2. Verify the affected behavior on Windows.
3. Re-check scrolling, flicker, and any keybinding or IPC changes that were touched.

## Scope Guard

This fork is not preserving the upstream macOS or GTK application surfaces.
Do not reintroduce:

- macOS application packaging or Xcode workflows
- GTK, Wayland, or X11 app-runtime logic
- Linux desktop packaging such as Flatpak or Snap

Keep the code and docs aligned with the Windows-only runtime.
