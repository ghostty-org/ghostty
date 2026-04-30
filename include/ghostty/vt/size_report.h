/**
 * @file size_report.h
 *
 * Size report encoding - encode terminal size reports into escape sequences.
 */

#ifndef GHOSTTY_VT_SIZE_REPORT_H
#define GHOSTTY_VT_SIZE_REPORT_H

/** @defgroup size_report Size Report Encoding
 *
 * Utilities for encoding terminal size reports into escape sequences,
 * supporting in-band size reports (mode 2048) and XTWINOPS responses
 * (CSI 14 t, CSI 16 t, CSI 18 t).
 *
 * ## Basic Usage
 *
 * Use ghostty_size_report_encode() to encode a size report into a
 * caller-provided buffer. If the buffer is too small, the function
 * returns GHOSTTY_OUT_OF_SPACE and sets the required size in the
 * output parameter.
 *
 * ## Example
 *
 * @snippet c-vt-size-report/src/main.c size-report-encode
 *
 * @{
 */

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Size report style.
 *
 * Determines the output format for the terminal size report.
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /** In-band size report (mode 2048): ESC [ 48 ; rows ; cols ; height ; width t */
    GHOSTTY_SIZE_REPORT_MODE_2048 = 0,
    /** XTWINOPS text area size in pixels: ESC [ 4 ; height ; width t */
    GHOSTTY_SIZE_REPORT_CSI_14_T = 1,
    /** XTWINOPS cell size in pixels: ESC [ 6 ; height ; width t */
    GHOSTTY_SIZE_REPORT_CSI_16_T = 2,
    /** XTWINOPS text area size in characters: ESC [ 8 ; rows ; cols t */
    GHOSTTY_SIZE_REPORT_CSI_18_T = 3,
    GHOSTTY_SIZE_REPORT_STYLE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySizeReportStyle;

/**
 * Terminal size information for encoding size reports.
 */
typedef struct {
    /** Terminal row count in cells. */
    uint16_t rows;
    /** Terminal column count in cells. */
    uint16_t columns;
    /** Width of a single terminal cell in pixels. */
    uint32_t cell_width;
    /** Height of a single terminal cell in pixels. */
    uint32_t cell_height;
} GhosttySizeReportSize;

/**
 * Encode a terminal size report into an escape sequence.
 *
 * Encodes a size report in the format specified by @p style into the
 * provided buffer.
 *
 * If the buffer is too small, the function returns GHOSTTY_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param style The size report format to encode
 * @param size Terminal size information
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GHOSTTY_API GhosttyResult ghostty_size_report_encode(
    GhosttySizeReportStyle style,
    GhosttySizeReportSize size,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_SIZE_REPORT_H */
