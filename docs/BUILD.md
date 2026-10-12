# Building from Source

**Observed:** 2026-09-17 · Commands below were checked against `build.zig`,
`src/build/Config.zig`, `wasm/build.sh`, and `conformance/build.sh`. Build
outcomes are reported with the date and the exact revision, because this
repository has multiple agents editing it concurrently.

---

## 1. Prerequisites

| Requirement | Version | Needed for |
|---|---|---|
| **Zig** | **0.16.0** (exact) | Everything. `build.zig.zon` sets `minimum_zig_version = "0.16.0"`. |
| `git` | any recent | Checkout, submodule-free dependency fetch |
| **Xcode** | current, with the **Metal toolchain** component | macOS app build, dylib SDK headers |
| GTK4 + `libadwaita` dev packages | 4.x | Linux app runtime (`gtk`) |
| Wayland and/or X11 dev headers | — | Linux windowing (`-Dgtk-wayland`, `-Dgtk-x11`) |
| `fontconfig` + `freetype` | — | Linux/BSD font discovery |
| Rust | ≥ 1.75 | `khostty-vt` crate (G5) |
| Node.js | ≥ 20 | `wasm/` package (G7) |
| `cc` / clang | — | `conformance/harness.c` |

Check Zig first, because a version mismatch fails early and confusingly:

```bash
zig version    # must print 0.16.0
```

Optional: `nix` users can use the provided dev shell.

```bash
direnv allow     # .envrc → `use flake` when nix is present
# or
nix develop
```

`.envrc` sources `.envrc.local` if present, which is the intended place for
machine-local overrides.

---

## 2. Quickstart: the VT library

This is the artifact almost everyone wants. It needs no GUI dependencies.

```bash
cd khostty
zig build -Demit-lib-vt -Doptimize=ReleaseSafe
```

Outputs land in `zig-out/`:

| Artifact | Path |
|---|---|
| Static library | `zig-out/lib/libghostty-vt.a` |
| Shared library | `zig-out/lib/libghostty-vt.0.1.0.dylib` (or `.so`) |
| Convenience symlinks | `libghostty-vt.0.dylib` → `libghostty-vt.0.1.0.dylib` → `libghostty-vt.dylib` |

For the Apple multi-platform bundle:

```bash
zig build -Demit-lib-vt -Demit-xcframework -Doptimize=ReleaseSafe
# zig-out/lib/ghostty-vt.xcframework/{macos-arm64_x86_64,ios-arm64,ios-arm64-simulator}
```

For other architectures:

```bash
zig build -Demit-lib-vt -Dtarget=aarch64-linux -Doptimize=ReleaseSafe
zig build -Demit-lib-vt -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

---

## 3. Quickstart: the application

The app runtime is chosen per platform — `gtk` on Linux/FreeBSD, and on macOS the
`.app` is produced by the Xcode project rather than `zig build`.

```bash
# Linux / FreeBSD (GTK4)
zig build -Doptimize=ReleaseSafe
zig build run                # build and launch

