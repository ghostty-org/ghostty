# AppKit responsiveness and polling cost review

Baseline: fe12edf6f. Symptoms: slow tab creation, delayed selected glyph feedback,
and ongoing CPU activity.

## Runtime evidence

The running `/Applications/OMG Dev.app` was version `0.18.0-dev.fe12edf6`.
A bounded three-second external sample of that process found 972 of 983 main
thread samples beneath `pollHermesPanes -> AgentHookInstaller.isInstalled`.
Most of those samples were in the full YAML hook audit and Foundation string
matching. The local configuration was 126,614 bytes. No configuration contents,
terminal contents or session commands were collected into this document.

The per-controller one-second timer performed that synchronous audit for local
panes. The timer shares the main thread with AppKit pointer tracking and window
creation, so it can delay both even though the expensive work is outside the
native widgets themselves. Raw samples remain private at
`/tmp/omg-appkit-cpu-96086.sample`; they describe the old process, not the fixed
build.

## Changes

- Local Hermes polling now uses a shared asynchronous presence cache. Multiple
  tabs/splits share one pending read and a five-second cached result. Hook
  install/remove notifications invalidate both cached and in-flight results.
  Remote probes and the existing two-second status-probe cadence are unchanged.
- YAML presence no longer performs a full version/event/helper audit. Stale
  installed hooks still count as installed, exactly as before. Maintenance
  retains the complete audit. ASCII marker searches use literal matching.
- Native row selection updates its icon synchronously with AppKit's selected
  row, before deferred window activation. Hover remains separate from selection.
  Row recycling can temporarily expose zero columns; the callback guards this
  boundary before looking up its cell.
- Mouse entry/exit only updates trailing controls; it no longer rebuilds the
  entire tab presentation or recomputes Agent state.
- Native buttons, table hover and tab cells/icons retain their `inVisibleRect`
  tracking areas instead of recreating them on every layout. Pointer hit testing
  rejects out-of-bounds controls before querying the WindowServer.
- Repeated native button configuration preserves image identity and does not
  invalidate intrinsic size unless title/image geometry changes.
- Native chrome obtains just its palette accent instead of constructing all 256
  colors and syntax attributes of an editor theme on each resolution. Tests
  compare the resulting accent with the original editor theme.

## Verification

The first test iteration found two implementation/test defects: the row callback
queried column zero during recycling, and the Unicode fixture used an incomplete
managed marker. Both were corrected. No test assertions or timing limits were
relaxed.

The focused rerun passed 32 tests. The final expanded run passed **125 tests in
10 suites**, including Agent status/integration, cache invalidation, native
controls/themes, sidebar/outline, tab lifecycle and diagnostics.

In the final run, three vertical creations took 49-64 ms synchronously and
88-98 ms through native selection/surface/sidebar mounting. Three horizontal
creations took 51-61 ms synchronously and 86-113 ms through mounting. These
fixtures run `/bin/sleep`, so they do not measure interactive shell startup,
SSH reconnection or the user's existing workload. The idle chrome check recorded
zero extra refreshes or visibility toggles.

Twenty presence scans of a generated Unicode configuration took about 48 ms.
The cache tests exercise 100 concurrent callers sharing one read, refresh expiry,
install/remove invalidation and rejection of an obsolete completion.

Logs:

- `/tmp/omg-appkit-cost-tests-2.log`: initial failures.
- `/tmp/omg-appkit-cost-tests-3.log`: focused passing run.
- `/tmp/omg-appkit-cost-regression.log`: final expanded passing run and timings.

The user's running development app was not terminated or replaced. Real-session
CPU and interactive new-tab acceptance require running the new build; the
controlled measurements above are not a claim that its live CPU is already low.
