# Security Model

**Observed:** 2026-09-17 · Trust boundaries, the authorization requirement, memory
safety approach, and an explicit list of what is not yet defended.

Khostty embeds an upstream terminal library and adds an agent-facing control
surface. That second part is the security-relevant delta: an IPC channel that can
write VT bytes into a live shell is remote code execution by design unless it is
authenticated and scoped.

---

## 1. Trust boundaries

```
 UNTRUSTED ─────────────────────────────────────────────────────────────────
  │
  │  PTY bytes          Agent JSON over IPC socket     Kitty image payloads
  │  (program output,   (local clients)                (APC sequences)
  │   possibly hostile)
  │        │                       │                          │
  ▼        ▼                       ▼                          ▼
 ┌──────────────────┐   ┌──────────────────────┐   ┌─────────────────────┐
 │ VT parser        │   │ IPC auth + dispatch  │   │ Image decode        │
 │ (src/terminal/)  │   │ (src/apprt/ipc/)     │   │ (wuffs / kitty)     │
 │                  │   │                      │   │                     │
 │ never fails on   │   │ fail-closed token    │   │ media policy gated  │
 │ malformed input  │   │ (auth.zig)           │   │ by host options     │
 └────────┬─────────┘   └──────────┬───────────┘   └──────────┬──────────┘
          │                        │                          │
          │  terminal state (trusted once parsed)             │
          ▼                        ▼                          ▼
 ┌──────────────────────────────────────────────────────────────────────────┐
 │ HOST CAPABILITIES — capability-gated, never ambient                       │
 │ clipboard read/write · desktop notification · progress report ·           │
 │ open URL · kitty image file media · paste confirmation                    │
 └──────────────────────────────────────────────────────────────────────────┘
          │
          ▼
 TRUSTED ── host application, user's filesystem, user's session
```

The design principle: **the parser is defensive about bytes and permissive about
nothing else.** Anything that reaches outside the terminal (clipboard, files,
notifications) is routed through a host callback that the embedder must explicitly
install.

---

## 2. Untrusted input handling

### The parser does not fail on hostile bytes

`ghostty_terminal_vt_write` is documented to **never fail**:

> Any erroneous input or errors in processing the input are logged internally but do
> not cause this function to fail because this input is assumed to be untrusted and
> from an external source; so the primary goal is to keep the terminal state
> consistent and not allow malformed input to corrupt or crash.

That is the right contract: a terminal must survive `cat /dev/urandom` without
taking down the session, and a partial escape sequence must leave usable state
rather than an error the host has to interpret.

### Paste is a separate trust decision

Pasted text is not the same as program output: it arrives from the user's clipboard
and may contain control characters that a shell would interpret as commands.

`include/ghostty/vt/paste.h` provides:

| API | Purpose |
|---|---|
| `ghostty_paste_is_safe(data, len)` | Conservative check; true only when the data contains no unsafe control bytes |
| `ghostty_terminal_paste(...)` | Writes only the first text representation; rejects with `GHOSTTY_REJECTED` **and writes nothing** unless `allow_unsafe` is set |
| `ghostty_paste_encode(...)` | Encodes without a terminal: bracketed paste wrapping and unsafe-byte stripping (NUL, ESC, DEL, and similar) |

The rejection-then-confirm pattern is deliberate: the host gets a clean
"rejected, nothing written" signal, shows the user a confirmation, and only then
retries with `allow_unsafe`. Nothing is written speculatively.

### Fuzzing

Upstream ships AFL++ harnesses in `test/fuzz-libghostty/` with 4,002 seed files and
three targets (`osc`, `parser`, `stream`), plus `replay-crashes.nu`. The G2
acceptance criterion is "zero new crashes on the corpus".

**Not verified here.** No fuzz run was executed on 2026-09-17. Treat the corpus as
available tooling, not as a current assurance.

---

## 3. IPC authorization requirement

**Requirement:** an unauthenticated IPC channel that accepts `pane.write` is
arbitrary code execution in the user's shell. Authentication is therefore a
correctness requirement, not a hardening nicety.

The v1 protocol spec ([`src/apprt/ipc/protocol.md`](../src/apprt/ipc/protocol.md)
§5) and the implementation (`src/apprt/ipc/auth.zig`) specify:

