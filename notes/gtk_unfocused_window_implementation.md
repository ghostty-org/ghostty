# GTK Implementation: Unfocused Window Opacity

## Overview

This document describes the implementation of the `unfocused-window-opacity` and `unfocused-window-fill` configuration options for the GTK (Linux) version of Ghostty. This feature dims all terminal surfaces in a window when it loses focus, making it visually clear which window is currently active.

## Implementation Summary

The implementation follows the same architectural pattern as the existing `unfocused-split-opacity` feature in GTK, using:

1. Dynamic CSS generation based on config values
2. GTK Revealer with DrawingArea overlay
3. Property binding in Blueprint templates
4. Window focus state tracking via GObject signals

## Files Modified

### 1. `src/apprt/gtk/class/application.zig`

**Location:** After unfocused-split CSS generation (around line 853)

**Changes:** Added CSS generation for the `unfocused-window` widget class:

```zig
const unfocused_window_fill: CoreConfig.Color = config.@"unfocused-window-fill" orelse config.background;

try writer.print(
    \\widget.unfocused-window {{
    \\ opacity: {d:.2};
    \\ background-color: rgb({d},{d},{d});
    \\}}
    \\
, .{
    1.0 - config.@"unfocused-window-opacity",
    unfocused_window_fill.r,
    unfocused_window_fill.g,
    unfocused_window_fill.b,
});
```

**Rationale:**

- Follows the exact pattern used for `unfocused-split` styling
- Uses `1.0 - opacity` to convert from "window opacity" to "overlay opacity"
- Defaults to background color if no custom fill color is specified

### 2. `src/apprt/gtk/class/surface.zig`

**Changes Made:**

#### A. Added `window-active` Property (after `is-split` property, ~line 306)

```zig
pub const @"window-active" = struct {
    pub const name = "window-active";
    const impl = gobject.ext.defineProperty(
        name,
        Self,
        bool,
        .{
            .default = true,
            .accessor = gobject.ext.privateFieldAccessor(
                Self,
                Private,
                &Private.offset,
                "window_active",
            ),
        },
    );
};
```

**Purpose:** Tracks whether the parent window is currently active (has focus)

#### B. Added Private Field (~line 629)

```zig
// True if the parent window is active (has focus)
window_active: bool = true,
```

#### C. Added Callback Function (~line 747)

```zig
/// Callback used to determine whether unfocused-window-fill / unfocused-window-opacity
/// should be applied to the surface
fn closureShouldUnfocusedWindowBeShown(
    _: *Self,
    window_active: c_int,
) callconv(.c) c_int {
    return @intFromBool(window_active == 0);
}
```

**Purpose:** Blueprint binding callback that returns true when window is NOT active

#### D. Connected Window Active Signal (~line 2962)

Added in `glareaRealize` function:

```zig
// Connect to window's is-active property to track focus
self.connectWindowActiveSignal();
```

New helper functions:

```zig
fn connectWindowActiveSignal(self: *Self) void {
    const widget = self.as(gtk.Widget);

    // Get the parent window using getAncestor
    const window = ext.getAncestor(Window, widget) orelse return;

    // Get initial window active state
    const priv = self.private();
    priv.window_active = window.as(gtk.Window).isActive() != 0;

    // Connect to notify::is-active signal
    _ = gobject.Object.signals.notify.connect(
        window.as(gobject.Object).as(gobject.Object),
        *Self,
        windowActiveChanged,
        self,
        .{},
    );
}

fn windowActiveChanged(
    _: *gobject.Object,
    _: *gobject.ParamSpec,
    self: *Self,
) callconv(.c) void {
    const priv = self.private();

    // Get window from widget ancestor
    const widget = self.as(gtk.Widget);
    const window = ext.getAncestor(Window, widget) orelse return;
    const is_active = window.as(gtk.Window).isActive() != 0;

    if (priv.window_active != is_active) {
        priv.window_active = is_active;
        self.as(gobject.Object).notify("window-active");
    }
}
```

**Purpose:**

- Connects to the parent window's `notify::is-active` signal
- Updates the `window_active` property when window focus changes
- Notifies property observers to trigger UI updates

#### E. Registered Callback (~line 3330)

```zig
class.bindTemplateCallback("should_unfocused_window_be_shown", &closureShouldUnfocusedWindowBeShown);
```

### 3. `src/apprt/gtk/css/style.css`

**Location:** After surface styling (around line 117)

**Changes:** Added CSS rule to prevent GTK's automatic backdrop dimming:

```css
/* Prevent GTK from automatically dimming the GL area when window is in backdrop state */
.surface:backdrop glarea {
  opacity: 1;
}
```

**Rationale:**

- GTK automatically applies the `:backdrop` pseudo-class to windows that lose focus
- This was causing the GLArea background to dim automatically
- Setting opacity to 1 explicitly prevents this default GTK behavior
- This ensures our unfocused-window-opacity feature has full control over dimming

### 4. `src/apprt/gtk/ui/1.2/surface.blp`

**Location:** After unfocused-split overlay (around line 176)

**Changes:** Added new overlay revealer:

```blueprint
[overlay]
// Apply unfocused-window-fill and unfocused-window-opacity when window loses focus
// This dims all surfaces in an unfocused window
Revealer {
  reveal-child: bind $should_unfocused_window_be_shown(template.window-active) as <bool>;
  transition-duration: 0;
  // This is all necessary so that the Revealer itself doesn't override
  // any input events from the other overlays.
  can-focus: false;
  can-target: false;
  focusable: false;

  DrawingArea {
    styles [
      "unfocused-window",
    ]
  }
}
```

**Rationale:**

