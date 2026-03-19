/**
 * @file modes.h
 *
 * Terminal mode utilities - pack and unpack ANSI/DEC mode identifiers.
 */

#ifndef GHOSTTY_VT_MODES_H
#define GHOSTTY_VT_MODES_H

/** @defgroup modes Mode Utilities
 *
 * Utilities for working with terminal modes. A mode is a compact
 * 16-bit representation of a terminal mode identifier that encodes both
 * the numeric mode value (up to 15 bits) and whether the mode is an ANSI
 * mode or a DEC private mode (?-prefixed).
 *
 * The packed layout (least-significant bit first) is:
 * - Bits 0–14: mode value (u15)
 * - Bit 15: ANSI flag (0 = DEC private mode, 1 = ANSI mode)
 *
 * ## Example
 *
 * @code{.c}
 * #include <stdio.h>
 * #include <ghostty/vt.h>
 *
 * int main() {
 *   // Create a mode for DEC mode 25 (cursor visible)
 *   GhosttyMode tag = ghostty_mode_new(25, false);
 *   printf("value=%u ansi=%d packed=0x%04x\n",
 *       ghostty_mode_value(tag),
 *       ghostty_mode_ansi(tag),
 *       tag);
 *
 *   // Create a mode for ANSI mode 4 (insert mode)
 *   GhosttyMode ansi_tag = ghostty_mode_new(4, true);
 *   printf("value=%u ansi=%d packed=0x%04x\n",
 *       ghostty_mode_value(ansi_tag),
 *       ghostty_mode_ansi(ansi_tag),
 *       ansi_tag);
 *
 *   return 0;
 * }
 * @endcode
 *
 * ## DECRPM Report Encoding
 *
 * Use ghostty_mode_report_encode() to encode a DECRPM response into a
 * caller-provided buffer:
 *
 * @code{.c}
 * #include <stdio.h>
 * #include <ghostty/vt.h>
 *
 * int main() {
 *   char buf[32];
 *   size_t written = 0;
 *
 *   // Encode a report that DEC mode 25 (cursor visible) is set
 *   GhosttyResult result = ghostty_mode_report_encode(
 *       GHOSTTY_MODE_CURSOR_VISIBLE,
 *       GHOSTTY_MODE_REPORT_SET,
 *       buf, sizeof(buf), &written);
 *
 *   if (result == GHOSTTY_SUCCESS) {
 *     printf("Encoded %zu bytes: ", written);
 *     fwrite(buf, 1, written, stdout);
 *     printf("\n");  // prints: ESC[?25;1$y
 *   }
 *
 *   return 0;
 * }
 * @endcode
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
#define GHOSTTY_MODE_KAM              (ghostty_mode_new(2, true))    /**< Keyboard action (disable keyboard) */
#define GHOSTTY_MODE_INSERT           (ghostty_mode_new(4, true))    /**< Insert mode */
#define GHOSTTY_MODE_SRM              (ghostty_mode_new(12, true))   /**< Send/receive mode */
#define GHOSTTY_MODE_LINEFEED         (ghostty_mode_new(20, true))   /**< Linefeed/new line mode */
/** @} */

/** @name DEC Private Modes
 * Modes for DEC private modes (?-prefixed).
 * @{
 */
