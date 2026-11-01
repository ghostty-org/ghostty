# OMG Dev memory diagnostics

This opt-in, metadata-only logger correlates **fixed lifecycle/action markers**
with an independent macOS memory/CPU sampler. Neither is a leak detector or an
allocation profiler. Never use view counts as renderer, IOSurface, image-cache,
or scrollback byte counts.

## Enable and collect

Run a **Debug** OMG Dev bundle (`com.jischeng.omg.debug`) with
`OMG_DEV_MEMORY_DIAGNOSTICS=1` **at process launch**. It is off by default; an
already-running process cannot be enabled by changing its shell environment.
For an authorized OMG Dev diagnosis or repair, a required Dev-only relaunch is
within task scope; preserve open terminal sessions through the normal
restoration path. Do not relaunch solely to enable this logger when a restart
is not otherwise part of the requested diagnosis. For a Dev app not already
running:

```sh
OMG_DEV_MEMORY_DIAGNOSTICS=1 '/Applications/OMG Dev.app/Contents/MacOS/omg'
```

The logger writes `~/Library/Application Support/OMG/MemoryDiagnostics/events.jsonl`
and `events.previous.jsonl`: at most 1 MiB each, owner-only (`0700` directory,
`0600` files). Older entries are discarded on rotation. Each fixed-schema line
contains UTC ISO 8601 `time`, a fixed `event` name, and the number of live macOS
surface views (`surfaces`), terminal tab controllers (`tabs`), and best-effort
native window groups (`windows`). Events: `start`, one `sample` per minute,
`surface_created`, `surface_destroyed`, `tab_created`, `tab_closed`,
`split_added`, `split_removed`, `window_opened`, `window_focused`,
`window_closing`. `window_focused` marks a key-window change, which may be a
native tab switch or simply returning focus to OMG; it does not identify a tab.

`split_added`/`split_removed` describe changes in an existing split tree,
including undo or moves; they don't claim a new/closed PTY. `tab_closed` and
`window_closing` are emitted in `windowWillClose`, so their counts may still
include the closing controller. `surface_destroyed` reflects *view* deinit,
which can lag the action and need not mean Zig/Metal resources were freed.
The log never contains terminal text, command history, titles, session paths,
process IDs, environment values, allocation stacks, or arbitrary messages.

For independent system measurements, from a **separate terminal**, identify the
running OMG Dev Debug PID and use the bounded read-only sampler:

```sh
dist/macos/dev-tool.sh python3 .agents/skills/omg-debug/scripts/observe.py sample \
  --pid <DEBUG_DEV_PID> --output-dir /tmp/omg-debug-session \
  --interval 60 --duration-minutes 120
```

The output directory must be private (`0700`); choose a new directory for each
run. `system-samples.csv` is created exclusively (`0600`) and contains UTC
`time`, PID, total `footprint_mb`, Malloc Small/Large, IOSurface MB and region
count, two graphics categories, cumulative `cpu_seconds`, and per-interval
`cpu_percent`. Footprint's `MB` is preserved as macOS reports it; other units
are converted in binary multiples. CPU percent is based on the delta of process
CPU time / monotonic elapsed time (100% = one fully busy core); the first sample
has no CPU percent. The script verifies the Debug bundle ID and the original
process identity each minute, stops after the requested bounded duration or
when the process changes, and never reads shell content or attaches a debugger.
Sampling has some cost and itself can perturb short peaks; use a 60-second
interval for routine work. To correlate existing data with the app events:

```sh
dist/macos/dev-tool.sh python3 .agents/skills/omg-debug/scripts/observe.py report \
  --csv /tmp/omg-debug-session/system-samples.csv
```

The tool entry point removes inherited SDK selection and chooses an installed
Python interpreter without invoking Apple's `/usr/bin/python3` installer shim.
A stale `SDKROOT` can otherwise trigger a Command Line Tools installation prompt
even when Xcode is installed. Use the same entry point for `xcrun xctrace` and
SwiftLint; ad hoc Python subprocesses should reuse `sys.executable`. Missing
tools produce a diagnostic instead of starting an installation.

The report sorts current and rotated JSONL by UTC time, keeps only the newest
`start` run boundary, shows baseline/peak/final *system* measurements and maps
fixed action markers to the nearest sample with its time offset. It does not
publish raw logs. If the start boundary is missing, it excludes events rather
than joining another run. A nearest sample is **not** a measurement at the exact
action time: compare after similar activity and a settling period. The CSV
belongs to one process; do not combine samples from different PIDs or a
restarted app. An external CSV may contain a PID but the app's JSONL does not.

## Controlled experiment and deeper profiling

1. Capture an idle baseline; note local times for a controlled sequence of
   opening/closing windows, native tabs and splits. Keep the workload similar.
2. Wait after each close and compare the settled footprint and counts with the
   corresponding baseline. Report transient peaks separately from persistent
   post-close levels. Inspect heap versus IOSurface/graphics categories and CPU
   independently. View/controller counts are not retained-resource counts.
3. For a reproducible *persistent* difference, use a separately prepared
   debuggable OMG Dev and Instruments **Allocations** to obtain allocation
   stacks, or Time Profiler for CPU hot paths. LLDB needs a debuggable build
   and suitable macOS permissions; it is not activated by the logger switch.
   Do not repeatedly attach Allocations to an unentitled app. A `leaks` result
   or a Time Profiler trace alone does not rule out still-referenced memory.

Agent logo animation remains a profiling lead, not an established memory
root cause. The former `TimelineView` and subsequent SwiftUI `repeatForever`
opacity animation both produced window-level SwiftUI rendering hotspots in
CPU investigations. The current implementation hosts static tinted content in
an AppKit container and animates only that container's layer with
`CABasicAnimation`; hidden, occluded and detached containers stop animating.
Validate CPU improvements with a visible working Agent under the same workload,
not an idle app baseline or passing functional tests. Persistent diagnostic logs deliberately
exclude framebuffers, renderer resources, IOSurface ownership, image-cache
and scrollback bytes; obtain system-level numbers independently rather than
inferring them from view counts.
