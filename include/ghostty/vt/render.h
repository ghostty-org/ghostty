/**
 * @file render.h
 *
 * Render state for creating high performance renderers.
 */

#ifndef GHOSTTY_VT_RENDER_H
#define GHOSTTY_VT_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @addtogroup render
 *
 * A render state is a copy of everything you need to draw one frame: the
 * rows, the cells, the cursor, and the colors. It only needs the terminal
 * during an update, so everything after that can happen while the terminal
 * keeps working.
 *
 * Use this when you draw the terminal yourself.
 *
 * ## Example
 *
 * @snippet c-vt-render/src/main.c render-state-update
 *
 * Full program: @ref c-vt-render/src/main.c
 *
 * See @ref guide-rendering for how to draw a frame, track what changed,
 * respect render holds, and use overscan and row identity. See
 * @ref guide-images for drawing images.
 *
 * @{
 */

/**
 * Dirty state of a render state after update.
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Not dirty at all; rendering can be skipped. */
  GHOSTTY_RENDER_STATE_DIRTY_FALSE = 0,

  /** Some rows changed; renderer can redraw incrementally. */
  GHOSTTY_RENDER_STATE_DIRTY_PARTIAL = 1,

  /** Global state changed; renderer should redraw everything. */
  GHOSTTY_RENDER_STATE_DIRTY_FULL = 2,
  GHOSTTY_RENDER_STATE_DIRTY_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateDirty;

/**
 * A number of rows above and below the viewport.
 *
 * This is used both to request overscan with
 * GHOSTTY_RENDER_STATE_OPT_OVERSCAN and to report how many rows an
 * update captured with GHOSTTY_RENDER_STATE_DATA_OVERSCAN. See
 * @ref guide-rendering-overscan for how the extra rows are used.
 *
 * @ingroup render
 */
typedef struct {
  /** Rows above the top of the viewport. */
  uint16_t above;

  /** Rows below the bottom of the viewport. */
  uint16_t below;
} GhosttyRenderStateOverscan;

/**
 * The identity of a row across render state updates.
 *
 * Treat this value as opaque. Two ids are the same when both words are
 * equal. No other comparison or interpretation is meaningful, and the
 * contents may change between library versions. A zero-initialized id is
 * never valid, so it can be used to mean "no row".
 *
 * @code{.c}
 * bool same = a.bits[0] == b.bits[0] && a.bits[1] == b.bits[1];
 * @endcode
 *
 * See @ref guide-rendering-row-identity for how to use ids.
 *
 * @ingroup render
 */
typedef struct {
  /** Opaque id data. Compare both words for equality. */
  uint64_t bits[2];
} GhosttyRenderStateRowId;

/**
 * Queryable data kinds for ghostty_render_state_get().
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_RENDER_STATE_DATA_INVALID = 0,

  /** Viewport width in cells (uint16_t). */
  GHOSTTY_RENDER_STATE_DATA_COLS = 1,

  /** Viewport height in cells (uint16_t). This does not include
   *  overscan rows. */
  GHOSTTY_RENDER_STATE_DATA_ROWS = 2,

  /** Current dirty state (GhosttyRenderStateDirty). */
  GHOSTTY_RENDER_STATE_DATA_DIRTY = 3,

  /** Populate a pre-allocated GhosttyRenderStateRowIterator with row data
   *  from the render state (GhosttyRenderStateRowIterator). Row data is
   *  only valid as long as the underlying render state is not updated.
   *  It is unsafe to use row data after updating the render state.
   *
   *  The iterator visits every row the last update captured, from top
   *  to bottom. This is exactly the viewport unless overscan was
   *  requested with GHOSTTY_RENDER_STATE_OPT_OVERSCAN.
   *  */
  GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR = 4,

  /** Default/current background color (GhosttyColorRgb). */
  GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND = 5,

  /** Default/current foreground color (GhosttyColorRgb). */
  GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND = 6,

  /** Cursor color when explicitly set by terminal state (GhosttyColorRgb).
   *  Returns GHOSTTY_NO_VALUE if no explicit cursor color is set. */
  GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR = 7,

  /** Whether an explicit cursor color is set (bool). */
  GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR_HAS_VALUE = 8,

  /** The active 256-color palette (GhosttyColorRgb[256]). */
  GHOSTTY_RENDER_STATE_DATA_COLOR_PALETTE = 9,

  /** The visual style of the cursor (GhosttyCursorStyle). */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE = 10,

  /** Whether the cursor is visible based on terminal modes (bool). */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE = 11,

  /** Whether the cursor should blink based on terminal modes (bool). */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING = 12,

  /** Whether the cursor is at a password input field (bool). */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_PASSWORD_INPUT = 13,

  /** Whether the cursor is visible within the viewport (bool).
   *  If false, querying the cursor viewport position values returns
   *  GHOSTTY_NO_VALUE. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE = 14,

  /** Cursor viewport x position in cells (uint16_t).
   *  Returns GHOSTTY_NO_VALUE when CURSOR_VIEWPORT_HAS_VALUE is false. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X = 15,

  /** Cursor viewport y position in cells (uint16_t).
   *  Returns GHOSTTY_NO_VALUE when CURSOR_VIEWPORT_HAS_VALUE is false. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y = 16,

  /** Whether the cursor is on the tail of a wide character (bool).
   *  Returns GHOSTTY_NO_VALUE when CURSOR_VIEWPORT_HAS_VALUE is false. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL = 17,

  /** All cursor state in one sized struct (GhosttyRenderStateCursor).
   *  Initialize the output with GHOSTTY_INIT_SIZED before querying. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR = 18,

  /** All render-state colors in one sized struct (GhosttyRenderStateColors).
   *  Initialize the output with GHOSTTY_INIT_SIZED before querying. */
  GHOSTTY_RENDER_STATE_DATA_COLORS = 19,

  /** How many overscan rows the last update captured on each side
   *  (GhosttyRenderStateOverscan). This is never more than the request.
   *  It is less when those rows don't exist: `above` is smaller near the
   *  top of the scrollback, and `below` is zero while the viewport is
   *  scrolled to the bottom. */
  GHOSTTY_RENDER_STATE_DATA_OVERSCAN = 20,

  /** The overscan request most recently set with
   *  GHOSTTY_RENDER_STATE_OPT_OVERSCAN (GhosttyRenderStateOverscan).
   *  The next update uses this request. Both sides are zero if it was
   *  never set. */
  GHOSTTY_RENDER_STATE_DATA_OVERSCAN_REQUEST = 21,

  /** Populate an existing GhosttyRenderStateImageIterator with the image
   *  placements found by the last update. See @ref guide-images-drawing. */
  GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR = 22,

  /** A value (uint64_t) that changes whenever an update changes the
   *  placements that GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR returns. If
   *  it matches the value from the last time you read the iterator, the
   *  placements are the same and you don't need to read them again. See
   *  @ref guide-images-changes for an example and for exactly when the
   *  value changes.
   *
   *  The value belongs to the whole list. To know when the pixels of a
   *  single image changed, use
   *  GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION.
   *
   *  Only compare the value for equality. It is always 0 when Kitty
   *  graphics are disabled. */
  GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION = 23,
  GHOSTTY_RENDER_STATE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateData;

/**
 * Settable options for ghostty_render_state_set().
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real option. ghostty_render_state_set() returns
   * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real option.
   */
  GHOSTTY_RENDER_STATE_OPT_INVALID = 0,

  /** Set dirty state (GhosttyRenderStateDirty). Each update sets this
   *  value itself, so there is no default to restore and a NULL value
   *  returns GHOSTTY_INVALID_VALUE. */
  GHOSTTY_RENDER_STATE_OPT_DIRTY = 1,

  /** Request overscan rows above and below the viewport
   *  (GhosttyRenderStateOverscan). The request takes effect on the next
   *  update and stays in effect until it is changed. Both sides are zero
   *  by default, which captures only the viewport. A NULL value restores
   *  that default. The rows of the last update can still be read after
   *  changing the request. Expect a full redraw on the update after a
   *  change. See @ref guide-rendering-overscan. */
  GHOSTTY_RENDER_STATE_OPT_OVERSCAN = 2,
  GHOSTTY_RENDER_STATE_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateOption;

/**
 * The image protocols that a terminal supports.
 *
 * The render state uses this to say which protocol each image placement
 * came from (see GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL). Use it to
 * decide where to read the image's pixels. Unlike the other image types
 * here, the name has no RenderState prefix, because the protocol isn't
 * specific to the render state.
 *
 * New protocols may be added in later versions. Skip placements with a
 * protocol you don't support.
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The Kitty graphics protocol. Read the image with
   *  ghostty_kitty_graphics_image(). */
  GHOSTTY_IMAGE_PROTOCOL_KITTY = 0,
  GHOSTTY_IMAGE_PROTOCOL_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyImageProtocol;

/**
 * The kinds of Kitty graphics placements in a render state's image list.
 *
 * Read with GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND. Most renderers
 * can draw every kind the same way. The kind is useful when you need to
 * tell them apart, for example for debugging.
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Part of a virtual placement: one run of neighboring placeholder
   *  cells in a single row. It is always one row tall. */
  GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_VIRTUAL = 0,

  /** A placement that a program positioned relative to another
   *  placement, its parent. Kitty graphics lets a program attach one
   *  image to another so that they move together. The parent is either
   *  a virtual or a fixed placement, possibly through a chain of other
   *  relative placements.
   *
   *  With a virtual parent, the position depends on the placeholder
   *  cells. It is measured from the top-left corner of the parent's
   *  cells on screen. That is the leftmost column and the topmost row
   *  that any of its cells use, which matches Kitty. If none of those
   *  cells are in the captured rows (the viewport plus any overscan), the
   *  relative placement is not included.
   *
   *  With a fixed parent, the position is measured from the parent's
   *  cell. The relative placement is included at its full size when any
   *  part of it is in the captured rows, even if the parent isn't, so it
   *  may need to be clipped when drawn.
   *
   *  See @ref guide-images-relative. */
  GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_RELATIVE = 1,

  /** A placement at a cell on the screen. It scrolls with the text,
   *  like a line of output would. Its z-index is the one the program
   *  chose, so it can be in any layer.
   *
   *  It is included at its full size when any part of it is in the
   *  captured rows, so it may need to be clipped when drawn. See
   *  @ref guide-images-clipping. */
  GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_FIXED = 2,
  GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateKittyPlacementKind;

/**
 * Data you can read about the current placement of an image iterator
 * with ghostty_render_state_image_get().
 *
 * The type in parentheses is the type that the `out` pointer must point
 * to. All pixel values use the cell size set with ghostty_terminal_resize().
 *
 * Some values only apply to one protocol, and have the protocol in their
 * name. For example, GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND only
 * applies to Kitty graphics placements. Reading one of these for a
 * placement from another protocol returns GHOSTTY_NO_VALUE.
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid value. Querying it returns GHOSTTY_INVALID_VALUE. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_INVALID = 0,

  /** The protocol the image came from (GhosttyImageProtocol). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL = 1,

  /** The ID of the image to draw (uint32_t). IDs are only unique within
   *  one protocol, so look the image up in the storage of its protocol.
   *  For Kitty graphics, use ghostty_kitty_graphics_image(). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID = 2,

  /** The generation of the image's contents (uint64_t). It changes
   *  whenever the image's pixels change, including when an animation
   *  moves to a new frame. Use it as part of your texture cache key,
   *  with the protocol and image ID: if it matches the texture you have,
   *  you don't need to read the pixels again. For Kitty graphics, this
   *  is the same value as GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION.
   *
   *  To know when the list of placements as a whole changed, use
   *  GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION = 3,

  /** The layer to draw the image in (GhosttyImageLayer). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER = 4,

  /** The z-index (int32_t), which orders images within a layer. Images
   *  with a lower z-index are drawn first. The value comes from the
   *  image's protocol. For Kitty graphics, it is the z-index the program
   *  asked for, and virtual placements are always -1. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_Z = 5,

  /** The column of the top-left cell (int32_t), where 0 is the leftmost
   *  column of the viewport. Fixed and relative placements are reported
   *  at their full size, so they can start to the left of the viewport,
   *  which gives a negative value. Virtual placements never do. See
   *  @ref guide-images-clipping. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL = 6,

  /** The row of the top-left cell (int32_t), where 0 is the top row of
   *  the viewport. A placement in an overscan row above the viewport has
   *  a negative row, the same as GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y.
   *  Fixed and relative placements are reported at their full size, so
   *  they can also start above the first overscan row. Virtual
   *  placements are always inside the captured rows. See
   *  @ref guide-images-clipping. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW = 7,

  /** The number of columns of cells the placement covers (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_COLS = 8,

  /** The number of rows of cells the placement covers (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_GRID_ROWS = 9,

  /** How far the image starts from the left edge of the top-left cell,
   *  in pixels (uint32_t). For a virtual placement, an image that is
   *  narrower than its cells is centered, so this can be larger than a
   *  cell is wide. For fixed and relative placements, this is the offset
   *  the program asked for, limited to less than one cell. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X = 10,

  /** How far the image starts from the top edge of the top-left cell,
   *  in pixels (uint32_t). For a virtual placement, an image that is
   *  shorter than its cells is centered, so this can be larger than a
   *  cell is tall. For fixed and relative placements, this is the offset
   *  the program asked for, limited to less than one cell. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y = 11,

  /** The width to draw the image at, in pixels (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH = 12,

  /** The height to draw the image at, in pixels (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT = 13,

  /** The left edge of the part of the image to draw, in image pixels
   *  (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X = 14,

  /** The top edge of the part of the image to draw, in image pixels
   *  (uint32_t). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y = 15,

  /** The width of the part of the image to draw, in image pixels
   *  (uint32_t). Scale it to PIXEL_WIDTH when drawing. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH = 16,

  /** The height of the part of the image to draw, in image pixels
   *  (uint32_t). Scale it to PIXEL_HEIGHT when drawing. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT = 17,

  /** Kitty graphics only: the placement ID (uint32_t), or 0 if there
   *  isn't one.
   *
   *  For a virtual placement, this is the placement ID that the
   *  placeholder cells ask for. Cells that don't ask for one show the
   *  image's virtual placement, whichever it is, and report 0. For a
   *  fixed or relative placement, this is the ID the program gave it, or
   *  0 if it didn't give one. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_PLACEMENT_ID = 18,

  /** Kitty graphics only: the kind of placement
   *  (GhosttyRenderStateKittyPlacementKind). */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_KITTY_KIND = 19,
  GHOSTTY_RENDER_STATE_IMAGE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateImageData;

/**
 * Queryable data kinds for ghostty_render_state_row_get().
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_RENDER_STATE_ROW_DATA_INVALID = 0,

  /** Whether the current row is dirty (bool). */
  GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY = 1,

  /** The raw row value (GhosttyRow). */
  GHOSTTY_RENDER_STATE_ROW_DATA_RAW = 2,

  /** Populate a pre-allocated GhosttyRenderStateRowCells with cell data for
   *  the current row (GhosttyRenderStateRowCells). Cell data is only 
   *  valid as long as the underlying render state is not updated. 
   *  It is unsafe to use cell data after updating the render state. */
  GHOSTTY_RENDER_STATE_ROW_DATA_CELLS = 3,

  /** Row-local selected cell range (GhosttyRenderStateRowSelection). */
  GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION = 4,

  /** A borrowed view of the raw cell values for the current row
   *  (GhosttyCellsView). One value per column, identical to querying
   *  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW for each cell. The view
   *  is only valid as long as the underlying render state is not
   *  updated; it is unsafe to use after updating the render state.
   *
   *  This is the bulk alternative to iterating cells one at a time.
   *  It lets callers with expensive call boundaries (e.g. WebAssembly
   *  embedders) read an entire row with a single call.
   *
   *  Bit positions aren't protected by ABI, so callers should parse them
   *  out of the manifest from `ghostty_type_json`. Callers with access
   *  to the C header or without high FFI costs should use `ghostty_cell_get`.
   */
  GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW = 5,

  /** The row's position relative to the top of the viewport (int32_t).
   *  Viewport rows are 0 through rows - 1. Overscan rows above the
   *  viewport are negative, and overscan rows below it start at rows.
   *  Without overscan, this equals the y reported by
   *  ghostty_render_state_row_iterator_next_dirty(). */
  GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y = 6,

  /** The row's identity across updates (GhosttyRenderStateRowId). This
   *  works with or without overscan. See
   *  @ref guide-rendering-row-identity. */
  GHOSTTY_RENDER_STATE_ROW_DATA_ID = 7,
  GHOSTTY_RENDER_STATE_ROW_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateRowData;

/**
 * Settable options for ghostty_render_state_row_set().
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real option. ghostty_render_state_row_set() returns
   * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real option.
   */
  GHOSTTY_RENDER_STATE_ROW_OPT_INVALID = 0,

  /** Set dirty state for the current row (bool). Each update sets this
   *  value itself, so there is no default to restore and a NULL value
   *  returns GHOSTTY_INVALID_VALUE. */
  GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY = 1,
  GHOSTTY_RENDER_STATE_ROW_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateRowOption;

/**
 * Row-local selection range.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED() before
 * querying GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION. See @ref sized-structs.
 *
 * Querying GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION returns GHOSTTY_NO_VALUE
 * if the current row does not intersect the current selection.
 *
 * @ingroup render
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyRenderStateRowSelection). */
  size_t size;

  /** Start column of the row-local selection range, inclusive. */
  uint16_t start_x;

  /** End column of the row-local selection range, inclusive. */
  uint16_t end_x;
} GhosttyRenderStateRowSelection;

