# Adaptive Power Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add battery-aware power management to Ghostty that detects AC/battery/critical states and adjusts rendering parameters via the existing conditional config system.

**Architecture:** Extend `conditional.zig`'s `State` struct with a `power` field. Add `src/os/power.zig` for cross-platform battery detection. Poll via timestamp check in `App.tick()`. Propagate state changes through the existing `changeConditionalState` → `reload_config` pipeline.

**Tech Stack:** Zig, sysfs (Linux), IOKit/IOPowerSources (macOS), xev event loop

**Spec:** `docs/superpowers/specs/2026-03-26-adaptive-power-management-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `src/os/power.zig` | **NEW** — Cross-platform power state detection (sysfs on Linux, IOKit on macOS, fallback for others) |
| `src/os/main.zig` | Export `power` module |
| `src/config/conditional.zig` | Add `Power` enum and `power` field to `State` |
| `src/config/Config.zig` | Add `PowerMode` enum, `power-mode`, `power-critical-threshold`, `power-poll-interval`, `draw-interval` config options |
| `src/App.zig` | Timestamp-gated power polling in `tick()`, state propagation via `config_conditional_state` |
| `src/renderer/Thread.zig` | Replace `DRAW_INTERVAL` constant with `config.draw_interval_ms` in `DerivedConfig` |
| `src/renderer/generic.zig` | No changes needed — `draw_interval_ms` lives in Thread's DerivedConfig, not renderer's |
| `pkg/macos/build.zig` | Link `IOKit.framework` gated on `.macos` |

---

### Task 1: `src/os/power.zig` — Linux Power Detection with Tests

**Files:**
- Create: `src/os/power.zig`
- Modify: `src/os/main.zig:1-81`

- [ ] **Step 1: Write test cases for Linux sysfs power detection**

Create `src/os/power.zig` with types, the testable `getPowerInfoFromPath` function signature, and all test cases. The tests create temporary directories mimicking sysfs structure.

```zig
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const PowerState = enum { ac, battery, critical };

pub const PowerInfo = struct {
    state: PowerState,
    battery_percent: ?u8,
};

/// Returns current power state. Pure function, no side effects.
/// Never errors — returns .ac with null percent on any failure.
pub fn getPowerInfo(critical_threshold: u8) PowerInfo {
    if (comptime builtin.os.tag == .linux) {
        return getPowerInfoFromPath("/sys/class/power_supply", critical_threshold);
    }
    // TODO: macOS implementation in Task 2
    return .{ .state = .ac, .battery_percent = null };
}

/// Testable version that accepts a custom sysfs path.
pub fn getPowerInfoFromPath(base_path: []const u8, critical_threshold: u8) PowerInfo {
    _ = base_path;
    _ = critical_threshold;
    return .{ .state = .ac, .battery_percent = null };
}

/// Read a single-line sysfs file, trimming whitespace.
fn readSysFile(dir: std.fs.Dir, name: []const u8, buf: []u8) ?[]const u8 {
    _ = dir;
    _ = name;
    _ = buf;
    return null;
}

// ── Helper for tests ──

fn createMockSysfs(
    tmp: *std.testing.TmpDir,
    devices: []const struct {
        name: []const u8,
        type_val: []const u8,
        files: []const struct { name: []const u8, value: []const u8 },
    },
) ![]const u8 {
    for (devices) |device| {
        try tmp.dir.makePath(device.name);
        var dev_dir = try tmp.dir.openDir(device.name, .{});
        defer dev_dir.close();

        // Write "type" file
        {
            const f = try dev_dir.createFile("type", .{});
            defer f.close();
            try f.writeAll(device.type_val);
        }

        // Write additional files
        for (device.files) |file| {
            const f = try dev_dir.createFile(file.name, .{});
            defer f.close();
            try f.writeAll(file.value);
        }
    }

    // Return the path as a slice we can pass to getPowerInfoFromPath
    return try tmp.dir.realpathAlloc(std.testing.allocator, ".");
}

