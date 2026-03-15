# Popup Terminal v2 Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add config hot-reload for popup profiles, per-popup working directory, and per-popup background opacity.

**Architecture:** Extend `PopupProfile` with two new fields (`cwd`, `opacity`), bridge them through the C API to Swift, and wire `updateProfileConfigs()` into the existing config reload path on both platforms. CWD and opacity are applied at surface creation time — no renderer changes needed.

**Tech Stack:** Zig (core + GTK apprt), Swift (macOS apprt), C API bridge

**Spec:** `docs/superpowers/specs/2026-03-14-popup-terminal-v2-design.md`

---

## Chunk 1: Zig Core — New PopupProfile Fields + C API Bridge

### Task 1: Add `cwd` and `opacity` fields to PopupProfile

**Files:**
- Modify: `src/apprt/popup.zig:58-101`
- Modify: `include/ghostty.h:493-502` (C header must match `PopupProfile.C`)

- [ ] **Step 1: Add fields to PopupProfile struct**

In `src/apprt/popup.zig`, add two new fields to `PopupProfile` (after `persist`):

```zig
cwd: ?[]const u8 = null,
opacity: ?f64 = null,
```

- [ ] **Step 2: Add fields to PopupProfile.C extern struct**

In the same file, add to `PopupProfile.C` (after `command`):

```zig
/// Sentinel-terminated CWD path, or null if not set.
cwd: ?[*:0]const u8,
/// Background opacity 0.0-1.0, or -1.0 if not set (extern structs can't have optionals).
opacity: f64,
```

- [ ] **Step 3: Update `cval()` to pass new fields**

Update the `cval` method signature to accept `cwd_z` parameter and map `opacity`:

```zig
pub fn cval(self: PopupProfile, command_z: ?[*:0]const u8, cwd_z: ?[*:0]const u8) C {
    return .{
        .position = @intFromEnum(self.position),
        .width_value = self.width.value,
        .width_is_percent = self.width.unit == .percent,
        .height_value = self.height.value,
        .height_is_percent = self.height.unit == .percent,
        .autohide = self.autohide,
        .persist = self.persist,
        .command = command_z,
        .cwd = cwd_z,
        .opacity = if (self.opacity) |o| o else -1.0,
    };
}
```

- [ ] **Step 4: Add unit tests for new fields**

Append to existing tests in `src/apprt/popup.zig`:

```zig
test "PopupProfile: default cwd and opacity are null" {
    const p = PopupProfile{};
    try std.testing.expect(p.cwd == null);
    try std.testing.expect(p.opacity == null);
}

test "PopupProfile.C: opacity -1.0 means unset" {
    const p = PopupProfile{};
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, -1.0), c.opacity);
    try std.testing.expect(c.cwd == null);
}

test "PopupProfile.C: opacity passes through" {
    const p = PopupProfile{ .opacity = 0.8 };
    const c = p.cval(null, null);
    try std.testing.expectEqual(@as(f64, 0.8), c.opacity);
}
```

- [ ] **Step 5: Run tests**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig test src/apprt/popup.zig`
Expected: All tests pass (existing + new)

- [ ] **Step 6: Update C header**

In `include/ghostty.h`, find the `ghostty_popup_profile_config_s` struct (line ~493) and add the new fields after `command`:

```c
typedef struct {
  int position;
  uint32_t width_value;
  bool width_is_percent;
  uint32_t height_value;
  bool height_is_percent;
  bool autohide;
  bool persist;
  const char* command;
  const char* cwd;       // NULL if not set
  double opacity;        // -1.0 if not set
} ghostty_popup_profile_config_s;
```

**Critical:** The field order and types must exactly match `PopupProfile.C` in `popup.zig`. If they don't match, the macOS Swift app will read garbage values from the struct.

- [ ] **Step 7: Commit**

```bash
git add src/apprt/popup.zig include/ghostty.h
git commit -m "feat(popup): add cwd and opacity fields to PopupProfile"
```

---

### Task 2: Update RepeatablePopup for new fields

**Files:**
- Modify: `src/config/Config.zig` (RepeatablePopup struct, lines ~9197-9389)

- [ ] **Step 1: Add `cwd_z` parallel array to RepeatablePopup**

Add a new field after `commands_z`:

```zig
/// Sentinel-terminated copies of CWD paths for the C API.
/// Indexed in parallel with names/profiles; null when no cwd.
cwd_z: std.ArrayListUnmanaged(?[*:0]const u8) = .empty,
```

- [ ] **Step 2: Update `parseCLI` — clear path**

In `parseCLI`, in the `input.len == 0` (clear all) block, add cleanup for `cwd_z` alongside the existing `commands_z` cleanup:

```zig
for (self.cwd_z.items) |cz| {
    if (cz) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        alloc.free(slice);
    }
}
// ... after existing clearRetainingCapacity calls:
self.cwd_z.clearRetainingCapacity();
```

- [ ] **Step 3: Update `parseCLI` — new profile path**

After the `cmd_z` allocation, add CWD sentinel copy:

```zig
const cwd_z_val: ?[*:0]const u8 = if (profile.cwd) |cwd|
    (try alloc.dupeZ(u8, cwd)).ptr
