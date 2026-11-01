# Local Hermes polling CPU investigation

## Evidence

The user observed an approximately 80% `OMG[DEBUG]` CPU peak during development.
There is no timestamp/PID for that historical peak. Both the installed Dev app
and app-hosted tests use the Debug process name, so that observation alone cannot
identify the workload.

The current investigation verified the installed `/Applications/OMG Dev.app`
process, PID 48743, version `0.18.0-dev.9e4e0986`. No test host was running during
the baseline. Its persisted workload contained 75 tabs across 14 workspaces,
including a 60-tab Personal workspace.

A 30-second observation using 15 two-second CPU-time deltas measured mean 8.53%,
median 3.967%, and maximum 46.158%. The investigator did not operate OMG during
this interval; user interaction was not excluded. These are process CPU-time
measurements, not a guarantee of strict idle or a reproduction of the reported
80% peak. They exclude the CPU used by child Python/`ps` processes.

A separate 15-second Time Profiler run recorded 1,096 ms of CPU sample weight,
including 223 ms on the main thread. `GitProcessRunner` appeared in 558 ms
(50.9%) of inclusive stacks and `pollHermesPanes` in 225 ms (20.5%). These
categories overlap and must not be added. Workspace checkpoint capture
accounted for 43 ms (3.9%). This sample did not identify terminal rendering or
SwiftUI host layout as the dominant source.

A short process-list observation with a six-second target window saw at least
26 distinct Python stdin children and up to eight concurrently. Polling misses
short-lived children and adds overhead, so this is a lower bound, not a complete
spawn count. Commands and terminal contents were not retained.

A second 30-second CPU observation measured mean 7.35%, median 7.404%, and maximum
7.935%. A separate, more frequent six-second process observation (70 polls over
6.057 seconds) captured 153 distinct Python children and up to ten concurrently.
Different polling frequencies explain why this count is not directly comparable
to the earlier 26-child lower bound; the repeat observer is retained for the
post-install comparison.

The managed Hermes hooks were installed. The previous local probe launched one
Python process per eligible pane approximately every two seconds, even when
that pane was not running Hermes. Each process invoked `ps` for its TTY and,
if it found a client, another `ps` for process age.

## Repair

All local panes now share an actor-owned in-flight probe and a two-second
snapshot. One Python process obtains PID, process group, TTY, foreground flags,
age and arguments in one process-table read. Only foreground Hermes clients
cause per-TTY session metadata reads. Results retain the existing session,
ownership, size, stale-breadcrumb and process-group isolation rules.

Probe and decoding failures remain errors, with a two-second retry cooldown;
they are not successful empty results that could erase Agent state. Cancellation
of one pane does not cancel work shared with other panes. A generation token
prevents older waiters from publishing over a newer probe. The controller still
checks pane/session/foreground identity before accepting a result.

Hidden and parked panes continue to track Agent state. The SSH transport keeps
its existing per-account, per-TTY probe. No renderer or window-visibility
lifecycle changes are part of this repair.

Private CPU statistics and sanitized stack exports are stored under
`/tmp/omg-cpu-audit-c2yk6ee0/`. Raw Instruments bundles are removed after exporting
the required profile table because trace metadata can include inherited process
environment. Nothing is uploaded.

## Validation

- Python probe tests: 14 passed, including one process-table read, multiple TTYs,
  macOS TTY/long elapsed-time parsing, background/false-positive filtering,
  ambiguous process groups, stale metadata, process failure and timeout.
- Focused Swift run: 58 tests in three suites passed. The six new cache tests
  cover 75 concurrent requests, expiry, TTY isolation, successful absence,
  failure cooldown, cancellation and slow-probe refresh.
- Change-plan selection falls back to all routine suites because the central
  terminal controller changed. All 1,314 tests across 165 suites passed in
  16 serial batches on the final implementation. The new suite was explicitly
  included in the inventory comparison.
- Changed-file strict SwiftLint, the 41-test selector contract, documentation,
  plist, settings JSON and diff checks passed.

This repair does not change native window selection, focus, hover or drag
routing. Interactive desktop tests were not rerun for the polling-only change.
Runtime CPU acceptance is separate from these functional tests.

## Installed result

Implementation commit `61327f96` was installed with the standard Dev installer
as `0.18.0-dev.61327f96` at `/Applications/OMG Dev.app`. The verified process was
PID 71991. The installed binary hash matched the built artifact; signing and
session-runtime checks passed, as did the installer's six SSH wrapper tests.

Before restarting, the Dev bundle, settings and workspace checkpoint were
backed up privately. After restart, all 75 persisted tab IDs and workspace
assignments matched, all 14 workspaces remained, and the live terminal surface
count remained 76. AppleScript tab object IDs are process-local pointers, so
persistent identity comparison uses the workspace checkpoint rather than
comparing those scripting IDs across restarts.

Both post-install CPU observations lasted 30 seconds with 15 two-second
intervals. No build/test host or profiler was running during them. The same
75-tab workload remained loaded; the investigator did not operate OMG during
the intervals. These are observations across a restart, not a controlled replay
of every terminal child workload or user action.

| Measure | Before repeat | After | After repeat |
| --- | ---: | ---: | ---: |
| Mean process CPU | 7.35% | 2.82% | 2.99% |
| Median process CPU | 7.404% | 2.950% | 2.952% |
| Maximum two-second CPU | 7.935% | 3.446% | 3.459% |

The same six-second child observer saw 153 distinct Python children before
(70 polls, 6.057 seconds) and three afterward (68 polls, 6.081 seconds).
Peak concurrent Python children dropped from ten to one. Both counts remain
polling lower bounds and include no child CPU-time measurements.

The separate 15-second post-install profile recorded 473 ms of total CPU sample
weight versus 1,096 ms before. Inclusive `GitProcessRunner` weight dropped from
558 ms to 25 ms, and `pollHermesPanes` from 225 ms to 51 ms. Main-thread sample
weight was 254 ms afterward versus 223 ms before: this experiment demonstrates
less process-launch work, not a measured main-thread or input-to-pixel latency
improvement. Remaining samples include the retained Agent/SSH polling and
workspace checkpoint capture.

The two post-install means are approximately 59-62% lower than the repeat
baseline. This does not establish that all future peaks are below 3.5%, nor
identify the exact context of the user's historical 80% peak.
