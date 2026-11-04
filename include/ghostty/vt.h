/**
 * @file vt.h
 *
 * libghostty-vt - Virtual terminal emulator library
 * 
 * This library provides functionality for parsing and handling terminal
 * escape sequences as well as maintaining terminal state such as styles,
 * cursor position, screen, scrollback, and more.
 *
 * Until 1.0, each minor release (such as 0.2) may make changes that break
 * existing programs. See the main page for details.
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
 * @section stability_sec Stability
 *
 * libghostty-vt is released separately from Ghostty, with its own version
 * numbers.
 *
 * Until 1.0, each minor release may change the API (the functions and
 * types in these headers) and the ABI (how compiled programs call the
 * library). A program built against 0.1 may not compile against 0.2, or
 * may not run with a 0.2 library installed. Patch releases, such as 0.1.1,
 * never break programs built against an earlier 0.1 release.
 *
 * From 1.0, only a new major version can break programs, and it comes with
 * a new shared library name such as `libghostty-vt.so.2`. Minor and patch
 * releases only add to the library.
 *
 * Every 0.x release uses the same shared library name, so the system
 * can't stop a program built against 0.1 from loading a 0.2 library. A
 * program can check this itself when it starts, by comparing the library's
 * version with the version of the headers it was compiled against:
 *
 * @snippet c-vt-build-info/src/main.c version-compatible
 *
 * See @ref version "Version" for the version macros and more examples.
 *
 * @section groups_sec API Reference
 *
 * The API is organized into the following groups:
 * - @ref terminal "Terminal" - Complete terminal emulator state and rendering
 * - @ref render "Render State" - Incremental render state updates for custom renderers
 * - @ref formatter "Formatter" - Format terminal content as plain text, VT sequences, or HTML
 * - @ref snapshot "Terminal Snapshot" - Encode and incrementally restore terminal state
 * - @ref search "Search" - Search terminal contents, including scrollback
 * - @ref osc "OSC Parser" - Parse OSC (Operating System Command) sequences
 * - @ref sgr "SGR Parser" - Parse SGR (Select Graphic Rendition) sequences
 * - @ref paste "Paste" - Paste into a terminal, validate and encode paste data
 * - @ref unicode "Unicode Utilities" - Codepoint properties for text layout
 * - @ref version "Version" - Check the version of the headers and the library
 * - @ref build_info "Build Info" - Query compile-time build configuration
 * - @ref allocator "Memory Management" - Memory management and custom allocators
 * - @ref io "Byte-stream I/O" - Reusable synchronous reader and writer callbacks
 * - @ref wasm "WebAssembly Utilities" - WebAssembly convenience functions
 *
 * Encoding related APIs:
 * - @ref focus "Focus Encoding" - Encode focus in/out events into terminal sequences
 * - @ref key "Key Encoding" - Encode key events into terminal sequences
 * - @ref mouse "Mouse Encoding" - Encode mouse events into terminal sequences
 *
 * @section keys_sec Reading and Writing Values by Key
 *
 * Much of the API reads and writes values through a small set of
 * functions that take a key. The key is an enum value that names the
 * value you want, and the value itself is passed through a `void *`
 * whose type is documented on each key. For example, this reads the
 * terminal's column count:
 *
 * @code{.c}
 * uint16_t cols = 0;
 * GhosttyResult result =
 *     ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
 * @endcode
 *
 * The same pattern is used by every function whose name ends in `_get`,
 * `_set`, `_setopt` or `_get_multi`, such as ghostty_terminal_get(),
 * ghostty_render_state_set() and ghostty_key_encoder_setopt().
 *
 * @subsection keys_compat_sec Newer Headers, Older Libraries
 *
 * New keys are added over time. A program built with a newer header can
 * end up running against an older copy of the library, for example when
 * the library is installed separately as a shared library. If you pass a
 * key that the loaded library does not know, the call returns
 * GHOSTTY_UNSUPPORTED and does not touch your output. This works the same
 * way in debug and release builds of the library.
 *
 * This lets you use a newer key when it is available and fall back when
 * it is not. In this example, imagine that
 * GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING was added in a later release
 * than the library your program loads:
 *
 * @code{.c}
 * bool blinking = false;
 * switch (ghostty_render_state_get(state,
 *                                  GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
 *                                  &blinking)) {
 * case GHOSTTY_SUCCESS:
 *   break;
 * case GHOSTTY_UNSUPPORTED:
 *   // This library predates the key. Use a sensible default instead.
 *   blinking = true;
 *   break;
 * default:
 *   // A real error, such as a NULL state. Handle it as usual.
 *   return;
 * }
 * @endcode
 *
 * GHOSTTY_UNSUPPORTED and GHOSTTY_INVALID_VALUE mean different things.
 * GHOSTTY_UNSUPPORTED means the library does not know the key at all.
 * GHOSTTY_INVALID_VALUE means the library knows the key, but something
 * you passed with it is wrong, such as a NULL pointer or an enum value
 * that is out of range.
 *
 * The same check applies to enum values you pass as plain arguments or
 * inside option values, such as a GhosttyKeyAction or the tag of a
 * GhosttyPoint. A value the library does not recognize returns
 * GHOSTTY_INVALID_VALUE and leaves the object unchanged.
 *
 * @subsection keys_multi_sec Reading Several Values at Once
 *
 * The `_get_multi` functions read several keys in one call, which helps
 * when each call is expensive, such as across FFI. They process keys in
 * order and stop at the first one that fails. Values for the keys before
 * it have already been written, and `out_written` receives the index of
 * the key that failed. That makes it easy to see exactly which key the
 * library rejected:
 *
 * @code{.c}
 * GhosttyTerminalData keys[] = {
 *     GHOSTTY_TERMINAL_DATA_COLS,
 *     GHOSTTY_TERMINAL_DATA_ROWS,
 * };
 * uint16_t cols = 0, rows = 0;
 * void *values[] = { &cols, &rows };
 * size_t written = 0;
 *
 * GhosttyResult result =
 *     ghostty_terminal_get_multi(terminal, 2, keys, values, &written);
 * if (result != GHOSTTY_SUCCESS) {
 *   // keys[written] failed. Every value before it is valid.
 * }
 * @endcode
 *
 * @section sized_sec Sized Structs
 *
 * Some structs begin with a `size_t size` field. These are called sized
 * structs. The `size` field records how large the struct was in the header
 * your program was compiled against. This lets later releases add fields
 * to the end of a struct without breaking programs built with older
 * headers.
 *
 * Initialize every sized struct with GHOSTTY_INIT_SIZED(). It sets `size`
 * for you and sets every other field to zero. Then fill in the fields you
 * need:
 *
 * @code{.c}
 * GhosttyTerminalSelectLineOptions opts =
 *     GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
 * opts.ref = ref;
 *
 * GhosttySelection selection;
 * GhosttyResult result =
 *     ghostty_terminal_select_line(terminal, &opts, &selection);
 * @endcode
 *
 * Language bindings that cannot use a C macro can call ghostty_sized_init()
 * instead.
 *
 * Zero is always the default value of a field. A field you leave at zero
 * behaves the same way the library did before that field existed. This is
 * why initializing with GHOSTTY_INIT_SIZED() matters: it keeps every field
 * you did not set, including fields added in later releases, at its
 * default.
 *
 * @subsection sized_compat_sec Newer Headers, Older Libraries
 *
 * Your program and the library it loads may come from different releases.
 * The `size` field lets the library handle either case:
 *
 * - When you pass a struct to the library, such as an options struct or a
 *   clipboard reply, and the library is newer than your header, the library
 *   reads the fields your struct does not have as zero.
 * - When the library is older than your header, it accepts your struct as
 *   long as every field it does not know about is still zero. If you set
 *   one of those fields, the call returns GHOSTTY_INVALID_VALUE instead of
 *   silently ignoring a setting it cannot honor.
 * - When the library fills a struct for you, such as
 *   GhosttyRenderStateCursor, it writes only the fields that fit within
 *   `size`. Fields the library does not know about keep the value you gave
 *   them, which is zero if you used GHOSTTY_INIT_SIZED().
 *
 * In every case, a `size` smaller than the struct has ever been returns
 * GHOSTTY_INVALID_VALUE. Clipboard replies are the one exception. The
 * reply function has no return value, so a reply with an invalid `size` is
 * treated as unsupported instead.
 *
 * Here is how a program can use a newer field when the library supports it
 * and fall back when it does not. Imagine that `semantic_prompt_boundary`
 * was added in a later release than the library your program loads:
 *
 * @code{.c}
 * GhosttyTerminalSelectLineOptions opts =
 *     GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
 * opts.ref = ref;
 * opts.semantic_prompt_boundary = true;
 *
 * GhosttySelection selection;
 * GhosttyResult result =
 *     ghostty_terminal_select_line(terminal, &opts, &selection);
 * if (result == GHOSTTY_INVALID_VALUE) {
 *   // This library may predate semantic_prompt_boundary. Try again
 *   // without it.
 *   opts.semantic_prompt_boundary = false;
 *   result = ghostty_terminal_select_line(terminal, &opts, &selection);
 * }
 * @endcode
 *
 * @section examples_sec Examples
 *
 * Complete working examples:
 * - @ref c-vt-build-info/src/main.c - Build info query example
 * - @ref c-vt/src/main.c - OSC parser example
 * - @ref c-vt-encode-key/src/main.c - Key encoding example
 * - @ref c-vt-encode-mouse/src/main.c - Mouse encoding example
 * - @ref c-vt-paste/src/main.c - Paste example
 * - @ref c-vt-sgr/src/main.c - SGR parser example
 * - @ref c-vt-formatter/src/main.c - Terminal formatter example
 * - @ref c-vt-grid-traverse/src/main.c - Grid traversal example using grid refs
 * - @ref c-vt-grid-ref-tracked/src/main.c - Tracked grid ref example
 * - @ref c-vt-compression/src/main.c - Idle scrollback compression example
 * - @ref c-vt-search/src/main.c - Terminal search example
 *
 */