/**
 * Render-state cursor information.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED() before
 * querying GHOSTTY_RENDER_STATE_DATA_CURSOR. See @ref sized-structs.
 *
 * When viewport_has_value is false, viewport_x, viewport_y, and wide_tail
 * contain undefined data and must not be read.
 *
 * @ingroup render
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyRenderStateCursor). */
  size_t size;

  /** Whether the cursor is visible within the viewport. */
  bool viewport_has_value;

  /** Cursor viewport x position in cells. */
  uint16_t viewport_x;

  /** Cursor viewport y position in cells. */
  uint16_t viewport_y;

  /** Whether the cursor is on the tail of a wide character. */
  bool wide_tail;

  /** Whether the cursor is visible based on terminal modes. */
  bool visible;

  /** Whether the cursor should blink based on terminal modes. */
  bool blinking;

  /** Whether the cursor is at a password input field. */
  bool password_input;

  /** The visual style of the cursor. */
  GhosttyCursorStyle visual_style;
} GhosttyRenderStateCursor;

/**
 * Render-state color information.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED() before
 * querying GHOSTTY_RENDER_STATE_DATA_COLORS. See @ref sized-structs.
 *
 * Example:
 * @code
 * GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
 * GhosttyResult result = ghostty_render_state_get(
 *     state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
 * @endcode
 *
 * @ingroup render
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyRenderStateColors). */
  size_t size;

  /** The default/current background color for the render state. */
  GhosttyColorRgb background;

  /** The default/current foreground color for the render state. */
  GhosttyColorRgb foreground;

  /** The cursor color when explicitly set by terminal state. */
  GhosttyColorRgb cursor;

  /** 
   * True when cursor contains a valid explicit cursor color value. 
   * If this is false, the cursor color should be ignored; it will 
   * contain undefined data.
   * */
  bool cursor_has_value;

  /** The active 256-color palette for this render state. */
  GhosttyColorRgb palette[256];
} GhosttyRenderStateColors;

