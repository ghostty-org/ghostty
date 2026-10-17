# 2026-10-17 Usability Audit — Khostty (v0.1.0)

**Observed:** 2026-10-17 · **Scope:** single-repo (`KooshaPari/Khostty` @ `main`,
`4c9e4c57a`; Phase 0 branch `test/agent-ipc-phase0` @ `b2e6c51f3`).
**Method:** read-only static analysis of `docs/`, `src/apprt/`, `src/apprt/ipc/`,
and the binding roots. No builds or tests were run. **Authored by agent.**

Sibling documents in `docs/audits/`:

- `20261017-stubs.md` — fork-vs-upstream static-stub scan (336 files / 71,743 insertions).
- `20261017-mux.md` — Phase 0 agent-IPC verification (DONE+verified on
  `test/agent-ipc-phase0`, not yet merged to `main`).
- `20261017-usability.md` — this file: CVP / MVP / intended user / risk surface.

## TL;DR

Khostty is the **library-first** fork of Ghostty. The CVP is `libghostty-vt` plus
a polyglot FFI surface (Rust, Go, Python, C, JS/TS via WASM). The GUI app is
upstream; the fork delta is small, named, and confined to four workstreams
(Windows runtime, agent IPC, polyglot FFI, WASM dist). **Phase 0 of agent IPC
(commands 2, 3, 4, 6 of the G4 acceptance set) is implemented at the module
level on a branch and not yet wired into any runtime**; the macOS operator path
today has no live IPC socket to connect to. **MVP completeness is uneven:**
library + bindings are install-and-run-verified on three platforms, while the
agent-IPC story — the headline differentiator — is reachable only on GTK Linux
and even there, two of thirteen commands (`pane.focus`, `pane.search`) return
`unsupported` against the real runtime.

## 1. Intended user

> A developer who wants to **embed Ghostty's terminal VT engine in their own
> application** (Rust, Go, Python, C, or browser/Node via WASM) and, as a
> follow-on, drive a hosted Ghostty instance from an AI agent over a JSON IPC
> channel. The GUI terminal is upstream, not a Khostty product.

That sentence is the *inferred* user. The repo never states a one-line intended
user. The closest evidence is the `package.json` /
[`Cargo.toml`](../../khostty-vt/Cargo.toml) /
[`pyproject.toml`](../../khostty-python/pyproject.toml) /
[`include/ghostty/vt.h`](../../include/ghostty/vt.h) audience plus the
[`docs/HANDOFF-20261015.md`](../HANDOFF-20261015.md) positioning
("value-add is the polyglot FFI + agent IPC, not another terminal").

## 2. User-facing surfaces

