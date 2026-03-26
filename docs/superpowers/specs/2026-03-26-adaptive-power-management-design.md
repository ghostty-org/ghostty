# Adaptive Power Management for Ghostty

## Summary

Add battery-aware power management to Ghostty. The system detects whether the machine is on AC power, battery, or critically low battery, and adjusts rendering parameters to reduce power consumption. Users can configure per-power-state overrides using the existing conditional config system.

## Motivation

Ghostty's renderer runs at 120 FPS for animations (`DRAW_INTERVAL = 8ms`), uses GPU-intensive features like background blur and custom shaders, and maintains a cursor blink timer — all of which consume power even when the user isn't actively interacting with the terminal. On laptops, this contributes to battery drain.

No terminal emulator currently implements battery-adaptive rendering. This would be a differentiating feature.

### Prior Art in Ghostty

- **Issue #9263**: macOS attributes subprocess power usage to Ghostty (unfixable — OS behavior).
- **Issue #8003**: Cursor blink timer wakes renderer unnecessarily (open).
- **PR #9662**: RenderState refactor reduced critical render lock time 2-5x.
- **PR #10668**: Draw timer now only activates when custom shaders are configured.
- **PR #2586**: Renderer prefers integrated GPU on dual-GPU Macs.

These fixes addressed specific regressions. This spec adds *proactive* power management.

## Design

### Approach: Extend Conditional Config

Ghostty's conditional config system (`src/config/conditional.zig`) allows config values to change based on state. Currently it supports `theme` (light/dark) and `os`. We add `power` as a third conditional state dimension.

This reuses the entire conditional infrastructure — parsing, matching, application, and config reload propagation — with minimal new code.

### Power States

Three states, represented as an enum:

```
ac       — plugged in or no battery detected
battery  — on battery power, above critical threshold
critical — on battery power, at or below critical threshold (default: 20%)
```

Desktops without batteries always report `ac`.

## Components

### 1. `src/os/power.zig` — Power Detection Module

A new OS module following the pattern of `desktop.zig` and `flatpak.zig`. Exported via `src/os/main.zig`.

**Public API:**

```zig
pub const PowerState = enum { ac, battery, critical };

pub const PowerInfo = struct {
    state: PowerState,
    battery_percent: ?u8,  // null if no battery detected
};

/// Returns current power state. Pure function, no side effects.
pub fn getPowerInfo(critical_threshold: u8) PowerInfo
```

**Platform implementations:**

- **Linux:** Reads `/sys/class/power_supply/` sysfs interface.
  - Iterates entries looking for `type == "Battery"` and `type == "Mains"`.
  - Reads `status` (Charging/Discharging/Full/Not charging) and `capacity` (0-100).
  - If any AC adapter has `online == 1` or battery status is `Charging`/`Full`, state is `.ac`.
  - Otherwise state is `.battery` or `.critical` based on capacity vs threshold.
  - Internal function `getPowerInfoFromPath(path, threshold)` takes a directory path for testability.
  - For multiple batteries, uses the lowest capacity (most conservative/safest for triggering `critical`). This is a deliberate design choice — on multi-battery systems (e.g., ThinkPad with internal + external), the lowest battery is the one most likely to cause a shutdown.

- **macOS:** Uses IOKit `IOPowerSources` C API via extern function declarations (matching the pattern in `src/os/macos.zig` which uses extern C functions like `pthread_set_qos_class_self_np`).
  - `IOPSCopyPowerSourcesInfo()` → `IOPSGetProvidingPowerSourceType()` for AC vs battery.
  - `IOPSGetPowerSourceDescription()` with `kIOPSCurrentCapacityKey` for battery percentage.
  - Requires linking `IOKit.framework` (added to `pkg/macos/build.zig`).
  - **CoreFoundation memory management:** `IOPSCopyPowerSourcesInfo()` returns a `CFTypeRef` that must be `CFRelease`d. Since `getPowerInfo()` is a synchronous function, it acquires and releases within the same call — no need for `CFReleaseThread`. The `IOPSGetPowerSourceDescription()` return value is a "Get" (not "Copy"), so it must NOT be released.