/** @name Lifecycle
 * @{
 */

/**
 * Create a new render state instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state Pointer to store the created render state handle (NULL returns
 *              GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 * failure
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_new(const GhosttyAllocator* allocator,
                                       GhosttyRenderState* state);

/**
 * Free a render state instance.
 *
 * Releases all resources associated with the render state. After this call,
 * the render state handle becomes invalid.
 *
 * @param state The render state handle to free (may be NULL)
 *
 * @ingroup render
 */
GHOSTTY_API void ghostty_render_state_free(GhosttyRenderState state);

/** @} */

/** @name Updating
 * @{
 */

/**
 * Update a render state instance from a terminal.
 *
 * This consumes terminal/screen dirty state in the same way as the internal
 * render state update path.
 *
 * This is a convenience function that performs a full update in one call,
 * equivalent to ghostty_render_state_begin_update immediately followed by
 * ghostty_render_state_end_update. Callers that hold a lock over the
 * terminal state should prefer calling the two phases directly so that the
 * lock is only held for the begin phase.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal The terminal handle to read from (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 * `terminal` is NULL, GHOSTTY_OUT_OF_MEMORY if updating the state requires
 * allocation and that allocation fails
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_update(GhosttyRenderState state,
                                          GhosttyTerminal terminal);

/**
 * Begin an update of a render state instance from a terminal.
 *
 * Every begin must be completed with a ghostty_render_state_end_update call
 * before the render state is read.
 *
 * This two-phase structure exists for callers that synchronize access to the
 * terminal state (e.g. with a lock shared with an IO thread): only this
 * function requires terminal access, so a caller can hold its lock for this
 * call only and then call ghostty_render_state_end_update after releasing
 * it. The end phase exclusively reads and writes memory owned by the render
 * state, so it is safe to call while the terminal is being modified.
 *
 * Work that doesn't require terminal access may be deferred to the end phase
 * to keep this call (and therefore lock hold time) as short as possible.
 * You must treat the render state as incomplete until
 * ghostty_render_state_end_update is called.
 *
 * This consumes terminal/screen dirty state in the same way as the internal
 * render state update path.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal The terminal handle to read from (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 * `terminal` is NULL, GHOSTTY_OUT_OF_MEMORY if updating the state requires
 * allocation and that allocation fails
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_begin_update(GhosttyRenderState state,
                                                GhosttyTerminal terminal);

/**
 * Complete a prior ghostty_render_state_begin_update call by performing any
 * deferred work.
 *
 * This only reads and writes memory owned by the render state, so it is safe
 * to call while the terminal is being modified (no terminal synchronization
 * is required). Calling this without a prior begin is a safe no-op.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 * NULL
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_end_update(GhosttyRenderState state);

/**
 * Mark all dirty render-state data as consumed.
 *
 * This sets the global dirty state to GHOSTTY_RENDER_STATE_DIRTY_FALSE and
 * clears every per-row dirty flag. It is idempotent and does not modify cell
 * contents or dirty state owned by the terminal. Call this only after a
 * complete frame has been rendered successfully; partial consumers should
 * use ghostty_render_state_set() and ghostty_render_state_row_set() instead.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_clean(GhosttyRenderState state);

/** @} */