| # | Surface | Artifact | Status today | Where |
|---|---|---|---|---|
| 1 | **C ABI / `libghostty-vt`** | `libghostty-vt.a`, `.dylib`, `.so` | DONE | [`src/lib_vt.zig`](../../src/lib_vt.zig), [`include/ghostty/vt.h`](../../include/ghostty/vt.h) |
| 2 | **Rust crate `khostty-vt`** | `crates.io` 0.1.0 + local `khostty-vt/` | DONE (install+run) | [`khostty-vt/Cargo.toml`](../../khostty-vt/Cargo.toml) version `0.1.0` |
| 3 | **Go module `khostty-go`** | local `khostty-go/` + examples | DONE (not on pkg.go.dev observed) | [`khostty-go/go.mod`](../../khostty-go/go.mod) |
| 4 | **Python `khostty_vt`** | local `khostty-python/dist/` | DONE locally; **PyPI not yet published** | [`khostty-python/pyproject.toml`](../../khostty-python/pyproject.toml) |
| 5 | **WASM + JS/TS bindings** | `khostty-vt.wasm` + `@khostty/libghostty-vt-wasm` on npm | DONE (npm 0.1.0); local `package.json` still `0.0.0` (drift) | [`wasm/package.json`](../../wasm/package.json) |
| 6 | **macOS `.app`** | `Khostty-0.1.0-macos.zip` | DONE — built, signed, GUI-launched, interactive keystroke round-trip 2026-09-20; **not notarized** | [`docs/INSTALL.md` §1 row 3](../INSTALL.md) |
| 7 | **Linux GTK `.deb`** | `khostty_0.1.0_amd64.deb` | DONE — install-verified on WSL Fedora 44, GUI-launch half-verified (Xvfb) | [`docs/INSTALL.md` §1 row 4](../INSTALL.md) |
| 8 | **Windows `setup.exe`** | `Khostty-0.1.0-windows-x86_64-setup.exe` | BUILT + INSTALLED + UNINSTALLED on Windows runner; **GUI window not launched, only `+version` + `ghostty-vt.dll` ABI verified** | [`docs/INSTALL.md` §1 rows 6–7](../INSTALL.md) |
| 9 | **Windows `ghostty.exe` runtime** | the artifact the installer drops | SCAFFOLD — `app runtime: .windows` reports OK, but the runtime is `error.Unimplemented` for all windowing + IPC operations | [`docs/ARCHITECTURE.md` §2](../ARCHITECTURE.md), [`docs/AGENT.md` §5](../AGENT.md) |
| 10 | **CLI: `+new-window` / `+new-tab` / `+toggle-quick-term`** | upstream IPC | DONE (narrow) | [`src/cli/ghostty.zig`](../../src/cli/ghostty.zig), [`src/apprt/ipc.zig`](../../src/apprt/ipc.zig) |
| 11 | **Agent IPC v1 (JSON over Unix socket, 13 commands)** | `src/apprt/ipc/` modules + `app_host.zig` + `server.zig` | IN PROGRESS on `test/agent-ipc-phase0`; **NOT REACHABLE on `main`** | [`docs/AGENT.md` §4](../AGENT.md), [`docs/audits/20261017-mux.md`](20261017-mux.md) |
| 12 | **Upstream terminal experience** (everything else) | full upstream | DONE (upstream) | `src/terminal/`, `src/renderer/`, `src/font/`, `src/config/` — explicitly unmodified per [`docs/ARCHITECTURE.md` §9](../ARCHITECTURE.md) |

## 3. CVP (Customer Value Proposition)

The Khostty CVP has three named layers, in priority order:

1. **"Library first."** A polyglot FFI over Ghostty's terminal VT layer so
   third-party apps can parse, render, search, snapshot, and inject keys/mouse
   events without forking the GUI. The headline is one C ABI (`include/ghostty/vt.h`,
   203 `GHOSTTY_API` functions across 30 module headers, observed 2026-09-17)
   consumed by Rust/Go/Python/JS-TS.
2. **"Drive a running terminal from an agent."** A typed JSON IPC v1 over Unix
   sockets with 13 commands (`ping`, `pane.{create,close,focus,list,write,state,search,resize_split,equalize,zoom}`,
   `events.{subscribe,unsubscribe}`), fail-closed token auth, and an async event
   broker.
3. **"Windows-native Ghostty."** A Win32 standalone app runtime — a thing
   upstream Ghostty does not yet ship.

The [`docs/FORK.md` §1](../FORK.md) self-description is the negation form:
"the value is **not** rebuilding what upstream has." That is the operator's
positioning, not a marketer's pitch. **Per [`docs/HANDOFF-20261015.md`](../HANDOFF-20261015.md),
v0.1.0 is the "first release of the new fork,"** so the CVP is being shipped,
not just promised.

## 4. MVP completeness

Scored per [`docs/AGENT.md` §1](../AGENT.md) and the
[`docs/PLATFORMS.md`](../PLATFORMS.md) honest matrix.

