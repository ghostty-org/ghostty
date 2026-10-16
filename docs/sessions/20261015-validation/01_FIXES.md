# Fixes & Validation — PR #16 + #17 (2026-10-15 17:56 PT)

## Critical correction to prior session notes

The 00_SESSION_OVERVIEW.md claim that "has_python_tests is exported and
consumed correctly" was WRONG. Verified by reading the actual detect job
on the final SHA de6971085: the detect step's `outputs:` block defines
`has_rust`, `has_deny`, `has_python`, `has_go`, `has_typescript`,
`has_security`, `has_trunk` — **no `has_python_tests`**. The shell
initialization that follows sets those exact same keys; nothing else.

The pytest job's `if: needs.detect.outputs.has_python_tests == 'true'`
therefore evaluated to an empty string, which GitHub treats as false
(skip). The smoking gun is the most recent run 38824904579 on the
final SHA de6971085: workflow `conclusion: success`, but the
"Python Tests" job `conclusion: skipped`. Silent green.

Fix landed in commit `272419186` on `ci/python-test-coverage`: the
guard now reads `needs.detect.outputs.has_python == 'true'`, the output
detect actually emits.

## Confirmed defects in PR #16's ci.yml (all fixed in `272419186`)

| # | Defect | Fix |
|---|---|---|
| 1 | install-zig step in pytest job passed only `version`, missing the `shasum` input. The action's regex `^[0-9a-f]{64}$` would have killed the step at pin time. | Added `shasum: 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00` (the ziglang.org-published SHA-256 for `zig-x86_64-linux-0.16.0.tar.xz`, captured 2026-10-15 from `https://ziglang.org/download/index.json`). |
| 2 | pytest job's `if:` referenced the non-existent `has_python_tests` output. | Now references the real `has_python` output. |
| 3 | `lint` aggregate's `needs:` list did not include `pytest`. A failing pytest run would never block the lint gate. | Added `pytest` to the `needs` list and to the inner `for pair` result loop. |
| 4 | `test` aggregate job's body was a fixed `echo "✅ All test stages passed (gated via ci / lint)"` that asserted nothing. | Replaced the body with a real aggregate over `[lint, pytest]` that fails the job on any `failure` or `cancelled` result. |
| 5 | Install step used `pip install -e khostty-python --no-deps --no-build-isolation`, which contradicts the "use declared project test extra" directive and is fragile on a clean machine. | Replaced with `pip install -e khostty-python` so cffi, pytest, and setuptools (all hash-pinned in `khostty-python/requirements-ci.txt`) are resolved through the normal resolver with default build isolation. |

## Confirmed defects in PR #17's zig-fork-tests.yml (all fixed in `39aebd313`)

| # | Defect | Fix |
|---|---|---|
| 1 | install-zig step in both jobs (windows-apprt and agent-ipc) passed only `version`, missing `shasum`. | Added the same `70e49664…` SHA-256. |
| 2 | Neither job installed Linux GUI deps (GTK4, libadwaita, oniguruma, libxml2, glib, pkg-config). The imported `apprt/windows/*.zig` modules transitively link against them; without them `zig build test-*` fails at link time on `ubuntu-latest`. | Added `cachix/install-nix-action@v31.11.1` (pinned to SHA `13d8dd58…`, matching the pattern in `test.yml` / `nix.yml` / `release-tip.yml`) and wrapped each `zig build test-*` in `nix develop -c …` so `flake.nix` supplies the missing libs. Skipped `cachix-action` itself: the fork has no `CACHIX_AUTH_TOKEN` and cachix-action without credentials 401s. |
| 3 | `continue-on-error: true` on the cheap `windows-apprt` job masked every regression. | Removed. |
| 4 | `continue-on-error: true` on the 60-min `agent-ipc` job masked every regression through the nightly schedule path. | Removed (operator directive: "remove masks for real test failures"). The 60-min cost is offset by the cron-only scheduling and the `workflow_dispatch` manual path. |

## Real CI runs on final SHAs

PR #16 final SHA after fix: `2724191863e06f69802a13fdc7c50a61cc514dac`
on branch `ci/python-test-coverage`. Triggered `workflow_dispatch` at
2026-10-15 17:56 PT; run id `38832342836`.

PR #17 final SHA after fix: `39aebd3132b04cddc59022a6362ea1fe5f5fe39a`
on branch `ci/zig-fork-tests`. zig-fork-tests.yml only exists on this
branch, not on master, so `gh workflow run` cannot dispatch it from
the CLI (GitHub only enumerates workflows from the default branch).
Plan: merge #16 first; then #17's stacked diff against the post-#16
master will be just the zig-fork-tests.yml addition. The next
scheduled cron (`20 5 * * *` UTC = 22:20 PT) will run the workflow;
this session cannot force-dispatch it.

