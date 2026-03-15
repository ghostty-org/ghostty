# Popup Terminal v2 — Config Hot-Reload + Quality of Life

**Date:** 2026-03-14
**Status:** Approved
**Scope:** Config hot-reload for popup profiles, per-popup `cwd`, per-popup `opacity`

---

## Overview

v1 shipped multi-instance popup terminals with named profiles. Changing popup config requires rebuilding. v2 makes popups respond to config reload and adds two per-popup properties: working directory and background opacity.

## Scope

1. **Config hot-reload** — edit popup config, reload, popups update without restart
2. **`cwd`** — per-popup working directory (explicit path or inherit from focused surface)
3. **`opacity`** — per-popup background opacity (0.0–1.0)

### Out of scope

- `border-color` — handled by external window manager/border app
- `dismiss-key` — the existing `keybind` property on popup profiles already toggles open/close

---

## 1. New PopupProfile Properties

### Zig (`src/apprt/popup.zig`)

Two new fields on `PopupProfile`:

```zig
cwd: ?[]const u8 = null,      // working directory path; null = inherit from focused surface
opacity: ?f64 = null,         // 0.0–1.0 background opacity; null = inherit global background-opacity
```

### Config syntax

```ini
popup = shell:cwd:~/projects,opacity:0.8,keybind:ctrl+shift+t
popup = lazygit:opacity:0.9,command:lazygit,persist:false
```

Parsed via existing `parseAutoStruct` — no parser changes needed.

### C API bridge (`PopupProfile.C`)

- `cwd`: `?[*:0]const u8` (sentinel-terminated string, null if not set)
- `opacity`: `f64` (use `-1.0` to represent "not set" since extern structs can't have Zig optionals)

`RepeatablePopup` gains a parallel `cwd_z` array (like `commands_z`) for sentinel-terminated CWD copies owned by the config.

---

## 2. Config Hot-Reload Flow

### Trigger

Existing config reload path: SIGHUP / `reload_config` action → `App.updateConfig()` → `config_change` action fires to apprt.

### Apprt handling

**GTK** — In `Application.configChange()`, call `popup_manager.updateProfileConfigs(new_config)`.

**macOS** — In `Ghostty.App` config change handler, call `popupManager.updateProfileConfigs(newConfig.popupProfiles)`. The macOS `PopupManager` already has this method; it's called from `init` today — wire it into the reload path too.

### `updateProfileConfigs()` logic (both platforms)

1. **Diff** old profile name set vs new profile name set
2. **Removed profiles** — if a popup window/controller exists for a removed name, hide and destroy it (regardless of `persist` flag)
3. **New profiles** — store config; popup is created lazily on first toggle/show (existing behavior)
4. **Changed profiles** — update stored config; changes apply on next toggle. Currently-visible popups keep running with old settings until hidden and re-shown. This avoids jarring mid-use window resizing.

### Keybind re-synthesis

`Config.finalize()` already re-runs `synthesizePopupKeybinds()` during reload, so new/changed/removed keybinds for popup profiles are handled automatically.

---

## 3. Per-Popup CWD

### Behavior

When a popup's terminal is first spawned:

1. If profile has explicit `cwd` → use that path (with `~` expansion)
2. If profile has no `cwd` → query focused surface's CWD via `ghostty_surface_pwd()` (OSC 7 tracking) and use it
3. Fallback: if focused surface has no known CWD, use `$HOME`

CWD is set once at spawn time. The popup's shell can `cd` freely after that.

### macOS

In `PopupController.makeSurfaceConfig()`, resolve CWD from profile or focused surface and set it on the surface config.

### GTK

In `PopupManager.createAndShow()`, resolve CWD from profile or focused surface and pass to the new surface config.

### Edge cases

- Explicit `cwd` path doesn't exist → shell handles it (starts in `/` or errors)
- Surface created with `persist=true` retains its CWD from original spawn — no CWD update on re-show

---

## 4. Per-Popup Opacity

### Behavior

When a popup surface is created, its background opacity is set from the profile's `opacity` field instead of the global `background-opacity`.

If `opacity` is null (not set), the popup inherits the global `background-opacity` setting — existing behavior, no change.

### macOS

In `PopupController.makeSurfaceConfig()`, if `profileConfig.opacity` is set, override the surface's `background-opacity` config value before creating the surface. The Metal renderer's existing opacity path handles the rest.

### GTK

Same approach — override `background-opacity` in the surface config at popup window creation time. The OpenGL renderer handles it from there.

### On config reload

Opacity changes apply on next toggle (consistent with Section 2). If `persist=false`, the popup is destroyed and recreated with new opacity. If `persist=true`, the old opacity stays until the shell exits.

No new rendering code — we override one config value at surface creation time and the existing renderers do the work.

---

## Files Modified

| File | Changes |
|------|---------|
| `src/apprt/popup.zig` | Add `cwd`, `opacity` fields to `PopupProfile`; add to `PopupProfile.C` |
| `src/config/Config.zig` | Update `RepeatablePopup` for new fields (C bridge, clone, equal, deinit) |
| `src/apprt/gtk/PopupManager.zig` | Add `updateProfileConfigs()` method; CWD/opacity at surface creation |
| `src/apprt/gtk/class/application.zig` | Call `popup_manager.updateProfileConfigs()` in `configChange()` |
| `macos/Sources/Features/Popup/PopupManager.swift` | Wire `updateProfileConfigs()` into config reload path |
| `macos/Sources/Features/Popup/PopupController.swift` | CWD/opacity in `makeSurfaceConfig()`; update `PopupProfileConfig` struct |
| `macos/Sources/Ghostty/Ghostty.Config.swift` | Bridge new fields in `popupProfiles` property |