/** @name Reading State
 * @{
 */

/**
 * Get a value from a render state.
 *
 * The `out` pointer must point to a value of the type corresponding to the
 * requested data kind (see GhosttyRenderStateData).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if `data` has no
 *         value right now, GHOSTTY_INVALID_VALUE if `state` or `out` is NULL
 *         or a sized output struct is smaller than its base layout, or
 *         GHOSTTY_UNSUPPORTED if `data` is not known to this version of the
 *         library
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_get(GhosttyRenderState state,
                                        GhosttyRenderStateData data,
                                        void* out);

/**
 * Get multiple data fields from a render state in a single call.
 *
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_render_state_get() once per key, so use
 * whichever reads better.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_get_multi(
    GhosttyRenderState state,
    size_t count,
    const GhosttyRenderStateData* keys,
    void** values,
    size_t* out_written);

/**
 * Set an option on a render state.
 *
 * The `value` pointer must point to a value of the type corresponding to the
 * requested option kind (see GhosttyRenderStateOption).
 *
 * Passing NULL for `value` restores the option's default. Options that
 * have no default, such as GHOSTTY_RENDER_STATE_OPT_DIRTY, return
 * GHOSTTY_INVALID_VALUE for NULL instead.
 *
 * @code{.c}
 * GhosttyRenderStateOverscan overscan = { .above = 4, .below = 4 };
 * ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN,
 *                          &overscan);
 *
 * // Later, go back to capturing only the viewport.
 * ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, NULL);
 * @endcode
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param[in] value Pointer to the value to set, or NULL to restore the
 *            option's default
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL, `value` is out of range, or `value` is NULL for an option
 *         with no default, or GHOSTTY_UNSUPPORTED if `option` is not known
 *         to this version of the library
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_set(GhosttyRenderState state,
                                       GhosttyRenderStateOption option,
                                       const void* value);

/** @} */