| G | Workstream | MVP claim | Reality on `main` | Reality on `test/agent-ipc-phase0` |
|---|---|---|---|---|
| G0 | Repo & docs | DONE | DONE | DONE |
| G1 | Conformance corpus | DONE | DONE | DONE |
| G2 | Conformance corpus (`conformance/`) | DONE | DONE | DONE |
| G3 | Windows runtime | SCAFFOLD | SCAFFOLD — `app_host.zig:79` reports `windowed = false` for `.windows`; all windowing + IPC ops `error.Unimplemented` | same |
| G4 | Agent IPC v1 | IN PROGRESS | 6 modules + `protocol.md` written; **no `Server.bind` caller anywhere in the tree**; `app_host.zig:79` only `windowed = true` for `.gtk` | modules wired; `pane.focus` and `pane.search` return `error.Unsupported` against the real app runtime; `pane.write` is parser-direct not pty-direct; verified only on GTK |
| G5 | Rust `khostty-vt` | IN PROGRESS | DONE per packaging: 0.1.0 on crates.io, install+test evidence 2026-09-18; gap: no safe `text()`/`html()` formatter wrapper | same |
| G6 | Go + Python | IN PROGRESS | Local trees present; `khostty-python/dist/` builds; **PyPI publish not made** | same |
| G7 | WASM | IN PROGRESS | DONE per packaging: tarball verified, npm `0.1.0`; local `wasm/package.json` is `0.0.0` (drift) | same |
| G8 | Benchmarks | NOT STARTED | no `bench/` in tree; `-Demit-bench` is upstream's bench, not the G8 deliverable | same |
| G9 | Docs | IN PROGRESS | 8 hand-curated docs (HANDOFF, ROADMAP, README, API, INSTALL, ARCH, FORK, UPSTREAM-DELTA, AGENT, PLATFORMS, BUILD, TESTING, SECURITY, GLOSSARY) | same |
| G10 | Releases | DONE for 0.1.0 | `v0.1.0` published; PyPI pre-flighted but unpublished | same |

**Scoring.** Of the 11 gates, **3 are DONE** (G0, G1, G2; plus G5/G7 are
install-verified and shippable). **5 are IN PROGRESS** with concrete artifacts
(G4, G5, G6, G7, G9). **1 is SCAFFOLD** (G3 — Windows runtime). **1 is NOT
STARTED** (G8 — benchmarks). **The integration gap** (G4) is the only gate
where the headline differentiator is unreachable from `main` today; the modules
are written, the test work proves they work in isolation on GTK, and they
simply need a runtime to call `Server.bind` — which would in turn require
running the GTK build (not available on the macOS operator host).

**Adjusted MVP score: 7/11 landed; 2/11 reachable-but-rough; 1/11 scaffold; 1/11 not-started.**

The honest, install-verified MVP a developer can consume today is:

- `cargo add khostty-vt` → instant parser in Rust.
- `npm install @khostty/libghostty-vt-wasm` → instant parser in browser/Node.
- A built `Khostty.app` that runs on macOS, behaves like upstream Ghostty, and
  exposes the three upstream `+new-window` / `+new-tab` / `+toggle-quick-term`
  actions over the existing narrow IPC.

That is a real, shippable library product. The "agent drives a GUI terminal" story
is not yet in that MVP — and the G4 docs are honest about it
([`docs/AGENT.md` §4](../AGENT.md) explicitly says "do not build against it, and do
not report it as shipped").

## 5. User-facing risks

Ordered by impact on a developer who integrates today.

1. **Agent IPC unreachable on macOS.** Verified by `rg 'Server.bind' src/` — the
   only two hits are inside `server.zig` itself; no runtime calls bind, no
   socket file is created at the documented path
   (`~/Library/Caches/khostty/ipc.sock`). Even if the operator wires a runtime,
   `app_host.zig:79-87` returns `windowed = false` for every build that isn't
   `.exe + .gtk`. **An agent on macOS cannot drive a hosted Khostty today.**
2. **`pane.focus` and `pane.search` return `unsupported` even on GTK.** The
   `pane.Host` vtable explicitly says so
   ([`docs/audits/20261017-mux.md` §2](20261017-mux.md) and the in-file
   comment table in `app_host.zig:18-30`). A protocol that advertises 13
   commands but only delivers 11 on its single supported runtime is a CVP gap
   to be honest about in user docs.
3. **`pane.write` is parser-direct, not pty-direct.** It calls
   `termio.Termio.terminal_stream.nextSlice` rather than the pty master fd
   (`app_host.zig:30` + the threading comment at `app_host.zig:46-60`). A user
   who types into the pane concurrently with an agent `pane.write` will see
   interleaving or a wrong surface — not a safe shell injection. The right
   fix (mailbox hop through `CoreSurface.queueIo`) is named in the file
   itself and is not yet wired.
4. **C ABI is unstable.** `include/ghostty/vt.h` opens with "This is an
   incomplete, work-in-progress API. It is not yet stable and is definitely
   going to change." Consumers must pin a revision (per
   [`docs/API.md` §1](../API.md)). The fork's `bindings-drift guard` test
   (`74aa5eea9`) reduces but does not eliminate the risk; the 17
   `libghostty-vt`-shaped upstream commits behind the merge-base are the
   exact surface to watch on the next rebase
   ([`docs/UPSTREAM-DELTA.md` §1 freshness note](../UPSTREAM-DELTA.md)).
