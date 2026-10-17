# Platform Support

**Observed:** 2026-09-17 · Honest matrix. A row is only marked **VERIFIED** when
this repository has an observed, dated result for it. Upstream support and
Khostty-verified support are different columns, because they are different claims.

---

## 1. Summary matrix

| Platform | VT library | Terminal app | Agent IPC | FFI | Renderer | Verified in this fork? |
|---|---|---|---|---|---|---|
| **macOS** (arm64/x86_64) | **VERIFIED** | `.app` built, signed, GUI-launched, keystroke round-trip verified | 3 actions | C, Rust, WASM | Metal / OpenGL | **YES** — library 2026-09-16/17; `.app` build 2026-09-18 + GUI launch 2026-09-20 |
| **Linux** (x86_64/arm64) | Upstream supported | Upstream GTK4 | 3 actions | C, Rust, WASM | OpenGL | **BUILT + INSTALL-VERIFIED + GUI-LAUNCH-VERIFIED 2026-09-19** (x86_64, WSL Fedora 44; `.deb` installed on the host, +version exit 0, bookworm negative control refuses on the derived libc6 2.43 floor; headless GTK launch under Xvfb + dbus-run-session: APP_ALIVE, zero-error GTK init, then purged; xwininfo/xwd unavailable on Fedora 44 so no window-tree/screenshot evidence; no arm64) |
| **Windows** (x86_64) | Upstream builds; **no default app runtime** (opt-in `-Dapp-runtime=windows` scaffold) | **CLI verified; GUI window not launched** | Named-pipe stub | C, Rust, Go | OpenGL (unproven) | **PARTIAL** — exe + DLL + installer verified 2026-09-18/19; no GUI window |
| **WASM** (`wasm32-freestanding`) | **VERIFIED** | n/a (headless) | n/a | JS/TS | WebGL (n/a for VT-only) | **YES** — artifact verified |
| **iOS** | Library only (xcframework slice) | Not supported | n/a | C | Metal | Artifact present, app not attempted |
| **FreeBSD** | Upstream supported | Upstream GTK4 | 3 actions | C, Rust | OpenGL | **NO** |

Read this table as: *only the macOS and WASM rows have fresh evidence in this
fork.* Everything else is upstream capability that Khostty has not independently
exercised.

---

## 2. Platform selection at build time

Three comptime choices decide what a target gets. Each falls back to a
platform-appropriate default when the corresponding `-D` flag is omitted.

### Application runtime — `src/apprt/runtime.zig`

```zig
pub fn default(target: std.Target) Runtime {
    return switch (target.os.tag) {
        .linux, .freebsd => .gtk,
        else             => .none,   // lib-only; no executable
    };
}
```

| Target | Default runtime | Consequence |
|---|---|---|
| Linux, FreeBSD | `gtk` | Full app; requires GTK4 + wayland/x11 |
| macOS | `none` | Library only; Xcode builds the `.app` |
| **Windows** | **`none`** | **Library only — this is the gap G3 fills** |
| wasm32 | `browser` (via `.wasm_module`) | Headless module |

### Renderer — `src/renderer/backend.zig`

```zig
if (target.cpu.arch == .wasm32) return switch (wasm_target) { .browser => .webgl };
if (target.os.tag.isDarwin())  return .metal;
return .opengl;
```

Override with `-Drenderer=opengl|metal|webgl`.

### Fonts — `src/font/backend.zig`

| Target | Default backend |
|---|---|
| macOS | `coretext` |
| Linux, BSD | `fontconfig_freetype` |
| Windows | `freetype_windows` (Windows font-directory scanner) |
| wasm32 | `web_canvas` (not used by the VT-only library) |

Override with `-Dfont-backend=…`. Note the Windows comment in-tree: fontconfig is
avoided on Windows because its libxml2 dependency may not unpack correctly;
a future DirectWrite backend may replace `freetype_windows`.

> Windows having a default *font* backend does not mean Windows has an
> application runtime. Font discovery and windowing are separate layers.

---

## 3. macOS

**Status: VERIFIED for the library; `.app` built, signed, and GUI-launched with an
interactive keystroke round-trip (2026-09-20). Notarization absent (untested path
on a pristine machine).**

