# 20261015-sync-validation

Session for validating `sync/upstream-20261015` branch of `KooshaPari/Khostty` fork at HEAD `81903d0c5`. Scope: confirmed defects, isolation, EGL portability fix, real builds/tests, PR against the fork.

## Status: EGL fix validated at comptime level; awaiting compile_remote / fork CI for byte-code evidence; alt-prefix follow-up deferred to operator

## Repository state

- Repo: `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`
- Main worktree branch: `sync/upstream-20261015` (operator-owned; left alone per "Bird instructed leave sync alone")
- Isolated worktree: `/Users/kooshapari/.jcode/scratch/khostty-sync-20261015-v2`
  - Detached HEAD: `bd2b97e23f6ea49b3185600a15b0482df0baacd2` (forward-merged from `81903d0c5` → `0458af155` accidental-docs → `bd2b97e23` clean revert; EGL fix in working tree, uncommitted)
  - Forward-merge method: real `git merge --ff-only bd2b97e23` from 81903d0c5, then stash pop. Not a force-push, not a reset, not a rebase.
  - Stash refs (cleared, recorded for audit): `85268e0e`, `7a323341`, `bb16644a`
- origin: `git@github.com:KooshaPari/Khostty.git` (FORK PR TARGET)
- upstream: `https://github.com/ghostty-org/ghostty.git` (NEVER write)
- Stale sibling worktree: `/Users/kooshapari/.jcode/scratch/khostty-pr16` (ci16-fix locked; DO NOT TOUCH)
- Bird's doc durability: `origin/docs/session-20261015-validation @ 1d9c34b88` (PUSHED to origin)
- Bird's CI status: #16 272419186 (red 161/162 on alt-prefix), #17 2794f0ed2 (running Linux PR jobs 38833663539)

## Confirmed defects in the merge commit

### Defect A — `pkg/opengl/egl.zig:126` (initial body)

`Display.initPlatform` body used:

```zig
const display = c.eglGetPlatformDisplay(platform, @ptrFromInt(@as(usize, @intCast(id))), attribs) ...
```

`id: c.EGLNativeDisplayType`. Per `vendor/glad/include/EGL/eglplatform.h:53-138`, `EGLNativeDisplayType` is:

- `void *` (Apple/macOS, Wayland-fallback, Khronos default — line 53)
- `HDC` (Windows — line 63) — pointer
- `wl_display *` (Wayland — line 87) — pointer
- `gbm_device *` (GBM — line 93) — pointer
- `Display *` (X11 — line 118) — pointer
- `int` (some legacy / fallback platforms — lines 75, 81, 130) — integer

Hardcoded `@intCast(id)` is a compile error for every pointer-typed platform. On integer-typed targets (rare fallback) it would compile but the runtime semantics are suspect (reinterpreting an int address with zero provenance info).

Generated header at `.zig-cache/.../opengl_c.h.zig:1289` declares `EGLNativeDisplayType = c_int`, but the **function** at `opengl_c.h.zig:1378` declares `eglGetPlatformDisplay(... native_display: ?*anyopaque ...)` — the inconsistency the prior assistant chased; `c.eglGetPlatformDisplay(platform, id, attribs)` literally does not compile because Zig forbids implicit `c_int → ?*anyopaque` conversions.

### Defect B — `pkg/opengl/egl.zig:99-125` (the speculative comment)

27-line block quoting `fe9cf6a26` ("build: fully transition away from cImport/addTranslateC") as the proximate cause and asserting the translator "resolved the wrong branch". The commit reference is suspect: the upstream `b3dc3d794` tree (the merge parent) has the exact same generated header shape. Operator: "remove speculative huge comments and false upstream blame". REMOVED.

### Not a defect — `pkg/opengl/egl.zig:308`

`ImageTarget.toClientBuffer` returning `@ptrFromInt(@as(usize, v))` for the `texture_2d` arm is the standard `GL_TEXTURE_2D → void*` EGL cast. `EGLClientBuffer` is `void *` in eglext.h, so converting a `u32` texture name to a pointer is the documented pattern. Do NOT touch without evidence of breakage.