5. **Borrowed-pointer discipline.** `GhosttyString` and row/cell handles are
   borrowed — valid only until the next mutating call. A naive integration
   copies past the lifetime. The Rust crate has RAII helpers; C and WASM
   callers must read [`docs/AGENT.md` §2](../AGENT.md) and the
   `examples/c-vt-*` set carefully.
6. **No notarized macOS build.** The `.app` is signed and verified but not
   notarized; first launch on a pristine machine requires a Gatekeeper
   override. Untested ([`docs/INSTALL.md` §1 row 3](../INSTALL.md)).
7. **Windows runtime is a scaffold, not a runtime.** `src/apprt/windows/` is
   not reachable from `src/apprt.zig`'s switch
   ([`docs/ARCHITECTURE.md` §2](../ARCHITECTURE.md)). The installed
   `ghostty.exe` reports `app runtime: .windows` and runs the CLI
   (`+version`) but **no GUI window was launched** in the
   2026-09-19 evidence, and the headless Xvfb GUI-launch test on Linux is
   half-verified only ([`docs/INSTALL.md` §1 rows 4 + 7](../INSTALL.md)).
8. **Version drift between `wasm/package.json` and the npm release.** The
   local `wasm/package.json` is `0.0.0`; the published npm artifact is
   `0.1.0`. Anyone re-running the wasm build.sh will produce an artifact
   tagged `0.0.0` and may publish a downgrade. Same drift risk applies
   less acutely to the Rust crate and Python sdist.
9. **G3 Windows IPC defects are known and recorded, not fixed.** Per
   [`docs/ARCHITECTURE.md` §2](../ARCHITECTURE.md), `mod.zig` imports
   `"Surface.zig"` (case-sensitive checkouts fail), the named-pipe prefix
   resolves to a single leading backslash (not the Win32 pipe namespace),
   and `keyboard.zig` is 734 lines (over the 500-line hard limit). All
   three are recorded under the G9 documentation gate.
10. **Conformance corpus excludes images in WASM.** Kitty graphics in the
    browser are parsed and silently ignored ([`docs/AGENT.md` §6](../AGENT.md)).
    A user driving image protocols in a browser gets nothing; they must use
    the native binding.

## 6. Intended-delta features not landed (still a delta from upstream)

Listed in priority order — what the user was promised that is not in any
working build today.

