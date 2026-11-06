/**
 * @file vt.h
 *
 * libghostty-vt - Virtual terminal emulator library
 * 
 * This library provides functionality for parsing and handling terminal
 * escape sequences as well as maintaining terminal state such as styles,
 * cursor position, screen, scrollback, and more.
 *
 * The C ABI is stable from 1.0. See @ref stability for details.
 */

/** @example c-vt-hello/src/main.c
 * The smallest complete program: create a terminal, write text with a color
 * sequence in it, and print the screen. This is the program on the main page.
 */

/** @example c-vt-stream/src/main.c
 * Feed VT sequences into a terminal, read the final screen back as plain text,
 * and draw it with a render state. Start here for read-only tools like replay
 * viewers and CI log viewers.
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
