# Contributing to winghostty

Thanks for working on `winghostty`.

This repository is a public Windows-first project. Issues and pull requests are
welcome, but contributions still need to be tight, technically defensible, and
validated against the Windows runtime shipped here.

For usage questions, design discussion, or anything that is not a
reproducible bug, please use
[Discussions](https://github.com/amanthanvi/winghostty/discussions). GitHub
Issues on this repo are reserved for reproducible bugs so triage stays
signal-heavy.

## Contribution Rules

1. Understand the change end to end before calling it done.
2. Prefer Windows-native behavior when it conflicts with upstream
   cross-platform behavior.
3. Keep the scope tight and validate with the lightest reliable Zig command
   before running broader checks.
4. Preserve `libghostty-vt`; it remains a supported deliverable in this repo.
5. Keep docs, packaging, and user-visible strings aligned with the shipped
   `winghostty` product identity.

## Before You Open A PR

- Read [HACKING.md](HACKING.md) for build, test, and runtime commands.
- Read any applicable `AGENTS.md` files before editing.
- If you use AI assistance, you are responsible for understanding and
  reviewing the final change. See [AI_POLICY.md](AI_POLICY.md).

## Validation

Prefer the narrowest command that covers your change:

- `zig build test -Dtest-filter=win32`
- `zig build test -Dtest-filter=scroll`
- `zig build test -Dtest-filter=keybind`
- `zig build`
- `zig build -Demit-exe=true`

If the change touches input, rendering, window chrome, process startup,
packaging, or update behavior, do a manual Windows check as well:

1. Launch `zig-out/bin/winghostty.exe`.
2. Verify the affected behavior on Windows.
3. Re-check scrolling, flicker, keybindings, IPC, or updater behavior that was touched.

## Scope Guard

This fork does not preserve upstream macOS or GTK app surfaces. Do not
reintroduce:

- macOS application packaging or Xcode workflows
- GTK, Wayland, or X11 app-runtime logic
- Linux desktop packaging such as Flatpak or Snap

## PR Notes

- Keep changes minimal and focused.
- Include validation results in the PR description.
- Call out risks or follow-up work if a change is intentionally partial.