- **Other platforms (Windows, FreeBSD, etc.):** Returns `PowerInfo{ .state = .ac, .battery_percent = null }`.

**Design constraints:**
- Pure function. No global state, no caching. Caller decides polling frequency.
- Never errors. Returns `.ac` with `null` percent on any failure (file not found, parse error, API failure).
- No libudev, no D-Bus, no netlink. Linux reads plain files. macOS uses a stable public C API.

### 2. Config Options in `src/config/Config.zig`

Three new configuration options:

```zig
/// Controls whether Ghostty adapts behavior based on power state.
///
/// `auto`: Detect power state via OS APIs and apply conditional defaults
/// for reduced power consumption on battery.
///
/// `performance`: Always use full performance settings regardless of
/// power state. Equivalent to forcing power=ac.
///
/// `efficiency`: Always use power-saving settings regardless of power
/// state. Equivalent to forcing power=critical.
///
/// `off`: Disable power detection entirely. No polling occurs.
/// This is the default because desktop machines without batteries
/// should not pay the cost of periodic polling.
@"power-mode": PowerMode = .off,

/// Battery percentage at or below which the power state transitions
/// to "critical". Only relevant when power-mode is "auto".
/// Valid range: 0-99. Set to 0 to disable the critical state entirely.
@"power-critical-threshold": u8 = 20,

/// How often to poll for power state changes, in seconds.
/// Only relevant when power-mode is "auto".
/// Valid range: 5-300.
@"power-poll-interval": u16 = 30,
```

**PowerMode enum:**

```zig
pub const PowerMode = enum {
    auto,
    performance,
    efficiency,
    off,
};
```

**New overridable rendering config:**

```zig
/// Draw interval in milliseconds for animation frames.
/// Lower values produce smoother animations but consume more power.
/// Default: 8 (approximately 120 FPS).
/// Common values: 16 (60 FPS), 32 (30 FPS).
/// Valid range: 2-100.
@"draw-interval": u16 = 8,
```

**Validation:** `draw-interval` is clamped to 2-100ms via `@min`/`@max` clamping in `finalize()`. Values below 2ms would oversaturate the event loop. Values above 100ms (< 10 FPS) would make the terminal feel broken. `power-poll-interval` and `power-critical-threshold` use the same clamping pattern in `finalize()`.

This replaces the hardcoded `DRAW_INTERVAL` constant in `renderer/Thread.zig` and makes frame rate controllable via config — including via conditional power overrides.

### 3. Conditional Config Extension in `src/config/conditional.zig`

Add `power` to the `State` struct:

```zig
pub const State = struct {
    theme: Theme = .light,
    os: std.Target.Os.Tag = builtin.target.os.tag,
    power: Power = .ac,

    pub const Theme = enum { light, dark };
    pub const Power = enum { ac, battery, critical };
};
```

The `Key` enum is auto-generated from `State` fields via comptime reflection, so it automatically includes `.power`. The `match()` function already handles all enum fields generically — no changes needed.

**Note:** `power` is only the second runtime-dynamic conditional key (after `theme`). The `os` key is set at compile time and never changes. The `changeConditionalState()` path in `Config.zig` (line 4315) iterates all conditional keys and checks if any relevant key changed, which handles multiple dynamic keys correctly. However, this path has only been tested with one dynamic key (`theme`). Integration tests should verify that independent changes to `theme` and `power` do not interfere with each other.

This enables user config like:

```
[conditional:power=battery]
draw-interval = 16
custom-shader-animation = false

[conditional:power=critical]
draw-interval = 32
custom-shader-animation = false
cursor-style-blink = false
background-blur = false
```

### 4. Power State Propagation via `src/App.zig`

**Polling via `tick()` timestamp check:**