#define GHOSTTY_MODE_DECCKM           (ghostty_mode_new(1, false))   /**< Cursor keys */
#define GHOSTTY_MODE_132_COLUMN       (ghostty_mode_new(3, false))   /**< 132/80 column mode */
#define GHOSTTY_MODE_SLOW_SCROLL      (ghostty_mode_new(4, false))   /**< Slow scroll */
#define GHOSTTY_MODE_REVERSE_COLORS   (ghostty_mode_new(5, false))   /**< Reverse video */
#define GHOSTTY_MODE_ORIGIN           (ghostty_mode_new(6, false))   /**< Origin mode */
#define GHOSTTY_MODE_WRAPAROUND       (ghostty_mode_new(7, false))   /**< Auto-wrap mode */
#define GHOSTTY_MODE_AUTOREPEAT       (ghostty_mode_new(8, false))   /**< Auto-repeat keys */
#define GHOSTTY_MODE_X10_MOUSE        (ghostty_mode_new(9, false))   /**< X10 mouse reporting */
#define GHOSTTY_MODE_CURSOR_BLINKING  (ghostty_mode_new(12, false))  /**< Cursor blink */
#define GHOSTTY_MODE_CURSOR_VISIBLE   (ghostty_mode_new(25, false))  /**< Cursor visible (DECTCEM) */
#define GHOSTTY_MODE_ENABLE_MODE_3    (ghostty_mode_new(40, false))  /**< Allow 132 column mode */
#define GHOSTTY_MODE_REVERSE_WRAP     (ghostty_mode_new(45, false))  /**< Reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN_LEGACY (ghostty_mode_new(47, false)) /**< Alternate screen (legacy) */
#define GHOSTTY_MODE_KEYPAD_KEYS      (ghostty_mode_new(66, false))  /**< Application keypad */
#define GHOSTTY_MODE_LEFT_RIGHT_MARGIN (ghostty_mode_new(69, false)) /**< Left/right margin mode */
#define GHOSTTY_MODE_NORMAL_MOUSE     (ghostty_mode_new(1000, false)) /**< Normal mouse tracking */
#define GHOSTTY_MODE_BUTTON_MOUSE     (ghostty_mode_new(1002, false)) /**< Button-event mouse tracking */
#define GHOSTTY_MODE_ANY_MOUSE        (ghostty_mode_new(1003, false)) /**< Any-event mouse tracking */
#define GHOSTTY_MODE_FOCUS_EVENT      (ghostty_mode_new(1004, false)) /**< Focus in/out events */
#define GHOSTTY_MODE_UTF8_MOUSE       (ghostty_mode_new(1005, false)) /**< UTF-8 mouse format */
#define GHOSTTY_MODE_SGR_MOUSE        (ghostty_mode_new(1006, false)) /**< SGR mouse format */
#define GHOSTTY_MODE_ALT_SCROLL       (ghostty_mode_new(1007, false)) /**< Alternate scroll mode */
#define GHOSTTY_MODE_URXVT_MOUSE      (ghostty_mode_new(1015, false)) /**< URxvt mouse format */
#define GHOSTTY_MODE_SGR_PIXELS_MOUSE (ghostty_mode_new(1016, false)) /**< SGR-Pixels mouse format */
#define GHOSTTY_MODE_NUMLOCK_KEYPAD   (ghostty_mode_new(1035, false)) /**< Ignore keypad with NumLock */
#define GHOSTTY_MODE_ALT_ESC_PREFIX   (ghostty_mode_new(1036, false)) /**< Alt key sends ESC prefix */
#define GHOSTTY_MODE_ALT_SENDS_ESC    (ghostty_mode_new(1039, false)) /**< Alt sends escape */
#define GHOSTTY_MODE_REVERSE_WRAP_EXT (ghostty_mode_new(1045, false)) /**< Extended reverse wrap */
#define GHOSTTY_MODE_ALT_SCREEN       (ghostty_mode_new(1047, false)) /**< Alternate screen */
#define GHOSTTY_MODE_SAVE_CURSOR      (ghostty_mode_new(1048, false)) /**< Save cursor (DECSC) */
#define GHOSTTY_MODE_ALT_SCREEN_SAVE  (ghostty_mode_new(1049, false)) /**< Alt screen + save cursor + clear */
#define GHOSTTY_MODE_BRACKETED_PASTE  (ghostty_mode_new(2004, false)) /**< Bracketed paste mode */
#define GHOSTTY_MODE_SYNC_OUTPUT      (ghostty_mode_new(2026, false)) /**< Synchronized output */
#define GHOSTTY_MODE_GRAPHEME_CLUSTER (ghostty_mode_new(2027, false)) /**< Grapheme cluster mode */
#define GHOSTTY_MODE_COLOR_SCHEME_REPORT (ghostty_mode_new(2031, false)) /**< Report color scheme */
#define GHOSTTY_MODE_IN_BAND_RESIZE   (ghostty_mode_new(2048, false)) /**< In-band size reports */
#define GHOSTTY_MODE_WIN32_INPUT      (ghostty_mode_new(9001, false)) /**< Win32 input mode */
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
typedef enum {
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
} GhosttyModeReportState;

/**
 * Encode a DECRPM (DEC Private Mode Report) response sequence.
 *
 * Writes a mode report escape sequence into the provided buffer.
 * The generated sequence has the form:
 * - DEC private mode: CSI ? Ps1 ; Ps2 $ y
 * - ANSI mode:        CSI Ps1 ; Ps2 $ y
 *
 * If the buffer is too small, the function returns GHOSTTY_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param mode The mode identifying the mode to report on
 * @param state The report state for this mode
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GhosttyResult ghostty_mode_report_encode(
    GhosttyMode mode,
    GhosttyModeReportState state,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_MODES_H */
