/**
 * @file encoder.h
 *
 * Mouse event encoding to terminal escape sequences.
 */

#ifndef GHOSTTY_VT_MOUSE_ENCODER_H
#define GHOSTTY_VT_MOUSE_ENCODER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/mouse/event.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

/**
 * Opaque handle to a mouse encoder instance.
 *
 * This handle represents a mouse encoder that converts normalized
 * mouse events into terminal escape sequences.
 *
 * @ingroup mouse
 */
typedef struct GhosttyMouseEncoderImpl *GhosttyMouseEncoder;

/**
 * Mouse tracking mode.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Mouse reporting disabled. */
  GHOSTTY_MOUSE_TRACKING_NONE = 0,

  /** X10 mouse mode. */
  GHOSTTY_MOUSE_TRACKING_X10 = 1,

  /** Normal mouse mode (button press/release only). */
  GHOSTTY_MOUSE_TRACKING_NORMAL = 2,

  /** Button-event tracking mode. */
  GHOSTTY_MOUSE_TRACKING_BUTTON = 3,

  /** Any-event tracking mode. */
  GHOSTTY_MOUSE_TRACKING_ANY = 4,
  GHOSTTY_MOUSE_TRACKING_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseTrackingMode;

/**
 * Mouse output format.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_MOUSE_FORMAT_X10 = 0,
  GHOSTTY_MOUSE_FORMAT_UTF8 = 1,
  GHOSTTY_MOUSE_FORMAT_SGR = 2,
  GHOSTTY_MOUSE_FORMAT_URXVT = 3,
  GHOSTTY_MOUSE_FORMAT_SGR_PIXELS = 4,
  GHOSTTY_MOUSE_FORMAT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseFormat;

/**
 * Mouse encoder size and geometry context.
 *
 * This describes the rendered terminal geometry used to convert
 * surface-space positions into encoded coordinates.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED(), then set
 * the fields you need. See @ref sized-structs.
 *
 * @ingroup mouse
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyMouseEncoderSize). */
  size_t size;

  /** Full screen width in pixels. */
  uint32_t screen_width;

  /** Full screen height in pixels. */
  uint32_t screen_height;

  /** Cell width in pixels. Must be non-zero. */
  uint32_t cell_width;

  /** Cell height in pixels. Must be non-zero. */
  uint32_t cell_height;

  /** Top padding in pixels. */
  uint32_t padding_top;

  /** Bottom padding in pixels. */
  uint32_t padding_bottom;

  /** Right padding in pixels. */
  uint32_t padding_right;

  /** Left padding in pixels. */
  uint32_t padding_left;
} GhosttyMouseEncoderSize;

/**
 * Mouse encoder option identifiers.
 *
 * These values are used with ghostty_mouse_encoder_set() to configure
 * the behavior of the mouse encoder.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real option. ghostty_mouse_encoder_set() returns
   * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real option.
   */
  GHOSTTY_MOUSE_ENCODER_OPT_INVALID = 0,

  /** Mouse tracking mode (value: GhosttyMouseTrackingMode,
   *  default: GHOSTTY_MOUSE_TRACKING_NONE). */
  GHOSTTY_MOUSE_ENCODER_OPT_EVENT = 1,

  /** Mouse output format (value: GhosttyMouseFormat,
   *  default: GHOSTTY_MOUSE_FORMAT_X10). */
  GHOSTTY_MOUSE_ENCODER_OPT_FORMAT = 2,

  /** Renderer size context (value: GhosttyMouseEncoderSize, default: a
   *  1x1 pixel screen with 1x1 pixel cells and no padding). */
  GHOSTTY_MOUSE_ENCODER_OPT_SIZE = 3,

  /** Whether any mouse button is currently pressed (value: bool,
   *  default: false). */
  GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED = 4,

  /** Whether to enable motion deduplication by last cell (value: bool,
   *  default: false). */
  GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL = 5,
  GHOSTTY_MOUSE_ENCODER_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseEncoderOption;

/**
 * Create a new mouse encoder instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param encoder Pointer to store the created encoder handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_new(const GhosttyAllocator *allocator,
                                        GhosttyMouseEncoder *encoder);

/**
 * Free a mouse encoder instance.
 *
 * @param encoder The encoder handle to free (may be NULL)
 *
 * @ingroup mouse
 */
GHOSTTY_API void ghostty_mouse_encoder_free(GhosttyMouseEncoder encoder);

/**
 * Set an option on the mouse encoder.
 *
 * Passing NULL for `value` resets the option to its default, the same
 * value a new encoder starts with. Each option's default is listed on
 * GhosttyMouseEncoderOption.
 *
 * @code{.c}
 * GhosttyMouseFormat format = GHOSTTY_MOUSE_FORMAT_SGR;
 * GhosttyResult result = ghostty_mouse_encoder_set(
 *     encoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT, &format);
 * @endcode
 *
 * @param encoder The encoder handle, must not be NULL
 * @param option The option to set
 * @param value Pointer to option value (type depends on option), or NULL to
 *              reset the option to its default
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `encoder` is
 *         NULL or the value is not valid (an unknown tracking mode or
 *         format, or a size that is too small or has a zero cell
 *         dimension), or GHOSTTY_UNSUPPORTED if `option` is not known to
 *         this version of the library
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_set(GhosttyMouseEncoder encoder,
                                  GhosttyMouseEncoderOption option,
                                  const void *value);

/**
 * Set encoder options from a terminal's current state.
 *
 * This sets tracking mode and output format from terminal state.
 * It also clears the last-cell state, as ghostty_mouse_encoder_reset() does,
 * so the next motion event isn't dropped as a repeat of the last cell.
 * It does not modify size or any-button state.
 *
 * @param encoder The encoder handle
 * @param terminal The terminal handle
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `encoder`
 *         or `terminal` is NULL. On error the encoder is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_set_from_terminal(GhosttyMouseEncoder encoder,
                                                GhosttyTerminal terminal);

/**
 * Reset internal encoder state.
 *
 * This clears motion deduplication state (last tracked cell).
 *
 * @param encoder The encoder handle
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `encoder`
 *         is NULL.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_reset(GhosttyMouseEncoder encoder);

/**
 * Encode a mouse event into a terminal escape sequence.
 *
 * Not all mouse events produce output. In such cases this returns
 * GHOSTTY_SUCCESS with @p out_written set to 0.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE and sets
 * @p out_written to the size needed. The buffer may then hold part of the
 * sequence, which you should discard. To get the size without encoding
 * anything, pass NULL for @p buf and 0 for @p buf_len. An event with no
 * output still returns GHOSTTY_SUCCESS in that case, because it needs no
 * space.
 *
 * A 128-byte buffer is enough for typical events:
 *
 * @code{.c}
 * uint8_t buf[128];
 * size_t written = 0;
 * if (ghostty_mouse_encoder_encode(encoder, event, buf, sizeof(buf),
 *                                  &written) == GHOSTTY_SUCCESS &&
 *     written > 0) {
 *   write(pty_fd, buf, written);
 * }
 * @endcode
 *
 * @param encoder The encoder handle, must not be NULL
 * @param event The mouse event to encode, must not be NULL
 * @param buf Buffer to write the sequence into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE. Must not be NULL.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if buffer is too small,
 *         or another error code
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_encoder_encode(GhosttyMouseEncoder encoder,
                                           GhosttyMouseEvent event,
                                           uint8_t *buf,
                                           size_t buf_len,
                                           size_t *out_written);

#endif /* GHOSTTY_VT_MOUSE_ENCODER_H */
