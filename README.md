<h1 align="center">winghostty</h1>

<p align="center">
  A native Windows terminal emulator with a retained <code>libghostty-vt</code> parser/state library.
  <br />
  Win32 runtime and OpenGL renderer.
</p>

<p align="center">
  <a href="https://github.com/amanthanvi/winghostty/releases">Releases</a>
  ·
  <a href="CONTRIBUTING.md">Contributing</a>
  ·
  <a href="HACKING.md">Developing</a>
  ·
  <a href="SECURITY.md">Security</a>
</p>

## About

`winghostty` is a Windows-first terminal emulator fork focused on a native
Win32 application experience. The project keeps the upstream terminal core
and VT implementation while removing the upstream/private-fork workflow
assumptions that made this repository awkward to use as a public project.

The runtime surface in this repo is Windows-only. `libghostty-vt` remains
available for Zig and C consumers.

## Install

Primary install path: [GitHub Releases](https://github.com/amanthanvi/winghostty/releases)

- Installer: `winghostty-<version>-windows-x64-setup.exe`
- Portable build: `winghostty-<version>-windows-x64-portable.zip`

Unsigned releases are expected to trigger Windows SmartScreen warnings until
code signing is added. That is a packaging limitation, not an indicator that
the release is unofficial.

## Build From Source

`winghostty` uses Zig for the app build.

```powershell
zig build
zig build -Demit-exe=true
```

The installed executable from a local build is `zig-out/bin/winghostty.exe`.

If Zig cannot populate its dependency cache in your environment, seed it first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

The repo also includes `scripts/dev-windows.ps1` and `scripts/dev-windows.cmd`
to bootstrap a Windows-native toolchain shell with the expected Zig cache
environment variables.

See [HACKING.md](HACKING.md) for the narrow validation commands and
Windows-specific runtime notes.

## Updates

The Windows app checks GitHub Releases for newer stable versions when
`auto-update=check` is enabled. The v1 updater is notify-only:

- It checks at most once per 24 hours.
- It does not silently replace binaries.
- It opens the release page or installer flow for the user to complete.
- `auto-update=download` is treated the same as `check` until signed
  background installs are implemented.

## Project Status

The current scope is:

- Native Win32 runtime
- Rich terminal features, tabs, splits, and window management
- Retained `libghostty-vt` library
- Public GitHub releases for Windows users

Not in scope for this fork:

- macOS application packaging
- GTK/Linux desktop runtime work
- upstream community process replication

## Crash Reports

Crash reports are stored locally under `%LOCALAPPDATA%\winghostty\crash`.
Legacy upstream-branded crash directories remain readable for compatibility.

Crash reports are not automatically uploaded anywhere. They are written on the
next successful launch after a crash. Use the CLI action below to inspect what
is available:

```powershell
winghostty +crash-report
```

Crash reports use Sentry envelope format and may contain sensitive memory
content from the crashed process. Review them before sharing.

## Upstream Attribution

This project is derived from [ghostty-org/ghostty](https://github.com/ghostty-org/ghostty).
`winghostty` keeps the upstream terminal core and Windows-focused fork work,
but it ships as its own public Windows project with its own release and
support surface.
