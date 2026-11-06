/**
 * @file color_scheme.h
 *
 * Color scheme report encoding - encode terminal color scheme reports into
 * escape sequences.
 */

#ifndef GHOSTTY_VT_COLOR_SCHEME_H
#define GHOSTTY_VT_COLOR_SCHEME_H

/** @addtogroup color_scheme
 *
 * A color scheme report tells a program whether your terminal is light or dark.
 *
 * You need this when a program sets mode 2031 and expects to hear when the
 * scheme changes. Encode the report and write it to the pty yourself. You don't
 * need it to answer a `CSI ? 996 n` query. A terminal does that for you through
 * a GhosttyTerminalColorSchemeFn.
 *
 * ## Example
 *
 * @snippet c-vt-color-scheme/src/main.c color-scheme-report-encode
 *
 * Full program: @ref c-vt-color-scheme/src/main.c
 *
 * See @ref guide-colors-scheme for when to send one.
 *
 * @{
 */

#include <stddef.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/device.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Encode a color scheme report into an escape sequence.
 *
 * Encodes a color scheme report into the provided buffer. Dark color schemes
 * emit ESC [ ? 997 ; 1 n, and light color schemes emit ESC [ ? 997 ; 2 n.
 * The encoded bytes are identical to the terminal's internal CSI ? 996 n
 * query response.
 *
 * Hosts should gate unsolicited sends on GHOSTTY_MODE_REPORT_COLOR_SCHEME
 * (mode 2031) being set. Read it with ghostty_terminal_get() and
 * GHOSTTY_TERMINAL_DATA_MODE.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE and sets
 * @p out_written to the size needed. The buffer may then hold part of the
 * sequence, which you should discard. To get the size without encoding
 * anything, pass NULL for @p buf and 0 for @p buf_len.
 *
 * @param scheme The color scheme to encode
 * @param buf Buffer to write the sequence into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GHOSTTY_API GhosttyResult ghostty_color_scheme_report_encode(
    GhosttyColorScheme scheme,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_COLOR_SCHEME_H */