## The fix (current)

File: `pkg/opengl/egl.zig` lines 99-119 (Display.initPlatform). Replaced the speculative comment + broken body with a short factual comment + comptime dispatch:

```zig
const display = (comptime_blk: {
    const T = @TypeOf(id);
    break :comptime_blk switch (@typeInfo(T)) {
        .pointer => c.eglGetPlatformDisplay(platform, @ptrCast(id), attribs),
        .int, .comptime_int => c.eglGetPlatformDisplay(
            platform,
            @ptrFromInt(@as(usize, @intCast(id))),
            attribs,
        ),
        else => @compileError("unsupported EGLNativeDisplayType for eglGetPlatformDisplay"),
    };
}) orelse return mustError();
return initialize(display);
```

Plus 3 inline `test` blocks appended at end of file (lines 312+):

1. `EGLNativeDisplayType comptime arm dispatch matches type` — reflects on the actual translated type and verifies the expected arm expression is well-formed (sentinel cast checks for both arms, only the matching arm is compiled).
2. `EGL platform-display comptime conversion: integer round-trip` — pure comptime validation that the integer-arm expression shape `@ptrFromInt(@as(usize, @intCast(id)))` produces the documented address.
3. `EGL platform-display comptime conversion: pointer no-op` — pure comptime validation that the pointer-arm expression `@ptrCast(id)` preserves the address.

### Zig 0.16 API correction

Initial draft used `.Pointer`/`.Int`/`.ComptimeInt` (uppercase, Zig 0.13 style). Ghostty's `build.zig.zon` requires `.minimum_zig_version = "0.16.0"`, where the `@typeInfo` enum variants are **lowercase**: `.pointer`, `.int`, `.comptime_int`, `.@"struct"`, `.@"union"`. All project source uses lowercase. **Caught and fixed** via a standalone comptime check (`.jcode-comptime-check.zig`) that compiled clean against the host zig 0.16.0.

## Verification (cheap, captured exit codes)

| Check | Command | EXIT | Notes |
|------|---------|------|-------|
| zig fmt egl.zig | `zig fmt --check pkg/opengl/egl.zig` | 0 | Clean |
| comptime logic (standalone stub) | `zig test .jcode-comptime-check.zig` | 0 | 3/3 tests passed; the dispatch shape is correct on Zig 0.16 |
| API casing (Zig 0.16) | inline test inside `.jcode-comptime-check.zig` | 0 | `.pointer`/`.int`/`.comptime_int` accepted |
| full `zig build test` | `zig build test -Dtest-filter="EGLNativeDisplayType ..." -j2` | 124 (timeout) | Hit 600s wall on 16GB host; only "Metal toolchain not found" warning in log; no compilation output. Per "ONE memory-heavy local build max" binding, NOT retried locally. |

### Why a full local test_exe was not run

The build host is 16GB / 1TB / 1 iGPU. A full `zig build test` on this host hit the 10-minute wall during dep resolution, not during compilation. Per the operator's binding "ONE memory-heavy local build max", I will not re-attempt locally. The standalone comptime check (3/3 passing) confirms the fix's LOGIC is correct; a full byte-code compile + test run is deferred to either:

- a remote box with adequate RAM/CPUs (preferred), or
- the fork's CI on PR opening.

## Operator ping answered: alt-prefix regression (bird's question)

Bird's report: pytest on #16 final SHA 272419186 ran 162 tests, 161 passed, 1 failed: `tests/test_key.py:127 test_alt_prefix_needs_both_settings`. Failure: library emits `b'\x1ba'` (ESC+a) when the test sets only `alt_esc_prefix=True` (no `option_as_alt`), expecting `b'a'`.

### Investigation (no code changes; analysis only)

Test (`khostty-python/tests/test_key.py:123-137`):

