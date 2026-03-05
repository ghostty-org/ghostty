# VisionOS Fork Stack

This repository is configured to build visionOS with forked upstream dependencies.

## Forked dependencies

- `libxev`
  - Fork: `https://github.com/douglance/libxev`
  - Commit: `3726043b4942d5ad88f33f6b1ed0e9a60548f5a0`
  - Purpose: add `.visionos` mapping to the kqueue backend selection.

- `zig` stdlib for visionOS builds
  - Fork: `https://github.com/douglance/zig`
  - Branch: `fix/visionos-std-coverage-0.15x`
  - Commit: `34470b281dec31c254a11571f8d3c81ea0755dcc`
  - Purpose: backport `std.fs` and Darwin AArch64 debug context visionOS coverage to `0.15.x`.

## Build commands

Use the wrapper for visionOS builds so Zig uses the forked stdlib:

```bash
./scripts/zig-visionos.sh prepare
./scripts/zig-visionos.sh build lib-vt -Dtarget=aarch64-visionos -Doptimize=ReleaseFast
./scripts/build-visionos-xcframework.sh
```

`build-visionos-xcframework.sh` produces `macos/GhosttyKit.xcframework` with `xros` slices.

The wrapper downloads the Zig fork tarball once into `.toolchains/zig-visionos` and then runs:

```bash
zig --zig-lib-dir <forked-zig-lib> ...
```
