/**
 * @file color_scheme.h
 *
 * Color scheme report encoding - encode terminal color scheme reports into
 * escape sequences.
 */

#ifndef GHOSTTY_VT_COLOR_SCHEME_H
#define GHOSTTY_VT_COLOR_SCHEME_H

/** @defgroup color_scheme Color Scheme Report Encoding
 *
 * Utilities for encoding color scheme reports into terminal escape
 * sequences for color scheme reporting mode (mode 2031).
 *
 * ## Basic Usage
 *
 * Use ghostty_color_scheme_report_encode() to encode a color scheme report
 * into a caller-provided buffer. If the buffer is too small, the function
 * returns GHOSTTY_OUT_OF_SPACE and sets the required size in the output
 * parameter.
 *
 * ## Example
 *
 * @snippet c-vt-color-scheme/src/main.c color-scheme-report-encode
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
 * Hosts should gate unsolicited sends on GHOSTTY_MODE_COLOR_SCHEME_REPORT
 * (mode 2031) being set, which can be checked via the mode getters.
 *
 * If the buffer is too small, the function returns GHOSTTY_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param scheme The color scheme to encode
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GHOSTTY_API GhosttyResult ghostty_color_scheme_report_encode(
    GhosttyColorScheme scheme,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_COLOR_SCHEME_H */
