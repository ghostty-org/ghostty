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
 * `_set` or `_get_multi`, such as ghostty_terminal_get(),
 * ghostty_render_state_set() and ghostty_key_encoder_set().
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
 * @section buffers_sec Output Buffers
 *
 * Functions that write bytes for you take a buffer, its length and an
 * `out_written` pointer. Pass NULL with a length of 0 to learn the size
 * needed. When there is nothing to write, the call returns
 * GHOSTTY_SUCCESS and sets `out_written` to 0, even for a size query.
 * When the buffer is too small, the call returns GHOSTTY_OUT_OF_SPACE and
 * sets `out_written` to the size needed. The contents of the buffer are
 * then unspecified unless the function says otherwise, so discard them
 * and retry with a larger buffer.
 *
 * @section threads_sec Threads
 *
 * The library creates no threads, and every callback runs on the thread
 * whose call triggered it. Calls on one handle, and on any handle
 * borrowed from it, must not run at the same time unless a function's
 * documentation says otherwise. Handles that share nothing can be used on
 * different threads.
 *
 * @section features_sec Optional Features
 *
 * Some parts of libghostty-vt are optional. A program that only draws a
 * terminal doesn't need search or snapshots, for example, so the library
 * can be built without them to make it smaller. Features are chosen when
 * the library is built, with the `-Dvt-features` build option.
 *
 * Every function in these headers exists in every build, whichever
 * features it includes. A program links and loads the same way against
 * any build. When it calls a function whose feature was left out, the
 * function does nothing and returns GHOSTTY_UNSUPPORTED.
 *
 * | Feature              | Functions |
 * | -------------------- | --------- |
 * | `%snapshot`           | `ghostty_snapshot_*` |
 * | `%formatter`          | `ghostty_formatter_*` |
 * | `%selection`          | `ghostty_terminal_select_*`, `ghostty_terminal_selection_*`, `ghostty_selection_gesture_*` |
 * | `%search`             | `ghostty_search_*` |
 * | `%render_state`       | `ghostty_render_state_*` |
 * | `%input_encode`       | `ghostty_key_event_*`, `ghostty_key_encoder_*`, `ghostty_mouse_event_*`, `ghostty_mouse_encoder_*`, ghostty_focus_encode(), `ghostty_paste_*`, ghostty_terminal_paste() |
 * | `%color`              | `ghostty_color_*` |
 * | `%grid_introspection` | `ghostty_grid_ref_*`, `ghostty_tracked_grid_ref_*`, `ghostty_cell_get*`, `ghostty_row_get*`, ghostty_terminal_grid_ref_track() |
 * | `%glyph_protocol`     | None. It lets applications register custom glyphs with Ghostty's glyph protocol. |
 * | `%kitty_graphics`     | `ghostty_kitty_graphics_*`, and the Kitty options and data of ghostty_terminal_set() and ghostty_terminal_get() |
 *
 * A few functions depend on two features:
 *
 * - ghostty_terminal_grid_ref() and ghostty_terminal_point_from_grid_ref()
 *   need either `%grid_introspection` or `%selection`.
 * - ghostty_tracked_grid_ref_snapshot() needs both `%grid_introspection`
 *   and `%snapshot`.
 *
 * Kitty graphics need a clock, so builds for targets without an operating
 * system, such as wasm32-freestanding, never include `%kitty_graphics`.
 *
 * @subsection features_check_sec Checking for a Feature
 *
 * To find out up front, for example to hide a menu item, ask
 * ghostty_build_info() with the feature's key. Each feature has a
 * `GHOSTTY_BUILD_INFO_FEATURE_*` key, except Kitty graphics, which uses
 * GHOSTTY_BUILD_INFO_KITTY_GRAPHICS:
 *
 * @code{.c}
 * bool has_search = false;
 * ghostty_build_info(GHOSTTY_BUILD_INFO_FEATURE_SEARCH, &has_search);
 * if (!has_search) {
 *   // Hide the find bar.
 * }
 * @endcode
 *
 * You can also just call the function and check its result. A function
 * that creates a handle sets the handle to NULL, so cleanup code that
 * frees it still works:
 *
 * @code{.c}
 * GhosttySearch search = NULL;
 * GhosttyResult result = ghostty_search_new(NULL, &search, terminal);
 * if (result == GHOSTTY_UNSUPPORTED) {
 *   // This library was built without search. search is NULL.
 * }
 * @endcode
 *
 * @subsection features_values_sec Functions Without a Result
 *
 * A function that doesn't return a GhosttyResult can't report
 * GHOSTTY_UNSUPPORTED. When its feature is left out, it returns a fixed
 * value instead:
 *
 * - Functions that free a handle do nothing.
 * - Functions that return `bool`, such as iterator `_next` functions,
 *   return false.
 * - Functions that return a number, an enum or a struct return zero or a
 *   zeroed struct. ghostty_key_event_get_utf8() returns an empty string.
 * - ghostty_color_rgb_get(), ghostty_color_palette_default() and
 *   ghostty_color_palette_generate() fill their outputs with zeros.
 * - ghostty_color_x11_name_count() returns 0, so the array returned by
 *   ghostty_color_x11_names() is empty.
 * - ghostty_kitty_graphics_image() returns NULL.
 *
 * In practice these values rarely matter. Most of these functions take a
 * handle that could only come from a `_new` function of the same
 * feature, and that function returned GHOSTTY_UNSUPPORTED.
 *
 * @section examples_sec Examples
 *
 * Complete working examples, each in its own directory under `example/`.
 *
 * @subsection examples_start_sec Start Here
 *
 * - @ref c-vt-stream/src/main.c - Feed VT sequences into a terminal and read
 *   the final screen back as plain text. Use this for read-only tools like
 *   replay viewers and CI log viewers.
 * - @ref c-vt-formatter/src/main.c - Write text and cursor movement into a
 *   terminal, then stream the screen to stdout as plain text through a
 *   GhosttyWriter.
 *
 * @subsection examples_terminal_sec Terminal
 *
 * - @ref c-vt-colors/src/main.c - Set the default colors and palette, then
 *   read effective and default values as an OSC 10 override layers on top.
 * - @ref c-vt-effects/src/main.c - Register callbacks for what a program asks
 *   of the terminal: pty replies, the bell, title changes, OSC 52 clipboard
 *   reads and writes, and unknown sequences. You need these as soon as a real
 *   program runs in the terminal.
 * - @ref c-vt-compression/src/main.c - Compress scrollback while the terminal
 *   is idle.
 * - @ref c-vt-snapshot/src/main.c - Encode a terminal's full state and
 *   restore it three ways: in one shot, with scrollback kept compressed, and
 *   page by page. The page by page path gives you a terminal you can draw
 *   before the old history arrives.
 * - @ref c-vt-grid-traverse/src/main.c - Walk the whole grid cell by cell
 *   with grid refs, reading codepoints, row wrap state and styles.
 * - @ref c-vt-grid-ref-tracked/src/main.c - Keep a reference to one cell
 *   while the terminal scrolls under it.
 * - @ref c-vt-render/src/main.c - Draw a frame from a render state: check
 *   what's dirty, walk the rows and cells, and read styles, colors, the
 *   cursor and the selection. Use this when you render the terminal yourself.
 * - @ref c-vt-search/src/main.c - Search the terminal for a string, step
 *   through the matches like a find bar, and read the viewport matches to
 *   draw highlights.
 * - @ref c-vt-selection/src/main.c - Select a word, a line, a command's
 *   output or the whole screen, then format each selection as text. The line
 *   and output selections use OSC 133 prompt markers.
 * - @ref c-vt-selection-gesture/src/main.c - Feed press, drag, release and
 *   deep press events to ghostty_selection_gesture_event() and get back
 *   selections you can show or copy.
 * - @ref c-vt-kitty-graphics/src/main.c - Accept images sent with the Kitty
 *   Graphics Protocol and find out what to draw. It installs a stand-in PNG
 *   decoder, reads placements from the render state, and plays an animation.
 *
 * @subsection examples_input_sec Input
 *
 * - @ref c-vt-encode-key/src/main.c - Encode Ctrl+C as an escape sequence
 *   with the Kitty keyboard protocol.
 * - @ref c-vt-encode-mouse/src/main.c - Encode a left button press at a pixel
 *   position as an SGR mouse sequence.
 * - @ref c-vt-encode-focus/src/main.c - Encode a focus gained event as CSI I,
 *   for programs that turn on focus reporting (mode 1004).
 * - @ref c-vt-paste/src/main.c - Paste into a terminal with
 *   ghostty_terminal_paste(): plain text, bracketed paste (mode 2004), the
 *   unsafe-paste confirmation, and Kitty paste events (mode 5522). It also
 *   checks paste safety and encodes paste data without a terminal.
 *
 * @subsection examples_blocks_sec Building Blocks
 *
 * - @ref c-vt-osc/src/main.c - Parse an OSC sequence and read the window
 *   title out of it.
 * - @ref c-vt-sgr/src/main.c - Parse SGR sequences into text attributes,
 *   including a real one from Kakoune with a curly underline and RGB colors.
 * - @ref c-vt-modes/src/main.c - Pack DEC and ANSI mode numbers into a
 *   GhosttyMode and encode a DECRPM report.
 * - @ref c-vt-color-scheme/src/main.c - Encode a color scheme report, the
 *   reply to a CSI ? 996 n query.
 * - @ref c-vt-size-report/src/main.c - Encode an in-band size report (mode
 *   2048) from the grid and cell size.
 * - @ref c-vt-allocator/src/main.c - Run a terminal on your own allocator,
 *   built on `malloc` and `free`. It counts live bytes to check that the
 *   terminal frees everything.
 * - @ref c-vt-build-info/src/main.c - Query build options like SIMD and Kitty
 *   graphics, then check that the loaded library matches the headers you
 *   compiled against.
 *
 * @subsection examples_build_sec Build Systems
 *
 * - @ref c-vt-cmake/src/main.c - Build and link libghostty-vt from a CMake
 *   project with `FetchContent`.
 * - @ref c-vt-cmake-static/src/main.c - Build and statically link
 *   libghostty-vt from a CMake project with `FetchContent`.
 * - @ref c-vt-cmake-cross/src/main.c - Cross-compile and statically link
 *   libghostty-vt from CMake with `ghostty_vt_add_target()`. The default
 *   target is a different OS from your host.
 * - @ref c-vt-static/src/main.c - Statically link libghostty-vt from a Zig
 *   build with the `ghostty-vt-static` artifact. The program is the same as
 *   c-vt-osc.
 *
 */

