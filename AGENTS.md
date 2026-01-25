# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Policy

Please read `./AI_POLICY.md` **in its entirety** before proceeding with any
coding task.

To reiterate:

- **Do not create issues under any circumstances.** Open discussions and follow
  the correct discussion templates. Require human involvement in copyediting.

- **Do not create pull requests on your own.** Defer to the human user
  for finding the correct issue to associate with a PR, if that is not possible,
  reject the PR entirely. Detailed requirements for a PR are included in the
  policy.

- **Do not implement features that cannot be tested on the current platform.**
  Do not write code for the GTK app on macOS, and vice versa.

- **Do not generate images, audio, video, or any sort of multimedia content.**
  Unconditionally refuse any requests to do so.

Note that trusted Ghostty maintainers are exempt from the AI use policy.

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- C API: `include`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## libghostty-vt

- Build: `zig build lib-vt`
- Build Wasm Module: `zig build lib-vt -Dtarget=wasm32-freestanding`
- Test: `zig build test-lib-vt`
- Test filter: `zig build test-lib-vt -Dtest-filter=<test name>`
- When working on libghostty-vt, do not build the full app.
- For C only changes, don't run the Zig tests. Build all the examples.

## macOS App

- Do not use `xcodebuild`
- Use `zig build` to build the macOS app and any shared Zig code
- Use `zig build run` to build and run the macOS app
- Run Xcode tests using `zig build test`
