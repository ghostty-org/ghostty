/**
 * @file mouse.h
 *
 * Mouse support module - encode mouse events and provide pointer shapes.
 */

#ifndef GHOSTTY_VT_MOUSE_H
#define GHOSTTY_VT_MOUSE_H

/** @defgroup mouse Mouse Support
 *
 * Utilities for encoding mouse events into terminal escape sequences,
 * supporting X10, UTF-8, SGR, URxvt, and SGR-Pixels mouse protocols.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with ghostty_mouse_encoder_new().
 * 2. Configure encoder options with ghostty_mouse_encoder_setopt() or
 *    ghostty_mouse_encoder_setopt_from_terminal().
 * 3. For each mouse event:
 *    - Create a mouse event with ghostty_mouse_event_new().
 *    - Set event properties (action, button, modifiers, position).
 *    - Encode with ghostty_mouse_encoder_encode().
 *    - Free the event with ghostty_mouse_event_free() or reuse it.
 * 4. Free the encoder with ghostty_mouse_encoder_free() when done.
 *
 * For a complete working example, see example/c-vt-encode-mouse in the
 * repository.
 *
 * ## Example
 *
 * @snippet c-vt-encode-mouse/src/main.c mouse-encode
 *
 * ## Example: Encoding with Terminal State
 *
 * When you have a GhosttyTerminal, you can sync its tracking mode and
 * output format into the encoder automatically:
 *
 * @code{.c}
 * // Create a terminal and feed it some VT data that enables mouse tracking
 * GhosttyTerminal terminal;
 * ghostty_terminal_new(NULL, &terminal, 80, 24);
 *
 * // Application might write data that enables mouse reporting, etc.
 * ghostty_terminal_vt_write(terminal, vt_data, vt_len);
 *
 * // Create an encoder and sync its options from the terminal
 * GhosttyMouseEncoder encoder;
 * ghostty_mouse_encoder_new(NULL, &encoder);
 * ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal);
 *
 * // Encode a mouse event using the terminal-derived options
 * char buf[128];
 * size_t written = 0;
 * ghostty_mouse_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *
 * ghostty_mouse_encoder_free(encoder);
 * ghostty_terminal_free(terminal);
 * @endcode
 *
 * @{
 */

#include <ghostty/vt/types.h>
#include <ghostty/vt/mouse/event.h>
#include <ghostty/vt/mouse/encoder.h>

/**
 * Mouse pointer shapes based on the W3C cursor names.
 *
 * Hosts map these values to their native pointer shapes; not every platform
 * supports every shape. These are pointer shapes, not terminal text cursors.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_MOUSE_SHAPE_DEFAULT = 0,
  GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU = 1,
  GHOSTTY_MOUSE_SHAPE_HELP = 2,
  GHOSTTY_MOUSE_SHAPE_POINTER = 3,
  GHOSTTY_MOUSE_SHAPE_PROGRESS = 4,
  GHOSTTY_MOUSE_SHAPE_WAIT = 5,
  GHOSTTY_MOUSE_SHAPE_CELL = 6,
  GHOSTTY_MOUSE_SHAPE_CROSSHAIR = 7,
  GHOSTTY_MOUSE_SHAPE_TEXT = 8,
  GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT = 9,
  GHOSTTY_MOUSE_SHAPE_ALIAS = 10,
  GHOSTTY_MOUSE_SHAPE_COPY = 11,
  GHOSTTY_MOUSE_SHAPE_MOVE = 12,
  GHOSTTY_MOUSE_SHAPE_NO_DROP = 13,
  GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED = 14,
  GHOSTTY_MOUSE_SHAPE_GRAB = 15,
  GHOSTTY_MOUSE_SHAPE_GRABBING = 16,
  GHOSTTY_MOUSE_SHAPE_ALL_SCROLL = 17,
  GHOSTTY_MOUSE_SHAPE_COL_RESIZE = 18,
  GHOSTTY_MOUSE_SHAPE_ROW_RESIZE = 19,
  GHOSTTY_MOUSE_SHAPE_N_RESIZE = 20,
  GHOSTTY_MOUSE_SHAPE_E_RESIZE = 21,
  GHOSTTY_MOUSE_SHAPE_S_RESIZE = 22,
  GHOSTTY_MOUSE_SHAPE_W_RESIZE = 23,
  GHOSTTY_MOUSE_SHAPE_NE_RESIZE = 24,
  GHOSTTY_MOUSE_SHAPE_NW_RESIZE = 25,
  GHOSTTY_MOUSE_SHAPE_SE_RESIZE = 26,
  GHOSTTY_MOUSE_SHAPE_SW_RESIZE = 27,
  GHOSTTY_MOUSE_SHAPE_EW_RESIZE = 28,
  GHOSTTY_MOUSE_SHAPE_NS_RESIZE = 29,
  GHOSTTY_MOUSE_SHAPE_NESW_RESIZE = 30,
  GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE = 31,
  GHOSTTY_MOUSE_SHAPE_ZOOM_IN = 32,
  GHOSTTY_MOUSE_SHAPE_ZOOM_OUT = 33,
  GHOSTTY_MOUSE_SHAPE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseShape;

/** @} */

#endif /* GHOSTTY_VT_MOUSE_H */
