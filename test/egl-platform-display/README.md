# EGL platform-display synthetic harness (SYNTHETIC)

This directory is the persistent home of the SYNTHETIC test harness that
exercises `pkg/opengl/egl.zig::pickEglIdCast` on a host that lacks
`libEGL.dylib` (the macOS dev box does not ship it in the Zig 0.16
darwin-sdk). It is **SYNTHETIC**, NOT a full linked runtime: the
`opengl_c_stub.zig` here is a lazy analysis stub that supplies only the
`opengl_c` symbols referenced by `pkg/opengl/egl.zig`. No FFI fires at
test time; `StubGetPlatformDisplay` in `egl.zig` intercepts.

## Why SYNTHETIC, not full runtime

- `zig build` on this host fails at the link step on `libEGL.dylib` (env gap).
- The fork's CI/test workflow is a stub echo on `KooshaPari/Khostty`;
  `test.yml`'s real test job is gated to `ghostty-org/ghostty`.
- This harness is the next-best real gate available locally and is
  marked SYNTHETIC so reviewers know it is not a substitute for upstream CI.

## Reproducible command

From the worktree root:

```sh
zig test --dep opengl_c -Mroot=pkg/opengl/egl.zig \
    -Mopengl_c=test/egl-platform-display/opengl_c_stub.zig
```

## Expected result

Exit code 0. 13/13 inline tests pass; see `PROOF-LOG.txt` for the most
recent capture.

## Provenance

- `pkg/opengl/egl.zig` helpers + inline tests: commits `431bc6fba`
  (`fix(opengl): comptime-branch eglGetPlatformDisplay id for typed
EGLNativeDisplayType`) and `5055d2c17` (`test(egl): expand
pickEglIdCast coverage to BOTH arms with synthetic types`).
- This harness persistence: tracked here so the next reviewer can
  re-run the same gate without rebuilding the probe state.
- Original (now-deprecated) location was `.jcode-egl-synth/`; the
  proof log captures the prior run that validated the move.

## Scope of stub

Lazy — only the 44 `opengl_c` symbols referenced by `pkg/opengl/egl.zig`
are declared in `opengl_c_stub.zig`. If production code adds new
`c.*` references, the stub will fail to compile, signaling the gap.

## Files

- `opengl_c_stub.zig` — the lazy-analysis stub (88 lines).
- `PROOF-LOG.txt` — the most recent successful run's transcript.
- `README.md` — this file.