```python
def test_alt_prefix_needs_both_settings(library: str) -> None:
    """An Alt prefix requires the DEC 1036 mode and option-as-alt together."""
    assert encode_key(Keys.A, Mods.ALT, utf8="a", library=library) == b"a"                              # PASSES (no flags)
    assert encode_key(Keys.A, Mods.ALT, utf8="a", alt_esc_prefix=True, library=library) == b"a"          # FAILS: emits \x1ba
    assert encode_key(Keys.A, Mods.ALT, utf8="a", alt_esc_prefix=True, option_as_alt=OptionAsAlt.TRUE, ...) == b"\x1ba"
```

Library (`src/input/key_encode.zig:552-572`):

```zig
fn legacyAltPrefix(...) std.Io.Writer.Error!bool {
    if (!binding_mods.alt or !opts.alt_esc_prefix) return false;
    if (comptime builtin.os.tag == .macos) {
        switch (opts.macos_option_as_alt) {
            .false => return false,
            .left => if (mods.sides.alt == .right) return false,
            .right => if (mods.sides.alt == .left) return false,
            .true => {},
        }
    }
    // emits ESC prefix
}
```

The `macos_option_as_alt` gate is only consulted when `comptime builtin.os.tag == .macos`. On non-macOS (the CI target) the gate is bypassed; `alt_esc_prefix` alone emits the ESC prefix.

### Diff vs upstream `b3dc3d794`

```
$ git diff b3dc3d794 81903d0c5 -- src/input/key_encode.zig
(empty)
```

The behavior is upstream-faithful, not a fork-introduced regression. The Options struct's own docstring (`src/input/key_encode.zig:40-42`) explicitly says `macos_option_as_alt` is a macOS-only setting: "Determines whether the 'option' key on macOS is treated as 'alt' or not."

### Conclusion: test / library version mismatch (NOT a fork regression)

