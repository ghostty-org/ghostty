/**
 * @file screen.h
 *
 * Terminal screen cell and row types.
 */

#ifndef GHOSTTY_VT_SCREEN_H
#define GHOSTTY_VT_SCREEN_H

#include <stdbool.h>
#include <stdint.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup screen Screen
 *
 * Terminal screen cell and row types.
 *
 * These types represent the contents of a terminal screen. A GhosttyCell
 * is a single grid cell and a GhosttyRow is a single row. Both are opaque
 * values whose fields are accessed via ghostty_cell_get() and
 * ghostty_row_get() respectively.
 *
 * @{
 */

/**
 * Opaque cell value.
 *
 * Represents a single terminal cell. The internal layout is opaque and
 * must be queried via ghostty_cell_get(). Obtain cell values from
 * terminal query APIs.
 *
 * @ingroup screen
 */
typedef uint64_t GhosttyCell;

/**
 * Opaque row value.
 *
 * Represents a single terminal row. The internal layout is opaque and
 * must be queried via ghostty_row_get(). Obtain row values from
 * terminal query APIs.
 *
 * @ingroup screen
 */
typedef uint64_t GhosttyRow;

/**
 * Cell content tag.
 *
 * Describes what kind of content a cell holds.
 *
 * @ingroup screen
 */
typedef enum {
  /** A single codepoint (may be zero for empty). */
  GHOSTTY_CELL_CONTENT_CODEPOINT = 0,

  /** A codepoint that is part of a multi-codepoint grapheme cluster. */
  GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME = 1,

  /** No text; background color from palette. */
  GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE = 2,

  /** No text; background color as RGB. */
  GHOSTTY_CELL_CONTENT_BG_COLOR_RGB = 3,
} GhosttyCellContentTag;

/**
 * Cell wide property.
 *
 * Describes the width behavior of a cell.
 *
 * @ingroup screen
 */
typedef enum {
  /** Not a wide character, cell width 1. */
  GHOSTTY_CELL_WIDE_NARROW = 0,

  /** Wide character, cell width 2. */
  GHOSTTY_CELL_WIDE_WIDE = 1,

  /** Spacer after wide character. Do not render. */
  GHOSTTY_CELL_WIDE_SPACER_TAIL = 2,

  /** Spacer at end of soft-wrapped line for a wide character. */
  GHOSTTY_CELL_WIDE_SPACER_HEAD = 3,
} GhosttyCellWide;

/**
 * Semantic content type of a cell.
 *
 * Set by semantic prompt sequences (OSC 133) to distinguish between
 * command output, user input, and shell prompt text.
 *
 * @ingroup screen
 */
typedef enum {
  /** Regular output content, such as command output. */
  GHOSTTY_CELL_SEMANTIC_OUTPUT = 0,

  /** Content that is part of user input. */
  GHOSTTY_CELL_SEMANTIC_INPUT = 1,

  /** Content that is part of a shell prompt. */
  GHOSTTY_CELL_SEMANTIC_PROMPT = 2,
} GhosttyCellSemanticContent;

/**
 * Cell data types.
 *
 * These values specify what type of data to extract from a cell
 * using `ghostty_cell_get`.
 *
 * @ingroup screen
 */
typedef enum {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_CELL_DATA_INVALID = 0,

  /**
   * The codepoint of the cell (0 if empty or bg-color-only).
   *
   * Output type: uint32_t *
   */
  GHOSTTY_CELL_DATA_CODEPOINT = 1,

  /**
   * The content tag describing what kind of content is in the cell.
   *
   * Output type: GhosttyCellContentTag *
   */
  GHOSTTY_CELL_DATA_CONTENT_TAG = 2,

  /**
   * The wide property of the cell.
   *
   * Output type: GhosttyCellWide *
   */
  GHOSTTY_CELL_DATA_WIDE = 3,

  /**
   * Whether the cell has text to render.
   *
   * Output type: bool *
   */
  GHOSTTY_CELL_DATA_HAS_TEXT = 4,

  /**
   * Whether the cell has non-default styling.
   *
   * Output type: bool *
   */
  GHOSTTY_CELL_DATA_HAS_STYLING = 5,

  /**
   * The style ID for the cell (for use with style lookups).
   *
   * Output type: uint16_t *
   */
  GHOSTTY_CELL_DATA_STYLE_ID = 6,

  /**
   * Whether the cell has a hyperlink.
   *
   * Output type: bool *
   */
  GHOSTTY_CELL_DATA_HAS_HYPERLINK = 7,

  /**
   * Whether the cell is protected.
   *
   * Output type: bool *
   */
  GHOSTTY_CELL_DATA_PROTECTED = 8,

  /**
   * The semantic content type of the cell (from OSC 133).
   *
   * Output type: GhosttyCellSemanticContent *
   */
  GHOSTTY_CELL_DATA_SEMANTIC_CONTENT = 9,

  /**
   * The palette index for the cell's background color.
   * Only valid when content_tag is GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE.
   *
   * Output type: GhosttyColorPaletteIndex *
   */
  GHOSTTY_CELL_DATA_COLOR_PALETTE = 10,

  /**
   * The RGB value for the cell's background color.
   * Only valid when content_tag is GHOSTTY_CELL_CONTENT_BG_COLOR_RGB.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_CELL_DATA_COLOR_RGB = 11,
} GhosttyCellData;

/**
 * Row semantic prompt state.
 *
 * Indicates whether any cells in a row are part of a shell prompt,
 * as reported by OSC 133 sequences.
 *
 * @ingroup screen
 */
typedef enum {
  /** No prompt cells in this row. */
  GHOSTTY_ROW_SEMANTIC_NONE = 0,

  /** Prompt cells exist and this is a primary prompt line. */
  GHOSTTY_ROW_SEMANTIC_PROMPT = 1,

  /** Prompt cells exist and this is a continuation line. */
  GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION = 2,
} GhosttyRowSemanticPrompt;

/**
 * Row data types.
 *
 * These values specify what type of data to extract from a row
 * using `ghostty_row_get`.
 *
 * @ingroup screen
 */
typedef enum {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_ROW_DATA_INVALID = 0,

  /**
   * Whether this row is soft-wrapped.
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_WRAP = 1,

  /**
   * Whether this row is a continuation of a soft-wrapped row.
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_WRAP_CONTINUATION = 2,

  /**
   * Whether any cells in this row have grapheme clusters.
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_GRAPHEME = 3,

  /**
   * Whether any cells in this row have styling (may have false positives).
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_STYLED = 4,

  /**
   * Whether any cells in this row have hyperlinks (may have false positives).
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_HYPERLINK = 5,

  /**
   * The semantic prompt state of this row.
   *
   * Output type: GhosttyRowSemanticPrompt *
   */
  GHOSTTY_ROW_DATA_SEMANTIC_PROMPT = 6,

  /**
   * Whether this row contains a Kitty virtual placeholder.
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_KITTY_VIRTUAL_PLACEHOLDER = 7,

  /**
   * Whether this row is dirty and requires a redraw.
   *
   * Output type: bool *
   */
  GHOSTTY_ROW_DATA_DIRTY = 8,
} GhosttyRowData;

/**
 * Get data from a cell.
 *
 * Extracts typed data from the given cell based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `GhosttyCellData` enum.
 *
 * @param cell The cell value
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the
 *         data type is invalid
 *
 * @ingroup screen
 */
GhosttyResult ghostty_cell_get(GhosttyCell cell,
                               GhosttyCellData data,
                               void *out);

/**
 * Get data from a row.
 *
 * Extracts typed data from the given row based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `GhosttyRowData` enum.
 *
 * @param row The row value
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the
 *         data type is invalid
 *
 * @ingroup screen
 */
GhosttyResult ghostty_row_get(GhosttyRow row,
                              GhosttyRowData data,
                              void *out);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SCREEN_H */
