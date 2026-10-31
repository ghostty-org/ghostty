# Inspector switching and history loading

Baseline: c98a588dd. User reports CPU peaks, slow/flickering Inspector switches,
an unwanted option focus outline, and expensive Agent History loading.

## Evidence and limits

The running OMG Dev was `0.18.0-dev.c98a588d`. A five-second sample found the
main thread waiting for events in 2,170 of 2,184 samples; the old synchronous
YAML-audit hotspot was absent. The reported 200% peak and the whole-window
disappearance were not captured in these samples.

Native UI inspection showed 32 tabs and 4,160 history sessions. The previous
Inspector eligibility rule checked attachment and hidden ancestors but not
whether the native window was selected/visible. A regression with eight attached
tabs confirms that the old rule admitted eight while the fixed implementation
presents exactly one provider, including after tab switches. This is an
amplification of presentation/provider work, not proof of 32 identical history
disk scans: Agent History already shares its session cache per host.

## Changes

- Only a visible, selected native tab outside a parked workspace presents an
  Inspector provider. Window/key/occlusion changes refresh this decision.
- Pane switches lay out/display the incoming cached host before hiding the old
  one, without disabling application-wide screen updates. Native view identity,
  window visibility and window frame remain stable.
- Files preserves outstanding work on title-only changes, using the same
  location-based lifecycle rule as Git. Agent History keeps its context-update
  behavior and retains selected/loaded transcripts across pane switches.
- Option popovers use a subtle fill for keyboard focus instead of a stroked
  rectangle. Checked-state indicators and arrow/Return navigation remain.
- Agent History defaults to three calendar months. Local and SSH discovery
  apply file-date limits before header reading/decompression. Local scans keep
  older valid cache entries, limit header parsing to two workers and check
  cancellation between batches.
- All/Year requests expand the host cache; switching to a narrower range does
  not reload it. Search uses the selected filter scope. Agent counts use one
  scoped pass instead of rescanning sessions separately for every Agent, and
  calendar cutoffs are computed once per filtering pass.

## Validation

Final product source: **71 tests in eight suites passed**. Tests cover inactive
native tabs, Files lifecycle, retained pane identity/window frame/visibility,
loaded transcript reuse, recent/all cache behavior, native keyboard focus,
local date filtering and execution of the actual generated remote Python
discovery script against temporary fixtures.

Cached pane switches measured a median of about 0.13 ms and a maximum of
0.49 ms in the controlled fixture. This measures the native switch operation,
not an end-user cold filesystem/history load or GPU presentation latency.

The first regression retained the old all-time reset expectation and failed;
it was updated to assert the requested three-month default and explicit All
expansion. The first remote-script fixture escaped slashes as JSON inside a
Python string; its test-only root literal was corrected. Product assertions
were not relaxed.

Logs: `/tmp/omg-inspector-loading-complete.log` (final passing run),
`/tmp/omg-inspector-loading-tests.log` (old reset expectation),
`/tmp/omg-inspector-history-remote.log` (initial fixture failure).
Private original-process samples: `/tmp/omg-inspector-cpu-17452.sample` and
`/tmp/omg-inspector-history-switch.sample`.

The running application was not replaced or restarted. Actual peak CPU and
the reported whole-window flash still need acceptance on the new build.