`App.zig` does not own an xev event loop. It is a pure data/logic layer that gets `tick()`-ed by the apprt on every iteration. Theme changes propagate through `colorSchemeEvent()` called by the apprt, which triggers `performAction(.reload_config, .{ .soft = true })`.

Power polling follows the same pattern using a timestamp check inside `tick()`:

```zig
// New fields on App:
last_power_check: ?std.time.Instant = null,
last_power_state: ?configpkg.ConditionalState.Power = null,
```

```
App.init():
  if power-mode == .performance → set config_conditional_state.power = .ac
  if power-mode == .efficiency → set config_conditional_state.power = .critical
  if power-mode == .off → no action (power stays at default .ac)
  if power-mode == .auto → initial power check happens on first tick()

App.tick(rt_app):
  self.drainMailbox(rt_app);
  if power-mode == .auto:
    now = std.time.Instant.now()
    if last_power_check is null OR now.since(last_power_check) >= power-poll-interval_ns:
      last_power_check = now
      info = os.power.getPowerInfo(critical_threshold)
      new_state = info.state
      if new_state != last_power_state:
        last_power_state = new_state
        config_conditional_state.power = new_state
        rt_app.performAction(.reload_config, .{ .soft = true })
```

**Why this approach:** This mirrors how `colorSchemeEvent()` works — update `config_conditional_state`, then trigger a soft config reload. The `reload_config` path calls `updateConfig()` which applies conditionals via `changeConditionalState()` and pushes updates to all surfaces, renderers, and termio instances. The entire pipeline is reused.

**Config reload handling:** If `power-mode` itself changes during a config reload (e.g., user switches from `auto` to `off`), `tick()` simply stops checking because the power-mode config will reflect the new value. If `power-poll-interval` changes, the next timestamp comparison uses the new interval. No timer cancellation needed.

### 5. Renderer Integration in `src/renderer/Thread.zig`

**`DerivedConfig` changes:**

```zig
pub const DerivedConfig = struct {
    custom_shader_animation: configpkg.CustomShaderAnimation,
    draw_interval_ms: u16,  // NEW: replaces DRAW_INTERVAL constant
    // ... existing fields
};
```

**`syncDrawTimer()` changes:**

The draw timer uses `self.config.draw_interval_ms` instead of the hardcoded `DRAW_INTERVAL` constant. **Both call sites** must be updated:
- `syncDrawTimer()` (initial arm, ~line 329): `self.draw_h.run(..., self.config.draw_interval_ms, ...)`
- `drawCallback()` (re-arm, ~line 590): `t.draw_h.run(..., t.config.draw_interval_ms, ...)`

The timer interval takes effect on the next re-arm cycle — no explicit cancellation needed.

**`changeConfig()` must call `syncDrawTimer()`:** When a config change message arrives with a new `draw_interval_ms` value, the `changeConfig()` handler (line 488) must call `syncDrawTimer()` to ensure the draw timer state is re-evaluated. This already happens — the `change_config` message handler at line 456 calls `self.syncDrawTimer()` after `self.changeConfig()`.

### 6. Auto Mode Defaults

When `power-mode == .auto`, the system injects default conditional config entries during config `finalize()`. These are injected *before* user-defined conditional entries, so user overrides naturally take priority (later entries win in the config system).

**Injected defaults:**

| Conditional Block | Settings |
|---|---|
| `[conditional:power=battery]` | `draw-interval = 16`, `custom-shader-animation = false` |
| `[conditional:power=critical]` | `draw-interval = 32`, `custom-shader-animation = false`, `cursor-style-blink = false`, `background-blur = false` |

**Implementation:** During `Config.finalize()`, if `power-mode == .auto`, prepend synthetic conditional replay entries to the config's conditional set. These behave identically to user-written entries but appear earlier in the evaluation order, so any user-written `[conditional:power=battery]` block overrides them.

This approach:
- Requires no new tracking infrastructure (no "was this field explicitly set?" mechanism).
- Uses the existing conditional application pipeline without modification.
- Is transparent — the user's explicit config always wins.

