/**
 * @file vt.h
 *
 * libghostty-vt - Virtual terminal emulator library
 * 
 * This library provides functionality for parsing and handling terminal
 * escape sequences as well as maintaining terminal state such as styles,
 * cursor position, screen, scrollback, and more.
 *
 * WARNING: This is an incomplete, work-in-progress API. It is not yet
 * stable and is definitely going to change. 
 */

/**
 * @mainpage libghostty-vt - Virtual Terminal Emulator Library
 *
 * libghostty-vt is a C library which implements a modern terminal emulator,
 * extracted from the [Ghostty](https://ghostty.org) terminal emulator.
 *
 * libghostty-vt contains the logic for handling the core parts of a terminal
 * emulator: parsing terminal escape sequences, maintaining terminal state,
 * encoding input events, etc. It can handle scrollback, line wrapping, 
 * reflow on resize, and more.
 *
 * @warning This library is currently in development and the API is not yet stable.
 * Breaking changes are expected in future versions. Use with caution in production code.
 *
 * @section groups_sec API Reference
 *
 * The API is organized into the following groups:
 * - @ref terminal "Terminal" - Complete terminal emulator state and rendering
 * - @ref render "Render State" - Incremental render state updates for custom renderers
 * - @ref formatter "Formatter" - Format terminal content as plain text, VT sequences, or HTML
 * - @ref osc "OSC Parser" - Parse OSC (Operating System Command) sequences
 * - @ref sgr "SGR Parser" - Parse SGR (Select Graphic Rendition) sequences
 * - @ref paste "Paste Utilities" - Validate paste data safety
 * - @ref build_info "Build Info" - Query compile-time build configuration
 * - @ref allocator "Memory Management" - Memory management and custom allocators
 * - @ref wasm "WebAssembly Utilities" - WebAssembly convenience functions
 *
 * Encoding related APIs:
 * - @ref focus "Focus Encoding" - Encode focus in/out events into terminal sequences
 * - @ref key "Key Encoding" - Encode key events into terminal sequences
 * - @ref mouse "Mouse Encoding" - Encode mouse events into terminal sequences
 *
 * @section examples_sec Examples
 *
 * Complete working examples:
 * - @ref c-vt-build-info/src/main.c - Build info query example
 * - @ref c-vt/src/main.c - OSC parser example
 * - @ref c-vt-encode-key/src/main.c - Key encoding example
 * - @ref c-vt-encode-mouse/src/main.c - Mouse encoding example
 * - @ref c-vt-paste/src/main.c - Paste safety check example
 * - @ref c-vt-sgr/src/main.c - SGR parser example
 * - @ref c-vt-formatter/src/main.c - Terminal formatter example
 * - @ref c-vt-grid-traverse/src/main.c - Grid traversal example using grid refs
 *
 */

/** @example c-vt-build-info/src/main.c
 * This example demonstrates how to query compile-time build configuration
 * such as SIMD support, Kitty graphics, and tmux control mode availability.
 */

/** @example c-vt/src/main.c
 * This example demonstrates how to use the OSC parser to parse an OSC sequence,
 * extract command information, and retrieve command-specific data like window titles.
 */

/** @example c-vt-encode-key/src/main.c
 * This example demonstrates how to use the key encoder to convert key events
 * into terminal escape sequences using the Kitty keyboard protocol.
 */

/** @example c-vt-encode-mouse/src/main.c
 * This example demonstrates how to use the mouse encoder to convert mouse events
 * into terminal escape sequences using the SGR mouse format.
 */

/** @example c-vt-paste/src/main.c
 * This example demonstrates how to use the paste utilities to check if
 * paste data is safe before sending it to the terminal.
 */

/** @example c-vt-sgr/src/main.c
 * This example demonstrates how to use the SGR parser to parse terminal
 * styling sequences and extract text attributes like colors and underline styles.
 */

/** @example c-vt-formatter/src/main.c
 * This example demonstrates how to use the terminal and formatter APIs to
 * create a terminal, write VT-encoded content into it, and format the screen
 * contents as plain text.
 */

/** @example c-vt-grid-traverse/src/main.c
 * This example demonstrates how to traverse the entire terminal grid using
 * grid refs to inspect cell codepoints, row wrap state, and cell styles.
 */

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/build_info.h>
#include <ghostty/vt/clipboard.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/focus.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/osc.h>
#include <ghostty/vt/sgr.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/key.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/mouse.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/wasm.h>

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_H */
