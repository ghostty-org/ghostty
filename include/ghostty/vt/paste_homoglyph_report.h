/**
 * @file paste_homoglyph_report.h
 *
 * Layout for mixed-script URL homoglyph data passed to embedders via
 * `ghostty_runtime_confirm_read_clipboard_cb`. Shared with `paste.h` for the VT
 * library; this header has no VT paste API and does not include `types.h`.
 */

#ifndef GHOSTTY_VT_PASTE_HOMOGLYPH_REPORT_H
#define GHOSTTY_VT_PASTE_HOMOGLYPH_REPORT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** UTF-8 byte range in paste data (`end` exclusive). */
typedef struct {
    size_t start;
    size_t end;
} ghostty_paste_homoglyph_span_t;

/** Max spans stored in `ghostty_paste_homoglyph_report_t::spans`. */
#define GHOSTTY_PASTE_HOMOGLYPH_REPORT_MAX_SPANS 128

typedef struct {
    size_t url_start;
    size_t url_end;
    size_t span_total;
    size_t span_written;
    ghostty_paste_homoglyph_span_t spans[GHOSTTY_PASTE_HOMOGLYPH_REPORT_MAX_SPANS];
} ghostty_paste_homoglyph_report_t;

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_PASTE_HOMOGLYPH_REPORT_H */
