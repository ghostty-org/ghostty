# Implementation Plan: Window Dimming on Focus Loss

## Overview

Add window dimming functionality that dims ALL surfaces in a window when it loses focus and returns to normal appearance when it gains focus. This feature will be controlled by a new configuration option `unfocused-window-opacity` with a default value of 0 (disabled).

## Requirements Summary

- Dim all surfaces when window loses focus (windowDidResignKey)
- Return to normal when window gains focus (windowDidBecomeKey)
- Use semi-transparent black rectangle overlay (same approach as split dimming)
- Configuration option: `unfocused-window-opacity` (default: 0, disabled)
- Simple black overlay for dimming

## Implementation Steps

### Step 1: Add Configuration Field to Zig Config

**File:** `src/config/Config.zig`
**Location:** After line 973 (after `@"unfocused-split-fill": ?Color = null,`)

Add the new configuration field with documentation:

```zig
/// The opacity level (opposite of transparency) of an unfocused window.
/// When a window loses focus, all surfaces in the window are dimmed by this amount
/// to make it easier to see which window has focus. To disable this feature, set
/// this value to 1 or 0.
///
/// A value of 1 is fully opaque (no dimming) and a value of 0 is fully transparent.
/// Because "0" is not useful (it makes the window look very weird), the minimum value
/// is 0.15. This value still looks weird but you can at least see what's going on.
/// A value outside of the range 0.15 to 1 will be clamped to the nearest valid value.
///
/// When set to 0 (the default), this feature is disabled completely.
@"unfocused-window-opacity": f64 = 0,
```

**Rationale:**

- Uses `f64` type to match existing opacity configurations
- Default value of 0 disables the feature (no breaking changes)
- Documentation follows the pattern of `unfocused-split-opacity`
- Placed logically with related window appearance options

### Step 2: Add Value Clamping in Config Finalization

**File:** `src/config/Config.zig`
**Location:** In `finalize()` function, after line 4258 (after unfocused-split-opacity clamping)

Add clamping logic to ensure valid values:

```zig
    // Clamp our window opacity - allow 0 for "disabled"
    if (self.@"unfocused-window-opacity" > 0) {
        self.@"unfocused-window-opacity" = @min(1.0, @max(0.15, self.@"unfocused-window-opacity"));
    }
```

**Rationale:**

- Only clamps if value > 0 (preserves "0 = disabled" semantic)
- Uses same range as split opacity (0.15 to 1.0) for consistency
- Prevents unusable values while allowing explicit disabling

### Step 3: Add Swift Configuration Accessor

**File:** `macos/Sources/Ghostty/Ghostty.Config.swift`
**Location:** After line 419 (after `unfocusedSplitOpacity` property)

Add Swift accessor to expose config value to UI layer:

```swift
        var unfocusedWindowOpacity: Double {
            guard let config = self.config else { return 0 }
            var opacity: Double = 0
            let key = "unfocused-window-opacity"
            _ = ghostty_config_get(config, &opacity, key, UInt(key.lengthOfBytes(using: .utf8)))
            return 1 - opacity
        }
```

**Rationale:**

- Returns 0 (disabled) if config not loaded
- **Critical:** Uses `1 - opacity` transformation to convert from "opacity when unfocused" to "overlay opacity"
  - Example: config value 0.7 (70% opaque) → returns 0.3 (30% overlay opacity for dimming)
- Matches the pattern used by `unfocusedSplitOpacity`

### Step 4: Add Window Dimming Overlay

**File:** `macos/Sources/Ghostty/SurfaceView.swift`
**Location:** After line 236 (after split dimming overlay, before ZStack closing brace)

Add the window dimming overlay in the ZStack:

```swift
                // If our window doesn't have focus, we put a semi-transparent black
                // rectangle above our view to make it look unfocused. This is independent
                // of split focus - it applies to ALL surfaces in an unfocused window.
                if (!windowFocus) {
                    let overlayOpacity = ghostty.config.unfocusedWindowOpacity;
                    if (overlayOpacity > 0) {
                        Rectangle()
                            .fill(Color.black)
                            .allowsHitTesting(false)
                            .opacity(overlayOpacity)
                    }
                }
```

**Rationale:**

- Uses existing `windowFocus` state (already tracked via NSWindow notifications at lines 79-91)
- Placed AFTER split dimming for proper visual layering
- Uses `Color.black` as specified (simple black overlay)
- `if (overlayOpacity > 0)` prevents unnecessary view creation when disabled
- `.allowsHitTesting(false)` ensures overlay doesn't intercept mouse events
- Follows identical structure to split dimming overlay

## Visual Behavior

### Layering Effects

- **Window focused, split focused:** No dimming
- **Window focused, split unfocused:** Only split dimming (existing behavior)
- **Window unfocused, split focused:** Only window dimming (new)
- **Window unfocused, split unfocused:** Both overlays stack (intentional - shows clear hierarchy)

### Why Layering Works

- Window overlay (black) + split overlay (configurable color) = stronger dimming for unfocused splits in unfocused windows
- Provides clear visual hierarchy: window focus > split focus
- Each effect is independently controlled and can be disabled

## Files Modified

| File                                         | Lines Added | Description                  |
| -------------------------------------------- | ----------- | ---------------------------- |
| `src/config/Config.zig`                      | ~12         | Config field definition      |
| `src/config/Config.zig`                      | ~4          | Value clamping in finalize() |
| `macos/Sources/Ghostty/Ghostty.Config.swift` | ~8          | Swift accessor property      |
| `macos/Sources/Ghostty/SurfaceView.swift`    | ~11         | Window dimming overlay       |

**Total:** ~35 lines of new code

## Testing Considerations

### Basic Functionality

1. Set `unfocused-window-opacity = 0.3` in config
2. Open Ghostty and click to another application → verify black dimming appears
3. Click back to Ghostty → verify dimming disappears instantly

### Default Disabled State

1. Remove/comment out config option
2. Restart Ghostty and click away → verify NO dimming occurs

### Interaction with Split Dimming

1. Set both `unfocused-window-opacity = 0.3` and `unfocused-split-opacity = 0.7`
2. Create splits and test all focus combinations
3. Verify that unfocused splits in unfocused windows show both effects (stronger dimming)

### Multiple Windows

1. Open two Ghostty windows
2. Click between them → verify only unfocused window dims
3. Click to third application → verify both Ghostty windows dim

### Value Clamping

1. Test edge values: -0.5 (disabled), 0.1 (clamps to 0.15), 1.5 (clamps to 1.0)
2. Verify 1.0 shows maximum dimming (not disabled)

## Key Design Decisions

1. **Default disabled (0):** No breaking changes for existing users
2. **Black overlay only:** Simpler than customizable color, sufficient for use case
3. **Independent from split dimming:** Both can be active, allowing fine-grained control
4. **Additive layering:** Multiple overlays stack naturally for compound states
5. **Reuse existing state:** `windowFocus` already tracked, no new notification handlers needed
