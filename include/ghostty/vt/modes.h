/**
 * @file modes.h
 *
 * Terminal mode utilities - pack and unpack ANSI/DEC mode identifiers.
 */

#ifndef GHOSTTY_VT_MODES_H
#define GHOSTTY_VT_MODES_H

/** @addtogroup modes
 *
 * A GhosttyMode is a terminal mode number packed into 16 bits, together with
 * whether it's an ANSI mode or a DEC private mode.
 *
 * The number alone isn't enough. ANSI mode 4 is insert mode, and DEC private
 * mode 4 is slow scroll. Use these to name a mode when you read or set one on a
 * terminal with GhosttyTerminalModeConfig, or to encode a DECRPM report with
 * ghostty_mode_report_encode(). You don't need a terminal to pack one.
 *
 * ## Example
 *
 * @snippet c-vt-modes/src/main.c modes-pack-unpack
 *
 * Full program: @ref c-vt-modes/src/main.c
 *
 * See the @ref guide-input "Input guide" for the modes that change what input
 * encodes to.
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @name ANSI Modes
 * Modes for standard ANSI modes.
 * @{
 */
#define GHOSTTY_MODE_DISABLE_KEYBOARD (ghostty_mode_new(2, true))    /**< Keyboard action (disable keyboard) */
#define GHOSTTY_MODE_INSERT           (ghostty_mode_new(4, true))    /**< Insert mode */
#define GHOSTTY_MODE_SEND_RECEIVE_MODE (ghostty_mode_new(12, true))   /**< Send/receive mode */
#define GHOSTTY_MODE_LINEFEED         (ghostty_mode_new(20, true))   /**< Linefeed/new line mode */
/** @} */

/** @name DEC Private Modes
 * Modes for DEC private modes (?-prefixed).
 * @{
 */
#define GHOSTTY_MODE_CURSOR_KEYS      (ghostty_mode_new(1, false))   /**< Cursor keys */
#define GHOSTTY_MODE_132_COLUMN       (ghostty_mode_new(3, false))   /**< 132/80 column mode */
#define GHOSTTY_MODE_SLOW_SCROLL      (ghostty_mode_new(4, false))   /**< Slow scroll */
#define GHOSTTY_MODE_REVERSE_COLORS   (ghostty_mode_new(5, false))   /**< Reverse video */
#define GHOSTTY_MODE_ORIGIN           (ghostty_mode_new(6, false))   /**< Origin mode */
#define GHOSTTY_MODE_WRAPAROUND       (ghostty_mode_new(7, false))   /**< Auto-wrap mode */
#define GHOSTTY_MODE_AUTOREPEAT       (ghostty_mode_new(8, false))   /**< Auto-repeat keys */
#define GHOSTTY_MODE_MOUSE_EVENT_X10  (ghostty_mode_new(9, false))   /**< X10 mouse reporting */
#define GHOSTTY_MODE_CURSOR_BLINKING  (ghostty_mode_new(12, false))  /**< Cursor blink */
#define GHOSTTY_MODE_CURSOR_VISIBLE   (ghostty_mode_new(25, false))  /**< Cursor visible (DECTCEM) */
#define GHOSTTY_MODE_ENABLE_MODE_3    (ghostty_mode_new(40, false))  /**< Allow 132 column mode */
#define GHOSTTY_MODE_REVERSE_WRAP     (ghostty_mode_new(45, false))  /**< Reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN_LEGACY (ghostty_mode_new(47, false)) /**< Alternate screen (legacy) */
#define GHOSTTY_MODE_KEYPAD_KEYS      (ghostty_mode_new(66, false))  /**< Application keypad */
#define GHOSTTY_MODE_BACKARROW_KEY_MODE (ghostty_mode_new(67, false))  /**< Backarrow key mode (DECBKM) */
#define GHOSTTY_MODE_ENABLE_LEFT_AND_RIGHT_MARGIN (ghostty_mode_new(69, false)) /**< Left/right margin mode */
#define GHOSTTY_MODE_MOUSE_EVENT_NORMAL (ghostty_mode_new(1000, false)) /**< Normal mouse tracking */
#define GHOSTTY_MODE_MOUSE_EVENT_BUTTON (ghostty_mode_new(1002, false)) /**< Button-event mouse tracking */
#define GHOSTTY_MODE_MOUSE_EVENT_ANY  (ghostty_mode_new(1003, false)) /**< Any-event mouse tracking */
#define GHOSTTY_MODE_FOCUS_EVENT      (ghostty_mode_new(1004, false)) /**< Focus in/out events */
#define GHOSTTY_MODE_MOUSE_FORMAT_UTF8 (ghostty_mode_new(1005, false)) /**< UTF-8 mouse format */
#define GHOSTTY_MODE_MOUSE_FORMAT_SGR (ghostty_mode_new(1006, false)) /**< SGR mouse format */
#define GHOSTTY_MODE_MOUSE_ALTERNATE_SCROLL (ghostty_mode_new(1007, false)) /**< Alternate scroll mode */
#define GHOSTTY_MODE_MOUSE_FORMAT_URXVT (ghostty_mode_new(1015, false)) /**< URxvt mouse format */
#define GHOSTTY_MODE_MOUSE_FORMAT_SGR_PIXELS (ghostty_mode_new(1016, false)) /**< SGR-Pixels mouse format */
#define GHOSTTY_MODE_IGNORE_KEYPAD_WITH_NUMLOCK (ghostty_mode_new(1035, false)) /**< Ignore keypad with NumLock */
#define GHOSTTY_MODE_ALT_ESC_PREFIX   (ghostty_mode_new(1036, false)) /**< Alt key sends ESC prefix */
#define GHOSTTY_MODE_ALT_SENDS_ESCAPE (ghostty_mode_new(1039, false)) /**< Alt sends escape */
#define GHOSTTY_MODE_REVERSE_WRAP_EXTENDED (ghostty_mode_new(1045, false)) /**< Extended reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN       (ghostty_mode_new(1047, false)) /**< Alternate screen */
#define GHOSTTY_MODE_SAVE_CURSOR      (ghostty_mode_new(1048, false)) /**< Save cursor (DECSC) */
#define GHOSTTY_MODE_ALT_SCREEN_SAVE_CURSOR_CLEAR_ENTER (ghostty_mode_new(1049, false)) /**< Alt screen + save cursor + clear */
#define GHOSTTY_MODE_BRACKETED_PASTE  (ghostty_mode_new(2004, false)) /**< Bracketed paste mode */
#define GHOSTTY_MODE_SYNCHRONIZED_OUTPUT (ghostty_mode_new(2026, false)) /**< Synchronized output */
#define GHOSTTY_MODE_GRAPHEME_CLUSTER (ghostty_mode_new(2027, false)) /**< Grapheme cluster mode */
#define GHOSTTY_MODE_REPORT_COLOR_SCHEME (ghostty_mode_new(2031, false)) /**< Report color scheme */
#define GHOSTTY_MODE_REPORT_VISIBILITY (ghostty_mode_new(2033, false)) /**< Report terminal visibility */
#define GHOSTTY_MODE_IN_BAND_SIZE_REPORTS (ghostty_mode_new(2048, false)) /**< In-band size reports */
#define GHOSTTY_MODE_KITTY_PASTE_EVENTS (ghostty_mode_new(5522, false)) /**< Kitty clipboard protocol paste events */
/** @} */

