# Popup Terminal Design Spec

**Date:** 2026-03-14
**Status:** Draft
**Scope:** Generalize Ghostty's Quick Terminal into a multi-instance, configurable popup terminal system.

## Overview

Ghostty's existing Quick Terminal is a single-instance Quake-style dropdown terminal. This feature extends it into a named, multi-instance popup system with configurable positioning, sizing, persistence, and auto-hide behavior. The Quick Terminal becomes a built-in popup profile named `"quick"` — old configs migrate transparently.

### Goals

- Multiple named popup profiles, each with independent configuration
- Configurable positioning, sizing, auto-hide, persistence, and initial command
- Backward-compatible migration from `quick-terminal-*` config keys
- Instant show/hide (<100ms)
- No impact on normal window behavior

### Non-Goals (v1)

- X11 support (currently disabled for quick terminal; separate effort)
- New popup animation — the migrated `"quick"` profile carries forward `quick-terminal-animation-duration` as a legacy property, but new popup profiles have no animation
- Per-window opacity/transparency
- Multi-monitor targeting
- Restoration of non-`"quick"` popup state across app restart
- Config hot-reload of popup profiles (changes require app restart in v1; profiles are loaded once at startup)

### Platform Scope

| Platform | Support |
|----------|---------|
| macOS (AppKit/Metal) | Full: positioning, always-on-top, focus restoration |
| Linux/Wayland (GTK4) | Partial: edge anchoring + margins via `wlr-layer-shell`, no arbitrary x/y |
| Linux/X11 (GTK4) | Not supported in v1 (matches current quick terminal) |

## Configuration

### Syntax

```
popup = <name>:<key>:<value>,<key>:<value>,...
```

Parsed using the existing `cli.args.parseAutoStruct` infrastructure, which uses **colons** as key-value delimiters and commas as field separators. This matches the existing convention used by `command-palette-entry` and other structured config fields. The popup name is extracted by splitting on the first `:`, then the remainder is fed to `parseAutoStruct`.

Note: the name delimiter and key-value delimiter are both `:`. This works because the name is extracted by the *first* colon only, and `parseAutoStruct` then parses the remainder. Example: `popup = quick:position:top,width:100%` → name=`quick`, parsed fields=`position:top,width:100%`.

### Name Rules

- Must be non-empty
- Allowed characters: `[a-zA-Z0-9_-]` (alphanumeric, underscore, hyphen)
- Colons, spaces, and special characters are **not allowed** (colon is the name delimiter)
- Invalid names produce a config parse error

### Duplicate Names

If two `popup = ...` lines share the same name, the **last definition wins** (consistent with how Ghostty handles duplicate keybinds and other repeatable config). No warning emitted.

### PopupProfile Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `position` | enum: `center`, `top`, `bottom`, `left`, `right` | `center` | Named position shortcut |
| `anchor` | enum: `top-left`, `top-right`, `bottom-left`, `bottom-right`, `center` | (none) | Corner/edge to anchor to (macOS only in v1) |
| `x` | dimension (pixels or %) | (none) | Horizontal offset from anchor (macOS only in v1) |
| `y` | dimension (pixels or %) | (none) | Vertical offset from anchor (macOS only in v1) |
| `width` | dimension (pixels or %) | `80%` | Popup width |
| `height` | dimension (pixels or %) | `80%` | Popup height |
| `keybind` | key trigger string | (none) | Toggle keybinding for this popup |
| `command` | shell command string | user's shell | Initial command to run |
| `autohide` | bool | `true` | Hide when popup loses focus |
| `persist` | bool | `true` | Keep terminal alive when hidden |

**Dimension format:** bare number = pixels (e.g., `400`), number with `%` = percentage of screen (e.g., `80%`).

### Position Resolution Rules

1. If only `position` is set: uses sensible defaults for that position
   - `top` → full width, 50% height, anchored to top edge
   - `bottom` → full width, 50% height, anchored to bottom edge
   - `left` → 50% width, full height, anchored to left edge
   - `right` → 50% width, full height, anchored to right edge
   - `center` → centered, 80% width, 80% height
2. If `x`/`y` are set (macOS only): `position` is ignored, explicit coordinates used
3. If `anchor` is set without `x`/`y` (macOS only): anchor determines corner, sized by `width`/`height`
4. On Wayland: `x`, `y`, and `anchor` are **ignored with a log warning** — only edge anchoring via `position` and sizing via `width`/`height` are supported. Note: `position=center` with no anchors relies on compositor behavior to center the surface — this is not guaranteed by the `wlr-layer-shell` protocol and may vary by compositor (e.g., GNOME vs Sway).