test "power: ac power only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "AC", .type_val = "Mains", .files = &.{
            .{ .name = "online", .value = "1" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expect(info.battery_percent == null);
}

test "power: battery discharging at 50%" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "50" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 50), info.battery_percent);
}

test "power: battery critical at 15%" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "15" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 15), info.battery_percent);
}

test "power: battery charging reports ac" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Charging" },
            .{ .name = "capacity", .value = "40" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 40), info.battery_percent);
}

test "power: battery full reports ac" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Full" },
            .{ .name = "capacity", .value = "100" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 100), info.battery_percent);
}

test "power: no power supply directory" {
    const info = getPowerInfoFromPath("/nonexistent/path/that/doesnt/exist", 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expect(info.battery_percent == null);
}

test "power: malformed capacity file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "abc" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expect(info.battery_percent == null);
}

test "power: empty directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expect(info.battery_percent == null);
}

test "power: multiple batteries uses lowest capacity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "30" },
        } },
        .{ .name = "BAT1", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "60" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 30), info.battery_percent);
}

test "power: ac online overrides battery discharging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "AC", .type_val = "Mains", .files = &.{
            .{ .name = "online", .value = "1" },
        } },
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "45" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.ac, info.state);
    try std.testing.expectEqual(@as(?u8, 45), info.battery_percent);
}

test "power: threshold boundary - capacity equals threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "20" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 20), info.battery_percent);
}

test "power: capacity at 0" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "0" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.critical, info.state);
    try std.testing.expectEqual(@as(?u8, 0), info.battery_percent);
}

test "power: threshold 0 disables critical state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "5" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 0);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 5), info.battery_percent);
}

test "power: capacity 100 while discharging" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try createMockSysfs(&tmp, &.{
        .{ .name = "BAT0", .type_val = "Battery", .files = &.{
            .{ .name = "status", .value = "Discharging" },
            .{ .name = "capacity", .value = "100" },
        } },
    });
    defer std.testing.allocator.free(path);

    const info = getPowerInfoFromPath(path, 20);
    try std.testing.expectEqual(PowerState.battery, info.state);
    try std.testing.expectEqual(@as(?u8, 100), info.battery_percent);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="power" 2>&1 | head -30`
Expected: Multiple FAIL results (stub implementation returns `.ac` for everything)

- [ ] **Step 3: Implement `getPowerInfoFromPath` and `readSysFile`**

Replace the stub implementations:

```zig
/// Read a single-line sysfs file, trimming whitespace.
fn readSysFile(dir: std.fs.Dir, name: []const u8, buf: []u8) ?[]const u8 {
    const file = dir.openFile(name, .{}) catch return null;
    defer file.close();
    const len = file.readAll(buf) catch return null;
    return std.mem.trimRight(u8, buf[0..len], &std.ascii.whitespace);
}