/** @example c-vt-stream/src/main.c
 * Feed VT sequences into a terminal and read the final screen back as plain
 * text. Use this for read-only tools like replay viewers and CI log viewers.
 */

/** @example c-vt-formatter/src/main.c
 * Write text and cursor movement into a terminal, then stream the screen to
 * stdout as plain text through a GhosttyWriter.
 */

/** @example c-vt-colors/src/main.c
 * Set the default colors and palette, then read effective and default values
 * as an OSC 10 override layers on top.
 */

/** @example c-vt-effects/src/main.c
 * Register callbacks for what a program asks of the terminal: pty replies,
 * the bell, title changes, OSC 52 clipboard reads and writes, and unknown
 * sequences. You need these as soon as a real program runs in the terminal.
 */

/** @example c-vt-compression/src/main.c
 * Compress scrollback while the terminal is idle.
 */

/** @example c-vt-snapshot/src/main.c
 * Encode a terminal's full state and restore it three ways: in one shot, with
 * scrollback kept compressed, and page by page. The page by page path gives
 * you a terminal you can draw before the old history arrives.
 */

/** @example c-vt-grid-traverse/src/main.c
 * Walk the whole grid cell by cell with grid refs, reading codepoints, row
 * wrap state and styles.
 */

/** @example c-vt-grid-ref-tracked/src/main.c
 * Keep a reference to one cell while the terminal scrolls under it.
 */

