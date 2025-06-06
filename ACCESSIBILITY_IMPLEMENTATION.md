# Ghostty macOS Accessibility Implementation

This document describes the accessibility support added to Ghostty for macOS.

## Overview

The implementation adds basic accessibility support to the Ghostty terminal emulator, allowing assistive technologies like VoiceOver to read the terminal content. This is achieved by:

1. Adding a C API function to extract the visible terminal viewport text
2. Implementing NSAccessibility protocol methods in the macOS SurfaceView

## Changes Made

### 1. C API Addition (src/apprt/embedded.zig)

Added `ghostty_surface_viewport_text` function that:
- Extracts the visible text content from the terminal viewport
- Handles proper UTF-8 encoding
- Trims trailing spaces from lines
- Returns properly formatted text with newlines between rows

### 2. Header File Update (include/ghostty.h)

Added the function declaration:
```c
uintptr_t ghostty_surface_viewport_text(ghostty_surface_t, char*, uintptr_t);
```

### 3. macOS Accessibility Implementation (macos/Sources/Ghostty/SurfaceView_AppKit.swift)

Implemented the following NSAccessibility protocol methods:

- `isAccessibilityElement()` - Returns true to indicate this is an accessible element
- `accessibilityRole()` - Returns `.textArea` role
- `accessibilityValue()` - Returns the current viewport text using the C API
- `accessibilityLabel()` - Returns "Terminal" as the label
- `isAccessibilityFocused()` - Returns the current focus state
- `accessibilitySelectedText()` - Returns selected text if any
- `accessibilitySelectedTextRange()` - Returns the range of selected text
- `accessibilityNumberOfCharacters()` - Returns the character count
- `accessibilityString(for:)` - Returns text for a specific range
- `accessibilityLine(for:)` - Returns line number for a character index
- `accessibilityRange(forLine:)` - Returns the range for a specific line
- `accessibilityPerformPress()` - Focuses the terminal when activated

### 4. Automatic Updates

Added throttled accessibility notifications when the terminal content changes:
- Updates are throttled to maximum 2 times per second to avoid overwhelming the accessibility system
- Notifications are sent when the terminal layer is redrawn

## Usage

With these changes, macOS accessibility tools can now:
1. Read the terminal content using VoiceOver
2. Navigate through the text line by line
3. Access selected text
4. Be notified when content changes

## Building

To build Ghostty with these changes:
1. Install Zig (required for building the core library)
2. Run `zig build` to build the XCFramework
3. Open `macos/Ghostty.xcodeproj` in Xcode
4. Build and run the project

## Testing

To test the accessibility features:
1. Enable VoiceOver (Cmd+F5)
2. Navigate to the Ghostty terminal window
3. Use VoiceOver commands to read the terminal content
4. The Accessibility Inspector should now show the terminal text content

## Future Improvements

Potential enhancements could include:
- Support for cursor position tracking
- More granular text change notifications
- Support for reading specific regions (like prompts vs output)
- Integration with terminal semantic markers