else
    null;
```

- [ ] **Step 4: Update `parseCLI` — duplicate name (replace) path**

In the "last definition wins" loop body, add cleanup and replacement for `cwd_z`:

```zig
// Free old CWD string before overwriting.
if (self.profiles.items[i].cwd) |old_cwd| alloc.free(old_cwd);
if (self.cwd_z.items[i]) |old_cwd_z| {
    const slice = std.mem.sliceTo(old_cwd_z, 0);
    alloc.free(slice);
}
// (existing overwrites...)
self.cwd_z.items[i] = cwd_z_val;
self.profiles_c.items[i] = profile.cval(cmd_z, cwd_z_val);
```

Also update the existing `profiles_c` line to pass the new `cwd_z_val` argument.

- [ ] **Step 5: Update `parseCLI` — append path**

Add the `cwd_z` append alongside the other parallel arrays:

```zig
try self.cwd_z.append(alloc, cwd_z_val);
```

And update the `profiles_c` append to pass `cwd_z_val`:

```zig
try self.profiles_c.append(alloc, profile.cval(cmd_z, cwd_z_val));
```

- [ ] **Step 6: Update `clone`**

In the `clone` method, after deep-copying `command`, add deep-copy for `cwd`:

```zig
if (profile.cwd) |cwd| {
    cloned_profile.cwd = try alloc.dupe(u8, cwd);
}
```

And create a sentinel copy for the clone:

```zig
const new_cwd_z: ?[*:0]const u8 = if (cloned_profile.cwd) |cwd|
    (try alloc.dupeZ(u8, cwd)).ptr
else
    null;
try new.cwd_z.append(alloc, new_cwd_z);
```

Update the `profiles_c` append to pass `new_cwd_z`:

```zig
try new.profiles_c.append(alloc, cloned_profile.cval(new_cmd_z, new_cwd_z));
```

- [ ] **Step 7: Update `deinit`**

Add cleanup for `cwd_z` and `cwd` fields:

```zig
// In the profiles loop, add:
if (profile.cwd) |cwd| alloc.free(cwd);

// After the commands_z loop, add:
for (self.cwd_z.items) |cz| {
    if (cz) |ptr| {
        const slice = std.mem.sliceTo(ptr, 0);
        alloc.free(slice);
    }
}
// Add to the deinit calls:
self.cwd_z.deinit(alloc);
```

- [ ] **Step 8: Update `equal`**

No changes needed — `equal` already uses `deepEqual` on `PopupProfile`, which will compare the new `cwd` and `opacity` fields automatically (optional slices are compared by content in `deepEqual`).

- [ ] **Step 9: Build to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false 2>&1 | head -30`
Expected: Compiles without errors. Fix any compile errors from callers of `cval()` that now need the extra parameter.

- [ ] **Step 10: Fix any remaining `cval()` callers**