**Example:** If the user writes:
```
power-mode = auto

[conditional:power=battery]
draw-interval = 8  # I want full speed even on battery
```

The system injects `draw-interval = 16` first, then the user's `draw-interval = 8` overrides it. Result: 8ms on battery.

## Testing Strategy

### Unit Tests for `power.zig`

The Linux implementation exposes `getPowerInfoFromPath(path, threshold)` for testing with mock sysfs directories.

**Test cases:**

1. **AC power only** — Directory contains `AC/type=Mains`, `AC/online=1`. No battery. Expect: `{ .ac, null }`.
2. **Battery discharging at 50%** — `BAT0/type=Battery`, `BAT0/status=Discharging`, `BAT0/capacity=50`. Expect: `{ .battery, 50 }`.
3. **Battery at critical (15%)** — Same as above with `capacity=15`, threshold 20. Expect: `{ .critical, 15 }`.
4. **Battery charging** — `BAT0/status=Charging`, `BAT0/capacity=40`. Expect: `{ .ac, 40 }`.
5. **Battery full** — `BAT0/status=Full`, `BAT0/capacity=100`. Expect: `{ .ac, 100 }`.
6. **No power supply directory** — Path doesn't exist. Expect: `{ .ac, null }`.
7. **Malformed capacity file** — `BAT0/capacity=abc`. Expect: `{ .ac, null }` (graceful degradation).
8. **Empty directory** — Path exists but no entries. Expect: `{ .ac, null }`.
9. **Multiple batteries** — `BAT0` discharging at 30%, `BAT1` discharging at 60%. Expect: uses lowest capacity (30%), state based on that.
10. **AC online + battery discharging** — `AC/online=1` AND `BAT0/status=Discharging`. Expect: `{ .ac, <percent> }` (AC wins).
11. **Threshold boundary** — Capacity exactly equal to threshold. Expect: `{ .critical, <threshold> }`.
12. **Capacity at 0%** — Expect: `{ .critical, 0 }`.
13. **Capacity at 100% while discharging** — Expect: `{ .battery, 100 }`.
14. **Threshold at 0** — Critical disabled. Battery at 5%. Expect: `{ .battery, 5 }` (never critical).

**macOS tests:** Compile-time gated. On non-Darwin, the macOS path is not compiled. On Darwin CI, test that `getPowerInfo()` returns a valid `PowerInfo` without crashing (the actual values depend on the machine).

### Unit Tests for `conditional.zig`

Extend the existing test:

```zig
test "conditional power match" {
    const state: State = .{ .power = .battery };
    try testing.expect(state.match(.{ .key = .power, .op = .eq, .value = "battery" }));
    try testing.expect(!state.match(.{ .key = .power, .op = .eq, .value = "ac" }));
    try testing.expect(state.match(.{ .key = .power, .op = .ne, .value = "critical" }));
}

test "conditional power and theme independence" {
    const state: State = .{ .theme = .dark, .power = .critical };
    // Power match should not affect theme match
    try testing.expect(state.match(.{ .key = .theme, .op = .eq, .value = "dark" }));
    try testing.expect(state.match(.{ .key = .power, .op = .eq, .value = "critical" }));
    // Changing one should not affect the other
    const state2: State = .{ .theme = .light, .power = .critical };
    try testing.expect(state2.match(.{ .key = .theme, .op = .eq, .value = "light" }));
    try testing.expect(state2.match(.{ .key = .power, .op = .eq, .value = "critical" }));
}
```

### Unit Tests for Config

1. **PowerMode parsing** — `"auto"`, `"performance"`, `"efficiency"`, `"off"` parse correctly.
2. **Critical threshold validation** — Values 0-99 accepted, 100+ rejected.
3. **Poll interval validation** — Values 5-300 accepted, below 5 rejected.
4. **draw-interval default** — Default is 8, overridable.
5. **draw-interval validation** — Values 2-100 accepted, 0, 1, and 101+ rejected.