## Run 38832342836 outcome (2026-10-15 18:01 PT, completed FAILURE)

| Job | Outcome | Notes |
|---|---|---|
| Zig Fmt | success | install-zig shasum fix worked; zig-fmt clean |
| Detect Languages | success | outputs are correct |
| Python | success | ruff/format advisory-only |
| Rust | success | |
| Go | success | |
| TS/JS | success | |
| **Python Tests** | **failure** | 161 passed, 1 failed: `tests/test_key.py::test_alt_prefix_needs_both_settings`. Real behavior bug in libghostty-vt (or the Python binding wrapper), not a CI configuration issue. See "Real failure" section below. |
| Build (macOS) | skipped | `if: ${{ false }}` (intentional, billed runners disabled) |
| Dependency Review | skipped | Pre-existing, see prior session notes |
| Cargo Deny | skipped | `has_deny=false` (no deny.toml) |
| **Security Scan** | **failure** | gitleaks `generic-api-key` rule fired in `benchmark-sources.txt` and `.github/workflows/release-pr.yml`. Pre-existing findings in the source tree, not introduced by these PRs. OUT OF SCOPE for the CI fix. |
| **ci / lint** | **failure** | **NEW BEHAVIOR, INTENTIONAL**: lint aggregate now correctly fails because `pytest` failed. The fix to defect #3 works as designed. |
| **ci / test** | **failure** | **NEW BEHAVIOR, INTENTIONAL**: test aggregate now correctly fails because `pytest` failed. The fix to defect #4 works as designed. |

## Real failure (operator directive: report directly, no speculation)

**`tests/test_key.py::test_alt_prefix_needs_both_settings`** (line 127):

```python
def test_alt_prefix_needs_both_settings(library: str) -> None:
    """An Alt prefix requires the DEC 1036 mode and option-as-alt together."""
    assert encode_key(Keys.A, Mods.ALT, utf8="a", library=library) == b"a"
    assert encode_key(Keys.A, Mods.ALT, utf8="a",
                      alt_esc_prefix=True, library=library) == b"a"
```

The second assertion fails:

```
AssertionError: assert b'\x1ba' == b'a'
At index 0 diff: b'\x1b' != b'a'
+ b'\x1ba'    (actual: ESC + 'a')
- b'a'        (expected: just 'a')
```

The test expects that with `alt_esc_prefix=True`, the Alt + 'a' combo
should NOT emit the ESC prefix. The library under test is emitting
`\x1ba` regardless of the `alt_esc_prefix` flag.

This is a behavior bug in either:
- The C-level libghostty-vt key encoder (it does not honor the
  alt_esc_prefix disable path)
- The Python binding wrapper that maps `alt_esc_prefix` to the C flag
- The test itself, if the C API contract has changed since the test
  was written

**This is NOT a CI configuration issue and not in scope for the
ci.pytest-test-coverage work.** The CI changes are correct: pytest
runs, fails, and the failure propagates to both the `lint` and
`test` aggregate gates, exactly as defect #3 and #4 fixes intended.

The fix is in the test source / binding / library, owned by the other
worker on `sync/upstream-20261015`. Once that worker lands a fix that
turns this test green, PR #16's pytest job will be green and the
aggregates will pass.

**Decision: do NOT merge PR #16 yet.** The CI infrastructure is fixed
and behaving correctly. The remaining blocker is the test failure,
which is a code bug, not a CI bug. Operator's directive "Run/observe
actual jobs on final SHAs before merge" is satisfied by reporting the
failure.

## Operator-suspected defects confirmed false (kept for the record)

- **"has_python_tests not exported"** — operator was right; my prior
  note was wrong. The output does not exist. The pytest job is fixed
  in `272419186`.
- **"pip install -e '.[test]' at repo root"** — prior wording was
  partly wrong (the actual command was `pip install -e khostty-python
  --no-deps --no-build-isolation`, not `.[test]`), but the underlying
  concern (fragile install) was correct. The fix in `272419186` drops
  `--no-deps --no-build-isolation` and uses default resolver behavior.

## Files

- `00_SESSION_OVERVIEW.md` (this session) — needs the "has_python_tests
  IS exported" line on lines 36-42 corrected before final hand-off.
- `01_FIXES.md` (this file) — what was actually changed.
- Worktrees: `/Users/kooshapari/.jcode/scratch/khostty-pr16` (branch
  `ci16-fix`) and `/Users/kooshapari/.jcode/scratch/khostty-pr17`
  (branch `ci17-fix`).