| Control | Behaviour |
|---|---|
| Required for | **Every** command except `ping` |
| `ping` exemption | Deliberate: lets an agent probe liveness and version without a secret |
| Token sources, in order | `KHOSTTY_IPC_TOKEN`, then a token file (`KHOSTTY_IPC_TOKEN_FILE`, else `ipc.token` beside the socket) |
| Missing token | **Fail-closed.** Every authenticated command is rejected with `unauthorized`. The server never runs unauthenticated. |
| Comparison | Constant-time (`std.crypto.utils.timingSafeEql`), length checked first in a way that does not leak length through early-exit timing |
| Token generation | `std.crypto.random`, 32 bytes, hex-encoded (64 chars) |
| Token file permissions | Expected `0600`; loose permissions are **logged, not refused** |

Socket placement also matters, and the spec follows the platform convention:

| Platform | Path |
|---|---|
| macOS | `~/Library/Caches/khostty/ipc.sock` |
| Linux/BSD | `$XDG_RUNTIME_DIR/khostty/ipc.sock` (fallback `/tmp/khostty-$UID/ipc.sock`) |
| Override | `KHOSTTY_IPC_SOCKET` |

`$XDG_RUNTIME_DIR` is per-user and mode-restricted, which is the correct default.
The `/tmp` fallback is the weakest option and depends on the `-$UID` suffix and
directory permissions for isolation.

### What is not yet true about IPC

| Gap | Why it matters |
|---|---|
| `server.zig` exists (1,238 lines, 14 tests) but is not wired into a runtime | The accept loop and client wire types are covered end to end (`Server.bind` / `Server.start` / `Client.connect` round-trip tests), but no running `khostty` exposes the socket, so the auth path is exercised in-process, not under a real GUI. |
| `app_host.zig` exists (574 lines, full `Host` vtable) but is not wired into a runtime | The `Host` vtable is implemented and exercised against `fake_host.zig` in tests; it is not yet invoked from GTK or any other app runtime, so the `windowed_vtable` path is reachable only through the test build. |
| Not wired into any runtime | No running Khostty exposes the socket (build graph has `test-agent-ipc` at `build.zig:79-508` for in-process coverage, but no GUI runtime constructs `Server.bind`). |
| Concurrency untested under a real runtime | The spec promises "concurrent pane operations do not deadlock"; the in-process tests cover it, but the GTK runtime wire-up is the only true e2e. |
| Scope of tokens | One token grants all commands. There is no per-command or per-pane capability granularity. |
| No rate limiting | No documented bound on commands per connection (Phase B3 will add `max_connections` + per-connection token-bucket). |
| Loose token-file permissions tolerated | Logged only; a world-readable token would still work |
| `pane.focus` and `pane.search` return `error.Unsupported` on GTK | `app_host.zig:177-178` (focus) and `app_host.zig:208-232` (search) refuse the call against the real runtime because no core or apprt API focuses a surface by id and there is no synchronous "scan and return matches" core API. The agent protocol maps this to `host_unsupported`; agents should treat it as "ask the user", not as a transient failure to retry. |

The first three are the wire-up gap, not implementation gaps. The next two
are design weaknesses to settle before the protocol ships. The
`pane.focus` / `pane.search` row is an honest disclosure, not a deferred
feature: closing either requires upstream-core API work that is out of
fork-only scope.

---

## 4. Windows transport weakness (scaffold)

`src/apprt/windows/ipc.zig` sketches a named pipe for the Windows equivalent of a
Unix domain socket. Observed 2026-09-17 03:58 PT (rewritten by commit `1e6687dd2`).

**The pipe path is correct and unit-tested.** The constant is:

```zig
pub const PIPE_PREFIX: []const u8 = &.{
    backslash, backslash, '.', backslash, 'p', 'i', 'p', 'e', backslash,
    'k',       'h',       'o', 's',       't', 't', 'y', '-',
};
```