| Feature | Where it lives | State | Why it matters |
|---|---|---|---|
| **Windows GUI app** | `src/apprt/windows/` | SCAFFOLD | The fork's third CVP pillar. Currently no GUI window launched. |
| **Windows named-pipe IPC** | `src/apprt/windows/ipc.zig` | SCAFFOLD — all `error.Unimplemented`; the wrong pipe prefix is hard-coded | Prevents the same `pane.*` story on Windows. |
| **macOS agent IPC** | runtime would need to call `Server.bind` from the embedded (AppKit) App | **Not implemented; explicitly out of scope on macOS** per `app_host.zig:79` | Operator on macOS cannot use the agent IPC at all today. |
| **`pane.focus` and `pane.search` on the real runtime** | upstream lacks a "focus surface by id" and a synchronous search API | DESIGNED but UNSUPPORTED — `error.Unsupported` per `app_host.zig:30` | 2 of 13 protocol commands can't be served; users hitting the API get a stable, honest error rather than a fake. |
| **Mailbox-hop `pane.write`** | surface mailbox `CoreSurface.queueIo` | named in `app_host.zig:46-60`; not wired | Race-free shell injection. Today's parser-direct `pane.write` interleaves with user keystrokes. |
| **Async event hooks (title/child-exit/resize/bell)** | the matching runtime callbacks | named in `app_host.zig:54-58`; not wired | `events.subscribe` has no producer side beyond the broker. |
| **PyPI publication** | `publish-pypi.yml` | committed, pre-flighted, **awaiting operator's publisher registration** ([`docs/INSTALL.md` §0](../INSTALL.md)) | Python binding is the only one not on a registry. |
| **Benchmark harness** | `bench/` | NOT STARTED in tree ([`docs/ARCHITECTURE.md` §8](../ARCHITECTURE.md)) | G8 deliverable absent. |
| **Safe Rust `text()` / `html()` formatter** | `khostty-vt/src/formatter.rs` (does not exist) | not implemented ([`docs/AGENT.md` §2](../AGENT.md)) | Forces Rust users to `unsafe`-call `ghostty_formatter_*` or switch to the WASM package. |
| **Bump `wasm/package.json` to `0.1.0`** | `wasm/package.json` | local file `0.0.0` while npm published `0.1.0` | Prevents accidental downgrade publish on next local `npm publish`. |

## 7. Documentation gaps

The docs are unusually honest for a 0.1.0 release. The gaps are concrete.

1. **No single-line "intended user"** anywhere. The closest is
   [`docs/HANDOFF-20261015.md`](../HANDOFF-20261015.md) but it does not name a
   persona. A new visitor reads 9,000 words of positioning without learning
   "this is for you if you want to embed a terminal parser in X."
2. **The CLI `+new-window` / `+new-tab` actions are upstream-only.** A user
   reading [`docs/AGENT.md` §3](../AGENT.md) learns that the v1 protocol is
   *additive*, but nothing in the doc says "on macOS or Windows, there is no
   server, so don't expect `khostty +list-panes` to work." The `+list-actions`
   introspection command will list upstream actions, hiding the gap.
3. **`docs/API.md` lists 9 surfaces** (C ABI, Rust, JS/TS, Zig, Go, C#,
   Python, Apple/ObjC, .NET) but the Apple/ObjC and .NET rows are aspirational
   — the `khostty-vt` Rust crate is the only Rust entry; the Zig surface is
   the in-process API, not a binding; C# and .NET have no observed files in
   `khostty-vt/` or anywhere in the tree. The doc should mark which rows are
   "shipped" vs "intended."
4. **`pane.focus` and `pane.search` limitations are buried.** They appear in
   `app_host.zig:30` (in the source) and in the mux audit. A user reading only
   `docs/protocol.md` and the spec sees 13 commands and assumes parity.
5. **`khostty-python/dist/` is a `0.1.0` sdist/wheel locally, but PyPI is
   unpublished.** Nothing in the docs says "to install the Python binding
   today, `pip install khostty-python/dist/khostty_vt-0.1.0-*.whl`" — the
   pre-flight `publish-pypi.yml` step is recorded but the install path is
   not.
6. **Build host requirements are scattered.** The Zig 0.16.0 floor, glibc 2.43
   on Linux, GTK 4 + libadwaita + gtk4-layer-shell, Node ≥ 20, Inno Setup
   6.7.1 on Windows, `libc6 (>= 2.43)` on Debian — each appears in the
   install evidence for the artifact that needed it, but no `BUILD.md` /
   `INSTALL.md` summary table consolidates them. A first-time builder can hit
   any of the three blockers and not find a single page to read first.
7. **The "fork discipline" boundary** ([`docs/ARCHITECTURE.md` §9](../ARCHITECTURE.md))
   is stated but not enforced by CI. A future change to `src/terminal/` would
   silently break the upstream-merge-cheap property. There is no
   `tools/check-fork-discipline.zig` or CI job named in the audit files.
8. **CVP is not asserted anywhere.** There is no single document that says,
   in one paragraph, "Khostty is the polyglot-FFI + agent-IPC + Windows fork
   of Ghostty; everything else is upstream." The closest is
   [`docs/FORK.md` §1](../FORK.md) in negation form.
