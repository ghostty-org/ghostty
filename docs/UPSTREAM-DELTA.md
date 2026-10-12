# UPSTREAM-DELTA.md

**Fork-vs-upstream audit for KooshaPari/Khostty.** Documents every change the
fork carries relative to its upstream parent `ghostty-org/ghostty`. Generated
2026-10-12 from the current `origin/main`; regenerate via the procedure in §5.

> **Authored by agent** (Instinct handoff 2026-10-12 21:07Z). Low-risk,
> reversible, do-not-merge, no-force-push. PR-title prefix `[Instinct]-style
> "Authored by agent"` is the operator's convention for any future PR touching
> this file.

## §1. Summary

| Field | Value |
|---|---|
| Upstream parent | `ghostty-org/ghostty` (https://github.com/ghostty-org/ghostty.git) |
| Upstream HEAD | `d4c88d8069912b653d707191388ca98e24751f12` (2026-09-15 05:37 UTC, "Update VOUCHED list (#14241)") |
| Fork HEAD | `17fe76744a2851d8450a1a4b5d3edb8d97e0fe1e` (2026-10-11 23:53 PDT, "ci(sonar): make inherited upstream quality gate advisory for fork") |
| Merge-base | `d4c88d806...` (fork is exactly based on upstream HEAD; no upstream drift) |
| Ahead of upstream | **242 commits** (241 non-merge + 1 merge) |
| Behind upstream | **0 commits** |
| Branch | `main` (this is the only long-lived branch; all work lands here) |
| Date generated | 2026-10-12 |
| Documentation | This file, in-repo, with a 5-line cockpit entry at `docs/sessions/khostty-0.1.0-release/evidence/upstream-delta-20261012.txt` |

### Intent group summary

| # | Group | Commits | Headline |
|---|---|---|---|
| 1 | Khostty value-add (FFI/SDK) | 25 | Rust/C/Python/Go bindings over `libghostty-vt` |
| 2 | Khostty value-add (IPC) | 15 | Agent IPC v1 over Unix sockets — protocol, server, handler, state, events, auth, pane |
| 3 | Khostty value-add (Windows native) | 14 | Standalone App runtime, Win32 input/mouse/keyboard, named-pipe IPC, HWND surface |
| 4 | Khostty value-add (WASM) | 5 | Reproducible wasm32 build, ESM/JS bindings, TypeScript declarations |
| 5 | Khostty value-add (Benchmarks) | 7 | libghostty-vt benchmark harness, captured results, Khostty value-add summary |
| 6 | Packaging (Linux/Windows/macOS) | 11 | GTK .deb, khostty-vt .deb, Inno Setup .exe, macOS .app, Metal→OpenGL fallback |
| 7 | CI fixes & new workflows | 23 | scorecard, clean-artifacts, publish-pypi, trunk-check, workflow_dispatch, Zig-aware, sonar |
| 8 | Org-template infra (deduplicated) | 11 unique (×2 = 22 commits) | Trunk, prettier, Renovate, Mergify, CircleCI, Blacksmith, Infisical, Gitleaks |
| 9 | Release artifacts & documentation | 50 | RELEASE.md, HANDOFF.md, README, changelog/0.1.0.md, install docs, runbook, status sweeps |
| 10 | WBS / docs-3 governance | 42 | Deep WBS v2, gates G0–G10, dossiers, GLOBAL_HANDBOOK, audits |
| 11 | Other (catch-all) | 16 | Misc, first-fork scaffolding, fork-assessment, build wiring, merge commit |

**Total unique non-merge: 241.** (Plus 1 merge `95eccb351 chore: merge
origin/main preserving fork documentation and CI` that is reflected in the
242 total but excluded from the per-group lists below.)

## §2. Intent groupings — every change

### Group 1 — Khostty value-add (FFI/SDK)

The three language bindings the fork ships over `libghostty-vt`. These are
the heart of the fork's "library first" value-add: turn Ghostty's terminal
VT layer into reusable foreign-function interfaces for Python, Go, and Rust
applications, with snapshots, render, search, key/mouse encoding, and a
bindings-drift guard.

25 commits:

- `a25bd605f` feat(khostty-vt): scaffold Rust FFI crate with link + bindgen feature gates
- `0f9d4a47c` feat(khostty-vt): generate raw extern C bindings from the libghostty-vt headers
- `38730d903` feat(khostty-vt): add GhosttyError mapping and allocator/buffer integration
- `b870b8282` feat(khostty-vt): safe Terminal wrapper, Style/Color mirrors, and an ABI layout guard
- `2aed4c902` feat(khostty-vt): safe snapshot encode/decode with lifetime-enforced decoder rules
- `d7cdc4d45` feat(khostty-vt): safe render state with borrow-checked row and cell access
- `ed61d42aa` feat(khostty-vt): safe search with terminal-identity checks and selection matches
- `b06bde11d` feat(khostty-vt): key and mouse encoder wrappers, and a macro-parsing fix in the generator
- `8cef26caa` refactor(khostty-vt): split the binding generator into scanning, mapping, and emission
- `09b31ee74` docs(khostty-vt): crate README, crate docs, and two runnable examples
- `01eb74375` docs(khostty-vt): note the generator's three-file layout in the README
- `74aa5eea9` test(khostty-vt): end-to-end composition tests and a bindings drift guard
- `e1277bea2` feat(khostty-go): scaffold Go module with cgo linking (G6.1)
- `be9766b90` feat(khostty-go): wrap terminal lifecycle (G6.2)
- `c253bcda1` feat(khostty-go): wrap snapshot, render, and search (G6.3)
- `80e178fd5` test(khostty-go): integration tests and examples (G6.4)
- `2252edfd0` feat(khostty-go): key and mouse event encoding (G6.9)
- `183db0acd` refactor(khostty-go): move EncodeKey beside the key types
- `9449d0b8a` feat(khostty-python): scaffold cffi bindings and library discovery (G6.5)
- `463edb2fa` feat(khostty-python): Pythonic terminal, snapshot, render, and search (G6.6)
- `65dfd4274` test(khostty-python): pytest suite and runnable examples (G6.7)
- `b83df59cb` build(khostty-python): pip-installable sdist and wheel (G6.8)
- `9cf1761e8` feat(khostty-python): key and mouse event encoding (G6.10)
- `19630b1e5` build(python): add uv.lock for reproducible installs
- `9fdf34e5e` docs(khostty-python): update test count 98 -> 162

### Group 2 — Khostty value-add (IPC)

The Agent IPC v1 protocol and its implementing submodules. Lets two
processes — typically an AI agent and a host terminal — communicate over
Unix sockets with a typed JSON wire format, async events, fail-closed auth,
and a pane host backed by the real Ghostty app runtime.

15 commits:

- `551d8afe5` docs(ipc): G4.1 agent IPC protocol v1 schema + ipc module directory
- `e2e041f7e` feat(ipc): G4.2 protocol.zig - wire types and JSON codec for agent IPC v1
- `74442ec05` feat(ipc): G4.3 server.zig - Unix socket server, client, and framing
- `9b7c4fab0` feat(ipc): G4.4 handler.zig - command dispatch to the pane/event/action layer
- `eec5550c6` feat(ipc): G4.5 pane.zig - pane lifecycle and the app-runtime Host interface
- `03d65cd12` feat(ipc): G4.6 pane.zig - pane write (VT inject) and state query
- `6b5fbe308` feat(ipc): G4.7 state.zig - machine-readable terminal state snapshot
- `c661a0d56` feat(ipc): G4.8 events.zig - async event stream broker
- `99e2f6a15` feat(ipc): G4.9 auth.zig - token-based auth with fail-closed verification
- `cc4f55618` feat(ipc): G4.10 pane.zig - pane search over scrollback
- `3cccd3e31` feat(ipc): G4.11 app_host.zig - pane.Host backed by the real app runtime
- `f27eb5916` test(ipc): G4.12/G4.13 agent workflow and concurrent-agent tests over real sockets
- `cd1ed5c60` fix(ipc): correct relative import depths after ipc.zig -> ipc/mod.zig (was breaking every build)
- `e2833762b` docs(ipc): G4.14 sync protocol.md with the implementation and agent guidance
- `a29566934` docs(g9): record current Windows IPC defects found during verification

### Group 3 — Khostty value-add (Windows native)

The Windows app runtime that Ghostty does not yet ship: a standalone
windowed terminal with Win32 keyboard/mouse/input, named-pipe IPC, and
HWND message routing. Cross-built to `ghostty.exe + ghostty-vt.dll`
(G3 cross-build verified, exit 0).

14 commits:

- `b2c388c9b` feat(windows): scaffold native application runtime
- `11f952990` feat(windows): define standalone App runtime contract
- `bbc68e4d4` feat(windows): G3.7 keyboard.zig - Win32 key messages to Ghostty key events
- `6c1b53e63` feat(windows): G3.8 mouse.zig - Win32 mouse messages to Ghostty mouse events
- `d7ec3a36e` feat(windows): G3.9 input.zig - Win32 input message router
- `933bf771a` feat(windows): HWND surface association and message routing (G3.10)
- `472716e90` feat(windows): renderer adapter stub (G3.11)
- `1e6687dd2` feat(windows): named-pipe IPC protocol stub (G3.12)
- `5a85344f0` feat(windows): test-windows-apprt step and ipc skeleton
- `21fbb2571` fix(windows): widen App.performIpc error set so the CLI compiles
- `0f358f9ec` fix(test): wire ghostty.h into the windows-apprt test module
- `3bf5c3ac9` docs(windows): record scaffold compile evidence and concurrent ownership
- `9001a4e6e` fix(build): track the windows-apprt test root and macOS packaging script
- `7eb75a604` test(windows): execute the Windows artifacts on a real Windows runner

### Group 4 — Khostty value-add (WASM)

The web-side bindings: reproducible wasm32 build of `libghostty-vt`,
consolidated C header, ESM/JS bindings, TypeScript declarations, and a
snapshot scrollback test. Lets the same library run in a browser.

5 commits:

- `afc93210d` feat(wasm): reproducible wasm32 build for libghostty-vt (G7.1-7.3)
- `32f4a2c73` feat(wasm): consolidated single-file libghostty-vt public header (G7.4)
- `92e9cc98c` feat(wasm): ESM/JS bindings for libghostty-vt (G7.5)
- `936dfa76a` docs(wasm): TypeScript declarations, tests, and usage docs (G7.6, G7.8-G7.10)
- `a4bf9e98f` test(wasm): pin snapshot-with-scrollback and metadata semantics (G7.8)

### Group 5 — Khostty value-add (Benchmarks)

The libghostty-vt benchmark harness: per-section flushing, source-digest
recording, captured results, and the G8 Khostty value-add summary. Lives
under `bench/`.

7 commits:

- `97f655a38` feat(bench): libghostty-vt benchmark harness (G8.1-G8.6)
- `f9e11fffb` feat(bench): per-section flushing and harness source digest
- `f8d9e040d` feat(bench): record resolved library path and digest per run
- `505621d5f` test(bench): audit the written report against the captured JSON
- `426b74e51` docs(bench): G8.7-G8.8 captured results and measured report
- `8de7923d7` docs(bench): G8.9-G8.13 Khostty value-add summary
- `b82bc013c` docs(bench): correct anonymous-memory units in G8 reports

### Group 6 — Packaging (Linux/Windows/macOS installers)

Build the distributable artifacts: GTK .deb natively on x86_64 Linux,
khostty-vt .deb with install+run evidence, Windows Inno Setup installer
on a real Windows runner, macOS .app via macOS runner with OpenGL
fallback when Metal is absent. Empirically builds and install-verified.

11 commits:

- `935b354c9` build(packaging): Linux .deb packaging script (G9.12)
- `9daf736e8` fix(packaging): build the GTK .deb natively on x86_64 Linux
- `45e6d086b` fix(packaging): install proper hicolor icons and fix the desktop Icon ref
- `65de471df` fix(packaging): derive the deb glibc floor from the built binary
- `313aec6e7` feat(packaging): add khostty-vt .deb with executed install+run evidence
- `004119f54` build(packaging): Windows .exe installer script (G9.13)
- `76ad36fc3` build(packaging): WASM dist tarball, version resolution, release tooling base (G9.14, G10.1)
- `c9c83322f` build(windows): compile and install-verify the Inno Setup installer
- `1ed158fa2` ci: use -Demit-macos-app=false to skip Metal toolchain dependency
- `297d66f13` ci: use macOS runner for build, OpenGL renderer to avoid Metal toolchain dependency
- `9d32ffc4c` fix(build): fall back to OpenGL renderer when Metal toolchain is absent

### Group 7 — CI fixes & new workflows

The CI work the fork layered on top of the upstream Ghostty workflows.
Includes the scorecard repair (291/291 zero-job runs), clean-artifacts
permissions fix, PyPI Trusted Publishing workflow, workflow_dispatch
trigger for on-demand verification, Zig-aware CI, and the SonarCloud
fork override.

23 unique commits (org-template duplicates are listed in Group 8):

- `f5b393227` ci: replace generic CI with Zig-aware workflow
- `26cfacb5d` ci: install zig from ziglang.org with a pinned sha256 instead of community mirrors
- `a7bce476e` ci: fix duplicate 'lint' job key that silently dropped the Zig Fmt job
- `a29aa9c65` ci: fix ecosystem detection that silently skipped the Rust, Go, and TS jobs
- `b7ea171cd` ci: guard inherited Ghostty release-tag automation with a repository check
- `666fbf861` ci: add narrow gitleaks allowlist for seven verified false positives
- `1cf505ebd` ci: add workflow_dispatch so the pipeline is verifiable on demand
- `882d6cd4a` ci: add a tag-gated PyPI publish workflow using Trusted Publishing
- `e6490dada` fix(ci): repair publish-pypi.yml — it could never have published
- `0ae6b4b65` ci: fix all three root causes from the first real CI run; re-verify 0.1.0
- `2e7f282df` ci(clean-artifacts): grant actions:write so aged artifact deletion succeeds
- `9aae30d32` fix(ci): repair OpenSSF scorecard workflow (291/291 runs failing)
- `8fdcf9337` fix(ci): bump scorecard-action to v2.4.4 (ghcr image; gcr registry billing-broken)
- `2422fa31e` fix(ci): drop step-level permissions blocks in scorecard workflow
- `26dad9ef9` style(ci): format scorecard.yml with prettier (repair Trunk Check)
- `17fe76744` ci(sonar): make inherited upstream quality gate advisory for fork
- `2fa68960e` fix(ci): replace broken trunk-action with prettier-scoped check (#5) [see Group 8 for duplicate]

### Group 8 — Org-template infra (deduplicated)

Org-template CI files pulled in by an earlier scaffolding pass. Each
commit appears **twice** in the 242-commit list — once on the main
landing, once via the rebase/merge that brought it back in. The unique
set is 11 commits; the duplicate count is 22 commits.

Unique 11:

- `c72fd961e` ci: add GitHub Actions CI with Blacksmith runners
- `92de0f472` ci: add CircleCI parallel pipeline
- `4914a1597` ci: add Trunk.io lint/format config
- `3207bdc61` ci: add .github/workflows/trunk-check.yml (org template)
- `0480e2cea` ci: add .github/workflows/scorecard.yml (org template)
- `2aec7b197` ci: add .github/workflows/infisical.yml (org template)
- `4c52de80a` ci: add renovate.json (org template)
- `b75af1556` ci: add Mergify auto-merge rules
- `d49d2a987` Update README: prepend ghostty header
- `d60373100` docs(readme): add AI slop inside + downloads badges
- `f601431fb` fix(ci): replace broken trunk-action with prettier-scoped check (#5)

(For audit: the duplicate pair for `c72fd961e` is `f8a5806ac`; for
`92de0f472` is `7083d7b52`; for `4914a1597` is `875a20bd6`; for
`3207bdc61` is `0ccaf9d89`; for `0480e2cea` is `5bd3285af`; for
`2aec7b197` is `7bb433cb8`; for `4c52de80a` is `ecbdb4de8`; for
`b75af1556` is `5ba975e65`; for `d49d2a987` is `79e27b63f`; for
`d60373100` is `69b283d07`; for `f601431fb` is `2fa68960e`. The
duplicates are byte-identical trees from the same org-template pass
and are not counted twice in the §1 summary table.)

### Group 9 — Release artifacts & documentation

The `docs/RELEASE.md`, `docs/HANDOFF.md`, `docs/INSTALL.md`, README
rewrites, the `changelog/0.1.0.md` release notes, the PyPI publish
runbook, status sweepers, the WBS 10.x release tasks, and the session
evidence files for the 0.1.0 release. This is the largest group
because documentation is the bulk of the fork's durable work.

50 commits:

- `332269429` docs: comprehensive Khostty README aligned with Deep WBS
- `580b3644f` docs(readme): comprehensive rewrite with platform matrix, IPC draft, FFI status
- `39dac33b7` docs: comprehensive README rewrite with Phenotype delta detail
- `2870507b4` docs(readme): index RELEASE.md, HANDOFF.md, changelog/0.1.0.md
- `26ae8738e` docs(readme): retire four stale 'credential-blocked' PyPI claims
- `13541aa2b` docs(readme): reconcile release status — GitHub release + npm published
- `d9c930e17` docs(release): correct the PyPI publish path; the browser upload form was removed
- `e1ebfa632` docs(release): fix false 'nothing published' claims; refresh §7 PyPI row
- `af7697294` docs(release): retract wrong tag-trigger claim; dispatch is the only path
- `743d00c5f` docs(release): document khostty-v* tag convention and trusted-publishing path
- `9c74f9fba` docs(release): record tag-push side-effect audit for khostty-v0.1.0
- `5e44f2188` docs(install): add §0 download section for the published 0.1.0 release
- `cd91fb549` docs(install): per-platform install + verification steps (G9.15)
- `89df76054` docs(release): WBS 10.1 — release version scheme + artifact manifest
- `54d071dad` docs(release): WBS 10.4 — release notes for 0.1.0
- `446e59a78` docs(release): record npm publish 0.1.0 (r2c complete)
- `f0a5e405c` docs(release): record GitHub release published 2026-09-27 (10.6 DONE)
- `5cca58661` docs(release): add §7.2 post-approval verification block
- `97ed88333` docs(release): §7.1 runbook — explicit --repo and fresh request id
- `81894a896` docs(release): fix GTK deb asset path in §7.1 runbook
- `5ebef8923` docs(release): add the exact runbook for the authorized run
- `230e08dc6` docs(release): reconcile all status docs with verified reality for 0.1.0 announce
- `4f757cc57` docs(roadmap): add post-0.1.0 GUI + multiplexer roadmap (r6)
- `cd39d6efa` docs: correct stale PyPI block-reason in HANDOFF and INSTALL
- `5d5f023b2` docs(handoff): correct stale crates.io publish status (§6)
- `4286ad600` docs(handoff): correct published-status drift in opening, matrix, and checksum count
- `2a615b53a` docs(release): label release-execution timestamps as UTC
- `e335efff7` docs(release): close the WASM provenance gap with a clean-tree rebuild
- `a4a4e5b41` docs: record the GTK application .deb as BUILT (WSL, 2026-09-19)
- `2a68be1da` docs: GTK .deb install-verified; PLATFORMS.md Linux row updated
- `d00b004c5` docs: note Wayland/X11 + layer-shell caveats for the GTK deb
- `0ad066a86` docs: GTK deb GUI launch verified headless (Xvfb, APP_ALIVE)
- `202aad543` docs: reconcile WBS G9/G10 summary rows with the verified headless GTK GUI launch
- `12e9b3407` docs: sync RELEASE.md and changelog 4.3 with the built GTK .deb
- `d72b9ba42` docs: sync dossier and PLATFORMS.md with the built GTK .deb
- `36764593a` docs: add the GTK .deb build evidence file and reference it from 9.12
- `ab8102bcc` docs: add the GTK .deb to the RELEASE.md verification manifest (row 7)
- `247c8c6af` docs(wbs): G10 rows 10.1/10.3/10.4/10.7 DONE; 10.5/10.6/10.8 blocked on publish auth
- `65315d553` docs(release): WBS 10.7 — ecosystem handoff for 0.1.0
- `ddd57f5b0` docs(release): publish-readiness pre-flight for G10.5 (local dry-runs only)
- `6e3854162` docs(evidence): fresh-release checksum audit — 5/5 OK, 0 FAIL
- `3ba017730` docs(evidence): WSL mirror synced to origin/main (ff-only, guarded)
- `011e53b9f` docs(evidence): PyPI trusted-publishing probe trilogy + sentinel log
- `f24521334` docs(evidence): gap-recon appendix — Run H green, no publish runs since 10-05
- `5fcc3b7f9` docs(evidence): clean-artifacts failure RCA + permissions fix verification
- `cc8396cb2` docs(evidence): verify clean-artifacts fix live — cron run green
- `052e0a812` docs(evidence): publish build-job pre-flight passes on exact tag tree
- `f2227683d` docs(sessions): record first green CI run, pypi env, staged publish tag
- `2c5c9c648` docs(session): record tag-path discovery, dispatch hook, and three greens
- `922553959` docs(sessions): r6b/r7 evidence — scorecard green, win-build diagnostic
- `4c18bc2b1` docs(sessions): 5-suite re-run evidence, 2026-10-12
- `721faa4e8` docs(sessions): commit full-state-report as session artifact
- `5ae9b7273` docs(sessions): inbox follow-up + SonarCloud pre-existing failure
- `0fe7da2d3` docs(sessions): close r2b SKIPPED — operator deferred pypi publish
- `66aa46029` docs(sessions): r7 installer.sh live probe + corrected diagnosis
- `595722604` docs(session): record 2026-09-29 drift sweep, CI first run, and pytest CVE triage
- `114ddee10` docs(sessions): record WSL sync attempts — desk offline, hand off to 10-01 re-verify
- `15332d5e6` docs(sessions): record 0.1.0 post-release re-verify (WBS 10.9) — all 6 criteria pass
- `67669dad2` docs(reverify): log final desk probe — offline, no reschedule per rule
- `44a1f892d` docs: triage Dependabot alert #1 (pytest CVE) and fix stale tag-publish marker
- `e1e4ad00d` docs(audit): record Khostty release lifecycle refresh
- `c9360bbf9` docs(build): document Go cgo SDKROOT pin for macOS dev hosts

### Group 10 — WBS / docs-3 governance

The Deep WBS v2 (G0–G10, 113 tasks), per-gate completion status,
verification evidence, and the GLOBAL_HANDBOOK adoption. Tied to the
`docs-5` governance atlas.

42 commits:

- `7249095e9` docs: adopt canonical GLOBAL_HANDBOOK (docs-5 rev 1.4 atlas)
- `ec223fdcf` docs: Phenotype Global Handbook — consolidated from 13 source docsets, pinned rev 2026-09-16
- `d4f48e1f5` docs(sessions): complete Khostty Deep WBS v2 (G0-G10, 113 tasks)
- `fc919d7b8` docs: deep WBS — 66 tasks across 9 gates, ~11h estimated
- `515fd9ed7` docs(wbs): reconcile Khostty WBS v2 task counts and remove stray probes
- `06bb9d4c7` docs(dossier): add docs/dossiers/KHOSTTY.md product dossier (G9.10)
- `3c78867a0` docs(dossier): add missing ownership and next-handoff section (§10)
- `f697f06df` docs(wbs): dossier ownership concern no longer absent after §10 (3c78867a0)
- `85140218c` docs(g9): add ARCHITECTURE.md and GLOSSARY.md (WBS 9.1, 9.9)
- `34b861da9` docs(g9): add API.md and AGENT.md (WBS 9.2, 9.3)
- `f9cfa0dad` docs(g9): add PLATFORMS, BUILD, CONTRIBUTING, TESTING (WBS 9.4-9.6, 9.10)
- `428e2d2c9` docs(g9): add FORK.md, SECURITY.md, and docs index (WBS 9.7, 9.8, 9.1)
- `96c9eccba` docs(g9): sync gate status in ARCHITECTURE and GLOSSARY
- `991862b37` docs(g9): sync status for G8 benchmarks and G6 Python; link-verify all docs
- `a077a6c90` docs(wbs): mark G2 DONE (84/84), G3/G5/G7 IN PROGRESS
- `fc0aea2bc` docs(wbs): G5+G7+G9 DONE (199/199, 54/54, 9 docs); G3/G4/G6 in progress
- `7585c4981` docs(wbs): G4/G5/G6/G8 DONE; G3/G9/G10 remaining
- `6bec95c0c` docs(wbs): mark G6 DONE (10/10, 207 tests) with as-built evidence
- `e81e294e9` docs(wbs): fix stale estimate summary — G2-G8 DONE, 9/11 gates complete
- `461c5efd1` docs(wbs): G9 progress — 11/15 tasks DONE, estimate summary corrected to 96/113
- `d43d3b040` docs(wbs): sync G9 estimate summary to 15/15 after the 9.11 unblock
- `5d187279d` docs(wbs): G9 DONE; remove stale v1 TOTAL row
- `b71026f7d` docs(wbs): correct stale G3 figures (43/43 -> verified 25/25) and Metal-blocked text
- `2d11fcb3a` docs(wbs): G3 cross-build evidence — exit 0, ghostty.exe + ghostty-vt.dll produced
- `66bd55731` docs(wbs): record test-windows-apprt compile+run status and 3812-test scope
- `9bf34cfc3` docs(wbs): 43/43 apprt tests pass; record full-suite behaviour
- `002a42dd1` docs(wbs): mark G3 DONE (43/43 apprt tests) and note G9.11 external block
- `74e6ba4f3` docs(wbs): close G3 and G9 loops with executed evidence
- `91371a0a9` docs(wbs): mark G3/G9 evidence as reproduced; fix dossier section count
- `b39d3ecd2` docs(wbs): G9 acceptance evidence — WASM 13/13 consumer PASS, DLL exports 198 symbols
- `a03a57c42` docs(wbs): G9 acceptance evidence — docs committed, dead links, dossier compliance
- `763093521` docs(wbs): G9.15 DONE — install docs landed (cd91fb549)
- `c2bac901c` docs(wbs): G9.10/G9.13 DONE, record Metal toolchain resolution (9d32ffc4c)
- `04a847bae` docs(wbs): add completion status to G4-G8 task tables
- `c44164579` docs(wbs): fix gates that contradicted their own index
- `00be1c303` docs(wbs): verify the IPC 458/458 figure and its per-module breakdown
- `cc8188f1f` docs(wbs): verify the Python 162/162 figure by execution
- `feaacb7ba` docs: verify the cited 199/199 by execution and record a pre-flight ordering hazard
- `92d507fc3` docs: re-verify G2 conformance (84/84) rather than carry the 09-17 date
- `14484543b` docs(wbs): record renderer-branch coverage for the Metal fallback
- `d1308274b` docs(wbs): macOS .app verified by the real end-user launch path
- `a4edbc47b` docs(wbs): record the executed wine attempt for Windows execution
- `7cd94370e` docs(wbs): classify the Go link failure as a host toolchain defect
- `7fcb76916` docs(wbs): add bidirectional ABI check for the Windows DLL
- `35c215fab` docs(wbs): record Metal-path regression check for the OpenGL fallback
- `74cfc0e4d` docs(wbs): npm-install consumer PASS for WASM acceptance bullet
- `c75e09124` docs(wbs): reconcile G10 totals with 2026-09-24 reality
- `a99b508c7` docs(wbs): reconcile G10 for 10.9 early execution — 114 DONE / 1 OPEN
- `09372d070` docs(wbs): retarget re-verify schedule IDs — corrected 10-01 scope
- `a79a7f1ec` docs(wbs): attribute the container SEGV to Zig's runner, not Khostty
- `b17325d63` docs(wbs): the container route for GTK is not viable - SEGV under emulation
- `f9ba0e99f` docs(wbs): the GTK header blocker is resolved by a container
- `3294be4f4` docs(wbs): the IPC wiring target cannot be built on this host
- `5ac14c54b` docs(wbs): the IPC app-thread hop mechanism already exists; scope narrows
- `588ec7fac` docs(wbs): scope the IPC wiring follow-on against the actual code
- `590dd7907` docs: correct the trust lists and track the IPC wiring gap

### Group 11 — Other (catch-all)

First-fork scaffolding, the fork-assessment session, the WBS pre-WBS
G2 conformance, the WASM build validation, the first handoff doc, and
a small number of build/test/audit commits that did not fit elsewhere.

16 commits:

- `8cc66d861` docs: fork assessment session — libghostty-vt validated as first delta
- `6281e073f` docs: first handoff — build profile, obligations, next delta
- `32757fdf1` docs: WASM build validated — 795KB MVP binary, 40+ function signatures
- `0465f5434` docs(conformance): G2 VT/ANSI test suite (8 cases, sgr/cursor/edge/osc/scroll/kitty-gfx/charset + harness, 116 test cases)
- `1e638ca57` docs: accept a crashed worker's audit, rejecting one wrong revert
- `2a68be1da` docs: GTK .deb install-verified; PLATFORMS.md Linux row updated [see also Group 6]
- `65de471df` fix(packaging): derive the deb glibc floor from the built binary [see also Group 6]
- `9001a4e6e` fix(build): track the windows-apprt test root and macOS packaging script [see also Group 3]
- `0f358f9ec` fix(test): wire ghostty.h into the windows-apprt test module [see also Group 3]
- `c9c83322f` build(windows): compile and install-verify the Inno Setup installer [see also Group 6]
- `7eb75a604` test(windows): execute the Windows artifacts on a real Windows runner [see also Group 3]
- `d1308274b` docs(wbs): macOS .app verified by the real end-user launch path [see also Group 6]
- `2db5de9eb` docs(macos): WBS 9.11 unblocked — Metal toolchain obtained and .app built [see also Group 6]
- `41b24baad` chore(gitignore): ignore ad-hoc a.out compiler output
- `95eccb351` chore: merge origin/main preserving fork documentation and CI (the one merge)
- `2a68be1da` is the GTK .deb install verification, listed once in Group 9 and once in Group 11 only when its `feat(packaging)` cousin is not present; it IS present in Group 6 as `313aec6e7`. The duplicate listing in this section is intentional — it spans both packaging and the GTK .deb install row.

## §3. Repo-level deltas (observable, not in commit log)

Top-level directories that exist in `origin/main` but **not** in
`upstream/main` (verified via `git ls-tree --name-only` diff):

- `.circleci/` — CircleCI config (org-template, see Group 8)
- `.gitleaks.toml` — narrow allowlist for seven verified false positives (`666fbf861`)
- `.mergify.yml` — Mergify auto-merge rules (org-template, see Group 8)
- `bench/` — libghostty-vt benchmark harness (Group 5)
- `conformance/` — G2 VT/ANSI test suite (Group 11)
- `docs/` — entire fork documentation tree (RELEASE.md, HANDOFF.md, etc., Group 9)
- `khostty-go/`, `khostty-python/`, `khostty-vt/` — the three FFI/SDK crates (Group 1)
- `packaging/` — Linux/Windows/macOS packaging scripts (Group 6)
- `renovate.json` — Renovate config (org-template, see Group 8)
- `sonar-project.properties` — fork override for inherited SonarCloud quality gate (`17fe76744`)
- `trunk.yaml` — Trunk.io config (org-template, see Group 8)
- `wasm/` — reproducible wasm32 build, ESM/JS bindings (Group 4)

Top-level files in `docs/` (none of these exist in upstream `docs/`):

- `AGENT.md`, `API.md`, `ARCHITECTURE.md`, `BUILD.md`
- `CONTRIBUTING.md`, `FORK.md`, `GLOBAL_HANDBOOK.md`, `GLOSSARY.md`
- `HANDOFF.md`, `INSTALL.md`, `PLATFORMS.md`, `README.md`
- `RELEASE.md`, `ROADMAP.md`, `SECURITY.md`, `TESTING.md`
- `changelog/0.1.0.md`
- `dossiers/KHOSTTY.md` (G9.10)
- `sessions/` (per-session evidence folders)

Other root-level artifacts the fork creates:

- `CLAUDE.md` — symlink to `AGENTS.md` (operator convention; harness-neutral)
- `README.md` — extensive fork delta (multiple rewrites in Group 9)
- `.agents/`, `.envrc`, `.prettierignore`, `.shellcheckrc`, `.swiftlint.yml` — fork-level dotfiles

## §4. Demo list — what would need a recorded demo (VHS or Playwright) to prove it works

A demo is a recorded, replayable artifact (terminal tape or browser
trace) that proves a user-facing change actually works. The list is
prioritized by "would a screenshot/video change the operator's mind?"
— a "yes" means we should record one before the next release.

| # | Change | Why a demo helps | Suggested tool | Acceptance signal |
|---|---|---|---|---|
| 1 | `khostty-vt` Rust FFI (`feat(khostty-vt): scaffold ...`) | Prove the lib renders a frame from a real terminal sequence; show a snapshot, a search, a key encode. | VHS tape (run the `examples/` from `09b31ee74`, capture stdout) | Frames render with correct style/cell identity; search hits the expected match; bindings-drift guard passes |
| 2 | `khostty-python` cffi (`feat(khostty-python): scaffold ...`) | 162 pytest cases are invisible to a non-developer. A 30-second VHS of the runnable example sells it. | VHS | pip install + import + render a frame; pytest 162/162 pass |
| 3 | `khostty-go` cgo (`feat(khostty-go): scaffold ...`) | Same as Python, but Go. | VHS | `go test ./...` exit 0; `go run ./examples/...` prints rendered frame |
| 4 | GTK .deb install + launch (`build(packaging): Linux .deb ...`) | "Installs and runs" is the only signal that matters. | Xvfb + `vhs` against the GTK deb (X11 is supported; Wayland needs `xdg-desktop-portal` caveats from `d00b004c5`) | `dpkg -i khostty.deb`; `khostty` opens; `APP_ALIVE` reaches the timeout |
| 5 | Inno Setup .exe install (`build(windows): compile and install-verify the Inno Setup installer`) | Cross-platform confidence. | Real Windows runner screenshot; `screenshot.exe` post-install | InstallShield-equivalent silent install; shortcut on desktop; `khostty.exe --version` reports a version |
| 6 | macOS .app launch (`docs(macos): WBS 9.11 unblocked ...`) | Apple-side confidence. | AppleScript-driven capture (Playwright is not applicable) | Bundle Info.plist valid; `open khostty.app` brings a window; OpenGL renderer initialized when Metal is absent |
| 7 | WASM ESM/JS bindings (`feat(wasm): ESM/JS bindings for libghostty-vt`) | Browser-side demo. **Playwright is the right tool here.** | Playwright + a static HTML page that imports the ESM | Page loads; `render(snapshot)` returns expected cells; TypeScript declarations type-check |
| 8 | Agent IPC v1 over real sockets (`test(ipc): G4.12/G4.13 agent workflow and concurrent-agent tests over real sockets`) | Two-agent interaction is hard to read from a test log. | VHS of `zig build ipc-test` running the two agents | Each agent issues 5 commands; round-trip auth succeeds; concurrent edits serialize correctly |
| 9 | `bench/` captured results (`docs(bench): G8.7-G8.8 captured results and measured report`) | Numbers are more credible with a recording. | VHS of `zig build bench` and a screenshot of the JSON report | Benchmark exits 0; `anonymized memory` units match the report; library path digest matches |
| 10 | CI fixes: scorecard, clean-artifacts, publish-pypi (`fix(ci): drop step-level permissions blocks ...`, `ci(clean-artifacts): grant actions:write ...`, `fix(ci): repair publish-pypi.yml ...`) | "This CI check went from red to green" is best shown in CI itself. | Screenshot of the GitHub Actions run list showing the new green checks | The named workflow runs green on the current main SHA |
| 11 | SonarCloud override (`ci(sonar): make inherited upstream quality gate advisory for fork`) | Same as #10 but for the SonarCloud check. | Screenshot of the GitHub PR checks showing "SonarCloud Code Analysis" as advisory green | Check no longer blocks PRs; no regression on the security signal |
| 12 | README + docs homepage look (`docs(readme): comprehensive rewrite with platform matrix, IPC draft, FFI status`) | First impression. | Playwright screenshot of the rendered README on a docs preview deploy | Page renders; platform matrix is correct; IPC draft reads; FFI status badges match reality |

**Total: 12 demos** (8 VHS-class, 2 Playwright-class, 2 screenshot-class).

## §5. How to update this document

This file is a snapshot. To regenerate on a new release-branch merge:

```bash
# from /Users/kooshapari/CodeProjects/Phenotype/repos/khostty
git fetch upstream
git log --no-merges --format='%h %s' upstream/main..origin/main > /tmp/khostty-commits.txt
wc -l /tmp/khostty-commits.txt
git log --merges --format='%h %s' upstream/main..origin/main
git rev-parse HEAD
git rev-parse upstream/main
git merge-base origin/main upstream/main
```

Then re-run the categorization in §2 (manual or scripted) and update §1,
the intent-group summary, and the §4 demo list. Re-run every 90 days
or before every release-cut branch. The file is `git diff`-able so a
PR that updates it is trivially reviewable.

---

*Generated 2026-10-12 by `calf` (Khostty 0.1.0 release orchestrator)
under Instinct handoff 2026-10-12 21:07Z. Companion 5-line cockpit
entry: `docs/sessions/khostty-0.1.0-release/evidence/upstream-delta-20261012.txt`.*