/**
 * A packed 16-bit terminal mode.
 *
 * Encodes a mode value (bits 0–14) and an ANSI flag (bit 15) into a
 * single 16-bit integer. Use the inline helper functions to construct
 * and inspect modes rather than manipulating bits directly.
 */
typedef uint16_t GhosttyMode;

/**
 * Create a mode from a mode value and ANSI flag.
 *
 * @param value The numeric mode value (0–32767)
 * @param ansi true for an ANSI mode, false for a DEC private mode
 * @return The packed mode
 *
 * @ingroup modes
 */
static inline GhosttyMode ghostty_mode_new(uint16_t value, bool ansi) {
    return (GhosttyMode)((value & 0x7FFF) | ((uint16_t)ansi << 15));
}

/**
 * Extract the numeric mode value from a mode.
 *
 * @param mode The mode
 * @return The mode value (0–32767)
 *
 * @ingroup modes
 */
static inline uint16_t ghostty_mode_value(GhosttyMode mode) {
    return mode & 0x7FFF;
}

/**
 * Check whether a mode represents an ANSI mode.
 *
 * @param mode The mode
 * @return true if this is an ANSI mode, false if it is a DEC private mode
 *
 * @ingroup modes
 */
static inline bool ghostty_mode_ansi(GhosttyMode mode) {
    return (mode >> 15) != 0;
}

/**
 * DECRPM report state values.
 *
 * These correspond to the Ps2 parameter in a DECRPM response
 * sequence (CSI ? Ps1 ; Ps2 $ y).
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /** Mode is not recognized */
    GHOSTTY_MODE_REPORT_NOT_RECOGNIZED = 0,
    /** Mode is set (enabled) */
    GHOSTTY_MODE_REPORT_SET = 1,
    /** Mode is reset (disabled) */
    GHOSTTY_MODE_REPORT_RESET = 2,
    /** Mode is permanently set */
    GHOSTTY_MODE_REPORT_PERMANENTLY_SET = 3,
    /** Mode is permanently reset */
    GHOSTTY_MODE_REPORT_PERMANENTLY_RESET = 4,
    GHOSTTY_MODE_REPORT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyModeReportState;

/**
 * Encode a DECRPM (DEC Private Mode Report) response sequence.
 *
 * Writes a mode report escape sequence into the provided buffer.
 * The generated sequence has the form:
 * - DEC private mode: CSI ? Ps1 ; Ps2 $ y
 * - ANSI mode:        CSI Ps1 ; Ps2 $ y
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE and sets
 * @p out_written to the size needed. The buffer may then hold part of the
 * sequence, which you should discard. To get the size without encoding
 * anything, pass NULL for @p buf and 0 for @p buf_len.
 *
 * @snippet c-vt-modes/src/main.c modes-decrpm
 *
 * Full program: @ref c-vt-modes/src/main.c
 *
 * @param mode The mode identifying the mode to report on
 * @param state The report state for this mode
 * @param buf Buffer to write the sequence into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small, or GHOSTTY_INVALID_VALUE if @p out_written is NULL
 */
GHOSTTY_API GhosttyResult ghostty_mode_report_encode(
    GhosttyMode mode,
    GhosttyModeReportState state,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_MODES_H */