/** @name Rows
 * @{
 */

/**
 * Create a new row iterator instance.
 *
 * All fields except the allocator are left undefined until populated
 * via ghostty_render_state_get() with
 * GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, GHOSTTY_INVALID_VALUE if @p out_iterator is NULL
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderStateRowIterator* out_iterator);

/**
 * Free a render-state row iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup render
 */
GHOSTTY_API void ghostty_render_state_row_iterator_free(GhosttyRenderStateRowIterator iterator);

/**
 * Move a render-state row iterator to the next row.
 *
 * Rows are visited in order from top to bottom with no gaps. Without
 * overscan, the first row is the top row of the viewport. With overscan,
 * the first row is the highest captured row above the viewport (see
 * GHOSTTY_RENDER_STATE_OPT_OVERSCAN). Returns true if the iterator
 * moved successfully and row data is available to read at the new
 * position.
 *
 * @param iterator The iterator handle to advance (may be NULL)
 * @return true if advanced to the next row, false if `iterator` is
 *         NULL or if the iterator has reached the end
 *
 * @ingroup render
 */
GHOSTTY_API bool ghostty_render_state_row_iterator_next(GhosttyRenderStateRowIterator iterator);

/**
 * Move a render-state row iterator to the next row requiring a redraw.
 *
 * If the global dirty state is GHOSTTY_RENDER_STATE_DIRTY_FALSE, this returns
 * false. If it is GHOSTTY_RENDER_STATE_DIRTY_PARTIAL, clean rows are skipped.
 * If it is GHOSTTY_RENDER_STATE_DIRTY_FULL, every remaining row is returned
 * regardless of its per-row dirty flag. Rows are returned in ascending
 * viewport order. This function does not clear any dirty state.
 *
 * @param iterator The iterator handle to advance (NULL returns false)
 * @param[out] out_y Receives the row's position in the iterator when true
 *                   is returned (NULL returns false). It is not modified
 *                   when false is returned. Without overscan, this is the
 *                   viewport y. With overscan, it counts from the highest
 *                   captured row, so use
 *                   GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y to place
 *                   the row.
 * @return true if advanced to a row requiring a redraw, false if an argument
 *         is NULL or the iterator has reached the end of the effective dirty
 *         rows
 *
 * @ingroup render
 */
