# Popup Terminal Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize Ghostty's Quick Terminal into a multi-instance, configurable popup terminal system with named profiles.

**Architecture:** PopupManager (per-platform registry) delegates window creation to existing infrastructure. Config uses `parseAutoStruct` colon-based syntax. Backward-compatible migration from `quick-terminal-*` keys. macOS + Wayland only (no X11 in v1).

**Tech Stack:** Zig 0.15.2+, Swift/AppKit (macOS), GTK4/libadwaita (Linux), wlr-layer-shell (Wayland)

**Spec:** `docs/superpowers/specs/2026-03-14-popup-terminal-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `src/apprt/popup.zig` | `PopupProfile` struct, `Dimension` type, `Position`/`Anchor` enums, config name validation |
| `src/apprt/gtk/PopupManager.zig` | GTK popup registry: profiles hashmap, instances hashmap, toggle/show/hide/hideAll, focus-loss handler |
| `macos/Sources/Features/Popup/PopupManager.swift` | macOS popup registry: `[String: PopupController]` dict, toggle/show/hide dispatch |
| `macos/Sources/Features/Popup/PopupWindow.swift` | NSPanel subclass — programmatic (no XIB), floating level, non-activating |
| `macos/Sources/Features/Popup/PopupController.swift` | Per-instance lifecycle — evolved from QuickTerminalController with lazy surface, focus restoration, space handling, per-screen frame cache |

### Modified Files (key changes only)

| File | Key Change |
|------|-----------|
| `src/config/Config.zig` | `popup` repeatable field + `RepeatablePopup` type (with C API) + migration post-processing |
| `src/input/Binding.zig` | `toggle_popup`, `show_popup`, `hide_popup` action variants (string param) + `scope()` entries |
| `src/apprt/action.zig` | Same 3 actions in apprt Action union + `PopupAction` C-compatible payload struct |
| `src/App.zig` | Dispatch bridge: input binding actions → apprt actions (with `[]const u8` → `[:0]const u8` conversion) |
| `include/ghostty.h` | 3 new action enum values + `ghostty_action_popup_s` struct + popup profile C accessors |
| `src/apprt/gtk/class/application.zig` | PopupManager ownership + `performAction` dispatch (stubs added with action.zig to avoid build break) |
| `src/apprt/gtk/class/window.zig` | `is-popup` GObject property (additive, keep `quick-terminal` as alias) |
| `src/apprt/gtk/class/surface.zig` | `GHOSTTY_POPUP` env var injection |
| `src/apprt/gtk/winproto/wayland.zig` | Generalize `syncQuickTerminal` → `syncPopup` using profile data + Wayland-incompatible property warnings |
| `macos/Sources/App/macOS/AppDelegate.swift` | Replace `quickController` with PopupManager |
| `macos/Sources/Ghostty/Ghostty.App.swift` | Handle 3 new action keys in `performAction` |
| `macos/Sources/App/macOS/MainMenu.xib` | Quick Terminal menu item action → PopupManager route |

---

## Chunk 1: Core Types & Config Parsing

### Task 1: Create PopupProfile shared types

**Files:**
- Create: `src/apprt/popup.zig`
- Test: inline tests in `src/apprt/popup.zig`

**Context:** This file defines all shared types used by both platforms. It follows the pattern of other `src/apprt/*.zig` files. The `Dimension` type must handle both pixel and percentage values. `PopupProfile` must be compatible with `parseAutoStruct` (all fields are struct fields with defaults).

- [ ] **Step 1: Write the PopupProfile struct and supporting types**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Dimension: either absolute pixels or percentage of screen.
/// Parsed from strings like "400" (pixels) or "80%" (percentage).
pub const Dimension = struct {
    value: u32,
    unit: Unit,

    pub const Unit = enum { pixels, percent };

    pub fn initPixels(v: u32) Dimension {
        return .{ .value = v, .unit = .pixels };
    }

    pub fn initPercent(v: u32) Dimension {
        return .{ .value = v, .unit = .percent };
    }

    /// Parse from a string like "400" or "80%"
    pub fn parseCLI(input: []const u8) !Dimension {
        if (input.len == 0) return error.InvalidValue;
        if (input[input.len - 1] == '%') {
            const num = std.fmt.parseInt(u32, input[0 .. input.len - 1], 10) catch
                return error.InvalidValue;
            if (num == 0 or num > 100) return error.InvalidValue;
            return initPercent(num);
        }
        const num = std.fmt.parseInt(u32, input, 10) catch
            return error.InvalidValue;
        return initPixels(num);
    }

    pub fn format(
        self: Dimension,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        switch (self.unit) {
            .pixels => try writer.print("{d}", .{self.value}),
            .percent => try writer.print("{d}%", .{self.value}),
        }
    }
};

pub const Position = enum {
    center,
    top,
    bottom,
    left,
    right,
};

pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,
    center,
};

/// Profile definition for a named popup terminal.
/// Field names match parseAutoStruct keys (colon-delimited).
pub const PopupProfile = struct {
    position: Position = .center,
    anchor: ?Anchor = null,
    x: ?Dimension = null,
    y: ?Dimension = null,
    width: Dimension = Dimension.initPercent(80),
    height: Dimension = Dimension.initPercent(80),
    keybind: ?[]const u8 = null,
    command: ?[]const u8 = null,
    autohide: bool = true,
    persist: bool = true,
};

/// Validate a popup profile name.
/// Allowed: [a-zA-Z0-9_-], non-empty.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}
```

- [ ] **Step 2: Write inline tests for Dimension parsing and name validation**

```zig
test "Dimension: parse pixels" {
    const d = try Dimension.parseCLI("400");
    try std.testing.expectEqual(@as(u32, 400), d.value);
    try std.testing.expectEqual(Dimension.Unit.pixels, d.unit);
}

test "Dimension: parse percent" {
    const d = try Dimension.parseCLI("80%");
    try std.testing.expectEqual(@as(u32, 80), d.value);
    try std.testing.expectEqual(Dimension.Unit.percent, d.unit);
}

test "Dimension: reject zero percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("0%"));
}

test "Dimension: reject over 100 percent" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI("101%"));
}

test "Dimension: reject empty" {
    try std.testing.expectError(error.InvalidValue, Dimension.parseCLI(""));
}

test "isValidName: valid names" {
    try std.testing.expect(isValidName("quick"));
    try std.testing.expect(isValidName("my-popup"));
    try std.testing.expect(isValidName("calc_2"));
}

test "isValidName: invalid names" {
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("bad name"));
    try std.testing.expect(!isValidName("bad:name"));
    try std.testing.expect(!isValidName("bad@name"));
}
```

- [ ] **Step 3: Run tests to verify**

Run: `zig build test -Dtest-filter="Dimension" && zig build test -Dtest-filter="isValidName"`
Expected: All PASS

- [ ] **Step 4: Commit**

```bash
git add src/apprt/popup.zig
git commit -m "feat: add PopupProfile shared types (popup.zig)"
```

---

### Task 2: Add popup repeatable config field

**Files:**
- Modify: `src/config/Config.zig` (add field + RepeatablePopup type)
- Reference: `src/config/Config.zig:8623-8679` (RepeatableCommand pattern)
- Reference: `src/cli/args.zig:525-604` (parseAutoStruct)

**Context:** Follow the exact `RepeatableCommand` pattern at `Config.zig:8623`. The `popup` field is a repeatable list where each line is `<name>:<parseAutoStruct fields>`. The name is extracted before feeding to `parseAutoStruct`.

- [ ] **Step 1: Add the `popup` config field declaration**

In `src/config/Config.zig`, add after the `keybind` field (around line 1817):

```zig
/// Named popup terminal profiles. Each popup is a floating terminal window
/// that can be toggled with a keybinding. See the documentation for the
/// full list of properties.
///
/// Example:
///     popup = quick:position:top,width:100%,height:50%,keybind:ctrl+`
///     popup = scratch:position:center,width:80%,height:80%
popup: RepeatablePopup = .{},
```

- [ ] **Step 2: Implement RepeatablePopup type**

Add after the existing `RepeatableCommand` type (around line 8700), following its exact pattern:

```zig
pub const RepeatablePopup = struct {
    const Self = @This();

    /// Parsed popup profiles: parallel arrays for names and profiles.
    /// Using ArrayLists (not HashMap) to match RepeatableCommand pattern
    /// and support C API iteration.
    names: std.ArrayListUnmanaged([:0]const u8) = .empty,
    profiles: std.ArrayListUnmanaged(popupmod.PopupProfile) = .empty,

    /// C-compatible struct for iterating profiles from Swift.
    /// Sync with: ghostty_config_popup_s
    pub const C = extern struct {
        names: [*][*:0]const u8,
        profiles: [*]popupmod.PopupProfile.C,
        len: usize,
    };

    pub fn parseCLI(
        self: *Self,
        alloc: Allocator,
        input_: ?[]const u8,
    ) !void {
        const input = input_ orelse "";
        if (input.len == 0) {
            // Empty input clears all popups
            self.names.clearRetainingCapacity();
            self.profiles.clearRetainingCapacity();
            return;
        }

        // Extract name by splitting on first colon
        const colon_idx = std.mem.indexOf(u8, input, ":") orelse
            return error.InvalidValue;
        const name_raw = std.mem.trim(u8, input[0..colon_idx], " ");

        if (!popupmod.isValidName(name_raw))
            return error.InvalidValue;

        const remainder = input[colon_idx + 1 ..];

        // Parse remainder using parseAutoStruct
        const profile = try cli.args.parseAutoStruct(
            popupmod.PopupProfile,
            alloc,
            remainder,
            null,
        );

        // Duplicate name with sentinel terminator for C API
        const name = try alloc.dupeZ(u8, name_raw);

        // Last definition wins: check if name already exists
        for (self.names.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, name_raw)) {
                self.profiles.items[i] = profile;
                alloc.free(name); // Don't leak
                return;
            }
        }

        // New name — append
        try self.names.append(alloc, name);
        try self.profiles.append(alloc, profile);
    }

    /// Get a profile by name. Returns null if not found.
    pub fn get(self: *const Self, name: []const u8) ?popupmod.PopupProfile {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return self.profiles.items[i];
        }
        return null;
    }

    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        var new: Self = .{};
        for (self.names.items) |name| {
            try new.names.append(alloc, try alloc.dupeZ(u8, name));
        }
        for (self.profiles.items) |profile| {
            try new.profiles.append(alloc, profile);
        }
        return new;
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        for (self.names.items) |name| alloc.free(name);
        self.names.deinit(alloc);
        self.profiles.deinit(alloc);
    }

    pub fn equal(a: Self, b: Self) bool {
        if (a.names.items.len != b.names.items.len) return false;
        for (a.names.items, a.profiles.items, 0..) |name_a, prof_a, i| {
            const name_b = b.names.items[i];
            if (!std.mem.eql(u8, name_a, name_b)) return false;
            if (!std.meta.eql(prof_a, b.profiles.items[i])) return false;
        }
        return true;
    }
};
```

Also add the import at the top of `Config.zig`:
```zig
const popupmod = @import("../apprt/popup.zig");
```

- [ ] **Step 3: Write tests for popup config parsing**

```zig
test "RepeatablePopup: basic parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var popup: RepeatablePopup = .{};
    try popup.parseCLI(alloc, "quick:position:top,width:100%,height:50%");

    try std.testing.expectEqual(@as(usize, 1), popup.names.items.len);
    const profile = popup.get("quick").?;
    try std.testing.expectEqual(popupmod.Position.top, profile.position);
    try std.testing.expectEqual(@as(u32, 100), profile.width.value);
    try std.testing.expectEqual(popupmod.Dimension.Unit.percent, profile.width.unit);
}

test "RepeatablePopup: duplicate name last wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var popup: RepeatablePopup = .{};
    try popup.parseCLI(alloc, "quick:position:top");
    try popup.parseCLI(alloc, "quick:position:center");

    const profile = popup.get("quick").?;
    try std.testing.expectEqual(popupmod.Position.center, profile.position);
}

test "RepeatablePopup: invalid name rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var popup: RepeatablePopup = .{};
    try std.testing.expectError(error.InvalidValue, popup.parseCLI(alloc, ":position:top"));
    try std.testing.expectError(error.InvalidValue, popup.parseCLI(alloc, "b@d:position:top"));
}

test "RepeatablePopup: quoted command with commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var popup: RepeatablePopup = .{};
    try popup.parseCLI(alloc, "calc:command:\"echo hello,world\",position:center");

    const profile = popup.get("calc").?;
    try std.testing.expectEqualStrings("echo hello,world", profile.command.?);
    try std.testing.expectEqual(popupmod.Position.center, profile.position);
}

test "RepeatablePopup: clear on empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var popup: RepeatablePopup = .{};
    try popup.parseCLI(alloc, "quick:position:top");
    try std.testing.expectEqual(@as(usize, 1), popup.names.items.len);

    try popup.parseCLI(alloc, "");
    try std.testing.expectEqual(@as(usize, 0), popup.names.items.len);
}
```

- [ ] **Step 4: Build and run tests**

Run: `zig build test -Dtest-filter="RepeatablePopup"`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add src/config/Config.zig src/apprt/popup.zig
git commit -m "feat: add popup repeatable config field with parseAutoStruct parsing"
```

---

## Chunk 2: Actions & Bindings

### Task 3: Add popup actions to input/Binding.zig

**Files:**
- Modify: `src/input/Binding.zig` (add 3 action variants)
- Reference: `src/input/Binding.zig:317-333` (string-parameter pattern: `text: []const u8`)
- Reference: `src/input/Binding.zig:760` (existing `toggle_quick_terminal`)

**Context:** String-parameter actions are already supported — `text`, `csi`, `esc` all use `[]const u8`. The parse function at line 1217 auto-handles `[]const u8` fields by taking everything after the colon. So `toggle_popup:quick` naturally parses as `toggle_popup` with value `"quick"`.

- [ ] **Step 1: Add the three new action variants**

In `src/input/Binding.zig`, in the `Action` union (after `toggle_quick_terminal` around line 810), add:

```zig
/// Toggle a named popup terminal.
/// The parameter is the popup profile name (e.g., toggle_popup:quick).
toggle_popup: []const u8,

/// Show (or create) a named popup terminal. No-op if already visible.
/// Used by App Intents for show-only semantics.
show_popup: []const u8,

/// Hide a named popup terminal.
hide_popup: []const u8,
```

- [ ] **Step 2: Verify parsing works via existing test infrastructure**

The `parse` function at line 1217 uses comptime reflection over the Action union fields. `[]const u8` fields automatically parse the colon-suffix as the string value. Verify by adding a test:

```zig
test "action: parse toggle_popup" {
    const action = try Action.parse("toggle_popup:quick");
    try std.testing.expectEqualStrings("quick", action.toggle_popup);
}

test "action: parse toggle_popup missing name" {
    try std.testing.expectError(error.InvalidFormat, Action.parse("toggle_popup"));
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test -Dtest-filter="action: parse toggle_popup"`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add src/input/Binding.zig
git commit -m "feat: add toggle_popup/show_popup/hide_popup binding actions"
```

---

### Task 4: Add popup actions to apprt/action.zig and C header

**Files:**
- Modify: `src/apprt/action.zig` (add 3 action variants + TogglePopup payload)
- Modify: `include/ghostty.h` (add 3 enum values + C struct)
- Reference: `src/apprt/action.zig:115` (`toggle_quick_terminal`)
- Reference: `src/apprt/action.zig:694-716` (`SetTitle` pattern)
- Reference: `include/ghostty.h:859-924` (action enum)

**Context:** The apprt Action union uses a `Key` enum for C ABI dispatch. Each variant with a payload needs a C-compatible struct. `toggle_quick_terminal` is currently void (no payload). The new `toggle_popup` needs a string payload following the `SetTitle` pattern.

- [ ] **Step 1: Add TogglePopup payload struct to action.zig**

After `SetTitle` (around line 716):

```zig
/// Payload for popup actions (toggle, show, hide).
/// Sync with: ghostty_action_popup_s
pub const PopupAction = struct {
    name: [:0]const u8,

    pub const C = extern struct {
        name: [*:0]const u8,
    };

    pub fn cval(self: PopupAction) C {
        return .{ .name = self.name.ptr };
    }

    pub fn format(
        value: @This(),
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print("{s}{{ {s} }}", .{ @typeName(@This()), value.name });
    }
};
```

- [ ] **Step 2: Add 3 action variants to the Action union**

After `toggle_quick_terminal` (line 115):

```zig
/// Toggle a named popup terminal visibility.
toggle_popup: PopupAction,

/// Show a named popup terminal (create if needed, no-op if visible).
show_popup: PopupAction,

/// Hide a named popup terminal.
hide_popup: PopupAction,
```

- [ ] **Step 3: Add to Action.Key enum**

In the `Key` enum (around line 347-417), add:

```zig
toggle_popup,
show_popup,
hide_popup,
```

- [ ] **Step 4: Update include/ghostty.h**

Add to the `ghostty_action_tag_e` enum (after `GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL`):

```c
GHOSTTY_ACTION_TOGGLE_POPUP,
GHOSTTY_ACTION_SHOW_POPUP,
GHOSTTY_ACTION_HIDE_POPUP,
```

Add the C struct (after `ghostty_action_set_title_s`):

```c
// apprt.action.PopupAction.C
typedef struct {
  const char* name;
} ghostty_action_popup_s;
```

Add to the `ghostty_action_u` union:

```c
ghostty_action_popup_s toggle_popup;
ghostty_action_popup_s show_popup;
ghostty_action_popup_s hide_popup;
```

- [ ] **Step 5: Add stub handlers to prevent build break**

Adding new variants to `apprt.Action` creates exhaustiveness errors in `performAction` switches. Add stubs in `src/apprt/gtk/class/application.zig` (around line 662):

```zig
.toggle_popup => return false, // TODO: wire to PopupManager in Task 11
.show_popup => return false,
.hide_popup => return false,
```

Similarly check if `src/apprt/embedded.zig` needs stubs (it likely doesn't due to generic dispatch via `@unionInit`).

- [ ] **Step 6: Build to verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles successfully

- [ ] **Step 7: Commit**

```bash
git add src/apprt/action.zig include/ghostty.h src/apprt/gtk/class/application.zig
git commit -m "feat: add popup actions to apprt layer and C header (with dispatch stubs)"
```

---

### Task 5: Add popup actions to command.zig skip list

**Files:**
- Modify: `src/input/command.zig` (add to skip list)
- Reference: `src/input/command.zig:711-714` (existing skip list with `toggle_quick_terminal`)

**Context:** The command palette generates commands at comptime from the Action enum. String-parameter actions can't be statically enumerated, so they must be skipped.

- [ ] **Step 1: Add to skip list**

Find the skip list in `command.zig` (around line 711) and add:

```zig
.toggle_popup,
.show_popup,
.hide_popup,
```

alongside the existing `.toggle_quick_terminal` skip entry.

- [ ] **Step 2: Build to verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles

- [ ] **Step 3: Commit**

```bash
git add src/input/command.zig
git commit -m "feat: skip popup actions in static command palette"
```

---

### Task 6: Add App.zig dispatch bridge and scope entries

**Files:**
- Modify: `src/App.zig` (~line 441 performAction switch, ~line 1291 scope())
- Modify: `src/input/Binding.zig` (~line 1291 scope() function)
- Reference: `src/App.zig:441-456` (existing performAction dispatch)

**Context:** This is the critical bridge between input binding actions (`input.Binding.Action`) and apprt actions (`apprt.Action`). Without this, pressing the keybind does nothing. The input binding uses `[]const u8` for the popup name, but the apprt action needs `[:0]const u8`. The conversion must happen here.

Additionally, the `scope()` function on `Binding.Action` (around line 1291) determines whether an action targets the app or a surface. Popup actions target the app.

- [ ] **Step 1: Add scope entries in Binding.zig**

In the `scope()` function (around line 1291), add:

```zig
.toggle_popup, .show_popup, .hide_popup => .app,
```

- [ ] **Step 2: Add dispatch in App.zig performAction**

In `App.zig`'s `performBindingAction` switch (around line 441), add cases that convert `[]const u8` to `[:0]const u8` and dispatch to the apprt layer:

```zig
.toggle_popup => |name| {
    // Input binding has []const u8, apprt needs [:0]const u8
    const name_z = try self.alloc.dupeZ(u8, name);
    defer self.alloc.free(name_z);
    return try rt_app.performAction(
        target, .toggle_popup, .{ .name = name_z },
    );
},
.show_popup => |name| {
    const name_z = try self.alloc.dupeZ(u8, name);
    defer self.alloc.free(name_z);
    return try rt_app.performAction(
        target, .show_popup, .{ .name = name_z },
    );
},
.hide_popup => |name| {
    const name_z = try self.alloc.dupeZ(u8, name);
    defer self.alloc.free(name_z);
    return try rt_app.performAction(
        target, .hide_popup, .{ .name = name_z },
    );
},
```

**Important:** The `dupeZ` creates a sentinel-terminated copy. It's freed after `performAction` returns, which is safe because `performAction` is synchronous on the app thread and the PopupManager looks up the name in its own copied hashmap.

- [ ] **Step 3: Build to verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles (requires stubs in application.zig — Task 4 step 5 should have added them)

- [ ] **Step 4: Commit**

```bash
git add src/App.zig src/input/Binding.zig
git commit -m "feat: bridge popup binding actions to apprt layer in App.zig"
```

---

## Chunk 3: Config Migration & Keybind Synthesis

### Task 7: Implement quick-terminal config migration

**Files:**
- Modify: `src/config/Config.zig` (add post-processing migration function)
- Reference: `src/config/Config.zig:2599-2755` (all quick-terminal-* fields)

**Context:** After the full config is loaded, a post-processing function checks if `quick-terminal-*` keys were modified from defaults. If so, and no popup named `"quick"` exists, it synthesizes a popup profile. The old keys' platform-specific defaults must be preserved (e.g., `autohide` defaults to `true` on macOS, `false` on Linux).

- [ ] **Step 1: Add the migration function**

In `Config.zig`, add a method on the `Config` struct:

```zig
/// Synthesize a "quick" popup profile from legacy quick-terminal-* keys.
/// Called during config finalization, after all fields are parsed.
pub fn migrateQuickTerminalToPopup(self: *Config, alloc: Allocator) !void {
    // If a "quick" popup already exists, legacy keys are ignored
    if (self.popup.get("quick") != null) return;

    // Check if any quick-terminal key was explicitly set
    // (compare against default values to detect user modifications)
    const has_qt_config = !std.meta.eql(
        self.@"quick-terminal-position",
        @as(@TypeOf(self.@"quick-terminal-position"), .top),
    ) or self.@"quick-terminal-autohide" != true  // TODO: platform-specific default
      or self.@"quick-terminal-size" != .default;
    // ... check other quick-terminal-* fields

    if (!has_qt_config) return;

    // Log deprecation warning
    log.warn("quick-terminal-* config keys are deprecated; use popup = quick:... instead", .{});

    // Build the profile from legacy values
    var profile: popupmod.PopupProfile = .{};
    profile.position = switch (self.@"quick-terminal-position") {
        .top => .top,
        .bottom => .bottom,
        .left => .left,
        .right => .right,
        .center => .center,
    };
    profile.autohide = self.@"quick-terminal-autohide";
    // Map quick-terminal-size to width/height based on position
    // ... (implementation details follow existing QuickTerminalSize logic)

    const name_z = try alloc.dupeZ(u8, "quick");
    try self.popup.names.append(alloc, name_z);
    try self.popup.profiles.append(alloc, profile);
}
```

Note: The actual implementation needs to inspect all 9 quick-terminal fields. The field-by-field mapping follows the spec's migration table (spec lines 270-283). Platform-specific defaults for `autohide` should be detected via `@import("builtin").os.tag`.

- [ ] **Step 2: Write tests for migration**

```zig
test "migrateQuickTerminalToPopup: synthesizes from legacy keys" {
    // Set quick-terminal-position to non-default
    // Verify popup "quick" profile is created with correct position
}

test "migrateQuickTerminalToPopup: explicit popup wins" {
    // Set popup = quick:position:center AND quick-terminal-position = top
    // Verify popup "quick" has position=center (explicit wins)
}

test "migrateQuickTerminalToPopup: no-op when no legacy keys modified" {
    // Default config — no quick-terminal keys changed
    // Verify no popup profile synthesized
}
```

- [ ] **Step 3: Run tests**

Run: `zig build test -Dtest-filter="migrateQuickTerminal"`
Expected: All PASS

- [ ] **Step 4: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat: migrate quick-terminal-* config keys to popup profile"
```

---

### Task 8: Implement keybind synthesis post-processing

**Files:**
- Modify: `src/config/Config.zig` (add keybind synthesis function)
- Reference: `src/config/Config.zig:6376` (Keybinds struct)
- Reference: `src/input/Binding.zig:1217` (Action.parse)

**Context:** After all config is loaded AND migration is done, iterate popup profiles. For each with a `keybind:` value, check if that trigger is already bound. If unbound, insert `toggle_popup:<name>`.

- [ ] **Step 1: Add the keybind synthesis function**

```zig
/// Synthesize keybindings from popup profiles.
/// Only binds triggers that are not already claimed by explicit keybind = ... lines.
/// Called after migrateQuickTerminalToPopup.
pub fn synthesizePopupKeybinds(self: *Config, alloc: Allocator) !void {
    for (self.popup.names.items, self.popup.profiles.items) |name, profile| {
        const keybind_str = profile.keybind orelse continue;

        // Parse the trigger from the keybind string
        const trigger = inputpkg.Binding.Trigger.parse(keybind_str) catch |err| {
            log.warn("popup '{s}': invalid keybind '{s}': {}", .{ name, keybind_str, err });
            continue;
        };

        // Check if this trigger is already bound
        if (self.keybind.set.get(trigger) != null) continue;

        // Build the action string and parse it
        // This creates toggle_popup:<name> as the action
        var buf: [256]u8 = undefined;
        const action_str = std.fmt.bufPrint(&buf, "toggle_popup:{s}", .{name}) catch continue;
        const action = inputpkg.Binding.Action.parse(action_str) catch continue;

        // Insert into the keybind set
        try self.keybind.set.put(alloc, trigger, action);
    }
}
```

- [ ] **Step 2: Wire both post-processing functions into config finalization**

Find the config finalization / `load` function and call:
1. `self.migrateQuickTerminalToPopup(alloc)`
2. `self.synthesizePopupKeybinds(alloc)`

These must run in this order (migration first, then keybind synthesis from the merged profile set).

- [ ] **Step 3: Write tests**

```zig
test "synthesizePopupKeybinds: unbound trigger gets bound" {
    // Create config with popup = quick:keybind:ctrl+`, no explicit keybind for ctrl+`
    // Verify ctrl+` is bound to toggle_popup:quick
}

test "synthesizePopupKeybinds: explicit keybind wins" {
    // Create config with popup = quick:keybind:ctrl+`
    // AND keybind = ctrl+`=new_window
    // Verify ctrl+` remains bound to new_window
}
```

- [ ] **Step 4: Run tests and build**

Run: `zig build test -Dtest-filter="synthesizePopupKeybinds" && zig build -Demit-macos-app=false`
Expected: PASS + compiles

- [ ] **Step 5: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat: synthesize popup keybinds in config post-processing"
```

---

## Chunk 4: GTK PopupManager & Window Integration

### Task 9: Add is_popup property to GTK Window

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` (add `is-popup` property, keep `quick-terminal` as alias)
- Reference: `src/apprt/gtk/class/window.zig:135-151` (existing `quick-terminal` property)

**Context:** Add a new `is-popup` GObject property. Keep the old `quick-terminal` property as a deprecated alias that reads/writes the same private field. Internal code migrates to use `isPopup()` instead of `isQuickTerminal()`.

- [ ] **Step 1: Add the `is-popup` property definition**

After the existing `quick-terminal` property, add:

```zig
pub const @"is-popup" = struct {
    pub const name = "is-popup";
    const impl = gobject.ext.defineProperty(
        name,
        Self,
        bool,
        .{
            .default = false,
            .accessor = gobject.ext.privateFieldAccessor(
                Self,
                Private,
                &Private.offset,
                "is_popup",
            ),
        },
    );
};
```

Add `is_popup: bool = false` to the `Private` struct alongside `quick_terminal`.

- [ ] **Step 2: Add isPopup() method and update quick-terminal to alias**

```zig
pub fn isPopup(self: *Self) bool {
    return self.private().is_popup;
}
```

Modify the `quick-terminal` property setter to also set `is_popup`, and `isQuickTerminal` to delegate to `isPopup`:

```zig
pub fn isQuickTerminal(self: *Self) bool {
    return self.isPopup(); // Deprecated: use isPopup()
}
```

- [ ] **Step 3: Add popup_profile field to Private struct**

```zig
popup_profile: ?*const popupmod.PopupProfile = null,
```

- [ ] **Step 4: Update all internal references from quick_terminal to is_popup**

Search `window.zig` for all uses of `quick_terminal` and `isQuickTerminal()`. Update internal logic to use `is_popup` / `isPopup()`. Keep the `quick-terminal` GObject property for external compatibility.

Key locations to update (from spec review):
- Line 966: header bar visibility check
- Line 1094: autohide logic
- Line 1161: env injection

- [ ] **Step 5: Build and verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles (GTK window property is additive)

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/window.zig
git commit -m "feat: add is-popup GTK window property, keep quick-terminal as alias"
```

---

### Task 10: Create GTK PopupManager

**Files:**
- Create: `src/apprt/gtk/PopupManager.zig`
- Reference: `src/apprt/gtk/class/application.zig:2614-2634` (existing toggleQuickTerminal pattern)

**Context:** The PopupManager owns the registry of popup profiles and instances. It handles toggle/show/hide logic following the state machine in the spec (lines 159-172). It delegates window creation to the existing `Application.newWindow` path with popup overrides.

- [ ] **Step 1: Create PopupManager.zig**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const popupmod = @import("../popup.zig");
const Window = @import("class/window.zig").Window;
const Application = @import("class/application.zig").Application;

const log = std.log.scoped(.popup_manager);

pub const PopupState = struct {
    profile: popupmod.PopupProfile,
    window: ?*Window = null,
    visible: bool = false,
};

pub const PopupManager = struct {
    alloc: Allocator,
    app: *Application,
    /// Profile name → state. Names are owned copies.
    instances: std.StringHashMapUnmanaged(PopupState) = .{},

    pub fn init(alloc: Allocator, app: *Application, popup_config: *const configpkg.RepeatablePopup) !PopupManager {
        var self: PopupManager = .{ .alloc = alloc, .app = app };
        // Copy profiles from config into manager-owned storage
        for (popup_config.names.items, popup_config.profiles.items) |name, profile| {
            const name_copy = try alloc.dupe(u8, name);
            try self.instances.put(alloc, name_copy, .{ .profile = profile });
        }
        return self;
    }

    pub fn deinit(self: *PopupManager) void {
        self.hideAll();
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.instances.deinit(self.alloc);
    }

    pub fn toggle(self: *PopupManager, name: []const u8) bool {
        const state = self.instances.getPtr(name) orelse {
            log.warn("popup '{s}' not found in config", .{name});
            return false;
        };

        if (state.window) |win| {
            if (state.visible) {
                // Visible → Hidden (or Destroyed if !persist)
                self.hideInstance(state, win);
            } else {
                // Hidden → Visible
                self.showInstance(state, win);
            }
        } else {
            // Not Created → Visible
            self.createAndShow(name, state);
        }
        return true;
    }

    pub fn show(self: *PopupManager, name: []const u8) bool {
        const state = self.instances.getPtr(name) orelse {
            log.warn("popup '{s}' not found in config", .{name});
            return false;
        };

        if (state.window) |win| {
            if (!state.visible) {
                self.showInstance(state, win);
            }
            // Already visible: no-op
        } else {
            self.createAndShow(name, state);
        }
        return true;
    }

    pub fn hide(self: *PopupManager, name: []const u8) bool {
        const state = self.instances.getPtr(name) orelse return false;
        const win = state.window orelse return false;
        if (state.visible) {
            self.hideInstance(state, win);
        }
        return true;
    }

    pub fn hideAll(self: *PopupManager) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window) |win| {
                self.hideInstance(entry.value_ptr, win);
            }
        }
    }

    pub fn onFocusLost(self: *PopupManager, win: *Window) void {
        // Find which popup this window belongs to
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.window == win and entry.value_ptr.visible) {
                if (entry.value_ptr.profile.autohide) {
                    self.hideInstance(entry.value_ptr, win);
                }
                return;
            }
        }
    }

    fn createAndShow(self: *PopupManager, name: []const u8, state: *PopupState) void {
        _ = name;
        // Create window with is-popup=true and popup profile
        // Delegate to Application.newWindow with popup overrides
        // Apply positioning from profile
        // TODO: implement window creation
        _ = self;
        _ = state;
    }

    fn showInstance(_: *PopupManager, state: *PopupState, win: *Window) void {
        win.as(gtk.Window).present();
        state.visible = true;
    }

    fn hideInstance(_: *PopupManager, state: *PopupState, win: *Window) void {
        if (!state.profile.persist) {
            // Destroy
            win.as(gtk.Window).destroy();
            state.window = null;
            state.visible = false;
        } else {
            // Hide but keep alive
            win.as(gtk.Window).setVisible(false);
            state.visible = false;
        }
    }
};
```

- [ ] **Step 2: Build to verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles (PopupManager not yet wired into Application)

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/PopupManager.zig
git commit -m "feat: create GTK PopupManager with toggle/show/hide state machine"
```

---

### Task 11: Wire PopupManager into GTK Application

**Files:**
- Modify: `src/apprt/gtk/class/application.zig` (add PopupManager field, performAction dispatch, replace toggleQuickTerminal)
- Reference: `src/apprt/gtk/class/application.zig:662` (performAction switch)
- Reference: `src/apprt/gtk/class/application.zig:2614` (toggleQuickTerminal)

**Context:** The Application creates the PopupManager on init (after config is loaded) and owns it for the app's lifetime. The `performAction` dispatch routes `toggle_popup`/`show_popup`/`hide_popup` to PopupManager. The existing `toggle_quick_terminal` case delegates to `popup_manager.toggle("quick")`.

- [ ] **Step 1: Add PopupManager to Application Private struct**

In the `Private` struct:
```zig
popup_manager: ?PopupManager = null,
```

- [ ] **Step 2: Initialize PopupManager in Application startup**

In the `activate` or `startup` handler, after config is loaded:
```zig
priv.popup_manager = try PopupManager.init(alloc, self, &config.popup);
```

- [ ] **Step 3: Add performAction dispatch cases**

In the `performAction` switch (around line 662):

```zig
.toggle_popup => return if (priv.popup_manager) |*pm| pm.toggle(value.name) else false,
.show_popup => return if (priv.popup_manager) |*pm| pm.show(value.name) else false,
.hide_popup => return if (priv.popup_manager) |*pm| pm.hide(value.name) else false,
```

- [ ] **Step 4: Modify toggleQuickTerminal to delegate**

Replace the body of `toggleQuickTerminal` (line 2614):

```zig
pub fn toggleQuickTerminal(self: *Application) bool {
    const priv = self.private();
    if (priv.popup_manager) |*pm| {
        return pm.toggle("quick");
    }
    return false;
}
```

- [ ] **Step 5: Build and verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat: wire PopupManager into GTK Application dispatch"
```

---

### Task 12: Update GTK winproto for popup support

**Files:**
- Modify: `src/apprt/gtk/winproto/wayland.zig` (generalize `syncQuickTerminal` → `syncPopup`)
- Modify: `src/apprt/gtk/winproto/x11.zig` (rename `supportsQuickTerminal` → `supportsPopup`)
- Modify: `src/apprt/gtk/winproto/noop.zig` (rename stubs)

**Context:** The Wayland implementation currently reads quick-terminal-specific config. It needs to read from the window's popup profile instead. X11 and noop just need method renames (still returning false / doing nothing).

- [ ] **Step 1: Update x11.zig**

Rename `supportsQuickTerminal` → `supportsPopup`, `initQuickTerminal` → `initPopup`:
```zig
pub fn supportsPopup(_: App) bool {
    log.warn("popup terminals are not yet supported on X11", .{});
    return false;
}

pub fn initPopup(_: *App, _: *ApprtWindow) !void {}
```

Keep the old names as deprecated aliases if other code references them, or update all call sites.

- [ ] **Step 2: Update noop.zig similarly**

Same renames for the noop implementation.

- [ ] **Step 3: Update wayland.zig**

Rename `syncQuickTerminal` → `syncPopup`. Modify it to read position/size from the window's popup profile instead of from the global quick-terminal config. The popup profile is threaded through the window's private state (set when PopupManager creates the window).

```zig
fn syncPopup(self: *Window) !void {
    const profile = self.window.getPopupProfile() orelse return;

    // Warn about Wayland-incompatible properties
    if (profile.x != null or profile.y != null) {
        log.warn("popup: x/y positioning is not supported on Wayland, ignored", .{});
    }
    if (profile.anchor != null) {
        log.warn("popup: anchor is not supported on Wayland, ignored", .{});
    }

    // Use profile.position instead of config.@"quick-terminal-position"
    const anchored_edge: ?layer_shell.ShellEdge = switch (profile.position) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
        .center => null, // compositor-dependent centering
    };
    // Use profile.width/height for sizing
    // ... (follow existing syncQuickTerminal pattern but parameterized)
}
```

Also verify that the `supportsPopup` check (formerly `supportsQuickTerminal`) still correctly returns false when layer-shell is unavailable, and that a log warning is emitted.

- [ ] **Step 4: Update all call sites in application.zig and window.zig**

Replace calls to `supportsQuickTerminal()` with `supportsPopup()`, etc.

- [ ] **Step 5: Build and verify**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/winproto/wayland.zig src/apprt/gtk/winproto/x11.zig src/apprt/gtk/winproto/noop.zig src/apprt/gtk/class/application.zig src/apprt/gtk/class/window.zig
git commit -m "feat: generalize GTK winproto from quick-terminal to popup"
```

---

### Task 13: Update GTK surface environment variable

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig` (around line 1606)

**Context:** Currently sets `GHOSTTY_QUICK_TERMINAL=1`. Change to set `GHOSTTY_POPUP=<name>` for all popups, plus `GHOSTTY_QUICK_TERMINAL=1` additionally for the `"quick"` profile.

- [ ] **Step 1: Update env var injection**

Find the env var injection (around line 1606-1608) and update:

```zig
// Set popup environment variables
if (window.isPopup()) {
    if (window.getPopupName()) |name| {
        try env.put("GHOSTTY_POPUP", name);
        if (std.mem.eql(u8, name, "quick")) {
            try env.put("GHOSTTY_QUICK_TERMINAL", "1");
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `zig build -Demit-macos-app=false`

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/surface.zig
git commit -m "feat: set GHOSTTY_POPUP env var for popup surfaces"
```

---

## Chunk 5: macOS Popup System

### Task 14: Create PopupWindow.swift

**Files:**
- Create: `macos/Sources/Features/Popup/PopupWindow.swift`
- Reference: `macos/Sources/Features/QuickTerminal/QuickTerminalWindow.swift`

**Context:** NSPanel subclass created programmatically (no XIB). Evolved from QuickTerminalWindow but parameterized for different popup profiles. Key behaviors: floating level, non-activating, no title bar, accessibility subtype.

- [ ] **Step 1: Create PopupWindow.swift**

```swift
import Cocoa

/// Floating NSPanel for popup terminals.
/// Created programmatically — no XIB needed.
/// Follows the exact pattern from QuickTerminalWindow:
/// - Removes .titled from styleMask (no title bar)
/// - Inserts .nonactivatingPanel (doesn't steal focus from other apps)
class PopupWindow: NSPanel {
    /// The popup profile name (e.g., "quick", "scratch")
    let profileName: String

    /// Whether this is the legacy "quick" profile (retains animation behavior)
    var isQuickProfile: Bool { profileName == "quick" }

    init(profileName: String, contentRect: NSRect) {
        self.profileName = profileName

        // Start with a minimal styleMask, then adjust
        // (matches QuickTerminalWindow's awakeFromNib pattern)
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Remove title bar, add non-activating panel behavior
        // This matches QuickTerminalWindow exactly
        styleMask.remove(.titled)
        styleMask.insert(.nonactivatingPanel)

        identifier = NSUserInterfaceItemIdentifier(
            "com.mitchellh.ghostty.popup.\(profileName)"
        )
        setAccessibilitySubrole(.floatingWindow)

        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        level = .floating
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
```

**Note on NSWindowController:** PopupController should NOT use NIB-based initialization. Instead of subclassing `NSWindowController` with `windowNibName`, create the PopupWindow programmatically in `PopupController.init()` and pass it to `super.init(window:)`. This avoids the multi-instance NIB loading issue.

- [ ] **Step 2: Build macOS app to verify**

Run: `macos/build.nu --action build`
Expected: Compiles

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Popup/PopupWindow.swift
git commit -m "feat: add PopupWindow NSPanel subclass"
```

---

### Task 15: Create PopupController.swift

**Files:**
- Create: `macos/Sources/Features/Popup/PopupController.swift`
- Reference: `macos/Sources/Features/QuickTerminal/QuickTerminalController.swift` (evolve from this)

**Context:** This is the most complex file — it evolves from QuickTerminalController. Key behaviors to carry forward: lazy surface creation, focus restoration (`previousApp`), space handling, per-screen frame caching. New behavior: parameterized by PopupProfile instead of reading global quick-terminal config.

- [ ] **Step 1: Create PopupController.swift with core lifecycle**

Start by copying QuickTerminalController's structure but parameterized by profile. Key changes:
- Constructor takes a profile config struct instead of reading global config
- `PopupWindow` created programmatically (no XIB)
- Position calculated from profile's position/anchor/x/y/width/height
- For non-"quick" profiles: no animation (instant show/hide)
- For "quick" profile: preserve existing animation behavior

This is a large file (~400-500 lines). The implementation should follow QuickTerminalController line by line, replacing hardcoded quick-terminal assumptions with profile-parameterized equivalents.

Key methods to implement:
- `init(profile:ghosttyApp:)` — create window, don't create surface yet
- `show()` — create surface on first call, position window, make visible
- `hide()` — hide window (or destroy if !persist), restore focus
- `toggle()` — show if hidden, hide if visible
- `positionWindow()` — calculate frame from profile + screen bounds

- [ ] **Step 2: Build macOS app to verify**

Run: `macos/build.nu --action build`

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Popup/PopupController.swift
git commit -m "feat: add PopupController evolved from QuickTerminalController"
```

---

### Task 16: Create macOS PopupManager.swift

**Files:**
- Create: `macos/Sources/Features/Popup/PopupManager.swift`

**Context:** Thin registry that maps profile names to PopupController instances. Handles toggle/show/hide dispatch. Owned by AppDelegate.

- [ ] **Step 1: Create PopupManager.swift**

```swift
import Cocoa
import GhosttyKit

/// Registry of named popup terminal instances.
/// Owns PopupController lifecycle for each profile.
class PopupManager {
    private let ghosttyApp: Ghostty.App
    private var controllers: [String: PopupController] = [:]
    private var profiles: [String: Ghostty.PopupProfile] = [:]

    init(ghosttyApp: Ghostty.App, config: Ghostty.Config) {
        self.ghosttyApp = ghosttyApp
        // Load profiles from config
        // profiles = config.popupProfiles  // however Config surfaces this
    }

    func toggle(_ name: String) {
        let controller = getOrCreateController(name: name)
        controller?.toggle()
    }

    func show(_ name: String) {
        let controller = getOrCreateController(name: name)
        controller?.show()
    }

    func hide(_ name: String) {
        controllers[name]?.hide()
    }

    func hideAll() {
        for (_, controller) in controllers {
            controller.hide()
        }
    }

    private func getOrCreateController(name: String) -> PopupController? {
        if let existing = controllers[name] {
            return existing
        }
        guard let profile = profiles[name] else {
            Ghostty.logger.warning("popup '\(name)' not found in config")
            return nil
        }
        let controller = PopupController(profile: profile, ghosttyApp: ghosttyApp)
        controllers[name] = controller
        return controller
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `macos/build.nu --action build`

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Popup/PopupManager.swift
git commit -m "feat: add macOS PopupManager registry"
```

---

## Chunk 6: macOS Integration

### Task 17: Update AppDelegate to use PopupManager

**Files:**
- Modify: `macos/Sources/App/macOS/AppDelegate.swift`
- Reference: `macos/Sources/App/macOS/AppDelegate.swift` (quickController property, restoration encode/decode at lines 861-888)

**Context:** Replace `quickController`/`quickTerminalControllerState` with PopupManager. The PopupManager is created during app init. Restoration state is carried forward for the "quick" profile only.

- [ ] **Step 1: Replace quickController with popupManager**

```swift
// Replace:
//   var quickController: QuickTerminalController { ... }
//   private var quickTerminalControllerState: ...
// With:
lazy var popupManager: PopupManager = PopupManager(
    ghosttyApp: ghostty,
    config: ghostty.config
)
```

- [ ] **Step 2: Update restoration encode/decode**

Keep restoration for "quick" profile, reading from `popupManager.controllers["quick"]`:

```swift
func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
    if let quickController = popupManager.controllers["quick"],
       quickController.restorable {
        // Encode quick controller state (same as before)
    }
}
```

- [ ] **Step 3: Update all references to quickController**

Search AppDelegate.swift for `quickController` and replace with `popupManager.controllers["quick"]` or `popupManager.toggle("quick")` as appropriate.

- [ ] **Step 4: Build and verify**

Run: `macos/build.nu --action build`

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/App/macOS/AppDelegate.swift
git commit -m "feat: replace quickController with PopupManager in AppDelegate"
```

---

### Task 18: Update Ghostty.App.swift action dispatch

**Files:**
- Modify: `macos/Sources/Ghostty/Ghostty.App.swift` (performAction dispatch)
- Reference: `macos/Sources/Ghostty/Ghostty.App.swift` (GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL handling)

**Context:** Add handling for the 3 new action keys. Extract the popup name from the C struct and dispatch to PopupManager.

- [ ] **Step 1: Add action dispatch cases**

```swift
case GHOSTTY_ACTION_TOGGLE_POPUP:
    let name = String(cString: action.toggle_popup.name)
    delegate?.popupManager.toggle(name)
    return true

case GHOSTTY_ACTION_SHOW_POPUP:
    let name = String(cString: action.show_popup.name)
    delegate?.popupManager.show(name)
    return true

case GHOSTTY_ACTION_HIDE_POPUP:
    let name = String(cString: action.hide_popup.name)
    delegate?.popupManager.hide(name)
    return true
```

- [ ] **Step 2: Update existing TOGGLE_QUICK_TERMINAL handler**

Route through PopupManager:
```swift
case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
    delegate?.popupManager.toggle("quick")
    return true
```

- [ ] **Step 3: Build and verify**

Run: `macos/build.nu --action build`

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Ghostty/Ghostty.App.swift
git commit -m "feat: handle popup actions in macOS Ghostty.App dispatch"
```

---

### Task 19: Update macOS integration points

**Files:**
- Modify: `macos/Sources/Features/Update/UpdateDriver.swift` (~line 208)
- Modify: `macos/Sources/Features/App Intents/Entities/TerminalEntity.swift` (~line 57)
- Modify: `macos/Sources/Features/App Intents/QuickTerminalIntent.swift`
- Modify: `macos/Sources/App/macOS/MainMenu.xib` (Quick Terminal menu item)

- [ ] **Step 1: Update UpdateDriver.swift**

Replace `QuickTerminalWindow` check with `PopupWindow`:
```swift
// Before: (window is TerminalWindow || window is QuickTerminalWindow) && window.isVisible
// After:
(window is TerminalWindow || window is PopupWindow) && window.isVisible
```

- [ ] **Step 2: Update TerminalEntity.swift**

Replace controller type check:
```swift
// Before: if view.window?.windowController is QuickTerminalController
// After:
if view.window is PopupWindow {
    self.kind = .quick  // or a new .popup kind
} else {
    self.kind = .normal
}
```

- [ ] **Step 3: Update QuickTerminalIntent.swift**

Change from direct controller access to PopupManager.show (preserves show-only semantics):
```swift
func perform() async throws -> some IntentResult & ReturnsValue<[TerminalEntity]> {
    let delegate = // ... get app delegate
    delegate.popupManager.show("quick")
    // ... return terminals
}
```

- [ ] **Step 4: Update MainMenu.xib**

The Quick Terminal menu item currently sends `toggleQuickTerminal:` action. Update it to route through PopupManager. Either:
- Change the menu action to call `popupManager.toggle("quick")` on AppDelegate, or
- Keep the existing action selector but have the AppDelegate handler delegate to PopupManager (this may already be done in Task 17)

Verify by opening the XIB in Xcode's Interface Builder or editing the XML directly.

- [ ] **Step 5: Wire process exit handling**

When a popup's terminal process exits (e.g., user quits `htop`), the popup should auto-hide (persist=true) or destroy (persist=false). The existing QuickTerminalController handles this via `surfaceTreeDidChange` — when the surface tree becomes empty, it animates out.

In `PopupController.swift`, implement the same pattern:
```swift
func surfaceTreeDidChange() {
    if surfaceTree.isEmpty {
        if profile.persist {
            hide()
        } else {
            destroy()
        }
    }
}
```

- [ ] **Step 6: Build and verify**

Run: `macos/build.nu --action build`

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/Update/UpdateDriver.swift macos/Sources/Features/App\ Intents/ macos/Sources/App/macOS/MainMenu.xib
git commit -m "feat: update macOS integration points for popup system"
```

---

### Task 20: Add C API for popup profile access and update Ghostty.Config.swift

**Files:**
- Modify: `macos/Sources/Ghostty/Ghostty.Config.swift`

**Context:** Swift needs to read popup profiles from the Zig config. This requires C-compatible accessors since the macOS app calls into Zig via `libghostty`. Follow the existing pattern where `Config` exposes typed accessors (e.g., `ghostty_config_get` returns values by key).

- [ ] **Step 1: Add C API functions to ghostty.h**

```c
/// Get the number of popup profiles configured.
size_t ghostty_config_popup_count(ghostty_config_t config);

/// Get popup profile name at index (NULL if out of bounds).
const char* ghostty_config_popup_name(ghostty_config_t config, size_t index);

/// Get popup profile properties at index. Returns false if out of bounds.
/// Writes properties into the provided struct.
typedef struct {
    ghostty_popup_position_e position;
    uint32_t width_value;
    bool width_is_percent;
    uint32_t height_value;
    bool height_is_percent;
    bool autohide;
    bool persist;
    const char* command; // NULL if not set
} ghostty_popup_profile_s;

bool ghostty_config_popup_profile(
    ghostty_config_t config,
    size_t index,
    ghostty_popup_profile_s* out
);
```

- [ ] **Step 2: Implement C API functions in Zig**

In `src/main_c.zig` or the appropriate C API implementation file, implement the three functions by reading from `config.popup.names` and `config.popup.profiles`.

- [ ] **Step 3: Add Swift wrapper in Ghostty.Config.swift**

```swift
extension Ghostty.Config {
    struct PopupProfile {
        let name: String
        let position: Position
        let width: Dimension
        let height: Dimension
        let autohide: Bool
        let persist: Bool
        let command: String?
    }

    var popupProfiles: [String: PopupProfile] {
        var result: [String: PopupProfile] = [:]
        let count = ghostty_config_popup_count(config)
        for i in 0..<count {
            guard let namePtr = ghostty_config_popup_name(config, i) else { continue }
            let name = String(cString: namePtr)
            var cProfile = ghostty_popup_profile_s()
            guard ghostty_config_popup_profile(config, i, &cProfile) else { continue }
            result[name] = PopupProfile(
                name: name,
                position: Position(cProfile.position),
                width: Dimension(value: cProfile.width_value, isPercent: cProfile.width_is_percent),
                height: Dimension(value: cProfile.height_value, isPercent: cProfile.height_is_percent),
                autohide: cProfile.autohide,
                persist: cProfile.persist,
                command: cProfile.command.map { String(cString: $0) }
            )
        }
        return result
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `macos/build.nu --action build`

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/Ghostty.Config.swift include/ghostty.h src/main_c.zig
git commit -m "feat: add C API for popup profile access, wire to Swift Config"
```

---

## Chunk 7: Cleanup & Final Integration

### Task 21: Remove old QuickTerminal files

**Files:**
- Remove: `macos/Sources/Features/QuickTerminal/QuickTerminalWindow.swift`
- Remove: `macos/Sources/Features/QuickTerminal/QuickTerminalController.swift`
- Remove: `macos/Sources/Features/QuickTerminal/QuickTerminal.xib`
- Move/refactor: Supporting Swift files (see spec lines 339-348)

**Context:** Only do this AFTER all new Popup files are working and tested. The supporting files (QuickTerminalPosition.swift, etc.) are either folded into PopupController or kept as legacy helpers.

- [ ] **Step 1: Move supporting files into Popup directory**

```bash
# Move files that are kept
mv macos/Sources/Features/QuickTerminal/QuickTerminalScreen.swift macos/Sources/Features/Popup/
mv macos/Sources/Features/QuickTerminal/QuickTerminalSpaceBehavior.swift macos/Sources/Features/Popup/
# ... etc.
```

- [ ] **Step 2: Remove replaced files**

```bash
rm macos/Sources/Features/QuickTerminal/QuickTerminalWindow.swift
rm macos/Sources/Features/QuickTerminal/QuickTerminalController.swift
rm macos/Sources/Features/QuickTerminal/QuickTerminal.xib
```

- [ ] **Step 3: Update Xcode project if needed**

The macOS build may use an Xcode project that references files by path. Verify that `macos/build.nu` still works after file moves/deletions.

- [ ] **Step 4: Build and verify**

Run: `macos/build.nu --action build`
Expected: Compiles with no reference to removed files

- [ ] **Step 5: Commit**

```bash
git add -A macos/Sources/Features/
git commit -m "refactor: remove old QuickTerminal files, move supporting files to Popup"
```

---

### Task 22: Full build and manual smoke test

- [ ] **Step 1: Full Zig build**

Run: `zig build -Demit-macos-app=false`
Expected: Compiles

- [ ] **Step 2: Run all popup-related tests**

Run: `zig build test -Dtest-filter="popup" && zig build test -Dtest-filter="Dimension" && zig build test -Dtest-filter="isValidName" && zig build test -Dtest-filter="RepeatablePopup" && zig build test -Dtest-filter="migrateQuickTerminal" && zig build test -Dtest-filter="synthesizePopupKeybinds"`
Expected: All PASS

- [ ] **Step 3: Full macOS build**

Run: `macos/build.nu --action build`
Expected: Compiles

- [ ] **Step 4: Manual smoke test with test config**

Create a test config at `~/.config/ghostty/config`:
```
popup = quick:position:top,width:100%,height:50%,keybind:ctrl+`,autohide:true
popup = scratch:position:center,width:80%,height:80%,keybind:ctrl+shift+s
```

Test:
1. Press `ctrl+`` — quick popup appears at top, 100% width, 50% height
2. Press `ctrl+`` again — popup hides
3. Press `ctrl+`` again — popup reappears with scrollback preserved
4. Press `ctrl+shift+s` — scratch popup appears centered, 80%x80%
5. Click outside quick popup — it auto-hides
6. Verify both popups work independently

- [ ] **Step 5: Test backward compatibility**

Replace config with old-style:
```
quick-terminal-position = top
quick-terminal-autohide = true
keybind = ctrl+`=toggle_quick_terminal
```

Verify identical behavior to the new popup system.

- [ ] **Step 6: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found in smoke testing"
```

---

## Summary

| Chunk | Tasks | Key Deliverable |
|-------|-------|----------------|
| 1: Core Types & Config | 1-2 | PopupProfile struct, repeatable config parsing with C API + tests |
| 2: Actions & Bindings | 3-6 | toggle_popup/show_popup/hide_popup in binding + apprt + C header + App.zig dispatch bridge |
| 3: Config Migration | 7-8 | quick-terminal-* migration + keybind synthesis |
| 4: GTK Integration | 9-13 | PopupManager, window property, winproto (with Wayland warnings), env vars |
| 5: macOS Popup System | 14-16 | PopupWindow, PopupController (with process exit handling), PopupManager (Swift) |
| 6: macOS Integration | 17-20 | AppDelegate, action dispatch, integration points (incl. MainMenu.xib), C API Config bridge |
| 7: Cleanup | 21-22 | Remove old files, full build + smoke test |

**Total: 22 tasks across 7 chunks.**

## Review Findings Addressed

This plan revision addressed the following issues from plan review:

1. **App.zig dispatch bridge** — Added Task 6 with `[]const u8` → `[:0]const u8` conversion
2. **scope() entries** — Added to Task 6 (`.app` scope for all popup actions)
3. **Build break prevention** — Task 4 now includes stub handlers in application.zig
4. **Writer type** — Fixed `anytype` → `*std.Io.Writer` in all format functions
5. **RepeatablePopup C API** — Rewritten with parallel ArrayLists (matching RepeatableCommand pattern) + C struct
6. **RepeatablePopup.equal** — Now uses `std.meta.eql` for field comparison
7. **NSPanel styleMask** — Fixed to match QuickTerminalWindow's actual pattern (remove .titled, insert .nonactivatingPanel)
8. **NSWindowController NIB** — Added note about programmatic init via `super.init(window:)`
9. **Process exit handling** — Added to Task 19 (surfaceTreeDidChange)
10. **MainMenu.xib** — Added to Task 19
11. **Wayland warnings** — Added to Task 12 (log warning for x/y/anchor on Wayland)
12. **C API for config** — Task 20 rewritten with concrete ghostty_config_popup_* API design
13. **Quoted value test** — Added to Task 2 tests
14. **Missing files in summary** — Added App.zig, surface.zig, MainMenu.xib to modified files table