# macOS: library + Xcode-driven app
zig build -Demit-macos-app=true -Doptimize=ReleaseSafe
```

`-Demit-macos-app=false` skips the app bundle, which is what CI does:

```bash
zig build -Doptimize=ReleaseSafe -Demit-macos-app=false
```

---

## 4. Build flags

Flags are declared in `src/build/Config.zig`. This is the complete target/feature
set that matters for a fork build.

### Target and optimize

| Flag | Values | Notes |
|---|---|---|
| `-Doptimize` | `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall` | |
| `-Dtarget` | any Zig target triple | Defaults to the host |
| `-Dversion-string` | string | Overrides the app version |
| `-Dlib-version-string` | string | Overrides the library version |

### What to emit

| Flag | Default | Effect |
|---|---|---|
| `-Demit-lib-vt` | off | Build `libghostty-vt` static/shared |
| `-Demit-exe` | on | Build the executable |
| `-Demit-macos-app` | off | Build the macOS `.app` (Xcode path) |
| `-Demit-xcframework` | off | Build the Apple xcframework |
| `-Demit-docs` | on | Install man pages and docs |
| `-Demit-terminfo` | on | Install terminfo |
| `-Demit-termcap` | off | Install termcap |
| `-Demit-themes` | on | Install themes |
| `-Demit-webdata` | on | Install web assets |
| `-Demit-bench` | off | Build bench tooling (upstream) |
| `-Demit-test-exe` | on | Build the test executable |
| `-Demit-unicode-table-gen` | off | Build the unicode table generator |
| `-Demit-helpgen` | off | Build the help generator |

### Backends and platform features

| Flag | Default | Values |
|---|---|---|
| `-Dapp-runtime` | per-platform | `none`, `gtk`, (`windows` once G3 lands) |
| `-Drenderer` | per-platform | `opengl`, `metal`, `webgl` |
| `-Dfont-backend` | per-platform | `freetype`, `coretext`, `fontconfig_freetype`, `freetype_windows`, `web_canvas`, … |
| `-Dxcframework-target` | `universal` | Apple slice selection |
| `-Dsimd` | on | SIMD acceleration |
| `-Di18n` | on | Translations |
| `-Dsentry` | on | Crash reporting |
| `-Dgtk-wayland` / `-Dgtk-x11` | auto | Linux display backends |
| `-Dflatpak` / `-Dsnap` | off | Packaging integration |
| `-Dpie`, `-Dstrip` | off | Binary properties |
| `-Dvt-features` | full | Comma-separated libghostty-vt feature gates |
| `-Dtest-filter` | — | Filter Zig tests by name |

`--help` on the build prints the live list:
`zig build --help`.

---

## 5. Build steps

Named steps declared in `build.zig`:

| Step | Purpose |
|---|---|
| `zig build` | Default: build everything the config allows |
| `zig build run` | Build and run the app |
| `zig build run-valgrind` | Run under Valgrind |
| `zig build test` | Run the Zig test suite |
| `zig build test-lib-vt` | Run libghostty-vt tests |
| `zig build test-lib-vt-build` | Compile libghostty-vt tests without running them |
| `zig build test-lib-vt-schema` | Validate the libghostty-vt ABI type manifest |
| `zig build test-valgrind` | Run tests under Valgrind |
| `zig build dist` | Build the dist tarball |
| `zig build distcheck` | Install and validate the dist tarball |
| `zig build update-translations` | Refresh translation catalogs |

---

## 6. Per-platform notes

### macOS

- Xcode must be selected: `sudo xcode-select -s /Applications/Xcode.app`.
- The **Metal toolchain component** is required for the default `metal` renderer.
  If it is missing (a known Xcode 26 beta issue), either install the component or
  build with `-Drenderer=opengl`, or build the library only with `-Demit-lib-vt`.
- The `.app` is built through the Xcode project in `macos/`, not by `zig build`.
- **Go cgo test runs** (the `khostty-go` FFI suite) require a pinned SDK when
  CommandLineTools and Xcode disagree on the active macOS SDK. Default
  `xcrun --show-sdk-path` on a host with both installed may resolve to
  `MacOSX27.0.sdk` (CommandLineTools), whose TBD files use `arm64e`
  architecture tags the local Go 1.23.4 cgo linker cannot parse
  (`tapi error: malformed file`). Pin to Xcode 26's `MacOSX26.0.sdk`:
  ```bash
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk \
    go test -v ./...
  ```
  The build emits non-fatal `ld: warning: object file (...) was built for
  newer 'macOS' version (27.0) than being linked (26.0)` lines; the link
  succeeds and all 45 tests pass in ~0.8s. CI on GitHub is unaffected
  (Linux runners, no SDK). Confirmed on this host 2026-10-12; see
  `docs/sessions/khostty-0.1.0-release/evidence/5-suite-rerun-20261012.txt`.

### Linux / FreeBSD

- Install GTK4 development headers; `-Dapp-runtime=gtk` is the default.
- Choose display backends explicitly if autodetection misbehaves:
  `-Dgtk-wayland=true -Dgtk-x11=true`.
- Flatpak and Snap packaging definitions live in `flatpak/` and `snap/`.

### Windows

There is **no working Windows application build** (gate G3). Upstream sets the
Windows default runtime to `none`, so no executable is produced.

The intended cross-compile, once G3 lands:

```bash
zig build -Demit-lib-vt -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