GHOSTTY_API bool ghostty_render_state_row_iterator_next_dirty(
    GhosttyRenderStateRowIterator iterator,
    uint16_t* out_y);

/**
 * Get a value from the current row in a render-state row iterator.
 *
 * The `out` pointer must point to a value of the type corresponding to the
 * requested data kind (see GhosttyRenderStateRowData).
 * Call ghostty_render_state_row_iterator_next() or
 * ghostty_render_state_row_iterator_next_dirty() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle to query (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `iterator` or
 *         `out` is NULL or the iterator is not positioned on a row, or
 *         GHOSTTY_UNSUPPORTED if `data` is not known to this version of the
 *         library
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_get(
    GhosttyRenderStateRowIterator iterator,
    GhosttyRenderStateRowData data,
    void* out);

/**
 * Get multiple data fields from the current row in a single call.
 *
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_render_state_row_get() once per key, so
 * use whichever reads better.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param iterator The iterator handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_get_multi(
    GhosttyRenderStateRowIterator iterator,
    size_t count,
    const GhosttyRenderStateRowData* keys,
    void** values,
    size_t* out_written);

/**
 * Set an option on the current row in a render-state row iterator.
 *
 * The `value` pointer must point to a value of the type corresponding to the
 * requested option kind (see GhosttyRenderStateRowOption).
 * Call ghostty_render_state_row_iterator_next() or
 * ghostty_render_state_row_iterator_next_dirty() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle to update (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param[in] value Pointer to the value to set. Row options have no
 *            default to restore, so NULL returns GHOSTTY_INVALID_VALUE.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `iterator` or
 *         `value` is NULL or the iterator is not positioned on a row, or
 *         GHOSTTY_UNSUPPORTED if `option` is not known to this version of the
 *         library
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_set(
    GhosttyRenderStateRowIterator iterator,
    GhosttyRenderStateRowOption option,
    const void* value);

/** @} */

