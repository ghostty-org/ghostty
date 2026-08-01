/**
 * @file unicode.h
 *
 * Unicode utilities - codepoint properties matching the terminal's
 * text layout semantics.
 */

#ifndef GHOSTTY_VT_UNICODE_H
#define GHOSTTY_VT_UNICODE_H

/** @defgroup unicode Unicode Utilities
 *
 * Unicode codepoint properties matching the terminal's text layout
 * semantics.
 *
 * ## Basic Usage
 *
 * Use ghostty_unicode_codepoint_width() to determine how many terminal
 * grid cells a codepoint occupies, using the exact same width table the
 * terminal itself uses when laying out printed text. Use
 * ghostty_unicode_grapheme_width() to segment and measure full grapheme
 * clusters with the same rules the terminal uses when mode 2027 is
 * enabled. These functions are useful for predicting column layout of
 * text that has not yet been written to the terminal, such as IME
 * preedit (composition) overlays.
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
 * Returns the terminal display width of a Unicode codepoint in
 * terminal grid cells: 0, 1, or 2.
 *
 * This is the same width table the terminal itself uses when laying
 * out printed text, so callers can predict column layout (e.g. IME
 * preedit overlays) that exactly matches what the terminal will do
 * when the text is actually written to it.
 *
 * Semantics:
 * - Returns 0 for zero-width codepoints: C0/C1 control characters,
 *   nonspacing and enclosing combining marks, default-ignorable
 *   codepoints (ZWJ, ZWNJ, variation selectors, etc.), and
 *   surrogate codepoints.
 * - Returns 2 for wide codepoints: East Asian Wide/Fullwidth
 *   (including emoji with default emoji presentation) and regional
 *   indicators. Width is clamped to 2 (e.g. the three-em dash).
 * - Returns 1 for everything else, including invalid codepoints
 *   beyond U+10FFFF (this function is total; it never fails).
 *
 * This operates on a single codepoint only and therefore cannot account
 * for grapheme-cluster-level width rules (VS16 emoji presentation,
 * combining sequences, etc.). For cluster-accurate widths, use
 * ghostty_unicode_grapheme_width(). Summing per-codepoint widths is only
 * correct when mode 2027 (grapheme clustering) is disabled.
 *
 * This function is pure, allocates nothing, and is thread-safe.
 *
 * @param cp The Unicode codepoint to measure
 * @return Display width in cells: 0, 1, or 2
 */
GHOSTTY_API uint8_t ghostty_unicode_codepoint_width(uint32_t cp);

/**
 * Measures the terminal display width of the first grapheme cluster in a
 * sequence of Unicode codepoints.
 *
 * This uses the exact same grapheme segmentation and cluster width rules
 * the terminal itself uses when printing text with grapheme clustering
 * enabled (mode 2027), so callers can predict column layout (e.g. IME
 * preedit overlays) that exactly matches what the terminal will do when
 * the text is actually written to it. Unlike
 * ghostty_unicode_codepoint_width(), this accounts for cluster-level
 * rules: emoji variation selectors, ZWJ sequences, combining marks, and
 * skin tone modifiers.
 *
 * Reads codepoints from cps until the terminal would consider the
 * grapheme cluster complete, stores the cluster's total width in cells
 * (0, 1, or 2) into width (which may be NULL if only segmentation is
 * desired), and returns the number of codepoints consumed. Returns 0 if
 * and only if len is 0; otherwise consumes at least one codepoint. Measure
 * a whole string by calling in a loop:
 *
 * @code
 * size_t total = 0;
 * for (size_t i = 0; i < len;) {
 *   uint8_t width;
 *   i += ghostty_unicode_grapheme_width(cps + i, len - i, &width);
 *   total += width;
 * }
 * @endcode
 *
 * This is not a streaming API. The provided sequence must contain a
 * complete first grapheme cluster, or the logical end of the string. If
 * input arrives in chunks, keep buffering while this function consumes all
 * available codepoints (return value == len) and the stream may still
 * continue; a later codepoint could still extend the cluster and change
 * its width.
 *
 * Width semantics, matching the terminal with mode 2027 enabled:
 * - The cluster starts at the width of its first codepoint, as returned by
 *   ghostty_unicode_codepoint_width().
 * - VS16 (U+FE0F) forces the cluster wide (2) and VS15 (U+FE0E) forces it
 *   narrow (1), but only when the immediately preceding codepoint in the
 *   cluster is a valid emoji variation sequence base (per Unicode
 *   emoji-variation-sequences.txt). Invalid variation selectors are
 *   ignored entirely.
 * - Any other continuation codepoint that contributes to grapheme width
 *   forces the cluster wide (2). Note this means cluster width is NOT the
 *   maximum of per-codepoint widths: some continuation marks have narrow
 *   codepoint width yet still widen the cluster.
 *
 * Mode dependence: this models mode 2027 (grapheme clustering) enabled,
 * which is Ghostty's recommended configuration. When mode 2027 is
 * disabled, clusters never combine and variation selectors never change
 * width; predict layout in that case by summing
 * ghostty_unicode_codepoint_width() over each codepoint instead.
 *
 * Edge cases:
 * - Codepoints beyond U+10FFFF consume one codepoint, have width 1, and
 *   are always cluster boundaries. This function is total; it never fails.
 * - Control characters (C0/C1, CR, LF) are never printed through the
 *   terminal's text path; passing them here returns an unspecified (but
 *   stable and bounded) result.
 * - A cluster whose first codepoint is zero-width (e.g. a lone combining
 *   mark) is malformed at a cell start; the terminal may attach it to
 *   earlier screen content. This function reports the fold result for the
 *   sequence in isolation (typically 0).
 *
 * This function is pure, allocates nothing, and is thread-safe.
 *
 * @param cps Pointer to codepoints (may be NULL only when len is 0)
 * @param len Number of codepoints available
 * @param width Out: cluster display width in cells (0-2); may be NULL
 * @return Number of codepoints in the first grapheme cluster
 */
GHOSTTY_API size_t ghostty_unicode_grapheme_width(const uint32_t *cps,
                                                  size_t len,
                                                  uint8_t *width);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_UNICODE_H */
