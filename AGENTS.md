# Agent Development Guide

A file for [guiding coding agents](https://agents.md/).

## Commands

- **Build:** `zig build`
- **Test (Zig):** `zig build test`
- **Test filter (Zig)**: `zig build test -Dtest-filter=<test name>`
- **Formatting (Zig)**: `zig fmt .`
- **Formatting (Swift)**: `swiftlint lint --fix macos`
- **Formatting (other)**: `prettier -w .`

## Directory Structure

- Shared Zig core: `src/`
- C API: `include`
- macOS app: `macos/`
- GTK (Linux and FreeBSD) app: `src/apprt/gtk`

## macOS App

- Do not use `xcodebuild`
- Use `zig build` to build the macOS app and any shared Zig code
- Use `zig build run` to build and run the macOS app
- Run Xcode tests using `zig build test`

## Git workflow

- Don’t rebase a branch after it’s merged.
- Sync upstream into `upstream-main` via `--ff-only`, then merge `upstream-main` into `main`.
- Avoid force-pushing `main`; if needed, push a `legacy/...` backup ref first.

## Ghostree Project Context

- Remotes:
  `origin` = `sidequery/ghostree` (`git@github.com:sidequery/ghostree.git`)
  `upstream` = `ghostty-org/ghostty` (`https://github.com/ghostty-org/ghostty.git`)
- Branch intent:
  `main` = Ghostree customizations.
  `upstream-main` = mirror of `upstream/main` (fast-forward only).
- Never merge `upstream/main` directly into `main`; update `upstream-main` first, then merge `upstream-main` into `main`.
- Versioning:
  Ghostree release version comes from `build.zig.zon` (`.version`).
  Keep app target marketing versions aligned in `macos/Ghostty.xcodeproj/project.pbxproj`.
- Release naming:
  use `Ghostree v0.X.Y`.
- Bundle identifier must stay `dev.sidequery.Ghostree` (not `com.mitchellh.ghostty`).

## Issue and PR Guidelines

- Never create an issue.
- NEVER EVER EVER EVER EVER EVER open a PR against `ghostty-org/ghostty` (upstream), under any circumstances.
- If a PR is explicitly requested, it must target `sidequery/ghostree` only, never upstream.