9. **`docs/UPSTREAM-DELTA.md` carries its own freshness drift.** The
   `2026-10-14` note inside says the numbers will be wrong "in 8h." A user
   reading the file gets a clear caveat but no automated re-gen trigger
   beyond the §5 procedure.
10. **The fork has no `CONTRIBUTING.md` or `LICENSE` summary in the root.**
    The operator installs and runs an artifact that is partly GPL-3.0
    (upstream Ghostty) and partly Apache-2.0/MIT (the Khostty additions).
    Nothing in the readme surfaces the licensing boundary.

## 8. Gaps for synthesis (explicit, for the fwd-path synthesizer)

The downstream tool that reads this audit and produces a forward path needs
the following six facts, in order. If any are wrong, the rest of the plan
collapses.

1. **The MVP that is real today is the polyglot FFI + the upstream GUI app
   that ships in v0.1.0.** Anything agent-IPC-shaped is unreleased on `main`
   and even on `test/agent-ipc-phase0` is GTK-only.
2. **The macOS operator host is the wrong host for G4 work.** Even if a
   Phase 0 merge is unblocked, no macOS runtime calls `Server.bind`, and
   `app_host.zig:79` rejects macOS at compile time. G4 end-to-end verification
   requires a Linux GTK host (or a future macOS AppKit binding path).
3. **Two of thirteen G4 commands are intentionally `error.Unsupported` against
   the real runtime today.** `pane.focus` and `pane.search` need upstream
   work that has not been scheduled. They are not bugs to fix; they are
   surface limitations to disclose.
4. **`pane.write` is parser-direct by design today.** The mailbox-hop fix
   is named in the source. Replacing it changes a documented contract.
5. **Three concrete ships, in priority order, would close the largest CVP
   gap:** (a) wire a runtime to call `Server.bind` (GTK Linux path only);
   (b) publish `khostty_vt` to PyPI (workflow pre-flighted, blocked on
   operator registration); (c) bump `wasm/package.json` to `0.1.0` (one-line
   fix). Items (b) and (c) are non-architectural; (a) is the architectural
   one.
6. **The "fork discipline" boundary is what keeps upstream merges cheap.** No
   CI enforces it. The next `src/terminal/` modification will silently
   regress the property that makes Khostty worth being a fork.

## 9. Author and method notes

- Authored by agent on 2026-10-17, single-repo scope, FORK-ONLY (no upstream
  `gh` API calls).
- Inputs: `HANDOFF-20261015.md`, `ROADMAP.md`, root `README.md`, `docs/README.md`,
  `docs/audits/20261017-stubs.md`, `docs/audits/20261017-mux.md`, `docs/API.md`,
  `docs/PLATFORMS.md`, `docs/FORK.md`, `docs/ARCHITECTURE.md`, `docs/AGENT.md`,
  `docs/INSTALL.md` (head), `docs/UPSTREAM-DELTA.md` (head + §1 freshness
  notes). Targeted verifications: `rg 'Server.bind' src/`, `wc -l
  src/apprt/ipc/*.zig`, `head -50` of `src/apprt/ipc/{server,app_host}.zig`,
  `head -40` of `wasm/package.json` and `khostty-vt/Cargo.toml`.
- **Not done:** no `zig build` was executed. No G4 server was started. The
  mtime of `src/apprt/ipc/{server,app_host,mod}.zig` is **2026-10-16**,
  while every other file in that directory is **2026-09-17 03:47-04:55**
  — the three newer files are the Phase 0 work, the rest is the G4 design
  code. This mtime split is the cleanest signal that Phase 0 is on a
  branch and not on `main`.
- **Source-of-truth pointer for downstream:** [`docs/HANDOFF-20261015.md`](../HANDOFF-20261015.md)
  (positioning), [`docs/audits/20261017-mux.md`](20261017-mux.md)
  (Phase 0 evidence), [`docs/AGENT.md` §4](../AGENT.md) (the G4 protocol
  status), [`docs/ARCHITECTURE.md` §9](../ARCHITECTURE.md) (the fork boundary
  the forward path must preserve).
