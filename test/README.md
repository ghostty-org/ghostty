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

`windows-unfocused-redraw.ps1` validates that Ghostty continues to repaint
while unfocused. It captures hashes of the window image over time; a static
hash sequence while output is still flowing is treated as a failure.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows-unfocused-redraw.ps1
```

`windows-terminal-bench.ps1` runs repeatable text/ASCII throughput workloads
and prints timing + renderer health summaries, with logs saved under `.tmp`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows-terminal-bench.ps1
```