### Example Configs

```
# Quake-style dropdown (replaces quick terminal)
popup = quick:position:top,width:100%,height:50%,keybind:ctrl+`,autohide:true

# Centered floating scratchpad
popup = scratch:position:center,width:80%,height:80%,keybind:ctrl+shift+s

# Small calculator in top-right corner (macOS only positioning)
popup = calc:anchor:top-right,x:20,y:20,width:400,height:300,keybind:ctrl+alt+c,command:"bc -l",persist:false

# Monitoring panel pinned to the right side
popup = monitor:position:right,width:30%,height:100%,keybind:ctrl+alt+m,autohide:false,command:htop
```

### Keybind Precedence

**Rule:** Explicit `keybind = ...` lines always win over popup-generated bindings. Among popup profiles, the last `popup = ...` definition wins for a given trigger.

**Implementation:** A single post-processing step in `Config.zig` runs after the full config is loaded (all fields parsed, including all `keybind = ...` and `popup = ...` lines). This step iterates popup profiles in order and, for each profile with a `keybind:` property:

1. Check if the trigger is already bound in the keybind set (i.e., a user-defined `keybind = ...` line already claimed it)
2. If **unbound**: insert `toggle_popup:<name>` for that trigger
3. If **already bound**: skip — the explicit keybind wins, no warning emitted

For duplicate popup keybinds (two profiles claim the same trigger and neither has an explicit `keybind = ...` override): the **last popup definition** wins, because the post-processing iterates in order and overwrites. No warning emitted — consistent with Ghostty's existing "last wins" convention for keybinds.

### Error Handling

- **Unknown popup name in action** (e.g., `toggle_popup:nonexistent`): Log a warning, no-op. Do not crash.
- **Invalid popup config** (e.g., `popup = :width:100%` or `popup = b@d:...`): Config parse error, profile skipped with warning.
- **Command fails on start** (e.g., `command:nonexistent_binary`): Same behavior as a normal terminal whose command fails — the surface shows the error and the user can close it.

### Environment Variables

Popup surfaces set `GHOSTTY_POPUP=<name>` in the child process environment (e.g., `GHOSTTY_POPUP=quick`). For backward compatibility, the `"quick"` popup also sets `GHOSTTY_QUICK_TERMINAL=1` (matching the existing behavior in `surface.zig:1606`). Shell scripts that check for `GHOSTTY_QUICK_TERMINAL` continue to work unchanged.

## Architecture

### Component Diagram

```
Config.zig
  ├─ popup = main:...  ──→ Vec of PopupProfile structs
  ├─ popup = calc:...
  └─ quick-terminal-* keys ──→ synthesized PopupProfile named "quick"
                     │
                     ▼
PopupManager (per-platform)
  ├─ profiles: HashMap(name → PopupProfile)
  ├─ instances: HashMap(name → PopupState)
  │     PopupState = { profile, window, visible }
  │
  ├─ toggle(name)  → create / show / hide / destroy
  ├─ show(name)    → create if needed, then show (for App Intents)
  ├─ hide(name)    → hide or destroy based on persist
  └─ hideAll()     → called on app shutdown
         │
         ├─ macOS: PopupController (per instance)
         │    └─ PopupWindow (NSPanel)
         │
         └─ GTK: Window with is_popup=true + popup_profile
```

### PopupManager

Thin registry that maps profile names to popup state. One per platform runtime.

**State machine per popup instance:**

```
                    toggle/show
[Not Created] ──────────────────→ [Visible]
                                   ↑  │
                            toggle │  │ toggle/hide
                            show   │  │ focus lost (if autohide)
                                   │  ▼
                                  [Hidden]
                                     │
                              toggle/ │ (only if persist=false)
                              hide    │
                                     ▼
                              [Destroyed] = [Not Created]
