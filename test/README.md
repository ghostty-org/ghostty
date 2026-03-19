# Test Utilities

This directory contains anything related to testing Ghostty that doesn't
fit within the standard Zig testing framework alongside the source.

## Windows smoke test

`windows-hello-world.ps1` runs a minimal end-to-end smoke test against a
built `ghostty.exe`. It launches Ghostty with `-e` and verifies the child
command writes `hello world` to a temp file before Ghostty exits cleanly.

Run it from the repository root after building and bundling runtime DLLs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows-hello-world.ps1
```

`windows-interactive-input.ps1` validates interactive behavior. It launches
Ghostty with `cmd.exe /k`, verifies the GUI window appears, and checks startup
stability (no immediate crash). It also supports a manual input flow that
prompts you to type commands in the Ghostty window and validates output.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows-interactive-input.ps1
```

For pure startup-crash triage (no manual typing), run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows-interactive-input.ps1 -SkipInputCheck
```