/** @example c-vt-build-info/src/main.c
 * This example demonstrates how to query compile-time build configuration
 * such as SIMD support, Kitty graphics, and tmux control mode availability,
 * and how to check that the library matches the headers.
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
 * This example demonstrates how to paste into a terminal, including the
 * unsafe-paste confirmation flow and Kitty clipboard protocol paste events
 * (mode 5522), as well as the terminal-free paste safety and encoding
 * utilities.
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

/** @example c-vt-grid-ref-tracked/src/main.c
 * This example demonstrates how to track a grid ref as the terminal scrolls,
 * detect when it loses its value, and move it to a new point.
 */

/** @example c-vt-compression/src/main.c
 * This example demonstrates how to schedule incremental scrollback compression
 * after compression-relevant terminal activity becomes idle.
 */

/** @example c-vt-selection-gesture/src/main.c
 * This example demonstrates how to use synthetic selection gesture events to
 * derive drag and deep-press selection snapshots.
 */

/** @example c-vt-kitty-graphics/src/main.c
 * This example demonstrates how to use the system interface to install a
 * PNG decoder callback and send a Kitty Graphics Protocol image.
 */

/** @example c-vt-search/src/main.c
 * This example demonstrates how to search terminal contents for a
 * string, navigate between the matches like a find bar, and read the
 * viewport matches used to draw highlights.
 */

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <ghostty/vt/version.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/build_info.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/color_scheme.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/focus.h>
#include <ghostty/vt/formatter.h>
#include <ghostty/vt/render.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/grid_ref_tracked.h>
#include <ghostty/vt/io.h>
#include <ghostty/vt/osc.h>
#include <ghostty/vt/sgr.h>
#include <ghostty/vt/style.h>
#include <ghostty/vt/sys.h>
#include <ghostty/vt/key.h>
#include <ghostty/vt/kitty_graphics.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/mouse.h>
#include <ghostty/vt/paste.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/search.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/snapshot.h>
#include <ghostty/vt/unicode.h>
#include <ghostty/vt/wasm.h>

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_H */