/** @example c-vt-render/src/main.c
 * Draw a frame from a render state: check what's dirty, walk the rows and
 * cells, and read styles, colors, the cursor and the selection. Use this when
 * you render the terminal yourself.
 */

/** @example c-vt-search/src/main.c
 * Search the terminal for a string, step through the matches like a find bar,
 * and read the viewport matches to draw highlights.
 */

/** @example c-vt-selection/src/main.c
 * Select a word, a line, a command's output or the whole screen, then format
 * each selection as text. The line and output selections use OSC 133 prompt
 * markers.
 */

/** @example c-vt-selection-gesture/src/main.c
 * Feed press, drag, release and deep press events to
 * ghostty_selection_gesture_event() and get back selections you can show or
 * copy.
 */

/** @example c-vt-kitty-graphics/src/main.c
 * Accept images sent with the Kitty Graphics Protocol and find out what to
 * draw. It installs a stand-in PNG decoder, reads placements from the render
 * state, and plays an animation.
 */

/** @example c-vt-encode-key/src/main.c
 * Encode Ctrl+C as an escape sequence with the Kitty keyboard protocol.
 */

/** @example c-vt-encode-mouse/src/main.c
 * Encode a left button press at a pixel position as an SGR mouse sequence.
 */

/** @example c-vt-encode-focus/src/main.c
 * Encode a focus gained event as CSI I, for programs that turn on focus
 * reporting (mode 1004).
 */

