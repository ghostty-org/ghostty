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
 * - @ref key "Key Encoding" - Encode key events into terminal sequences
 * - @ref osc "OSC Parser" - Parse OSC (Operating System Command) sequences
 * - @ref sgr "SGR Parser" - Parse SGR (Select Graphic Rendition) sequences
 * - @ref paste "Paste Utilities" - Validate paste data safety
 * - @ref allocator "Memory Management" - Memory management and custom allocators
 * - @ref wasm "WebAssembly Utilities" - WebAssembly convenience functions
 *
 * @section examples_sec Examples
 *
 * Complete working examples:
 * - @ref c-vt/src/main.c - OSC parser example
 * - @ref c-vt-key-encode/src/main.c - Key encoding example
 * - @ref c-vt-paste/src/main.c - Paste safety check example
 * - @ref c-vt-sgr/src/main.c - SGR parser example
 *
 */

/** @example c-vt/src/main.c
 * This example demonstrates how to use the OSC parser to parse an OSC sequence,
 * extract command information, and retrieve command-specific data like window titles.
 */

/** @example c-vt-key-encode/src/main.c
 * This example demonstrates how to use the key encoder to convert key events
 * into terminal escape sequences using the Kitty keyboard protocol.
 */

/** @example c-vt-paste/src/main.c
 * This example demonstrates how to use the paste utilities to check if
 * paste data is safe before sending it to the terminal.
 */

/** @example c-vt-sgr/src/main.c
 * This example demonstrates how to use the SGR parser to parse terminal
 * styling sequences and extract text attributes like colors and underline styles.
 */

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <ghostty/vt/result.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/osc.h>
#include <ghostty/vt/sgr.h>
#include <ghostty/vt/key.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/wasm.h>

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_H */