/// Testable version that accepts a custom sysfs path.
pub fn getPowerInfoFromPath(base_path: []const u8, critical_threshold: u8) PowerInfo {
    var dir = std.fs.openDirAbsolute(base_path, .{ .iterate = true }) catch
        return .{ .state = .ac, .battery_percent = null };
    defer dir.close();

    var ac_online = false;
    var battery_charging = false;
    var lowest_capacity: ?u8 = null;
    var found_battery = false;

    var buf: [256]u8 = undefined;

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        var dev_dir = dir.openDir(entry.name, .{}) catch continue;
        defer dev_dir.close();

        const dev_type = readSysFile(dev_dir, "type", &buf) orelse continue;

        if (std.mem.eql(u8, dev_type, "Mains")) {
            const online = readSysFile(dev_dir, "online", &buf) orelse continue;
            if (std.mem.eql(u8, online, "1")) {
                ac_online = true;
            }
        } else if (std.mem.eql(u8, dev_type, "Battery")) {
            found_battery = true;

            const status = readSysFile(dev_dir, "status", &buf) orelse continue;
            if (std.mem.eql(u8, status, "Charging") or std.mem.eql(u8, status, "Full")) {
                battery_charging = true;
            }

            const cap_str = readSysFile(dev_dir, "capacity", &buf) orelse continue;
            const capacity = std.fmt.parseInt(u8, cap_str, 10) catch continue;

            if (lowest_capacity) |current| {
                if (capacity < current) lowest_capacity = capacity;
            } else {
                lowest_capacity = capacity;
            }
        }
    }

    // Determine state
    if (ac_online or battery_charging or !found_battery) {
        return .{ .state = .ac, .battery_percent = lowest_capacity };
    }

    // On battery — check if critical
    if (lowest_capacity) |cap| {
        if (critical_threshold > 0 and cap <= critical_threshold) {
            return .{ .state = .critical, .battery_percent = cap };
        }
        return .{ .state = .battery, .battery_percent = cap };
    }

    // Found battery but couldn't read capacity — treat as unknown/ac
    return .{ .state = .ac, .battery_percent = null };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="power" 2>&1 | tail -5`
Expected: All tests PASS

- [ ] **Step 5: Export from `src/os/main.zig`**

Add to the imports section (after line 18, `const kernel_info`):

```zig
const power = @import("power.zig");
```

Add to the `pub` exports section (after line 33, `pub const uri`):

```zig
pub const power = @import("power.zig");
```

Wait — the pattern is inconsistent. Some modules are imported as `const` and re-exported as functions, others are directly `pub const`. Looking at the file, `power` is a namespace module (like `shell`, `uri`), so use the direct pub pattern:

Add after line 33 (`pub const uri = @import("uri.zig");`):
```zig
pub const power = @import("power.zig");
```

Add `power` to the test block at the bottom (inside `test {}`):
```zig
    if (comptime builtin.os.tag == .linux) {
        _ = power;
    }
```

(Inside the existing `if (comptime builtin.os.tag == .linux)` block, after `_ = kernel_info;`)

- [ ] **Step 6: Commit**

```bash
git add src/os/power.zig src/os/main.zig
git commit -m "feat: add power detection module with Linux sysfs support

Cross-platform power state detection via os.power.getPowerInfo().
Linux reads /sys/class/power_supply/ for battery status and capacity.
Other platforms return .ac as fallback. Includes 14 unit tests with
mock sysfs directories."
```

---

### Task 2: Extend Conditional Config with `power` State

**Files:**
- Modify: `src/config/conditional.zig:9-16` (State struct)

- [ ] **Step 1: Write failing test for power conditional matching**

Add to `src/config/conditional.zig` after the existing test at line 94:

```zig
test "conditional power match" {
    const testing = std.testing;
    const state: State = .{ .power = .battery };
    try testing.expect(state.match(.{
        .key = .power,
        .op = .eq,
        .value = "battery",
    }));
    try testing.expect(!state.match(.{
        .key = .power,
        .op = .eq,
        .value = "ac",
    }));
    try testing.expect(state.match(.{
        .key = .power,
        .op = .ne,
        .value = "critical",
    }));
}