/**
 * Queryable data kinds for ghostty_render_state_row_cells_get().
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_INVALID = 0,

  /** The raw cell value (GhosttyCell). */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW = 1,

  /** The style for the current cell (GhosttyStyle). */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE = 2,

  /** The total number of grapheme codepoints including the base codepoint
   *  (uint32_t). Returns 0 if the cell has no text. */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN = 3,

  /**
   * Copy the cell's grapheme codepoints into a buffer you provide
   * (GhosttyCodepointBuffer).
   *
   * The base codepoint comes first, followed by any extra codepoints. Up
   * to cap codepoints are written, and len is set to the total number of
   * codepoints in the cell. If they do not all fit, this returns
   * GHOSTTY_OUT_OF_SPACE and the buffer holds the first cap of them. A
   * cell with no text returns GHOSTTY_SUCCESS with len set to 0.
   *
   * @code{.c}
   * uint32_t codepoints[16];
   * GhosttyCodepointBuffer graphemes = {.ptr = codepoints, .cap = 16};
   * GhosttyResult result = ghostty_render_state_row_cells_get(
   *     cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &graphemes);
   * if (result == GHOSTTY_OUT_OF_SPACE) {
   *   // The cell has graphemes.len codepoints, but only the first 16
   *   // were written. Retry with a larger buffer to get the rest.
   * }
   * @endcode
   */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF = 4,

  /** The resolved background color of the cell (GhosttyColorRgb).
   *  Flattens the three possible sources: content-tag bg_color_rgb,
   *  content-tag bg_color_palette (looked up in the palette), or the
   *  style's bg_color.
   *
   *  Returns GHOSTTY_NO_VALUE if the cell has no background color of its
   *  own. Draw it with your default background, such as the terminal's:
   *
   *  @code{.c}
   *  GhosttyColorRgb bg;
   *  GhosttyResult result = ghostty_render_state_row_cells_get(
   *      cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
   *  if (result == GHOSTTY_NO_VALUE) bg = colors.background;
   *  @endcode
   */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR = 5,

  /** The resolved foreground color of the cell (GhosttyColorRgb).
   *  Resolves palette indices through the palette. Bold color handling
   *  is not applied; you should handle bold styling separately.
   *  Returns GHOSTTY_NO_VALUE if the cell has no foreground color of its
   *  own. Draw it with your default foreground, such as the terminal's. */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR = 6,

  /** Whether the cell is contained within the current selection (bool).
   *  This returns true when the cell's column is within the current row's
   *  row-local selection range, and false otherwise. Rendering policy for
   *  selected cells (colors, inversion, etc.) is left to you.
   *
   *  Renderers that can draw cells in spans may be more efficient querying
   *  GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION once per row and applying that
   *  range directly, avoiding one C API call per cell for selection state. */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED = 7,

  /** Whether the cell has any explicit styling (bool).
   *  This is equivalent to querying the raw cell's
   *  GHOSTTY_CELL_DATA_HAS_STYLING value, but avoids materializing the raw
   *  GhosttyCell for renderers that only need to know whether fetching the
   *  full style is necessary. */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING = 8,

  /**
   * Encode the current cell's full grapheme cluster as UTF-8 into a
   * caller-provided buffer (GhosttyBuffer).
   *
   * The base codepoint is encoded first, followed by any extra grapheme
   * codepoints. Returns GHOSTTY_SUCCESS with len=0 when the cell has no text.
   *
   * If ptr is NULL or cap is too small for a non-empty cell, returns
   * GHOSTTY_OUT_OF_SPACE without writing any bytes and sets len to the required
   * buffer size in bytes.
   */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8 = 9,
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyRenderStateRowCellsData;

/** @name Cells
 * @{
 */

/**
 * Create a new row cells instance.
 *
 * All fields except the allocator are left undefined until populated
 * via ghostty_render_state_row_get() with
 * GHOSTTY_RENDER_STATE_ROW_DATA_CELLS.
 *
 * You can reuse this value repeatedly with ghostty_render_state_row_get() to 
 * avoid allocating a new cells container for every row.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_cells On success, receives the created row cells handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, GHOSTTY_INVALID_VALUE if @p out_cells is NULL
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderStateRowCells* out_cells);

/**
 * Move a render-state row cells iterator to the next cell.
 *
 * Returns true if the iterator moved successfully and cell data is
 * available to read at the new position.
 *
 * @param cells The row cells handle to advance (may be NULL)
 * @return true if advanced to the next cell, false if `cells` is
 *         NULL or if the iterator has reached the end
 *
 * @ingroup render
 */
GHOSTTY_API bool ghostty_render_state_row_cells_next(GhosttyRenderStateRowCells cells);