/** @example c-vt-paste/src/main.c
 * Paste into a terminal with ghostty_terminal_paste(): plain text, bracketed
 * paste (mode 2004), the unsafe-paste confirmation, and Kitty paste events
 * (mode 5522). It also checks paste safety and encodes paste data without a
 * terminal.
 */

/** @example c-vt-osc/src/main.c
 * Parse an OSC sequence and read the window title out of it.
 */

/** @example c-vt-sgr/src/main.c
 * Parse SGR sequences into text attributes, including a real one from Kakoune
 * with a curly underline and RGB colors.
 */

/** @example c-vt-modes/src/main.c
 * Pack DEC and ANSI mode numbers into a GhosttyMode and encode a DECRPM
 * report.
 */

/** @example c-vt-color-scheme/src/main.c
 * Encode a color scheme report, the reply to a CSI ? 996 n query.
 */

/** @example c-vt-size-report/src/main.c
 * Encode an in-band size report (mode 2048) from the grid and cell size.
 */

/** @example c-vt-allocator/src/main.c
 * Run a terminal on your own allocator, built on `malloc` and `free`. It
 * counts live bytes to check that the terminal frees everything.
 */

/** @example c-vt-build-info/src/main.c
 * Query build options like SIMD and Kitty graphics, then check that the
 * loaded library matches the headers you compiled against.
 */

/** @example c-vt-cmake/src/main.c
 * Build and link libghostty-vt from a CMake project with `FetchContent`.
 */

/** @example c-vt-cmake-static/src/main.c
 * Build and statically link libghostty-vt from a CMake project with
 * `FetchContent`.
 */

/** @example c-vt-cmake-cross/src/main.c
 * Cross-compile and statically link libghostty-vt from CMake with
 * `ghostty_vt_add_target()`. The default target is a different OS from your
 * host.
 */

/** @example c-vt-static/src/main.c
 * Statically link libghostty-vt from a Zig build with the `ghostty-vt-static`
 * artifact. The program is the same as c-vt-osc.
 */
#ifndef GHOSTTY_VT_H#ifndef GHOSTTY_VT_H
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