Search for all calls to `.cval(` and update them to pass the `cwd_z` argument. The main caller is in `RepeatablePopup` itself — the `cval()` method on the top-level struct should not need changes (it doesn't call `PopupProfile.cval`).

- [ ] **Step 11: Commit**

```bash
git add src/config/Config.zig
git commit -m "feat(popup): update RepeatablePopup for cwd and opacity fields"
```

---

## Chunk 2: GTK — Config Hot-Reload + CWD/Opacity

### Task 3: Add `updateProfileConfigs` to GTK PopupManager

**Files:**
- Modify: `src/apprt/gtk/PopupManager.zig`

- [ ] **Step 1: Add `updateProfileConfigs` method**

Add this method after `hideAll()` (line 153):

```zig
/// Update popup profiles from a new config. Handles additions, changes,
/// and removals:
/// - Removed profiles: hide and destroy any running popup instance
/// - New profiles: stored for lazy creation on next toggle/show
/// - Changed profiles: updated config applied on next toggle
pub fn updateProfileConfigs(self: *PopupManager, config: *const configpkg.Config) void {
    // 1. Find and destroy windows for removed profiles
    var i: usize = 0;
    while (i < self.window_names.items.len) {
        const wname = self.window_names.items[i];
        const still_exists = for (config.popup.names.items) |cname| {
            if (std.mem.eql(u8, wname, cname)) break true;
        } else false;

        if (!still_exists) {
            // Destroy the window if it still exists
            if (self.window_refs.items[i].get()) |win| {
                defer win.unref();
                win.as(gtk.Window).destroy();
            }
            self.removeWindowAt(i);
            // Don't increment i — removeWindowAt shifts elements down
        } else {
            i += 1;
        }
    }

    // 2. Reload all profiles from new config (handles adds + changes)
    self.loadConfig(config);
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/PopupManager.zig
git commit -m "feat(popup): add updateProfileConfigs to GTK PopupManager"
```

---

### Task 4: Wire config reload to GTK PopupManager

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`

- [ ] **Step 1: Update `configChange` to call popup manager**

In the `configChange` method (line ~1941), add popup manager update when target is `.app`:

```zig
pub fn configChange(
    self: *Application,
    target: apprt.Target,
    new_config: *const CoreConfig,
) !void {
    const alloc = self.allocator();
    const config_obj: *Config = try .new(alloc, new_config);
    defer config_obj.unref();

    switch (target) {
        .surface => |core| core.rt_surface.surface.setConfig(config_obj),
        .app => {
            self.setConfig(config_obj);
            // Update popup profiles on config reload
            if (self.private().popup_manager) |*pm| {
                pm.updateProfileConfigs(new_config);
            }
        },
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/apprt/gtk/class/application.zig
git commit -m "feat(popup): wire config reload to GTK PopupManager"
```

---

### Task 5: Add CWD support to GTK popup creation

**Files:**
- Modify: `src/apprt/gtk/PopupManager.zig`
- Modify: `src/apprt/gtk/class/application.zig` (to get focused surface)

- [ ] **Step 1: Update `createAndShow` to pass CWD**

In `PopupManager.createAndShow` (line 156), after verifying the profile exists, resolve the CWD and pass it to `newTabForWindow`:

```zig
fn createAndShow(self: *PopupManager, name: []const u8) bool {
    // ... existing gio_app / gtk_app setup ...

    // Verify the profile exists
    const profile = self.getProfile(name) orelse {
        log.warn("no popup profile found for name '{s}'", .{name});
        return false;
    };

    // Resolve working directory: explicit cwd > focused surface pwd > none
    const working_directory: ?[:0]const u8 = wd: {
        if (profile.cwd) |cwd| {
            // Expand ~ to HOME
            if (cwd.len > 0 and cwd[0] == '~') {
                if (std.posix.getenv("HOME")) |home| {
                    const expanded = std.fmt.allocPrintZ(
                        self.alloc,
                        "{s}{s}",
                        .{ home, cwd[1..] },
                    ) catch break :wd null;
                    // This leaks but is fine since it's only allocated once per popup creation
                    // and the popup lifetime is long. In practice we could track this, but
                    // it's simpler not to for a path string.
                    break :wd expanded;
                }
            }
            break :wd self.alloc.dupeZ(u8, cwd) catch break :wd null;
        }
        // Try to inherit from focused surface
        const active_win = gtk_app.getActiveWindow() orelse break :wd null;
        const ghostty_win = gobject.ext.cast(Window, active_win) orelse break :wd null;
        const surface = ghostty_win.getActiveSurface() orelse break :wd null;
        break :wd surface.getPwd();
    };

    // ... rest of existing createAndShow (name_z alloc, window creation, etc.) ...

    // Create initial tab — pass working_directory override
    win.newTabForWindow(null, .{
        .working_directory = working_directory,
    });

    // ... present window ...
}
```

Note: `getPwd()` returns a reference to the surface's internal string (no allocation needed) — it's valid for the duration of the call. `newTabForWindow` copies it internally.

- [ ] **Step 2: Add import for `Surface` if not already imported**

At the top of `PopupManager.zig`, check that `Surface` is available. It may need:

```zig
const Surface = @import("class/surface.zig").Surface;
```

- [ ] **Step 3: Build to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add src/apprt/gtk/PopupManager.zig
git commit -m "feat(popup): add CWD support to GTK popup creation"
```

---

### Task 6: Add opacity support to GTK popup creation

**Files:**
- Modify: `src/apprt/gtk/class/window.zig` (add `background_opacity` to `newTabForWindow` overrides)
- Modify: `src/apprt/gtk/class/surface.zig` (apply opacity override during surface init)
- Modify: `src/apprt/gtk/PopupManager.zig` (pass opacity through)

**Background:** In GTK, `background-opacity` is read from the config during surface initialization (`src/apprt/gtk/class/surface.zig` line ~3413 area, where `priv.pwd` is applied to config). The window toggles a CSS class based on whether opacity >= 1 (line 712 of `window.zig`). The renderer reads opacity from the surface's config at init time.

The approach: add a `background_opacity` field to `newTabForWindow`'s overrides struct. In the surface init path (where `pwd` is already applied from overrides), also apply the opacity override to the config.

- [ ] **Step 1: Add `background_opacity` to `newTabForWindow` overrides**

In `src/apprt/gtk/class/window.zig`, in the `newTabForWindow` method (line 422), add to the overrides struct:

```zig
pub fn newTabForWindow(
    self: *Self,
    parent_: ?*CoreSurface,
    overrides: struct {
        command: ?configpkg.Command = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,
        background_opacity: ?f64 = null,  // ADD: per-popup opacity override

        pub const none: @This() = .{};
    },
) void {
```

Pass the new field through to `newTabPage` and down to the surface creation path where config is built.

- [ ] **Step 2: Apply opacity override in surface config initialization**

In `src/apprt/gtk/class/surface.zig`, find where `priv.pwd` is applied to config (line ~3413). After the pwd block, add:

```zig
// Apply popup opacity override if set
if (priv.background_opacity) |opacity| {
    config.@"background-opacity" = std.math.clamp(opacity, 0.0, 1.0);
}
```

This requires adding a `background_opacity: ?f64 = null` field to the Surface private struct, set during creation from the overrides.

- [ ] **Step 3: Update PopupManager to pass opacity**

In `PopupManager.createAndShow`, update the `newTabForWindow` call:

```zig
win.newTabForWindow(null, .{
    .working_directory = working_directory,
    .background_opacity = if (profile.opacity) |o| o else null,
});
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false 2>&1 | head -20`
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add src/apprt/gtk/PopupManager.zig src/apprt/gtk/class/window.zig src/apprt/gtk/class/surface.zig
git commit -m "feat(popup): add per-popup opacity support in GTK"
```

---

## Chunk 3: macOS — Config Hot-Reload + CWD/Opacity

### Task 7: Add new fields to Swift PopupProfileConfig

**Files:**
- Modify: `macos/Sources/Features/Popup/PopupController.swift` (PopupProfileConfig struct, lines 16-34)
- Modify: `macos/Sources/Ghostty/Ghostty.Config.swift` (popupProfiles computed property, lines 606-638)

- [ ] **Step 1: Add fields to PopupProfileConfig**

In `PopupController.swift`, add to `PopupProfileConfig`:

```swift
var cwd: String? = nil
var opacity: Double? = nil  // nil means inherit global background-opacity
```

- [ ] **Step 2: Update Config.swift bridge to read new fields**

In `Ghostty.Config.swift`, in the `popupProfiles` computed property, update the result construction to include the new fields:

```swift
let cwdStr: String? = if let cwdPtr = p.cwd {
    String(cString: cwdPtr)
} else {
    nil
}
let opacityVal: Double? = if p.opacity >= 0 {
    p.opacity
} else {
    nil
}
result[name] = PopupController.PopupProfileConfig(
    position: PopupController.PopupProfileConfig.Position(rawValue: Int(p.position)) ?? .center,
    widthValue: p.width_value,
    widthIsPercent: p.width_is_percent,
    heightValue: p.height_value,
    heightIsPercent: p.height_is_percent,
    autohide: p.autohide,
    persist: p.persist,
    command: cmd,
    cwd: cwdStr,
    opacity: opacityVal
)
```

- [ ] **Step 3: Build macOS app to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && macos/build.nu`
Expected: Builds without errors.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Popup/PopupController.swift macos/Sources/Ghostty/Ghostty.Config.swift
git commit -m "feat(popup): add cwd and opacity to Swift PopupProfileConfig"
```

---

### Task 8: Wire config hot-reload on macOS

**Files:**
- Modify: `macos/Sources/Features/Popup/PopupManager.swift` (updateProfileConfigs method, lines 71-78)
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (ghosttyConfigDidChange, line ~791)

- [ ] **Step 1: Update `updateProfileConfigs` to handle removals**

In `PopupManager.swift`, replace the existing `updateProfileConfigs` method:

```swift
func updateProfileConfigs(_ configs: [String: PopupController.PopupProfileConfig]) {
    // Find and destroy controllers for removed profiles
    let removedNames = Set(profileConfigs.keys).subtracting(configs.keys)
    for name in removedNames {
        if let controller = controllers[name] {
            controller.hide()
            controllers.removeValue(forKey: name)
        }
    }

    // Update stored configs (handles new + changed profiles)
    profileConfigs = configs
}
```

- [ ] **Step 2: Wire into AppDelegate config change handler**

In `AppDelegate.swift`, in `ghosttyConfigDidChange(config:)`, add after `syncMenuShortcuts(config)` (line ~791):

```swift
// Update popup profiles on config reload
popupManager.updateProfileConfigs(config.popupProfiles)
```

`popupManager` is a `lazy var` directly on `AppDelegate` (line 135). No indirection needed.

- [ ] **Step 3: Build macOS app to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && macos/build.nu`
Expected: Builds without errors.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Popup/PopupManager.swift macos/Sources/App/macOS/AppDelegate.swift
git commit -m "feat(popup): wire config hot-reload to macOS PopupManager"
```

---

### Task 9: Add CWD support to macOS popup creation

**Files:**
- Modify: `macos/Sources/Features/Popup/PopupController.swift` (makeSurfaceConfig method, lines 218-228)

- [ ] **Step 1: Update `makeSurfaceConfig` to set working directory**

```swift
private func makeSurfaceConfig() -> Ghostty.SurfaceConfiguration {
    var config = Ghostty.SurfaceConfiguration()
    config.environmentVariables["GHOSTTY_POPUP"] = profileName
    if profileName == PopupManager.quickProfileName {
        config.environmentVariables["GHOSTTY_QUICK_TERMINAL"] = "1"
    }
    if let cmd = profileConfig.command, !cmd.isEmpty {
        config.command = cmd
    }

    // Set working directory: explicit cwd > focused surface pwd > default
    if let cwd = profileConfig.cwd {
        // Expand ~ to home directory
        config.workingDirectory = NSString(string: cwd).expandingTildeInPath
    } else {
        // Try to inherit from the currently focused surface.
        // Cast to BaseTerminalController (common base for TerminalController
        // and PopupController). SurfaceView has a @Published var pwd: String?
        // property populated by OSC 7.
        if let controller = NSApp.keyWindow?.contentViewController as? BaseTerminalController,
           let surfaceView = controller.focusedSurface,
           let pwd = surfaceView.pwd {
            config.workingDirectory = pwd
        }
    }

    return config
}
```

**Confirmed:** `SurfaceConfiguration` has a `workingDirectory: String?` field (line 648 of `SurfaceView.swift`). `SurfaceView` has `@Published var pwd: String?` (line 30 of `SurfaceView_AppKit.swift`). `BaseTerminalController` has a `focusedSurface` property that returns the active `SurfaceView`.

- [ ] **Step 3: Build macOS app to verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && macos/build.nu`
Expected: Builds without errors.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Popup/PopupController.swift
git commit -m "feat(popup): add CWD support to macOS popup creation"
```

---

### Task 10: Add opacity support to macOS popup creation

**Files:**
- Modify: `macos/Sources/Ghostty/Surface View/SurfaceView.swift` (add `backgroundOpacity` to `SurfaceConfiguration`)
- Modify: `macos/Sources/Features/Popup/PopupController.swift` (set opacity in `makeSurfaceConfig`)

**Background:** `SurfaceConfiguration` (line 643 of `SurfaceView.swift`) does NOT currently have a `backgroundOpacity` field. We need to add one, then wire it through the surface creation path so it overrides the `background-opacity` config value before the Metal renderer initializes.

- [ ] **Step 1: Add `backgroundOpacity` field to `SurfaceConfiguration`**

In `macos/Sources/Ghostty/Surface View/SurfaceView.swift`, add to the `SurfaceConfiguration` struct:

```swift
/// Per-popup background opacity override. nil means use global config.
var backgroundOpacity: Double? = nil
```

- [ ] **Step 2: Wire `backgroundOpacity` through surface creation**

Find where `SurfaceConfiguration` fields are applied to the surface/config during initialization. Search for where `workingDirectory` is applied (since it follows the same pattern) and add opacity application nearby. The opacity should be set on the Ghostty config object via `ghostty_config_set` or equivalent before the surface is created with that config.

If the config is applied via `ghostty_surface_config_set` or similar C API:

```swift
if let opacity = surfaceConfig.backgroundOpacity {
    let clamped = max(0.0, min(1.0, opacity))
    // Set background-opacity on the config that will be used to create the surface
    ghostty_config_set(config, "background-opacity", "\(clamped)")
}
```

The exact API call depends on how config overrides work in the Ghostty C API. Search for how `workingDirectory` is applied from `SurfaceConfiguration` to find the pattern.

- [ ] **Step 3: Set opacity in `makeSurfaceConfig`**

In `PopupController.makeSurfaceConfig()`, add before the return:

```swift
if let opacity = profileConfig.opacity {
    config.backgroundOpacity = max(0.0, min(1.0, opacity))
}
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && macos/build.nu`
Expected: Builds without errors.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Ghostty/Surface\ View/SurfaceView.swift macos/Sources/Features/Popup/PopupController.swift
git commit -m "feat(popup): add per-popup opacity support on macOS"
```

---

## Chunk 4: Update Roadmap + Final Verification

### Task 11: Update roadmap and documentation

**Files:**
- Modify: `ROADMAP.md`
- Modify: `docs/superpowers/specs/popup-terminal-roadmap-v2.md`

- [ ] **Step 1: Update ROADMAP.md v2 status**

Change v2 status from "Not started" to "In progress" (or "Complete" once verified).

Add the new properties to the key deliverables if not already listed.

- [ ] **Step 2: Full build verification**

Run both builds:

```bash
# Zig (core + GTK)
cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig build -Demit-macos-app=false

# macOS
macos/build.nu
```

Expected: Both build without errors.

- [ ] **Step 3: Run popup unit tests**

```bash
cd /Users/tucker/projects/ghostty/.claude/worktrees/glimmering-cuddling-spark && zig test src/apprt/popup.zig
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add ROADMAP.md docs/superpowers/specs/popup-terminal-roadmap-v2.md
git commit -m "docs: update roadmap with v2 progress"
```

---

## Task Dependency Graph

```
Task 1 (PopupProfile fields)
  → Task 2 (RepeatablePopup update)
      → Task 3 (GTK updateProfileConfigs)
      → Task 7 (Swift PopupProfileConfig)

Task 3 → Task 4 (GTK config reload wiring)
Task 3 → Task 5 (GTK CWD)
Task 3 → Task 6 (GTK opacity)

Task 7 → Task 8 (macOS config reload wiring)
Task 7 → Task 9 (macOS CWD)
Task 7 → Task 10 (macOS opacity)

Tasks 4-6, 8-10 → Task 11 (docs + verification)
```

**Parallelizable:** Tasks 3-6 (GTK) can run in parallel with Tasks 7-10 (macOS) since they touch different files.
