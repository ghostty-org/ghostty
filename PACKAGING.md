# Packaging winghostty for Distribution

This repository publishes Windows user artifacts directly from GitHub Releases.
The public packaging targets are:

- `winghostty-<version>-windows-x64-setup.exe`
- `winghostty-<version>-windows-x64-portable.zip`
- `SHA256SUMS.txt`

Primary distribution URL:

```text
https://github.com/amanthanvi/winghostty/releases
```

## Release Inputs

Tagged releases are expected to use semver tags such as `v1.3.2`.

The release workflow builds the Windows executable, stages runtime files, then
produces:

1. An Inno Setup installer
2. A portable ZIP
3. SHA256 checksums for published assets

Unsigned releases are allowed. SmartScreen friction is expected until code
signing is added.

## Local Packaging

Build the app first:

```powershell
zig build -Demit-exe=true
```

If Zig cannot hydrate its dependency cache automatically in your environment,
seed it first:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/fetch-zig-deps.ps1
zig build -Demit-exe=true
```

Then stage release assets:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/package-windows.ps1 -Version 0.0.0-test
```

If Inno Setup is available on the machine, the packaging script can also build
the installer. If it is not installed, the portable artifact and checksums are
still produced so packaging can be validated locally.

## Zig Version

This repo is pinned to Zig `0.15.2` in CI. Packaging should use the same Zig
version unless the repo is intentionally updated to a newer one.

## Library Consumers

`libghostty-vt` remains intentionally retained and keeps its existing public
name. The app binary and Windows packaging are rebranded to `winghostty`, but
the library surface is not being renamed as part of this packaging cleanup.