```

Transitions:
- **[Not Created] → [Visible]**: `toggle` or `show` — create window + surface, apply position, show
- **[Visible] → [Hidden]**: `toggle`, `hide`, or focus loss (if `autohide=true`) — hide window, keep surface alive
- **[Hidden] → [Visible]**: `toggle` or `show` — unhide window, focus surface
- **[Hidden] → [Destroyed]**: `toggle` or `hide` when `persist=false` — destroy window + surface, return to [Not Created]
- **[Visible] → [Visible]**: `show` — no-op
- **[Visible] → [Destroyed]**: `hide` when `persist=false` — destroy directly

**Process exit handling:** When the terminal process inside a popup exits (e.g., user quits `htop`, or shell exits), the popup behaves the same as a normal terminal surface: the `child_exited` event triggers surface cleanup. If the popup's surface tree becomes empty, the popup window is hidden (persist=true) or destroyed (persist=false). The next `toggle`/`show` creates a fresh surface.

**Methods:**
- `toggle(name)`: Main keybinding action. Creates → shows, or shows ↔ hides/destroys.
- `show(name)`: Creates if needed, shows if hidden, no-op if visible. Used by App Intents.
- `hide(name)`: Hides if visible (persist=true) or destroys (persist=false).
- `hideAll()`: Hides/destroys all popups. Called on app quit.
- `onFocusLost(window)`: Called when a popup window loses focus. Checks `autohide` on the corresponding profile.

### Actions

Three new actions added to both `input/Binding.zig` and `apprt/action.zig`:

| Action | Parameter | Description |
|--------|-----------|-------------|
| `toggle_popup` | name (string) | Toggle popup visibility |
| `show_popup` | name (string) | Show popup (create if needed, no-op if visible) |
| `hide_popup` | name (string) | Hide popup |

**Alias mechanism:** `toggle_quick_terminal` is retained in `Binding.zig`'s Action enum as a distinct variant. During action dispatch (in `performAction`), it is translated to `toggle_popup` with name `"quick"`. This avoids any string-aliasing complexity in the parser — the old action is simply handled by calling `PopupManager.toggle("quick")`. Both `toggle_quick_terminal` and `toggle_popup:quick` are accepted in config files.

**C API payload** (follows existing `SetTitle` pattern):

```zig
pub const TogglePopup = struct {
    name: [:0]const u8,

    pub const C = extern struct {
        name: [*:0]const u8,
    };

    pub fn cval(self: TogglePopup) C {
        return .{ .name = self.name.ptr };
    }
};
```

**String lifetime:** PopupManager owns copies of all profile names (allocated on init, freed on deinit). The `name` pointer in the C struct points into PopupManager-owned memory, not directly into the config — this is important because Ghostty can replace config objects on reload. For `toggle_quick_terminal`, the name `"quick"` is a comptime string literal. Action payload strings are stable for the lifetime of the PopupManager (which lives for the app's lifetime).

## Platform Implementation

### macOS

**PopupController** evolves from `QuickTerminalController`, keeping all existing behavior:

- **Lazy surface creation:** Surface created on first `show()`, not at profile load
- **Focus restoration:** Tracks `previousApp`, restores on hide
- **Space handling:** Tracks `previousActiveSpace`, moves terminal between spaces
- **Per-screen frame caching:** Reuses cached frame when redisplaying on same screen
- **Non-activating NSPanel:** Can become key window but doesn't appear in Cmd+Tab

**PopupWindow** evolves from `QuickTerminalWindow` (NSPanel subclass):
- `setAccessibilitySubrole(.floatingWindow)`
- `styleMask.remove(.titled)` for no decorations
- `styleMask.insert(.nonactivatingPanel)`
- **Window level**: For the `"quick"` profile (which retains animation), the existing two-phase approach is preserved: `.popUpMenu` during animation (renders above the menu bar during slide-in), then drops to `.floating` after animation completes. For new popup profiles (no animation), the level is set directly to `.floating` for always-on-top behavior.
- **Created programmatically**, not from a NIB — the existing `QuickTerminal.xib` is simple enough to replace with code, and this avoids the question of loading the same NIB for multiple popup instances

**PopupManager** owned by `AppDelegate`, replaces `quickController`/`quickTerminalControllerState`:
- Stores `[String: PopupController]` dictionary
- Handles `toggle_popup`/`show_popup`/`hide_popup` actions from the Zig C API

**Positioning:** `NSScreen.main.visibleFrame` for screen bounds, calculate frame from profile properties. `anchor`/`x`/`y` fully supported.

**Restoration:** Carried forward for the `"quick"` profile only. New profiles do not persist across app restart in v1.

### GTK/Wayland

**PopupManager** added to `Application`, replaces quick terminal toggle logic in `application.zig`.

**Window changes:**
- `is_popup: bool` — **new GObject property** (not a rename of `quick-terminal`). The old `quick-terminal` property is **kept as a deprecated alias** that maps to `is_popup` internally. This avoids breaking any external GTK CSS selectors or GSettings bindings that reference `quick-terminal`.
- New: `popup_profile: ?*PopupProfile` for profile-specific data
- Internal code migrates from checking `quick_terminal` to checking `is_popup`

**Positioning:** Via `wlr-layer-shell` protocol:
- `position=top/bottom/left/right` → edge anchoring with margins
- `position=center` → no anchors (compositor-dependent centering, not guaranteed)
- `width`/`height` → respected via layer-shell size requests
- `x`/`y`/`anchor` → **ignored with log warning** on Wayland
- **No `wlr-layer-shell` available:** Popup support is **disabled** with a log warning. No fallback to normal GTK windows — this avoids expanding scope and dropping key guarantees (always-on-top, positioning). Matches the existing quick terminal behavior, which also requires layer-shell.

**Focus loss:** `notify::is-active` signal → check `autohide` → hide if true.

## Backward Compatibility

### Config Migration

At config load time, after all fields are parsed, a post-processing step checks for `quick-terminal-*` keys:

1. If any `quick-terminal-*` key is set and no popup named `"quick"` exists: synthesize a `PopupProfile`
2. Map `quick-terminal-position` → `position`
3. Map `quick-terminal-size` → `width`/`height`
4. Map `quick-terminal-autohide` → `autohide` — **preserving the platform-specific default**: on macOS the existing default is `true`; on Linux it is `false`. The synthesized `"quick"` profile inherits whichever platform default applied, not the generic popup default of `true`.
5. Platform-specific keys are applied as legacy-only properties on the `"quick"` profile:
   - `quick-terminal-animation-duration` → animation duration (macOS `"quick"` profile only)
   - `quick-terminal-screen` → screen selection (macOS only)
   - `quick-terminal-space-behavior` → space handling (macOS only)
   - `quick-terminal-keyboard-interactivity` → keyboard interactivity (Wayland only)
   - `gtk-quick-terminal-layer` → layer-shell layer (Wayland only)
   - `gtk-quick-terminal-namespace` → layer-shell namespace (Wayland only)

If both old keys and an explicit `popup = quick:...` exist, the explicit popup wins and old keys are ignored.

### Action Migration

`toggle_quick_terminal` binding action is kept as a distinct action that dispatches to `PopupManager.toggle("quick")`. Both `toggle_quick_terminal` and `toggle_popup:quick` are accepted in config files.

### Deprecation

Old `quick-terminal-*` config keys emit a deprecation warning to stderr with guidance to use the new `popup = quick:...` syntax. No removal timeline in v1.

## File Changes

### New Files

| File | Purpose |
|------|---------|
| `src/apprt/popup.zig` | `PopupProfile` struct, `PopupState`, `Dimension`, shared types |
| `src/apprt/gtk/PopupManager.zig` | GTK popup registry, toggle/show/hide, positioning |
| `macos/Sources/Features/Popup/PopupManager.swift` | macOS popup registry, toggle/show/hide |
| `macos/Sources/Features/Popup/PopupWindow.swift` | NSPanel subclass (programmatic, replaces QuickTerminalWindow) |
| `macos/Sources/Features/Popup/PopupController.swift` | Per-instance lifecycle (evolves from QuickTerminalController) |

### Modified Files

| File | Change |
|------|--------|
| `src/config/Config.zig` | Add `popup` repeatable field, `PopupProfile` parsing via `parseAutoStruct`, post-processing migration from `quick-terminal-*` keys, keybind synthesis |
| `src/input/Binding.zig` | Add `toggle_popup`, `show_popup`, `hide_popup` actions with string parameter; keep `toggle_quick_terminal` as distinct variant |
| `src/apprt/action.zig` | Add `toggle_popup`, `show_popup`, `hide_popup` to Action union with `TogglePopup`/`ShowPopup`/`HidePopup` payloads |
| `include/ghostty.h` | Add three new action keys (`GHOSTTY_ACTION_TOGGLE_POPUP`, `GHOSTTY_ACTION_SHOW_POPUP`, `GHOSTTY_ACTION_HIDE_POPUP`) and C struct for string payload |
| `src/apprt/gtk/class/application.zig` | PopupManager ownership, `performAction` dispatch for new actions, `toggle_quick_terminal` dispatches to PopupManager |
| `src/apprt/gtk/class/window.zig` | Add `is-popup` GObject property, keep `quick-terminal` as deprecated alias, add `popup-profile` property |
| `src/apprt/gtk/winproto/wayland.zig` | Generalize `syncQuickTerminal` to `syncPopup` using profile data |
| `src/apprt/gtk/winproto/x11.zig` | Update `supportsQuickTerminal` → `supportsPopup` (still returns false) |
| `src/apprt/gtk/winproto/noop.zig` | Update stub names to match popup rename |
| `src/apprt/embedded.zig` | No changes needed — generic action dispatch (`@unionInit` + `.cval()`) automatically forwards new actions to the C API |
| `src/input/command.zig` | `toggle_popup`, `show_popup`, and `hide_popup` are excluded from the static command palette (require runtime popup name); `toggle_quick_terminal` remains in the skip list |
| `macos/Sources/App/macOS/AppDelegate.swift` | Replace `quickController`/`quickTerminalControllerState` with PopupManager; update restoration encode/decode for "quick" profile |
| `macos/Sources/Ghostty/Ghostty.App.swift` | Handle `GHOSTTY_ACTION_TOGGLE_POPUP`, `SHOW_POPUP`, `HIDE_POPUP` in `performAction` dispatch |
| `macos/Sources/Ghostty/Ghostty.Config.swift` | Surface popup profile config to Swift layer |
| `macos/Sources/Features/Update/UpdateDriver.swift` | Check `PopupWindow` instead of `QuickTerminalWindow` |
| `macos/Sources/Features/App Intents/Entities/TerminalEntity.swift` | Check `PopupController` instead of `QuickTerminalController` |
| `macos/Sources/Features/App Intents/QuickTerminalIntent.swift` | Call `PopupManager.show("quick")` (not toggle — preserves show-only App Intent contract) |
| `macos/Sources/App/macOS/MainMenu.xib` | Update Quick Terminal menu item action to route through PopupManager |

### Removed Files

| File | Replacement |
|------|-------------|
| `macos/Sources/Features/QuickTerminal/QuickTerminalWindow.swift` | → `Popup/PopupWindow.swift` (programmatic) |
| `macos/Sources/Features/QuickTerminal/QuickTerminalController.swift` | → `Popup/PopupController.swift` |
| `macos/Sources/Features/QuickTerminal/QuickTerminal.xib` | Eliminated — PopupWindow created programmatically |

### Supporting Swift Files (Moved/Refactored)

These existing QuickTerminal support files move into the Popup directory, renamed as appropriate:

| Old File | New File | Notes |
|----------|----------|-------|
| `QuickTerminalPosition.swift` | Kept or folded into `PopupController.swift` | Enum maps to Zig `Position` |
| `QuickTerminalScreen.swift` | Kept as legacy for "quick" profile | macOS screen selection |
| `QuickTerminalSize.swift` | Replaced by `Dimension` type in popup profile | |
| `QuickTerminalSpaceBehavior.swift` | Kept as legacy for "quick" profile | macOS space handling |
| `QuickTerminalScreenStateCache.swift` | Moved into `PopupController.swift` | Per-screen frame caching |
| `QuickTerminalRestorableState.swift` | Moved into `PopupController.swift` | Restoration for "quick" only |

## Testing Strategy

### Unit Tests

- **Config parsing:** Valid popup definitions, edge cases (empty name, invalid characters in name, missing required fields, unknown properties), quoted values with commas/colons/equals, duplicate names (last wins)
- **Migration logic:** Old quick-terminal keys → synthesized profile; explicit popup overrides old keys; both present; platform-specific `autohide` default preserved
- **Position resolution:** Named positions default sizes, anchor+x/y override, percentage vs pixel dimensions
- **Keybind precedence:** Popup-generated keybinds overridden by explicit keybind lines
- **Error handling:** Unknown popup name in action (no-op + warning), invalid config (skip + warning)

### Build Verification

- `zig build -Demit-macos-app=false` — Zig-side compiles
- `macos/build.nu` — macOS app builds
- `zig build test -Dtest-filter=popup` — targeted unit tests

### Manual Testing

- Toggle popup on/off with keybinding — verify instant show/hide
- Auto-hide on focus loss — click away, popup hides
- `autohide=false` — click away, popup stays visible
- Persist=true — toggle off, toggle on, verify scrollback preserved
- Persist=false — toggle off, toggle on, verify fresh shell
- Process exit in popup — command exits, popup hides/destroys appropriately
- Multiple popups — toggle two different profiles independently
- Quick terminal migration — use old `quick-terminal-*` config, verify identical behavior
- `toggle_quick_terminal` keybind — verify it still works as before
- Wayland — verify edge-anchored positioning, warning on x/y usage, test on Sway and GNOME
- Wayland without layer-shell — verify popup is disabled with warning (no fallback)
- macOS — verify full coordinate positioning, space handling, focus restoration
- macOS App Intent — "Open Quick Terminal" via Shortcuts, verify show-only (not toggle)

### Memory/Lifecycle

- Hidden persist=true popups: verify terminal+renderer stay in memory, no leaks
- Destroy persist=false popups: verify full cleanup (surface, PTY, renderer thread)
- App quit with hidden popups: verify clean shutdown, no orphaned processes
- Many popups (10+): verify no resource exhaustion