test "conditional power and theme independence" {
    const testing = std.testing;
    const state: State = .{ .theme = .dark, .power = .critical };
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .eq,
        .value = "dark",
    }));
    try testing.expect(state.match(.{
        .key = .power,
        .op = .eq,
        .value = "critical",
    }));

    const state2: State = .{ .theme = .light, .power = .critical };
    try testing.expect(state2.match(.{
        .key = .theme,
        .op = .eq,
        .value = "light",
    }));
    try testing.expect(state2.match(.{
        .key = .power,
        .op = .eq,
        .value = "critical",
    }));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="conditional" 2>&1 | head -10`
Expected: Compile error — `.power` field doesn't exist on `State`

- [ ] **Step 3: Add `Power` enum and `power` field to `State`**

In `src/config/conditional.zig`, modify the `State` struct (lines 9-16):

```zig
pub const State = struct {
    /// The theme of the underlying OS desktop environment.
    theme: Theme = .light,

    /// The target OS of the current build.
    os: std.Target.Os.Tag = builtin.target.os.tag,

    /// The current power state of the machine.
    power: Power = .ac,

    pub const Theme = enum { light, dark };
    pub const Power = enum { ac, battery, critical };
```

The `Key` enum is auto-generated from `State` fields at comptime (lines 40-54), so it automatically includes `.power`. The `match()` function uses `@tagName(raw)` on enum values (line 28), which works for `Power` since it's an enum. No other changes needed.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="conditional" 2>&1 | tail -5`
Expected: All tests PASS (including original theme test + new power tests)

- [ ] **Step 5: Commit**

```bash
git add src/config/conditional.zig
git commit -m "feat: add power state to conditional config system

Add Power enum (ac/battery/critical) to conditional.State.
The Key enum auto-generates to include .power. Existing match()
logic works unchanged since Power is an enum like Theme."
```

---

### Task 3: Add Config Options to `Config.zig`

**Files:**
- Modify: `src/config/Config.zig`

- [ ] **Step 1: Add `PowerMode` enum**

Find the config enums section (near line 5213 where `ConfirmCloseSurface` is defined). Add `PowerMode` nearby:

```zig
pub const PowerMode = enum {
    /// Detect power state and apply conditional defaults.
    auto,
    /// Always use full performance settings (force power=ac).
    performance,
    /// Always use power-saving settings (force power=critical).
    efficiency,
    /// Disable power detection entirely.
    off,
};
```

- [ ] **Step 2: Add config fields**

Add these fields to the Config struct. Place them near other rendering/performance options (near `@"window-vsync"` around line 2000):

```zig
/// Controls whether Ghostty adapts behavior based on power state.
///
/// `auto`: Detect power state via OS APIs and apply conditional defaults
/// for reduced power consumption on battery. `performance`: Always use
/// full performance settings regardless of power state. `efficiency`:
/// Always use power-saving settings regardless of power state. `off`:
/// Disable power detection entirely. No polling occurs. This is the
/// default because desktop machines without batteries should not pay
/// the cost of periodic polling.
@"power-mode": PowerMode = .off,

/// Battery percentage at or below which the power state transitions
/// to "critical". Only relevant when power-mode is "auto".
/// Set to 0 to disable the critical state entirely.
@"power-critical-threshold": u8 = 20,

/// How often to poll for power state changes, in seconds.
/// Only relevant when power-mode is "auto".
@"power-poll-interval": u16 = 30,

/// Draw interval in milliseconds for animation frames.
/// Lower values produce smoother animations but consume more power.
/// Default: 8 (approximately 120 FPS).
/// Common values: 16 (60 FPS), 32 (30 FPS).
@"draw-interval": u16 = 8,
```

- [ ] **Step 3: Add validation in `finalize()`**

In the `finalize()` function (starting at line 4491), add validation clamping:

```zig
    // Clamp power-related config values
    self.@"power-critical-threshold" = @min(self.@"power-critical-threshold", 99);
    self.@"power-poll-interval" = @max(5, @min(self.@"power-poll-interval", 300));
    self.@"draw-interval" = @max(2, @min(self.@"draw-interval", 100));
```

- [ ] **Step 4: Run config tests**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="Config" 2>&1 | tail -5`
Expected: All existing tests pass (new fields have defaults, no breakage)

- [ ] **Step 5: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat: add power-mode, draw-interval, and related config options

New config: power-mode (auto/performance/efficiency/off, default off),
power-critical-threshold (0-99, default 20), power-poll-interval
(5-300s, default 30), draw-interval (2-100ms, default 8).
Includes validation clamping in finalize()."
```

---

### Task 4: Replace `DRAW_INTERVAL` with Config-Driven Value in Renderer

**Files:**
- Modify: `src/renderer/Thread.zig:19,112-120,295-334,488-490,570-594`
- Modify: `src/renderer/generic.zig:536+`

- [ ] **Step 1: Add `draw_interval_ms` to Thread's `DerivedConfig`**

In `src/renderer/Thread.zig`, modify `DerivedConfig` (lines 112-120):

```zig
pub const DerivedConfig = struct {
    custom_shader_animation: configpkg.CustomShaderAnimation,
    draw_interval_ms: u16,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .custom_shader_animation = config.@"custom-shader-animation",
            .draw_interval_ms = config.@"draw-interval",
        };
    }
};
```

- [ ] **Step 2: Replace `DRAW_INTERVAL` constant usage in `syncDrawTimer`**

In `src/renderer/Thread.zig`, line 329, change:
```zig
        DRAW_INTERVAL,
```
to:
```zig
        self.config.draw_interval_ms,
```

- [ ] **Step 3: Replace `DRAW_INTERVAL` constant usage in `drawCallback`**

In `src/renderer/Thread.zig`, line 590, change:
```zig
        t.draw_h.run(&t.loop, &t.draw_c, DRAW_INTERVAL, Thread, t, drawCallback);
```
to:
```zig
        t.draw_h.run(&t.loop, &t.draw_c, t.config.draw_interval_ms, Thread, t, drawCallback);
```

- [ ] **Step 4: Remove the `DRAW_INTERVAL` constant**

Delete line 19:
```zig
const DRAW_INTERVAL = 8; // 120 FPS
```

- [ ] **Step 5: Verify the renderer tests still pass**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="Thread" 2>&1 | tail -5`
Expected: All tests pass (or compile succeeds if there are no Thread-specific tests)

- [ ] **Step 6: Commit**

```bash
git add src/renderer/Thread.zig
git commit -m "feat: replace hardcoded DRAW_INTERVAL with config-driven draw_interval_ms

Frame rate is now controlled by the draw-interval config option
instead of a hardcoded 8ms constant. Both syncDrawTimer() and
drawCallback() use the config value."
```

---

### Task 5: Power Polling in `App.zig`

**Files:**
- Modify: `src/App.zig:40-70,89-103,126-132`

- [ ] **Step 1: Add power polling fields to `App` struct**

In `src/App.zig`, add after line 60 (`last_notification_digest`):

```zig
/// Timestamp of last power state check for polling.
last_power_check: ?std.time.Instant = null,

/// Last observed power state to detect transitions.
last_power_state: ?configpkg.ConditionalState.Power = null,
```

- [ ] **Step 2: Initialize power state in `init()`**

The `init()` function (line 89-103) initializes `config_conditional_state`. Power state initialization depends on `power-mode`, but `init()` doesn't have access to the config. The initial power state is set on the first `tick()` call via the polling mechanism, which is the right approach — it mirrors how `colorSchemeEvent` works (called after init by the apprt).

No change needed in `init()`. The defaults (`.ac`, `null` for last_power fields) are correct.

- [ ] **Step 3: Add `internal_os` import**

`App.zig` does not currently import the OS module. Add near the top with other imports:

```zig
const internal_os = @import("os/main.zig");
```

- [ ] **Step 4: Add power polling to `tick()`**

Modify `tick()` at line 129-132. Add the power poll after `drainMailbox`:

```zig
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    // Drain our mailbox
    try self.drainMailbox(rt_app);

    // Poll power state if auto mode is enabled.
    // We check this on the config from the apprt since that's what
    // determines our behavior.
    try self.pollPowerState(rt_app);
}
```

- [ ] **Step 5: Implement `pollPowerState`**

Add after `tick()`:

```zig
/// Poll the power state and trigger a config reload if it changed.
/// Only active when power-mode is .auto.
fn pollPowerState(self: *App, rt_app: *apprt.App) !void {
    const config = rt_app.config();
    const power_mode = config.@"power-mode";

    switch (power_mode) {
        .off => return,
        .performance => {
            if (self.config_conditional_state.power != .ac) {
                self.config_conditional_state.power = .ac;
                _ = try rt_app.performAction(.app, .reload_config, .{ .soft = true });
            }
            return;
        },
        .efficiency => {
            if (self.config_conditional_state.power != .critical) {
                self.config_conditional_state.power = .critical;
                _ = try rt_app.performAction(.app, .reload_config, .{ .soft = true });
            }
            return;
        },
        .auto => {},
    }

    // Check if enough time has elapsed since last poll
    const now = std.time.Instant.now() catch return;
    if (self.last_power_check) |last| {
        const elapsed_ns = now.since(last);
        const interval_ns: u64 = @as(u64, config.@"power-poll-interval") * std.time.ns_per_s;
        if (elapsed_ns < interval_ns) return;
    }
    self.last_power_check = now;

    // Poll power state
    const info = internal_os.power.getPowerInfo(config.@"power-critical-threshold");
    const new_state = info.state;

    // Only trigger reload if state actually changed
    if (self.last_power_state) |last_state| {
        if (last_state == new_state) return;
    }
    self.last_power_state = new_state;
    self.config_conditional_state.power = new_state;

    _ = try rt_app.performAction(.app, .reload_config, .{ .soft = true });
}
```

- [ ] **Step 6: Verify compilation**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build 2>&1 | head -20`
Expected: Clean compilation (or warnings about unused imports that we'll fix)

Note: The `rt_app.config()` call and `performAction(.app, .reload_config, ...)` pattern need to match the actual apprt interface. Check the existing `colorSchemeEvent` call at line 426 for the exact signature and adjust accordingly.

- [ ] **Step 7: Commit**

```bash
git add src/App.zig
git commit -m "feat: add power state polling in App.tick()"
```

```bash
git add src/App.zig
git commit -m "feat: add power state polling in App.tick()

Polls battery state every power-poll-interval seconds when
power-mode=auto. Triggers config reload via existing
changeConditionalState pipeline when state transitions between
ac/battery/critical."
```

---

### Task 6: Build System — Link IOKit on macOS

**Files:**
- Modify: `pkg/macos/build.zig:37-40`

- [ ] **Step 1: Add IOKit framework linking**

In `pkg/macos/build.zig`, after line 39 (`module.linkFramework("Carbon", .{});`), still inside the `if (target.result.os.tag == .macos)` block:

```zig
    if (target.result.os.tag == .macos) {
        lib.linkFramework("Carbon");
        module.linkFramework("Carbon", .{});
        lib.linkFramework("IOKit");
        module.linkFramework("IOKit", .{});
    }
```

- [ ] **Step 2: Commit**

```bash
git add pkg/macos/build.zig
git commit -m "build: link IOKit framework on macOS for power detection

IOKit provides IOPowerSources API used by os.power module
for battery state detection. Gated on .macos (not all Darwin)
to match Carbon framework pattern."
```

---

### Task 7: macOS Power Detection Implementation

**Files:**
- Modify: `src/os/power.zig`

This task adds the macOS implementation using IOKit's IOPowerSources C API. It is compile-time gated so it only compiles on Darwin.

- [ ] **Step 1: Add macOS extern declarations and implementation**

In `src/os/power.zig`, update `getPowerInfo` and add macOS-specific code.

**Note on pattern choice:** Ghostty's `src/os/macos.zig` uses extern function declarations (e.g., `extern fn pthread_set_qos_class_self_np(...)`) rather than `@cImport`. However, the IOPowerSources API involves extensive CoreFoundation types (`CFDictionaryRef`, `CFStringRef`, `CFArrayRef`) that are tedious to declare individually. Using `@cImport` here is pragmatic — if it causes issues during implementation, switch to extern declarations following the `macos.zig` pattern.

```zig
pub fn getPowerInfo(critical_threshold: u8) PowerInfo {
    if (comptime builtin.os.tag == .linux) {
        return getPowerInfoFromPath("/sys/class/power_supply", critical_threshold);
    } else if (comptime builtin.os.tag == .macos) {
        return getMacOSPowerInfo(critical_threshold);
    }
    return .{ .state = .ac, .battery_percent = null };
}

// ── macOS implementation ──

fn getMacOSPowerInfo(critical_threshold: u8) PowerInfo {
    if (comptime builtin.os.tag != .macos) unreachable;

    const c = @cImport({
        @cInclude("IOKit/ps/IOPowerSources.h");
        @cInclude("IOKit/ps/IOPSKeys.h");
    });

    const info = c.IOPSCopyPowerSourcesInfo() orelse
        return .{ .state = .ac, .battery_percent = null };
    defer c.CFRelease(info);

    const list = c.IOPSCopyPowerSourcesList(info) orelse
        return .{ .state = .ac, .battery_percent = null };
    defer c.CFRelease(list);

    const count = c.CFArrayGetCount(list);
    if (count == 0) return .{ .state = .ac, .battery_percent = null };

    // Check providing power source type
    const source_type = c.IOPSGetProvidingPowerSourceType(info);
    const is_battery = if (source_type) |st|
        c.CFStringCompare(st, c.CFSTR("Battery Power"), 0) == c.kCFCompareEqualTo
    else
        false;

    // Get capacity from first power source
    var battery_percent: ?u8 = null;
    if (count > 0) {
        const ps = c.CFArrayGetValueAtIndex(list, 0);
        const desc = c.IOPSGetPowerSourceDescription(info, ps); // "Get" — do NOT CFRelease
        if (desc) |d| {
            const cap_key = c.CFSTR(c.kIOPSCurrentCapacityKey);
            if (c.CFDictionaryGetValue(d, cap_key)) |cap_val| {
                var cap: c_int = 0;
                if (c.CFNumberGetValue(@ptrCast(cap_val), c.kCFNumberIntType, &cap)) {
                    if (cap >= 0 and cap <= 100) {
                        battery_percent = @intCast(@as(u32, @bitCast(cap)));
                    }
                }
            }
        }
    }

    if (!is_battery) {
        return .{ .state = .ac, .battery_percent = battery_percent };
    }

    // On battery — check critical
    if (battery_percent) |cap| {
        if (critical_threshold > 0 and cap <= critical_threshold) {
            return .{ .state = .critical, .battery_percent = cap };
        }
    }

    return .{ .state = .battery, .battery_percent = battery_percent };
}
```

- [ ] **Step 2: Verify compilation on Linux (macOS code is compile-time gated)**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build 2>&1 | head -10`
Expected: Clean compilation (macOS code not compiled on Linux)

- [ ] **Step 3: Commit**

```bash
git add src/os/power.zig
git commit -m "feat: add macOS power detection via IOKit IOPowerSources

Uses IOPSCopyPowerSourcesInfo/IOPSGetProvidingPowerSourceType for
AC vs battery detection, CFDictionary lookup for capacity percent.
Compile-time gated to macOS only. Proper CFRelease memory management."
```

---

### Task 8: Auto Mode Default Injection

**Files:**
- Modify: `src/config/Config.zig` (finalize function)

This task injects synthetic conditional entries when `power-mode = auto` so users get sensible defaults without writing any `[conditional:power=...]` blocks.

- [ ] **Step 1: Understand the replay mechanism**

The `Replay.Step` union (line 5093 of `Config.zig`) already has a `conditional_arg` variant:

```zig
conditional_arg: struct {
    conditions: []const Conditional,
    arg: []const u8,
},
```

This is exactly what we need. When `power-mode == .auto`, we inject `conditional_arg` replay steps with power conditions. These steps get replayed during `changeConditionalState()` (which calls `cloneEmpty` + `loadIter` with the replay steps), so the conditional values are applied correctly.

The key insight: replay steps are appended to `_replay_steps` during config loading. To make auto-defaults *lower priority* than user config, we insert them at the **beginning** of `_replay_steps` in `finalize()`, so user-defined entries (which appear later) override them.

- [ ] **Step 2: Implement auto-default injection in `finalize()`**

In `finalize()`, after the existing validation clamping (added in Task 3), add:

```zig
    // Inject auto-mode power defaults as conditional replay steps.
    // These are prepended so user-defined conditional blocks override them.
    if (self.@"power-mode" == .auto) {
        const arena_alloc = self._arena.?.allocator();

        // Battery defaults
        const battery_cond = try arena_alloc.dupe(conditional.Conditional, &.{
            .{ .key = .power, .op = .eq, .value = "battery" },
        });
        // Critical defaults
        const critical_cond = try arena_alloc.dupe(conditional.Conditional, &.{
            .{ .key = .power, .op = .eq, .value = "critical" },
        });

        // Build the new steps to prepend
        const auto_steps = &[_]Replay.Step{
            .{ .conditional_arg = .{ .conditions = battery_cond, .arg = "draw-interval=16" } },
            .{ .conditional_arg = .{ .conditions = battery_cond, .arg = "custom-shader-animation=false" } },
            .{ .conditional_arg = .{ .conditions = critical_cond, .arg = "draw-interval=32" } },
            .{ .conditional_arg = .{ .conditions = critical_cond, .arg = "custom-shader-animation=false" } },
            .{ .conditional_arg = .{ .conditions = critical_cond, .arg = "cursor-style-blink=false" } },
            .{ .conditional_arg = .{ .conditions = critical_cond, .arg = "background-blur=false" } },
        };

        // Prepend: insert auto_steps before existing replay steps
        try self._replay_steps.insertSlice(arena_alloc, 0, auto_steps);

        // Mark power as a used conditional key so changeConditionalState
        // knows to re-evaluate when power state changes
        self._conditional_set.insert(.power);
    }
```

**Important:** The `_conditional_set` insertion is critical. Without it, `changeConditionalState()` would skip power state changes because it checks `self._conditional_set.contains(key)` (line 4327).

- [ ] **Step 3: Verify compilation and existing tests**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="Config" 2>&1 | tail -10`
Expected: All existing tests still pass

- [ ] **Step 4: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat: inject auto-mode power defaults during config finalize

When power-mode=auto, prepend default conditional entries for
battery (draw-interval=16, no shader animation) and critical
(draw-interval=32, no shader/blink/blur). User-defined
conditional blocks override these defaults."
```

---

### Task 9: End-to-End Verification

**Files:**
- No new files — verification only

- [ ] **Step 1: Full build verification**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build 2>&1 | head -20`
Expected: Clean compilation with no errors

- [ ] **Step 2: Run all unit tests**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 3: Test power module specifically**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="power" 2>&1`
Expected: All 14 power tests pass

- [ ] **Step 4: Test conditional module specifically**

Run: `cd /home/daaronch/src/legit/src/ghostty && zig build test -Dtest-filter="conditional" 2>&1`
Expected: All conditional tests pass (original + new power tests)

- [ ] **Step 5: Manual smoke test**

Test `power-mode` config by creating a test config and verifying it parses:
```bash
echo 'power-mode = auto' | ghostty +validate-config -
echo 'power-mode = performance' | ghostty +validate-config -
echo 'draw-interval = 16' | ghostty +validate-config -
echo 'power-critical-threshold = 10' | ghostty +validate-config -
```
Expected: All parse without errors

- [ ] **Step 6: Final commit if any fixups needed**

If any fixes were required during verification, stage only the changed files and commit:
```bash
git add <specific-files-that-changed>
git commit -m "fix: address issues found during end-to-end verification"
```