`src/apprt/windows/` also has an unresolved import casing defect described in
[PLATFORMS.md](PLATFORMS.md#known-defect-observed-2026-09-17).

### WASM

Use the wrapper script, which pins the target, isolates the cache, and validates
the output rather than trusting an exit code:

```bash
cd wasm
./build.sh                          # ReleaseSmall (default)
./build.sh --debug                  # larger, with debug info
./build.sh --optimize ReleaseFast
```

It runs:

```bash
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize="$opt" \
  --cache-dir "$cache" --prefix "$prefix"
```

then asserts the WebAssembly magic (`0061736d`) and version 1 (`01000000`)
preamble, copies to `wasm/khostty-vt.wasm`, and prints size + sha256.

| Variable | Effect |
|---|---|
| `KHOSTTY_WASM_CACHE` | Relocate the isolated wasm cache |

The isolated cache exists to avoid a stale-build-runner failure that is unrelated
to the wasm build itself (see Troubleshooting).

---

## 7. Building the Rust crate

```bash
cd khostty-vt
cargo build            # links zig-out/lib by default
cargo test             # requires the built shared library
cargo clippy
cargo fmt --check
```

The crate finds the library in this order:

1. `GHOSTTY_VT_LIB` — explicit file path
2. `GHOSTTY_VT_LIB_DIR` — explicit directory
3. `../zig-out/lib`, `../build/lib`, `../dist/lib`

Related variables:

| Variable | Purpose |
|---|---|
| `GHOSTTY_VT_INCLUDE_DIR` | Directory containing `ghostty/vt.h` |
| `GHOSTTY_VT_LINK_KIND` | Force `dylib` or `static` |

Typecheck without a native library:

```bash
cargo check --no-default-features     # disables the `link` feature
```

The `bindgen` feature regenerates bindings and compares them against the
checked-in `src/ffi.rs`; it requires libclang:

```bash
cargo test --features bindgen
```

---

## 8. Building the conformance harness

The harness links the **already-built** shared library, so build the library
first.

```bash
zig build -Demit-lib-vt -Doptimize=ReleaseSafe
conformance/build.sh          # build + run
conformance/build.sh build    # build only
conformance/build.sh run      # run only
```

Requirements and behaviour:

- Requires `zig-out/lib/libghostty-vt.dylib`. The script exits with a clear error
  if it is missing.
- Uses the macOS SDK from Xcode. Override with `SDK=/path/to/MacOSX.sdk`.
- Compiles `conformance/harness.c` with `cc -Iinclude -O2` and runs with
  `DYLD_LIBRARY_PATH` pointed at `zig-out/lib`.
- Emits `zig-out/bin/conformance_test`.

The harness is deliberately C rather than Zig: the Zig path needs the dependency
fetcher to populate `zig-pkg/` from `deps.files.ghostty.org`, and that fetch can
fail for packages the C harness does not need.

See [TESTING.md](TESTING.md).

---

## 9. Troubleshooting

### `unable to open '.../zig-pkg/<pkg>': FileNotFound`

Symptom, observed 2026-09-17 running `zig build -Demit-lib-vt` from the
repository's own `.zig-cache`:

```
unable to open '.../zig-pkg/uucode-0.2.0-ZZjBPlK5VADj7fdoq7G8LIHzD5o6FSkcBXXrRWr4jnrA': FileNotFound
```

The directory existed. The cached **build runner** was stale: it had been
generated against a different `zig-pkg` layout and fails at startup before it
re-resolves dependencies.

Fix: use a fresh cache directory.

```bash
zig build -Demit-lib-vt -Doptimize=ReleaseSafe \
  --cache-dir .cache-fresh --prefix zig-out-fresh
```

Confirming this worked is what let the build proceed to actual compilation in the
2026-09-17 observation. `wasm/build.sh` sidesteps the same class of failure by
always using its own cache directory.

If a fresh cache also fails, delete both the local `zig-pkg/` and the entry in
the global cache (`~/.cache/zig/p/`) for the offending package and rebuild, so
Zig re-fetches it.

### `unable to load 'main.zig': FileNotFound` / `unable to load 'quirks.zig'`

```
src/apprt/lib/main.zig:1:1: error: unable to load 'main.zig': FileNotFound
src/apprt/ipc/mod.zig:6:21: note: file imported here
const lib = @import("../lib/main.zig");
src/apprt/quirks.zig:1:1: error: unable to load 'quirks.zig': FileNotFound
src/apprt/ipc/mod.zig:5:24: note: file imported here
const assert = @import("../quirks.zig").inlineAssert;
```

**This is the current repository-wide blocker, observed 2026-09-17.** It affects
every build that compiles the VT library, including `zig build -Demit-lib-vt`.

Root cause: commit `e1277bea2` contains an unrelated pure rename
`src/apprt/ipc.zig` → `src/apprt/ipc/mod.zig` (git records it as `R100`, identical
content). Adding one directory level moves the file deeper, so its relative
imports are now wrong:

| Import in `src/apprt/ipc/mod.zig` | Resolves to | Should resolve to |
|---|---|---|
| `../quirks.zig` | `src/apprt/quirks.zig` (absent) | `../../quirks.zig` |
| `../lib/main.zig` | `src/apprt/lib/main.zig` (absent) | `../../lib/main.zig` |

Verify it is this and nothing else:

```bash
ls src/apprt/lib/main.zig src/apprt/quirks.zig   # both absent
ls src/lib/main.zig src/quirks.zig               # both present
```

Fix (two import paths in `src/apprt/ipc/mod.zig`):

```zig
const assert = @import("../../quirks.zig").inlineAssert;
const lib = @import("../../lib/main.zig");
```

Until that lands, the last buildable artifacts are those produced 2026-09-16.
`zig-out/` still contains them, which is why the conformance suite can still run
(see [TESTING.md](TESTING.md)).

Because `src/apprt/` is outside this documentation change's authorised scope, the
defect is **reported, not fixed**, here.

### `switch must handle all possibilities` / `unhandled enumeration value`

Symptom, observed 2026-09-17:

```
src/build/SharedDeps.zig:696:9: error: switch must handle all possibilities
src/apprt/runtime.zig:12:5: note: unhandled enumeration value: 'windows'
```

Cause: someone is mid-change. Adding a variant to the `Runtime` enum requires
updating every exhaustive switch over it, including the one in
`src/build/SharedDeps.zig`.

How to tell whether it is you or the tree:

```bash
git status --short src/apprt/runtime.zig src/build/SharedDeps.zig
git show HEAD:src/apprt/runtime.zig | grep -n -A6 'pub const Runtime'
```

If `runtime.zig` is modified but `SharedDeps.zig` is not, an in-flight edit is
the cause. Building a detached worktree at a known-good revision is the clean
way to separate the two:

```bash
git worktree add --detach /tmp/head-verify HEAD
```

### Other common failures

| Symptom | Cause and fix |
|---|---|
| Zig version message from `requireZig` | `build.zig.zon` requires exactly 0.16.0. Install 0.16.0 (`mlugg/setup-zig@v1` in CI, or `nix develop`). |
| `unable to find utility "metal"` / missing MetalToolchain | Install the Xcode Metal toolchain component; or build the library only (`-Demit-lib-vt`); or use `-Drenderer=opengl`. `-Demit-macos-app=false` alone does **not** avoid this — Metal is in the core library's macOS renderer path. |
| GTK not found on Linux | GTK4 dev headers missing. Check `pkg-config --modversion gtk4`. |
| Test executable cannot find the library | Integration tests are separate executables. The Rust `build.rs` emits an rpath; for C harnesses set it yourself: `DYLD_LIBRARY_PATH=zig-out/lib` (macOS) or `LD_LIBRARY_PATH=zig-out/lib` (Linux). |

---

## 10. Cleaning

```bash
make clean      # removes zig-out, .zig-cache, macos/build, macos/GhosttyKit.xcframework
```

Or selectively:

```bash
rm -rf zig-out .zig-cache
```

`zig-pkg/` holds fetched dependencies. Removing it forces a re-fetch and is the
remedy for a corrupted dependency tree, but it will fail if the dependency host
is unreachable.

---

## 11. Verification status (2026-09-17)

All builds below were attempted on the observed date. Two distinct breakages were
found, both introduced by concurrent work on other gates.

| Build | Revision | Result |
|---|---|---|
| `zig build -Demit-lib-vt` (repo `.zig-cache`) | working tree | **FAIL** — stale build runner, `uucode` `FileNotFound` |
| `zig build -Demit-lib-vt` (fresh cache) | working tree | **FAIL** — unhandled `Runtime.windows` arm in `src/build/SharedDeps.zig` |
| `zig build -Demit-lib-vt -Demit-xcframework=false` (fresh cache, detached worktree) | `a4bf9e98f` | **FAIL** — `src/apprt/ipc/mod.zig` relative imports resolve to missing files (50/64 steps succeeded, 2 compile errors) |
| `conformance/build.sh run` | artifacts from 2026-09-16 | **PASS** — 84/84, 100% |
| WASM artifact present | 2026-09-16 04:35 | 813,670 bytes, sha256 `08ac8ed8…` |

### What this means

**RESOLVED.** As observed on 2026-09-17, the committed revision did not build:
`zig build -Demit-lib-vt` failed at `src/apprt/ipc/mod.zig`, which commit
`e1277bea2` renamed from `src/apprt/ipc.zig` without updating its relative imports.
It was the top-priority defect of that day, blocking `libghostty-vt` regeneration
and every downstream gate. **Fixed by `cd1ed5c60`** ("correct relative import
depths after ipc.zig -> ipc/mod.zig"), after which the macOS `.app` rebuilt
(`packaging/macos-app.sh` exit 0, 2026-09-18) and the Linux/Windows builds and
release proceeded. The fix is the two import lines (§9), now in the tree.

The working tree additionally fails earlier, at build-graph construction, because
`Runtime.windows` was added without updating the exhaustive switch in
`src/build/SharedDeps.zig`.

Separating the two is exactly why the detached-worktree build was run: it isolates
committed state from uncommitted edits.

### What is still valid

The artifacts in `zig-out/` from 2026-09-16 remain the newest good build, which is
why the conformance suite still runs and still passes 84/84. That pass describes
that library, not the current source tree.

No claim in this document should be read as "the tree builds today". It does not.

---

## See also

- [PLATFORMS.md](PLATFORMS.md) — the support matrix these builds produce
- [TESTING.md](TESTING.md) — running the suites after a build
- [CONTRIBUTING.md](CONTRIBUTING.md) — CI, style, and the commit ledger
- Upstream `HACKING.md`, `PACKAGING.md` — deeper build and packaging detail
- `build.zig`, `src/build/Config.zig` — the authoritative flag definitions