Three operator-selectable resolutions, **deferred pending operator signal** (bird's ping: "Don't change the test or the binding without operator signal"):

- (A) Test reflects aspirational API not yet in lib: mark `test_alt_prefix_needs_both_settings` as `.xfail` in fork's pytest, or split the assertions.
- (B) Options struct doc is the contract and test is stale: edit the test to expect `b"\x1ba"` for the `alt_esc_prefix=True`-only case.
- (C) Real bug per test docstring: change `legacyAltPrefix` to apply the `macos_option_as_alt` gate on ALL platforms (drop the `comptime builtin.os.tag == .macos` guard). This is a Zig source change in main Ghostty, NOT a binding change.

## Constraints (binding)

1. NO edits to `.github/**` (CI files — operator restriction).
2. NO upstream writes (`gh pr create --repo ghostty-org/ghostty` etc.).
3. NO force-push, NO `git reset --hard`, NO `git branch -D`, NO `git clean -fd`, NO hook bypass.
4. NO squash merge of the upstream-sync commit; PRESERVE upstream ancestry (true; the bd2b97e23 commit is the clean inverse of 0458af155, no squash).
5. ONE memory-heavy local build on the 16GB host; jobs capped at `-j2`.
6. Capture direct exit codes (`set -o pipefail`), never infer from log absence / nohup.
7. Verify fork features (`.windows/` runtime, Metal fallback, IPC, VT/Python/Go) via test/build — NOT by file existence.

## Plan

1. Subagent reads `docs/sessions/20261015-sync-validation/SESSION.md` (this file). ✓
2. Subagent implements the type-correct portable fix in `pkg/opengl/egl.zig` only, plus inline tests. ✓
3. Subagent runs `zig fmt --check` (pass), `zig test .jcode-comptime-check.zig` (3/3 pass), `zig build test` (timeout, deferred per binding). ✓
4. Subagent commits with ledger trailers, pushes fork branch `fix/egl-typed-platform-display`, opens PR against `KooshaPari/Khostty` (base=master). Pending.
5. Subagent writes findings into this folder and reports. In progress.

## Deliverables

- Updated `pkg/opengl/egl.zig` (type-correct portable + 3 inline tests + clean comment). ✓
- Standalone comptime check `.jcode-comptime-check.zig` (scratch, NOT committed). ✓
- 1 ledger commit on fork branch `fix/egl-typed-platform-display` (NOT rewriting the sync/upstream-20261015 merge). Pending.
- 1 PR opened against `KooshaPari/Khostty` (NOT `ghostty-org/ghostty`). Pending.
- This `SESSION.md` updated with pass/fail per check + exact exit codes + final SHAs. In progress.

## Audit trail

| Step | Time (UTC) | Action | Result |
|------|------------|--------|--------|
| 1 | 2026-10-16T00:59Z | Inspected HEAD, confirmed merge ancestry | 81903d0c5 is true 2-parent merge |
| 2 | 2026-10-16T00:59Z | Read vendor/glad/include/EGL/eglplatform.h | EGLNativeDisplayType typedef enumerated |
| 3 | 2026-10-16T00:59Z | Created isolated worktree at /Users/kooshapari/.jcode/scratch/khostty-sync-20261015-v2 | Detached HEAD 81903d0c5 |
| 4 | 2026-10-16T01:00Z | Replaced speculative comment + broken body with comptime branch | egl.zig 99-126 rewritten |
| 5 | 2026-10-16T01:00Z | Appended 3 inline tests to egl.zig | Lines 310-372 added |
| 6 | 2026-10-16T01:00Z | `zig build test -Dtest-filter=... -j2` | EXIT 124 (timeout) — no compilation output |
| 7 | 2026-10-16T01:14Z | Forward-merge via `git merge --ff-only bd2b97e23` from 81903d0c5 | Stash 0/0/pop clean; HEAD = bd2b97e23 |
| 8 | 2026-10-16T01:15Z | Wrote standalone comptime check `.jcode-comptime-check.zig` | 58 lines, mirrors fix's dispatch |
| 9 | 2026-10-16T01:15Z | First `zig test .jcode-comptime-check.zig` | EXIT 1 — Zig 0.16 API drift (`.Pointer` not a member) |
| 10 | 2026-10-16T01:16Z | Fixed casing in egl.zig + standalone check: `.Pointer`→`.pointer`, `.Int`→`.int`, `.ComptimeInt`→`.comptime_int` | Done |
| 11 | 2026-10-16T01:17Z | Re-ran `zig test .jcode-comptime-check.zig` | EXIT 0 — 3/3 tests passed |
| 12 | 2026-10-16T01:17Z | `zig fmt --check pkg/opengl/egl.zig` | EXIT 0 — clean |
| 13 | 2026-10-16T01:18Z | Investigated alt-prefix regression (bird's question) | Test/library version mismatch; 3 resolution paths documented; deferred |

## Test outcomes

- comptime dispatch (standalone) — **PASS** (3/3, EXIT 0)
- zig fmt egl.zig — **PASS** (EXIT 0)
- full zig build test — **DEFERRED** (timeout; per "ONE memory-heavy local build max" binding)
- alt-prefix pytest case — **INVESTIGATED ONLY** (resolution deferred to operator; no source/test/binding changed)

## Untested

- Full Ghostty test_exe byte-code compile (deferred to remote / CI)
- Cross-platform comptime arm selection on pointer-typed `EGLNativeDisplayType` targets (the `.pointer` arm is well-formed per the project source pattern but is not exercised on this macOS dev host where `EGLNativeDisplayType = c_int`; the standalone test only validates the `.int` arm shape on this host)
- Fork features: `.windows/` runtime, Metal fallback, IPC, VT/Python/Go bindings — all preserved by tree identity, NOT verified by test/build outcome (per binding 7)

## Final state (awaiting push)

- HEAD: `bd2b97e23` (detached)
- Working tree: `pkg/opengl/egl.zig` modified (comptime fix + 3 tests); `.jcode-comptime-check.zig` and `docs/sessions/20261015-sync-validation/` untracked
- Branch to be created on commit: `fix/egl-typed-platform-display`
- PR target: `KooshaPari/Khostty`, base=master, head=fix/egl-typed-platform-display