/**
 * Move a render-state row cells iterator to a specific column.
 *
 * Positions the iterator at the given x (column) index so that
 * subsequent reads return data for that cell.
 *
 * @param cells The row cells handle to reposition (NULL returns
 *        GHOSTTY_INVALID_VALUE)
 * @param x The zero-based column index to select
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `cells`
 *         is NULL or `x` is out of range
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_select(
    GhosttyRenderStateRowCells cells, uint16_t x);

/**
 * Get a value from the current cell in a render-state row cells iterator.
 *
 * The `out` pointer must point to a value of the type corresponding to the
 * requested data kind (see GhosttyRenderStateRowCellsData).
 * Call ghostty_render_state_row_cells_next() or
 * ghostty_render_state_row_cells_select() at least once before
 * calling this function.
 *
 * @param cells The row cells handle to query (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the cell has no
 *         value for `data`, GHOSTTY_INVALID_VALUE if `cells` is NULL or the
 *         iterator is not positioned on a cell, or GHOSTTY_UNSUPPORTED if
 *         `data` is not known to this version of the library
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_get(
    GhosttyRenderStateRowCells cells,
    GhosttyRenderStateRowCellsData data,
    void* out);

/**
 * Get multiple data fields from the current cell in a single call.
 *
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_render_state_row_cells_get() once per
 * key, so use whichever reads better.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param cells The row cells handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_get_multi(
    GhosttyRenderStateRowCells cells,
    size_t count,
    const GhosttyRenderStateRowCellsData* keys,
    void** values,
    size_t* out_written);

/**
 * Free a row cells instance.
 *
 * @param cells The row cells handle to free (may be NULL)
 *
 * @ingroup render
 */
GHOSTTY_API void ghostty_render_state_row_cells_free(GhosttyRenderStateRowCells cells);

/** @} */

/** @name Images
 * @{
 */

/**
 * Create a new image iterator.
 *
 * The iterator starts out empty. Fill it from a render state with
 * ghostty_render_state_get() and GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR.
 * You can keep one iterator for the lifetime of your renderer and fill it
 * again after every update. See @ref guide-images-drawing for a complete
 * example.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, GHOSTTY_INVALID_VALUE if @p out_iterator is NULL
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_image_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderStateImageIterator* out_iterator);

/**
 * Free an image iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup render
 */
GHOSTTY_API void ghostty_render_state_image_iterator_free(
    GhosttyRenderStateImageIterator iterator);

/**
 * Move an image iterator to the next image placement.
 *
 * Call this before reading the first placement, and keep calling it
 * until it returns false.
 *
 * The order of placements is not the order to draw them in. Sort them
 * by layer (GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER) and then by z-index
 * (GHOSTTY_RENDER_STATE_IMAGE_DATA_Z) first.
 *
 * Only placements with something to draw are returned. For example,
 * placements of an image the terminal hasn't fully received yet are
 * skipped.
 *
 * The iterator reads from the render state that filled it. After the
 * next update of that render state, fill the iterator again before
 * using it.
 *
 * @param iterator The iterator handle (NULL returns false)
 * @return true if the iterator moved to a placement, false if there are
 *         no more placements
 *
 * @ingroup render
 */
GHOSTTY_API bool ghostty_render_state_image_iterator_next(
    GhosttyRenderStateImageIterator iterator);

/**
 * Read one value from the current placement of an image iterator.
 *
 * The `out` pointer must point to a value of the type listed for `data`
 * in GhosttyRenderStateImageData. To read several values at once, use
 * ghostty_render_state_image_get_multi().
 *
 * @param iterator The iterator handle, moved to a placement with
 *        ghostty_render_state_image_iterator_next()
 * @param data The value to read
 * @param[out] out Pointer that receives the value
 * @return GHOSTTY_SUCCESS on success. GHOSTTY_NO_VALUE if `data` only applies
 *         to another protocol. GHOSTTY_INVALID_VALUE if the iterator is NULL
 *         or is not on a placement. GHOSTTY_UNSUPPORTED if `data` is not known
 *         to this version of the library.
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_image_get(
    GhosttyRenderStateImageIterator iterator,
    GhosttyRenderStateImageData data,
    void* out);

/**
 * Read several values from the current placement of an image iterator in
 * one call.
 *
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_render_state_image_get() once per key,
 * so use whichever reads better.
 *
 * `values[i]` receives the value for `keys[i]`. The keys are read in
 * order, and reading stops at the first error.
 *
 * @param iterator The iterator handle, moved to a placement with
 *        ghostty_render_state_image_iterator_next()
 * @param count The number of keys and values
 * @param keys The values to read
 * @param values Output pointers, one for each key
 * @param[out] out_written If not NULL, receives the number of values
 *             written before any error
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_image_get_multi(
    GhosttyRenderStateImageIterator iterator,
    size_t count,
    const GhosttyRenderStateImageData* keys,
    void** values,
    size_t* out_written);

/** @} */

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_RENDER_H */