- Follows the exact structure of the unfocused-split overlay
- Uses `Revealer` for conditional visibility based on window focus
- `DrawingArea` with CSS class `unfocused-window` receives the styling
- Transition duration of 0 for instant appearance/disappearance
- Input event flags ensure overlay doesn't interfere with user interaction

## How It Works

### Initialization Flow

1. **Surface Creation:** When a surface is created, the `window_active` property defaults to `true`

2. **GL Area Realization:** When the GL rendering area is realized:
   - `glareaRealize()` is called
   - This calls `connectWindowActiveSignal()`
   - The parent window is found using `ext.getAncestor(Window, widget)`
   - Initial window active state is read and stored
   - Signal connection is established to window's `notify::is-active`

3. **CSS Generation:** When the application loads configuration:
   - `loadRuntimeCss()` is called
   - CSS rules are generated for `widget.unfocused-window` class
   - Opacity and background color are set based on config values

### Runtime Behavior

1. **Window Loses Focus:**
   - GTK window's `is-active` property changes to `false`
   - `windowActiveChanged()` callback is triggered
   - Surface's `window_active` property is updated to `false`
   - Property notification triggers Blueprint binding re-evaluation
   - `should_unfocused_window_be_shown()` returns `true` (window_active == 0)
   - Revealer shows the DrawingArea overlay
   - CSS styling applies dimming effect

2. **Window Gains Focus:**
   - GTK window's `is-active` property changes to `true`
   - Same callback chain as above
   - `should_unfocused_window_be_shown()` returns `false`
   - Revealer hides the overlay
   - Normal appearance is restored

## Interaction with Split Dimming

The unfocused window overlay is **independent** from split dimming:

- **Focused window, unfocused split:** Only split overlay shows
- **Unfocused window, focused split:** Only window overlay shows
- **Unfocused window, unfocused split:** Both overlays stack (intentional)
  - Provides clear visual hierarchy
  - Each effect can be independently configured or disabled

## Configuration

Users can configure this feature in their Ghostty config file:

```
# Opacity when window is unfocused (0.15 to 1.0)
# 1.0 = no dimming (default), lower = more dimming
unfocused-window-opacity = 0.7

# Color of the dimming overlay (optional)
# Defaults to background color
unfocused-window-fill = #000000
```

## Testing

### Manual Testing Steps

1. **Basic Functionality:**
   - Set `unfocused-window-opacity = 0.5` in config
   - Open Ghostty
   - Click to another application → window should dim
   - Click back to Ghostty → window should return to normal

2. **Default Disabled:**
   - Remove/comment out config option (or set to 1.0)
   - Restart Ghostty
   - Click away → no dimming should occur

3. **Custom Color:**
   - Set `unfocused-window-opacity = 0.3`
   - Set `unfocused-window-fill = #0000FF` (blue tint)
   - Unfocused window should have blue tint

4. **Multiple Windows:**
   - Open two Ghostty windows
   - Click between them → only unfocused window dims
   - Click to third app → both Ghostty windows dim

5. **With Splits:**
   - Set both `unfocused-window-opacity = 0.3` and `unfocused-split-opacity = 0.5`
   - Create splits
   - Test all combinations of window/split focus
   - Verify overlays stack correctly

## Known Issues and Solutions

### GTK Backdrop Dimming

**Issue:** GTK automatically applies opacity changes to widgets in unfocused windows via the `:backdrop` CSS pseudo-class. This was causing the background to dim even when `unfocused-window-opacity` was set to 1.0 (disabled).

**Solution:** Added explicit CSS rule `.surface:backdrop glarea { opacity: 1; }` to override GTK's default backdrop behavior and give our feature full control over dimming.

**Symptoms if missing:** Background becomes slightly transparent when window loses focus, even with opacity set to 1.0. Only visible with semi-transparent backgrounds or themes.

## Technical Notes

### Why `getAncestor` Instead of `getRoot`?

GTK's `getRoot()` returns a `gtk.Root` type, which cannot be directly cast to `gtk.Window`. Using `ext.getAncestor(Window, widget)` properly traverses the widget hierarchy to find the parent window.

### Signal Connection Timing

The signal connection happens in `glareaRealize()` because:

- The surface must be part of a realized widget tree
- The parent window must exist in the hierarchy
- Earlier connection attempts would fail to find the window

### Property Notification

Using `self.as(gobject.Object).notify("window-active")` triggers the Blueprint binding re-evaluation, which calls `should_unfocused_window_be_shown()` and updates the Revealer's visibility.

### Memory Management

The signal connection is made to the window object, not stored in the surface. GTK's signal system handles cleanup when either the window or surface is destroyed.

## Platform Parity

This implementation achieves feature parity with the macOS implementation:

| Feature                        | macOS                | GTK/Linux          |
| ------------------------------ | -------------------- | ------------------ |
| Window focus tracking          | ✅ NSWindow delegate | ✅ GObject signals |
| Opacity configuration          | ✅                   | ✅                 |
| Fill color configuration       | ✅                   | ✅                 |
| Dynamic overlay                | ✅ SwiftUI Rectangle | ✅ GTK DrawingArea |
| Independent from split dimming | ✅                   | ✅                 |
| Instant transition             | ✅                   | ✅                 |

## Future Enhancements

Potential improvements for future consideration:

1. **Transition Animation:** Currently uses instant appearance/disappearance. Could add smooth fade transition.

2. **Per-Monitor DPI Awareness:** Currently uses global scale factor. Could be enhanced for per-monitor DPI.

3. **Wayland-Specific Optimizations:** Could add Wayland protocol-specific focus tracking if available.

## Conclusion

The GTK implementation successfully mirrors the macOS implementation's behavior and architecture. It follows GTK best practices for signal handling, property binding, and dynamic styling, while maintaining consistency with existing Ghostty GTK patterns like the unfocused-split feature.
