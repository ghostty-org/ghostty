# Ghostty visionOS Support Plan

## Goal

Add first-class `visionOS` (`xros`) support for the embedded `libghostty` path so a Swift host app can consume Ghostty as an XCFramework on Apple Vision Pro.

This plan is intentionally scoped to the library/embedded runtime. It does not attempt to port the standalone Ghostty macOS app to visionOS.

## Current Findings

- The repo has no `visionOS` or `xros` references.
- The public embedding API only exposes `macOS` and `iOS` platform tags.
- XCFramework generation only emits macOS and iOS slices.
- Metal build helpers only know how to target `macOS` and `iOS`.
- Several OS abstraction switches assume a closed set of platforms and will fail to compile when a new Darwin target is introduced.
- The existing iOS path already avoids PTY-backed local process behavior, which is a good fit for a remote-terminal consumer such as VibeSSH.

## Design Assumption

Treat `visionOS` as a sibling of the current iOS embedded path:

- `UIView`-backed host surface
- Metal renderer
- no local PTY requirement
- host app provides networking/session integration

If that assumption proves false for one of the rendering APIs, the plan still stands, but the renderer workstream becomes larger.

## Workstreams

### 1. Public API and Embedded Runtime

Add `visionOS` as a first-class embedded platform in the C ABI and Zig runtime.

Primary files:

- `include/ghostty.h`
- `src/apprt/embedded.zig`

Tasks:

- Add `GHOSTTY_PLATFORM_VISIONOS` to the public C enum.
- Add a `visionos` case to `PlatformTag`.
- Extend `Platform` and `Platform.C` with a `UIView`-based visionOS payload unless a different host object is required.
- Update platform initialization and validation errors.

Exit criteria:

- The embedding API can describe a visionOS surface without overloading the iOS enum.

### 2. Build Targets and XCFramework Packaging

Teach the Zig build to emit `xros` and `xrsimulator` library slices.

Primary files:

- `src/build/Config.zig`
- `src/build/GhosttyXCFramework.zig`
- `src/build/MetallibStep.zig`
- `build.zig`

Tasks:

- Add `osVersionMin(.xros)` in `Config.zig`.
- Add device and simulator target queries for `xros`.
- Extend XCFramework generation to include:
  - `arm64-apple-xros`
  - `arm64-apple-xros-simulator`
- Update Metal SDK selection and minimum-version flags for `visionOS`.
- Confirm `XCFrameworkStep.zig` needs no changes beyond receiving additional libraries.

Exit criteria:

- `zig build` can produce a `GhosttyKit.xcframework` with visionOS slices.

### 3. Renderer Enablement

Make the Metal renderer compile and initialize on `visionOS`.

Primary files:

- `src/renderer/Metal.zig`
- `src/renderer/metal/IOSurfaceLayer.zig`
- `src/renderer/metal/Target.zig`

Tasks:

- Extend compile-time OS gates from `macos`/`ios` to include `xros`.
- Decide whether `visionOS` should follow iOS behavior for:
  - storage mode selection
  - `UIView` access
  - `CALayer` attachment via `addSublayer`
  - default Metal device selection
- Validate that `IOSurface`-backed texture creation is supported on `visionOS`.
- Validate that the required Objective-C properties and selectors exist on visionOS runtime classes.

Exit criteria:

- A minimal embedded surface can render frames on `visionOS` and `visionOS Simulator`.

### 4. OS Abstraction Cleanup

Update Darwin/mobile assumptions so `xros` compiles cleanly.

Primary first-pass touch list:

- `src/Command.zig`
- `src/input/keycodes.zig`
- `src/cli/tui.zig`
- `src/config/theme.zig`
- `src/os/desktop.zig`
- `src/os/open.zig`
- `src/os/homedir.zig`
- `src/pty.zig`
- `src/build/Config.zig`

Tasks:

- Add `xros` branches where the code currently handles only `ios` and `macos`.
- Use iOS-equivalent behavior for visionOS where appropriate:
  - no PTY-backed local process path
  - desktop environment always true/other as needed
  - `open` remains unimplemented until a proper host-side URL open hook exists
  - home-directory expansion behaves like iOS
  - keycode mapping follows Apple mobile path unless visionOS keyboard APIs differ

Exit criteria:

- The library compiles for `xros` without falling into `@compileError("unsupported platform")` branches.

### 5. Test and Validation Pass

Add a focused validation matrix before attempting broader rollout.

Tasks:

- Compile-only validation:
  - `arm64-apple-xros`
  - `arm64-apple-xros-simulator`
- XCFramework validation with `xcodebuild -create-xcframework`
- Consumer validation in a Swift host app:
  - surface creation
  - frame rendering
  - resize
  - keyboard input
  - clipboard hooks
  - URL open callback behavior

Exit criteria:

- The produced XCFramework links into a visionOS app and can render a live terminal surface.

## Recommended Execution Order

1. Add the platform enum/tag plumbing.
2. Add build-target support for `xros` and `xrsimulator`.
3. Do a compile-only pass and fix all unsupported OS branches.
4. Enable the Metal renderer for `visionOS`.
5. Validate in a minimal Swift host app.
6. Only after that, wire it into VibeSSH behind a feature flag.

## Risks

- `libghostty` embedding API is explicitly not yet a stable general-purpose API.
- Zig target support for `xros` must exist in the toolchain version used by Ghostty's build.
- Some Metal or CoreAnimation behavior may differ enough on `visionOS` that simple iOS aliasing is insufficient.
- The repo currently has no visionOS-specific CI or sample host app, so regressions would be easy to reintroduce.

## Definition of Done

- `visionOS` is a first-class platform in `libghostty` public and Zig APIs.
- XCFramework output includes device and simulator visionOS slices.
- Embedded Metal rendering works in a Swift visionOS host app.
- The port does not regress existing macOS or iOS embedded consumers.