(`src/apprt/windows/ipc.zig:34-39`.) Every byte is spelled individually on purpose:
Zig has no raw strings, so a `"\\.\\pipe\\khostty-"` literal has to double every
backslash, and an earlier revision of this constant lost exactly that doubling.
The unit test at `windows/ipc.zig:181-200` asserts byte positions (length 17,
two leading backslashes, `.`, `\`, `pipe`, `\`, `khostty-`) rather than comparing
two literals, so a regression cannot agree with itself.

**ACL decided, not yet wired into `Server.init`.** The chosen DACL is:

```zig
pub const PIPE_DACL_SDDL: []const u8 = "D:P(A;;GA;;;OW)";
pub const PIPE_HANDLE_INHERITABLE: bool = false;
```

(`src/apprt/windows/ipc.zig`.) `D:P(A;;GA;;;OW)` is the SDDL form of "Deny
nothing, then Allow Generic All to the Owner (the server process's user
account)"; the unit test asserts the byte shape (`D:P` prefix, `;;;OW)`
suffix, single parenthesized ACE). `PIPE_HANDLE_INHERITABLE = false` keeps
the pipe handle out of child processes spawned by the server. The DACL and
the inheritable-handle flag are passed to `CreateNamedPipeW` once
`Server.init` moves past `error.Unimplemented`; today the call still returns
`Unimplemented`, so the authorization model is documented and tested in
isolation, not yet exercised end to end.

`MessageFrame` (`extern struct { action: u16, length: u32 }`, payload packed after
the header) is unchanged, and every operation still returns
`error.Unimplemented`, so none of this is reachable today. **The Windows IPC
transport has its authorization design, including an explicit DACL and a
test asserting it; what remains is wiring it into `Server.init`.**

---

## 5. Memory safety

### Why the model is tractable

The engine is written in Zig, and the C ABI exposes **opaque handles** rather than
raw struct pointers for the important types:

```c
GhosttyTerminal term = NULL;
ghostty_terminal_new(NULL, &term, 80, 24);
/* term is opaque; you cannot dereference or forge it */
ghostty_terminal_free(term);
```

That is materially safer than a C library that hands out `struct` pointers.
Ownership rules are documented per API.

### Ownership rules that matter

| Rule | Consequence if violated |
|---|---|
| Library-owned buffers from `*_alloc` must be released with `ghostty_free` | Leak, or double-free if freed twice |
| Borrowed pointers (`GhosttyString`, row/cell handles, search match buffers) are valid only until the next mutating call on the object that produced them | Use-after-free that reads plausible data rather than crashing |
| A freed handle must not be used | Use-after-free |
| Callbacks must not unwind across the FFI boundary (Rust) | Undefined behaviour |
| Callbacks must not re-enter `vt_write` on the same terminal | Documented as no-reentrancy; violation is a logic error |

### How the wrappers defend against these

| Wrapper | Defence |
|---|---|
| Rust | RAII `Drop` on all wrapper types; `unsafe` confined to `src/ffi.rs` with documented invariants; borrowed values tied to Rust lifetimes so the borrow checker rejects outliving uses |
| Rust | `tests/abi_layout.rs` asserts layout against the library's own `ghostty_type_json()` manifest, so a struct change fails loudly instead of corrupting memory |
| Rust | `--features bindgen` regenerates bindings from the C headers and fails on drift |
| WASM | `js/memory.js` reacquires `ArrayBuffer`/typed-array views whenever the buffer identity or length changes, because an exported call can grow linear memory and leave host views detached. A stale view still reads and writes, producing plausible garbage rather than a fault. |
| WASM | Shared helper copies **before** freeing library-owned buffers, because the reverse order is a silent use-after-free |
| WASM | All struct layout read from the type manifest at runtime; no hardcoded offsets |

### AST-level static analysis

There is **no** Clippy-on-Zig equivalent wired up, and no sanitizer run is recorded.
`zig build test-valgrind` exists and `valgrind.supp` is maintained, but it was not
executed on 2026-09-17.

---

## 6. Host capabilities as attack surface

These are the sequences through which untrusted program output can reach outside
the terminal. Each is gated by an option the embedder controls, and each is
therefore a decision the embedder must make explicitly.

| Capability | Trigger | Gate |
|---|---|---|
| Clipboard **read** | OSC 52 `?`, OSC 5522 | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ` |
| Clipboard **write** | OSC 52 | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE` |
| Kitty image from **file** | APC image payload | `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE` |
| Kitty image from **temp file**, restricted to a directory | APC image payload | `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE` (the allowed directory is supplied by the host) |
| Kitty image from **shared memory** | APC image payload | `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM` |
| Image storage bounds | APC image payload | `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` |
| APC payload size bounds | APC sequences | `GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES`, `…_APC_MAX_BYTES_KITTY` |
| Desktop notification | OSC 9, OSC 777 | `GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION` |
| Progress report | OSC 9;4 | `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT` |
| Unknown sequence | any unrecognised escape | `GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE`, `…_UNKNOWN_MAX_BYTES` |
| Remote inquiry responses | ENQ, XTVERSION, device attributes | `…_ENQUIRY`, `…_XTVERSION`, `…_DEVICE_ATTRIBUTES` |
| Title / working directory | OSC 0/2, OSC 7 | `…_TITLE`, `…_PWD`, `…_TITLE_CHANGED`, `…_PWD_CHANGED` |

The safe default stance for an embedder processing untrusted output: leave the
clipboard and file-backed image media **unset**, and bound APC and unknown-sequence
sizes.

The file-backed image media deserves emphasis. A terminal that will read an image
from a path supplied by the program it is displaying has handed that program an
arbitrary-file-read primitive against the user's account. `libghostty-vt` makes this
opt-in and directory-restricted for the temp-file medium; the embedder still has to
decide.

---

## 7. WASM specifics

The WASM build has a structurally **smaller** attack surface than the native build:

| Property | Consequence |
|---|---|
| `wasm32-freestanding` | No PTY, no filesystem, no clock, no timestamps |
| Kitty graphics disabled (16 functions excluded) | No file-backed or shared-memory image media at all; sequences are parsed and ignored |
| No ambient authority | A module cannot touch the host except through declared imports (currently none) |
| Linear memory, no raw pointers on the host side | No host address-space access |

Residual risks are memory-safety bugs inside the module and any imports the host
chooses to supply via `ImportOverrides`. The default is zero imports.

---

## 8. Build and supply chain

| Control | State |
|---|---|
| Dependency pinning | 15 dependencies in `build.zig.zon` each pin a URL **and** a content hash |
| Dependency source | `deps.files.ghostty.org` (upstream-controlled) |
| Vendored code | `vendor/glad`, `vendor/nerd-fonts` committed in-tree |
| C/C++ in the build | `wuffs` (image decoding), `simdutf`, `highway` — upstream-vendored |
| npm dependencies | **None.** `wasm/package.json` has zero dependencies; tests use `node:test`; `typescript` is fetched on demand |
| Rust dependencies | **None** at runtime; `bindgen` is an optional build dependency behind a non-default feature |
| Secrets in the tree | None found: no `.env`, no credential files tracked, no key-shaped literals in `src/`, `include/`, `khostty-vt/src`, `khostty-go`, or `wasm/js` |
| SAST / secret scanning | **None configured.** G0 stripped upstream's Scorecard workflow as boilerplate; no CodeQL or equivalent replaced it |
| Dependency update automation | `dependabot.yml` is present |
| Open Dependabot alerts | **One, triaged 2026-09-29 and deliberately left open** — alert #1, `CVE-2025-71176` / `GHSA-6w46-j5rx-g56g`, `pytest` "vulnerable tmpdir handling" (medium), manifest `khostty-python/uv.lock`. The advisory covers pytest **through 9.0.2**; the fix line is **9.0.3**, which requires **Python ≥3.10**, and no patched 8.x exists (8.4.2 is the final 8.x release). This package declares `Requires-Python: >=3.8`, so the vulnerable resolution cannot be removed without dropping 3.8/3.9 support. Scope is bounded: `pytest` is a `test` **extra**, not a runtime dependency — the wheel's `METADATA` carries only `Requires-Dist: cffi>=1.15` plus `pytest>=7; extra == "test"`, and no `pytest` file is present in the shipped artifact. The 3.10+ lane already resolves to the patched 9.1.1, and CI runs Python 3.11. The residual risk is a local multi-user machine running the test suite on 3.8/3.9. Re-triage if the package drops 3.8/3.9 or a patched 8.x is backported. |
| **CI does not run on push** | **Confirmed broken 2026-09-29.** GitHub Actions is enabled for this repository (`actions/permissions` → `enabled: true`), yet `actions/runs?event=push` returns `total_count: 0` across the repository's entire history and for every one of the 12 registered workflows. `ci.yml` declares `push: branches: [main, master, develop]`; three pushes to `main` after that trigger was added produced no run, and a controlled push of `main` to a temporary `develop` branch (a branch the filter already names) also produced none. Only the one `workflow_dispatch` run (`36584839303`) has ever executed. Root cause is repository-level, not a workflow defect: this is a **fork**, and GitHub disables Actions on forked repositories by default; enabling it requires an explicit, per-repository action in the fork's **Settings → Actions → General → "Enable Actions"** (plus "General → Workflow permissions → Read and write" for anything that needs to write). The `workflow_dispatch` path still works, so CI is reachable on demand until the setting is flipped. Until then, **no automated gate runs on any push to `main`**, and the local verification that stands in for it is the documented manual command set in [INSTALL.md](INSTALL.md) and the re-verify record in `docs/sessions/20260927-0.1.0-reverify/README.md`. |

The absence of any automated security scanning is a real gap. The npm and Rust
dependency footprint is admirably small, which reduces risk, but nothing
continuously checks the C/Zig surface or the vendored code.

---

## 9. Threat model summary

| Threat | Control | Status |
|---|---|---|
| Malformed VT bytes corrupt or crash the terminal | `vt_write` never fails; input treated as untrusted | Designed and exercised by the conformance `edge` category (16 cases) |
| Hostile clipboard content executed as commands | `paste_is_safe`, reject-then-confirm, unsafe-byte stripping | Implemented upstream |
| Unauthorized local process drives the terminal | Token auth, fail-closed, constant-time compare | Designed; **not reachable** (no server) |
| Untrusted output reads user files via image media | Opt-in, directory-restricted image media | Implemented as host-gated options |
| Untrusted output exfiltrates clipboard | Clipboard read is a host-gated callback | Implemented upstream |
| Memory corruption at the FFI boundary | Opaque handles, RAII wrappers, ABI manifest assertions, copy-before-free | Implemented in Rust and WASM wrappers |
| ABI drift corrupts memory silently | `ghostty_type_json()` manifest + layout tests | Implemented |
| Other process in the session connects to the Windows pipe | Named pipe DACL `D:P(A;;GA;;;OW)` + non-inheritable handle | **Designed and unit-tested**; not yet wired into `Server.init` (still `error.Unimplemented`) |
| Compromised build dependency | Content-hash pinning | Implemented |
| Known-vulnerable dependency introduced | Automated scanning | **Not implemented** |
| Privilege escalation from the terminal process | OS sandboxing | **Not attempted.** The terminal runs with the user's full privileges, as upstream does. |

---

## 10. Reporting a vulnerability

This is a fork. Two upstreams are in play:

1. **If the issue is in `libghostty-vt` or the terminal engine** — it affects
   upstream Ghostty. Report to upstream through their security process. Fixing it
   only in the fork would leave upstream users exposed and make future merges
   harder.
2. **If the issue is in a Khostty-only surface** (`khostty-vt/`, `khostty-go/`,
   `wasm/`, `src/apprt/windows/`, `src/apprt/ipc/`, `conformance/`) — report to the
   Khostty maintainers.

Do not open a public issue containing a working exploit. Contact the maintainers
privately, allow time to assess and fix, and coordinate disclosure.

Nothing in this repository currently constitutes a supported security-response
commitment; there is no published security contact and no release to patch. Treat
this section as the intent, not a guarantee.

---

## 11. What is not defended (explicit list)

Listing these prevents them from being mistaken for solved:

- No OS sandbox around the terminal process
- No automated vulnerability scanning, secret scanning, or SAST in CI
- No fuzzing run recorded, and no sanitizer or Valgrind run recorded
- No IPC server, so no end-to-end authorization verification
- No per-command or per-pane token scoping; no rate limiting
- Windows named pipe has its authorization model documented and unit-tested (`PIPE_DACL_SDDL = "D:P(A;;GA;;;OW)"`, `PIPE_HANDLE_INHERITABLE = false`), but not yet wired into `Server.init` (§4)
- No security review of the Rust, Go, or WASM wrappers by anyone other than their authors
- No independent threat-model review
- No release, therefore no security-fix channel

---

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — where each trust boundary sits
- [AGENT.md](AGENT.md) — the IPC surface in practical detail
- [CONTRIBUTING.md](CONTRIBUTING.md) — the review checklist, including secrets
- [BUILD.md](BUILD.md) — dependency resolution and the current build blocker
- [`src/apprt/ipc/protocol.md`](../src/apprt/ipc/protocol.md) — the auth design in full
- `AI_POLICY.md` — upstream's AI usage policy (disclosure requirements)