### Unit Tests for Auto Defaults

1. **Auto mode applies defaults** — `power-mode=auto`, power=battery, no user conditionals. `draw-interval` resolves to 16.
2. **User override wins** — `power-mode=auto`, power=battery, user writes `[conditional:power=battery] draw-interval=8`. `draw-interval` resolves to 8.
3. **Performance mode** — `power-mode=performance`. Power conditional state forced to `ac` regardless of actual battery.
4. **Efficiency mode** — `power-mode=efficiency`. Power conditional state forced to `critical`.
5. **Off mode** — `power-mode=off`. No power polling, conditional state stays at default `.ac`.
6. **Auto mode with threshold 0** — Critical state never reached, only ac/battery transitions.

### Integration Tests

1. **State transition propagation** — Simulate power state change from `ac` → `battery`. Verify renderer's `DerivedConfig` updates with new `draw_interval_ms`.
2. **Config reload during power monitoring** — User reloads config while power polling is active. Verify new `power-poll-interval` is respected on next tick.
3. **Power-mode change at runtime** — Change `power-mode` from `auto` to `off`. Verify polling stops (no more `getPowerInfo` calls).
4. **Theme + power independence** — Change theme from light to dark while on battery. Verify both conditional dimensions apply correctly and don't interfere.

## File Changes Summary

| File | Change |
|---|---|
| `src/os/power.zig` | **NEW** — Power detection module |
| `src/os/main.zig` | Export `power` module |
| `src/config/Config.zig` | Add `power-mode`, `power-critical-threshold`, `power-poll-interval`, `draw-interval`, `PowerMode` enum |
| `src/config/conditional.zig` | Add `power: Power` field and `Power` enum to `State` |
| `src/App.zig` | Add timestamp-gated power check in `tick()`, propagate via `config_conditional_state` + soft reload |
| `src/renderer/Thread.zig` | Replace `DRAW_INTERVAL` with `config.draw_interval_ms` in `DerivedConfig`, call `syncDrawTimer()` in `changeConfig()` |
| `src/renderer/generic.zig` | Add `draw_interval_ms` to renderer `DerivedConfig` |
| `pkg/macos/build.zig` | Link `IOKit.framework` gated on `target.result.os.tag == .macos` (matching Carbon framework pattern at lines 37-39) |

## Out of Scope

- **Event-driven notifications** (udev, IOPSNotification) — future enhancement, polling is sufficient for v1.
- **Windows support** — returns `.ac` with `null` percent. Can be added later via `GetSystemPowerStatus()`.
- **Per-surface power config** — all surfaces share the same power state.
- **Power state in status bar / OSC** — exposing power info to shell programs.
- **Fixing macOS process attribution** (Issue #9263) — unfixable at the terminal level.
- **Wayland idle inhibitor interaction** — compositor idle detection behavior when Ghostty reduces frame rate on battery. Worth investigating in a follow-up.

## Risks

1. **Upstream acceptance** — `power-mode` defaults to `off`, so this is zero-impact for existing users. The conditional config extension is minimal. The `draw-interval` config has independent value even without power management.
2. **Sysfs path variation** — Some Linux systems name batteries `BAT0`, others `battery`, others `CMB0`. The implementation iterates all entries and checks `type` files rather than hardcoding names.
3. **IOKit framework availability** — IOKit is available on all macOS versions Ghostty supports. The API is stable and public (not private like `responsibility_spawnattrs_setdisclaim`).
4. **Multiple dynamic conditionals** — `power` is only the second runtime-dynamic conditional key (after `theme`). The `changeConditionalState` code path handles this correctly in theory (iterates all keys), but has only been tested with one dynamic key. Integration tests must cover independent theme + power state changes.
5. **tick() frequency** — `App.tick()` is called on every apprt loop iteration. The timestamp check adds one `std.time.Instant.now()` call per tick, which is a single `clock_gettime` syscall on Linux and `mach_absolute_time` on macOS — negligible overhead.
