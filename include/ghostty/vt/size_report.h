/**
 * @file size_report.h
 *
 * Size report encoding - encode terminal size reports into escape sequences.
 */

#ifndef GHOSTTY_VT_SIZE_REPORT_H
#define GHOSTTY_VT_SIZE_REPORT_H

/** @addtogroup size_report
 *
 * A size report tells a program how big your terminal is, in cells and pixels.
 *
 * These answer in-band size reports (mode 2048) and XTWINOPS queries
 * (CSI 14 t, CSI 16 t, CSI 18 t, CSI 19 t). A terminal answers those for you
 * through a GhosttyTerminalSizeFn, so you only need this without one. Fill in a
 * GhosttySizeReportSize and pass it to ghostty_size_report_encode().
 *
 * ## Example
 *
 * @snippet c-vt-size-report/src/main.c size-report-encode
 *
 * Full program: @ref c-vt-size-report/src/main.c
 *
 * See the @ref guide-effects "Effects guide" for the terminal's callback.
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
    /** XTWINOPS screen size in characters: ESC [ 9 ; rows ; cols t
     *
     *  The physical screen size is not known, so this reports the text
     *  area size in characters, the same as CSI 18 t. */
    GHOSTTY_SIZE_REPORT_CSI_19_T = 4,
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
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE and sets
 * @p out_written to the size needed. The buffer may then hold part of the
 * sequence, which you should discard. To get the size without encoding
 * anything, pass NULL for @p buf and 0 for @p buf_len.
 *
 * @param style The size report format to encode
 * @param size Terminal size information
 * @param buf Buffer to write the sequence into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small, or GHOSTTY_INVALID_VALUE if @p size is NULL
 */
GHOSTTY_API GhosttyResult ghostty_size_report_encode(
    GhosttySizeReportStyle style,
    const GhosttySizeReportSize* size,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_SIZE_REPORT_H */