> **Historical build blocker (observed 2026-09-17; FIXED by `cd1ed5c60`).** `zig
> build -Demit-lib-vt` failed for every platform: commit `e1277bea2` renamed
> `src/apprt/ipc.zig` to `src/apprt/ipc/mod.zig` without updating its relative
> imports. The two-line import fix landed as `cd1ed5c60` ("correct relative import
> depths"), after which the `.app` was rebuilt by `packaging/macos-app.sh` (exit 0,
> 2026-09-18). Diagnosis archive: [BUILD.md](BUILD.md#unable-to-load-mainzig-filenotfound--unable-to-load-quirkszig).

### Verified artifacts (2026-09-16, still present)

| Artifact | Size | Timestamp |
|---|---|---|
| `zig-out/lib/libghostty-vt.a` | 1,323,002 B | 2026-09-16 16:46 |
| `zig-out/lib/libghostty-vt.0.1.0.dylib` | 2,215,792 B | 2026-09-16 16:46 |
| `zig-out/lib/libghostty-vt.dylib` | symlink → `.0.dylib` → `.0.1.0.dylib` | 2026-09-16 04:31 |
| `zig-out/lib/ghostty-vt.xcframework/` | 3 slices | 2026-09-16 04:31 |
| `zig-out/bin/ghostty-vt.wasm` | 813,670 B | 2026-09-16 04:35 |

xcframework slices present: `macos-arm64_x86_64`, `ios-arm64`,
`ios-arm64-simulator`.

### Conformance (2026-09-17)

84/84 cases pass against the built `libghostty-vt.dylib`. Re-run with
`conformance/build.sh`. See [TESTING.md](TESTING.md).

### Known blocker: Metal toolchain

The full application build reports 285/302 steps succeeding. Metal shader
compilation fails on the installed Xcode because the **MetalToolchain component
is missing** (Xcode 26 beta). `-Demit-macos-app=false` does not avoid it, because
Metal is used by the core library's macOS renderer rather than only by the app
bundle.

Workarounds in use:

| Workaround | Effect |
|---|---|
| `-Drenderer=opengl` | Build with the OpenGL renderer instead of Metal |
| `-Demit-lib-vt` | Build only the VT library; no renderer at all |
| `-Demit-macos-app=false` | Skip the Xcode-driven `.app` (does not by itself fix Metal) |

CI reflects this: `.github/workflows/ci.yml` (the fork's own workflow) runs
`zig fmt --check src/ build.zig` on Ubuntu and
`zig build -Doptimize=ReleaseSafe -Demit-macos-app=false` on a macOS runner.

Why the CI record is still thin here: the Ubuntu job is **formatting only**, and
upstream's heavier suites are not effective in this fork. `test.yml` gates every
job on `github.repository == 'ghostty-org/ghostty'`, so it is inert here;
`nix.yml`, `flatpak.yml`, and `update-colorschemes.yml` carry the same guard.
`nix.yml` additionally targets `namespace-profile-ghostty-*` runners that do not
exist for this repository. 12 of the 16 workflow files have no repository guard
at all and would attempt to run. No CI workflow that can succeed in this fork
builds or tests Linux. The Linux x86_64 build and `.deb` install-verify that do
exist were run on the WSL Fedora 44 host (§4), not CI. See
[CONTRIBUTING.md](CONTRIBUTING.md#9-continuous-integration).

**Honest statement:** Khostty's macOS *library* and *application* paths are both
verified in this fork — the `.app` builds (the 2026-09-17 ipc-import breakage was
fixed by `cd1ed5c60`), signs, verifies, and launched in a live GUI session with an
interactive keystroke round-trip (2026-09-20). What remains untested is
first-launch Gatekeeper behavior on a pristine machine, because the bundle is not
notarized (`notarytool` credentials absent).

---

## 4. Linux

**Status: BUILT + INSTALL-VERIFIED (x86_64, 2026-09-19, WSL Fedora 44 on
`kooshapari-desk`); GUI launch and arm64 not verified.**

Upstream provides a full GTK4 application runtime (`src/apprt/gtk.zig` plus
`src/apprt/gtk/`, ~8000+ lines) that is the default for Linux and FreeBSD.

| Item | Value |
|---|---|
| Runtime | `gtk` (default) |
| Renderer | `opengl` |
| Fonts | `fontconfig_freetype` |
| Display backends | x11 and/or wayland (`-Dgtk-wayland`, `-Dgtk-x11`) |
| Packaging | `flatpak/`, `snap/`, `dist/linux/`; the GTK app `.deb` built + install-verified |

What was verified here (2026-09-19): the GTK application `.deb`
(`khostty_0.1.0_amd64.deb`, sha256 `63d4e615…de0`) was built natively in WSL
Fedora 44 (commits `9daf736e8`, `45e6d086b`, `65de471df`), then installed on that
host with `dpkg -i --force-depends` (the dpkg db there has no libc6 entry even
though the host runs glibc 2.43 binaries): `dpkg -s` → `install ok installed`,
`dpkg -V` clean, `dpkg -L` lists the binary + `.desktop` + metainfo + 6 hicolor
PNGs, `ldd` resolves everything, `desktop-file-validate` passes, the installed
`khostty +version` exits 0, and `dpkg --purge` leaves no residuals. The negative
control holds: in an x86-64 Debian 12 container (glibc 2.36) `dpkg -i` leaves the
package unpacked but unconfigured, refusing on the derived `libc6 (>= 2.43)`
floor. Evidence: `sessions/20260916-fork-assessment/evidence/gtk_deb_install_2026-09-19.txt`.

What is still open: a windowed GTK GUI launch (the WSL host has no desktop
session) and arm64 Linux. No CI job builds or tests on Linux; the Ubuntu job
runs only `zig fmt --check`. That remains a gap worth closing before broader
Linux-support claims.

---

## 5. Windows

**Status: PARTIAL (G3) — exe + DLL built 2026-09-18, executed on real Windows and install/uninstall-verified 2026-09-19; windowing still `error.Unimplemented`, so no GUI window.**

This is the fork's headline delta: upstream has no Windows application runtime.
`Runtime.default` returns `.none` for Windows, so upstream produces no executable.

### What exists

`src/apprt/windows/` — an isolated scaffold:

| File | State |
|---|---|
| `mod.zig` | Module root; `resourcesDir` returns `null` |
| `App.zig` | `init`, `registerWindowClass`, `run` all return `error.Unimplemented` |
| `Window.zig` | HWND wrapper type |
| `surface.zig` | Routes `WM_SIZE`, `WM_PAINT`, `WM_ERASEBKGND`, `WM_CLOSE`, `WM_DESTROY`; delegates rendering to the stub |
| `renderer.zig` | `init`, `resize`, `renderFrame`, `invalidate` all return `error.Unimplemented` |
| `win32api.zig` | Win32 type aliases and `user32`/`kernel32`/`dwmapi` declarations |
| `ipc.zig` | Named-pipe transport; all operations return `error.Unimplemented` |

### What now works (2026-09-18/19)

- **Wiring + opt-in runtime.** `src/apprt.zig` exports and selects `windows`
  (`.windows => windows`); `build.zig` accepts `-Dtarget=x86_64-windows-gnu
  -Dapp-runtime=windows` (documented as the opt-in scaffold, `build.zig:44`).
- **Cross-build.** `ghostty.exe` (43.5 MB, `PE32+ executable (GUI) x86-64`) and
  `ghostty-vt.dll` (7.5 MB) built 2026-09-18 and hashed.
- **Native run evidence (CLI).** Executed 2026-09-19 on `kooshapari-desk`
  (Windows NT 10.0.28120, AMD64): `ghostty.exe +version` → exit 0,
  `app runtime: .windows`, `font engine: .freetype_windows`, `libxev: iocp`;
  `ghostty-vt.dll` loads via `LoadLibraryW` and its ABI runs live
  (`terminal_new`/`resize`/`vt_write`/OSC-0 title/`terminal_free`) — 0 failures.
  Evidence `sessions/20260916-fork-assessment/evidence/windows_runtime_verify_2026-09-19.txt`.
- **Installer.** Inno Setup 6.7.1 package install/uninstall-verified 2026-09-19
  (`/VERYSILENT`, files landed, uninstall clean; see [INSTALL.md](INSTALL.md) §3.5).

### What still does not exist

- **No GUI window.** `App.zig` `init`/`registerWindowClass`/`run` still return
  `error.Unimplemented` (re-checked 2026-09-24), so the run loop cannot open a
  window; the 2026-09-19 execution is CLI `+version` only.
- **No real Win32 calls.** `win32api.zig` declares function pointers; no code
  invokes them.

| `mod.zig:4` now imports `surface.zig` (lowercase) — fixed |

### Windows IPC sketch

| Item | Value |
|---|---|
| Pipe name | `\\.\pipe\khostty-{server_pid}` intended; **the constant currently has one leading backslash, which is not the pipe namespace** (observed 2026-09-17) |
| Frame | `extern struct { action: u16, length: u32 }` + packed payload |
| Security attributes | **None declared.** The earlier null-DACL / inheritable-handle declaration was removed without a replacement, so no ACL design exists. |
| Status | SCAFFOLD, `error.Unimplemented` |

Details and the security implication: [SECURITY.md](SECURITY.md#4-windows-transport-weakness-scaffold).

### G3 exit criteria (from the WBS)

Cross-compile succeeds; the binary runs (native or Wine); keyboard and mouse
input encode correctly via `ghostty_key_encoder_*` / `ghostty_mouse_encoder_*`;
DirectWrite renders glyphs with font fallback; clipboard works with bracketed
paste; the named pipe accepts agent commands. **Two are met**: cross-compile succeeds (2026-09-18) and the binary runs natively (`+version`, DLL ABI, 2026-09-19). **Open**: keyboard and mouse input encode checks, DirectWrite render with font fallback, clipboard bracketed paste, and named-pipe command acceptance — the windowing and IPC scaffolds still return `error.Unimplemented`.

---

## 6. WebAssembly

**Status: IN PROGRESS (G7); artifact verified.**

| Item | Value |
|---|---|
| Target | `wasm32-freestanding` |
| Build | `wasm/build.sh` (pins target, isolates cache, validates magic + version) |
| Artifact | `813,670 bytes`, sha256 `08ac8ed881ffdae68b9f96f9afa6c834e57ba7ea49280d220e882938508e5bf6` |
| Module shape | 0 imports, 189 exports (187 `ghostty_*` functions + memory) |
| Runtime | Node ≥ 20; any browser with ESM + WebAssembly |
| Package | `@khostty/libghostty-vt-wasm` (private, `version 0.0.0`) |

### What works

The VT core: parser, screen, scrollback, cursor, styles, selection, search, render
state, snapshots, SGR, OSC, and key/mouse/focus encoding. The module is
freestanding with `rdynamic` exports, a growable indirect function table, no
entrypoint, and a 128 KB stack.

### What is excluded by design

| Excluded | Reason |
|---|---|
| Kitty graphics (16 functions) | Needs OS timestamps, unavailable when freestanding. Sequences are parsed and safely ignored. |
| PTY, filesystem, clock, timestamps | No OS |
| Renderer | `libghostty-vt` models state only. Draw the grid yourself, or use `html()`. |
| `web_canvas` font backend | Only relevant to the full browser app, not the VT-only library |

### Verification

```bash
cd wasm
npm run check    # header sync + typecheck + runtime/ABI tests + export dump
```

Reference for the export-count assertion: the ABI test requires the exported
function set to equal the consolidated header's declarations minus an explicit,
reasoned list — currently only the 16 `ghostty_kitty_graphics_*` entries.

### iOS note

The xcframework carries `ios-arm64` and `ios-arm64-simulator` slices of
`libghostty-vt`. The build system rejects the **full** Ghostty app for iOS (only
the library is supported there). No iOS build or run is recorded.

---

## 7. Feature availability by platform

| Feature | macOS | Linux | Windows | WASM |
|---|---|---|---|---|
| VT parsing / screen state | yes | yes | yes (library) | yes |
| Scrollback + reflow | yes | yes | yes (library) | yes |
| Snapshots | yes | yes | yes (library) | yes |
| Search | yes | yes | yes (library) | yes |
| Key / mouse / focus encoding | yes | yes | yes (library) | yes |
| Kitty graphics | yes | yes | yes (library) | **no** |
| C ABI | yes | yes | yes | via `wasm.h` |
| Rust wrapper | yes | yes | untested | n/a |
| JS/TS wrapper | n/a | n/a | n/a | yes |
| Native window | yes (Xcode) | yes (GTK4) | **no** | n/a |
| Clipboard integration | yes | yes | **no** | n/a |
| Agent IPC (3 actions) | yes | yes | **no** | n/a |
| Agent IPC (pane protocol) | **no server** | **no server** | **no server** | n/a |

"yes (library)" means the C library builds for that target and provides the
behaviour; it does not mean a Khostty application runs there.

---

## 8. What would change these verdicts

| Row | Evidence needed to move it |
|---|---|
| macOS app | DONE — full build with Metal toolchain (2026-09-18), codesign verify, and a live GUI launch with keystroke round-trip (2026-09-20); notarization still open |
| Linux | DONE — `zig build` on a Linux host (2026-09-19, WSL), `.deb` install-verify, and a headless GTK launch (Xvfb, APP_ALIVE) |
| Windows | PARTIAL — cross-built exe executed natively (`+version`, DLL ABI0 failures) and installer install/uninstall-verified (2026-09-19); still missing: a GUI window run, DirectWrite render check, input encode check, named-pipe command acceptance |
| WASM in a browser | A headless-Chromium smoke run (current tests are Node, exercising the same code path) |
| iOS | A build and run of a host app linking the xcframework slice |

Record the observation date with each result. A pass is only a pass for the
revision it was observed on.

---

## See also

- [BUILD.md](BUILD.md) — per-platform build commands
- [TESTING.md](TESTING.md) — how to produce the evidence above
- [FORK.md](FORK.md) — which platforms the fork actually adds
- [ARCHITECTURE.md](ARCHITECTURE.md) — the AppRT abstraction these defaults plug into
- Deep WBS: [`docs/sessions/20260916-fork-assessment/02_DEEP_WBS.md`](sessions/20260916-fork-assessment/02_DEEP_WBS.md)
