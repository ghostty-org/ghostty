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

/** @defgroup render Render State
 *
 * Represents the state required to render a visible screen (a viewport)
 * of a terminal instance. This is stateful and optimized for repeated
 * updates from a single terminal instance and only updating dirty regions
 * of the screen.
 *
 * The key design principle of this API is that it only needs read/write
 * access to the terminal instance during the update call. This allows
 * the render state to minimally impact terminal IO performance and also
 * allows the renderer to be safely multi-threaded (as long as a lock is 
 * held during the update call to ensure exclusive access to the terminal 
 * instance).
 *
 * The basic usage of this API is:
 *
 *   1. Create an empty render state
 *   2. Update it from a terminal instance whenever you need.
 *   3. Read from the render state to get the data needed to draw your frame.
 *
 * ## Two-Phase Updates
 *
 * For callers that synchronize terminal access (e.g. a renderer thread
 * sharing a lock with an IO thread), the update can be split into two
 * phases to minimize the time the terminal must be held exclusively:
 * ghostty_render_state_begin_update requires terminal access, while
 * ghostty_render_state_end_update completes any deferred work using only
 * memory owned by the render state. A typical renderer would lock, begin
 * the update, unlock, and then end the update while the IO thread is free
 * to continue modifying the terminal. ghostty_render_state_update is a
 * convenience that performs both phases in one call.
 *
 * ## Dirty Tracking
 *
 * Dirty tracking is a key feature of the render state that allows renderers
 * to efficiently determine what parts of the screen have changed and only 
 * redraw changed regions.
 *
 * The render state API keeps track of dirty state at two independent layers:
 * a global dirty state that indicates whether the entire frame is clean, 
 * partially dirty, or fully dirty, and a per-row dirty state that allows 
 * tracking which rows in a partially dirty frame have changed. 
 *
 * The user of the render state API is expected to unset both of these.
 * The `update` call does not unset dirty state, it only updates it. After
 * successfully rendering a complete frame, use ghostty_render_state_clean()
 * to unset both layers in one call. The granular setters remain available
 * for callers that only consume part of a frame.
 *
 * An extremely important detail: setting one dirty state doesn't unset
 * the other. For example, setting the global dirty state to false does not
 * reset the row-level dirty flags. So, the caller of the render state API must
 * be careful to manage both layers of dirty state correctly. 
 *
 * ## Render Holds (Synchronized Output)
 *
 * A program can ask the terminal to stop updating the screen while it
 * draws a frame, so the user never sees a half-drawn one. Today programs
 * do this with synchronized output (DEC private mode 2026).
 *
 * ghostty_render_state_update() does not check for this. It always
 * captures the terminal as it is right now, so a renderer that updates
 * on every draw will show half-drawn frames. To avoid that:
 *
 *   1. Set a GHOSTTY_TERMINAL_OPT_RENDER_HOLD callback on the terminal.
 *   2. When the callback reports that a hold began, update the render
 *      state from within the callback. This captures the frame the
 *      program wants left on screen.
 *   3. Don't update the render state again until the callback reports
 *      that the hold ended. You can keep drawing it in the meantime.
 *   4. End the hold yourself if it lasts too long (one second is a
 *      common limit) so a misbehaving program can't freeze the screen.
 *
 * See GhosttyTerminalRenderHoldFn for the details and a complete example.
 *
 * ## Overscan
 *
 * By default, the render state captures exactly the rows visible in the
 * viewport. That is all a renderer needs when it draws whole rows.
 *
 * Some renderers draw the grid shifted by a fraction of a row, most
 * commonly to scroll smoothly. While the grid is shifted, part of a row
 * just outside the viewport becomes visible at one edge, and the renderer
 * needs that row's content to draw it. Overscan asks the render state to
 * capture extra rows above and below the viewport for this purpose.
 *
 * Request overscan with GHOSTTY_RENDER_STATE_OPT_OVERSCAN. The request
 * applies to every update after it is set. The row iterator then visits
 * the extra rows along with the viewport, from top to bottom: the rows
 * above the viewport, the viewport rows, and then the rows below it.
 * GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y tells you where each row
 * belongs. Rows above the viewport have negative values, viewport rows
 * are 0 through rows - 1, and rows below the viewport start at rows.
 *
 * Extra rows are only captured when they exist. There is nothing above
 * the first line of scrollback, and there is nothing below the viewport
 * while it is scrolled to the bottom, which is the usual case. After an
 * update, GHOSTTY_RENDER_STATE_DATA_OVERSCAN reports how many rows were
 * actually captured on each side. Don't shift the grid toward a side
 * where nothing was captured.
 *
 * Extra rows carry the same data as viewport rows, including cells,
 * styles, dirty flags, and selection. The cursor is only reported when it
 * is inside the viewport.
 *
 * The render state doesn't store the scroll position. If you need it,
 * read GHOSTTY_TERMINAL_DATA_SCROLLBAR or
 * GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE with ghostty_terminal_get() at the
 * same time as you call ghostty_render_state_begin_update(), while you
 * have exclusive access to the terminal. The values then describe the
 * same moment as the render state.
 *
 * This example draws one frame of a smooth scroll. `offset_px` comes from
 * the renderer's own scroll animation. It is how far the grid is shifted
 * up, from zero up to but not including one row height.
 *
 * @code{.c}
 * // Once, when setting up the render state. One row below the viewport
 * // is enough to draw the partially visible row at the bottom edge.
 * GhosttyRenderStateOverscan request = { .above = 0, .below = 1 };
 * ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_OVERSCAN,
 *                          &request);
 *
 * // Each frame.
 * ghostty_render_state_update(state, terminal);
 *
 * GhosttyRenderStateOverscan captured;
 * ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_OVERSCAN,
 *                          &captured);
 *
 * // With no row below the viewport, there is nothing to scroll into.
 * if (captured.below == 0) offset_px = 0;
 *
 * ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
 *                          &rows);
 * while (ghostty_render_state_row_iterator_next(rows)) {
 *   int32_t y;
 *   ghostty_render_state_row_get(
 *       rows, GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y, &y);
 *   draw_row(rows, y * cell_height - offset_px);
 * }
 * @endcode
 *
 * ## Row Identity
 *
 * Every row has an id (GHOSTTY_RENDER_STATE_ROW_DATA_ID) that stays with
 * the row as it moves. When the viewport scrolls by one row, each row
 * shows up one position higher or lower in the next update but keeps
 * its id. Ids work with or without overscan.
 *
 * Ids let a renderer keep expensive per-row work, such as shaped text or
 * a prepared texture, in its own cache keyed by id. A cached entry can be
 * reused when both of these are true:
 *
 *   1. A row with the same id is present in the new update.
 *   2. That row's dirty flag is not set.
 *
 * The dirty flag is conservative. A row may be marked dirty even though
 * its content didn't change. For example, every row is currently marked
 * dirty after the viewport scrolls. Rebuilding a dirty row is always
 * correct.
 *
 * An id disappears when its row is no longer captured, is removed from
 * scrollback, or is changed in place by the terminal (for example, when a
 * program scrolls only part of the screen). Ids are never reused, so an
 * old id can never match a different row. Cache entries for ids that no
 * longer appear can be discarded.
 *
 * @code{.c}
 * while (ghostty_render_state_row_iterator_next(rows)) {
 *   GhosttyRenderStateRowId id;
 *   bool dirty;
 *   ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &id);
 *   ghostty_render_state_row_get(
 *       rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &dirty);
 *
 *   // `cache` is the renderer's own map from row id to prepared row.
 *   PreparedRow* prepared = dirty ? NULL : cache_find(cache, id);
 *   if (prepared == NULL) prepared = cache_prepare(cache, id, rows);
 *   draw_prepared_row(prepared);
 * }
 * @endcode
 *
 * ## Images
 *
 * Programs can show images in a terminal through image protocols, such
 * as the Kitty graphics protocol. The render state gives you the images
 * to draw as a list of image placements, which you read with a
 * @ref GhosttyRenderStateImageIterator. Each placement is one rectangle
 * of one image:
 *
 *   - **What** to draw: the image's protocol and ID, plus a source
 *     rectangle that selects part of the image in image pixels.
 *   - **Where** to draw it: the top-left cell, relative to the viewport,
 *     plus a pixel offset within that cell.
 *   - **How big** to draw it: a destination size in pixels. The image is
 *     already scaled to fit its cells.
 *   - **In what order** to draw it: a layer (below cell backgrounds,
 *     below text, or above text) and a z-index within the layer.
 *
 * These values mean the same thing for every protocol, so one drawing
 * routine handles all of them. The only part that depends on the
 * protocol is getting the image's pixels. Use the placement's protocol
 * to pick the right storage, and its image ID to look the image up. For
 * @ref GHOSTTY_IMAGE_PROTOCOL_KITTY, that is
 * ghostty_kitty_graphics_image().
 *
 * ### Which Images Are Included
 *
 * The list holds every Kitty graphics image on screen:
 *
 *   - Images shown with placeholder cells. See "Kitty Graphics
 *     Placeholders" below.
 *   - Images placed at a cell on the screen. These scroll with the text
 *     around them, like a line of output. See "Kitty Graphics Fixed
 *     Placements" below.
 *   - Images placed relative to another image. See "Kitty Graphics
 *     Relative Placements" below.
 *
 * Earlier versions left some of these images out, so renderers had to
 * draw them from the Kitty graphics placement iterator. That is no
 * longer needed. If your renderer still draws images from that
 * iterator, stop, or those images are drawn twice.
 *
 * ### Images Partly Outside the Captured Rows
 *
 * An image is in the list when any part of it is in the captured rows
 * (the viewport plus any overscan rows). Images shown with placeholder
 * cells are split into one placement per row of cells, so each of those
 * placements is always inside the captured rows.
 *
 * Every other placement is reported at its full size, even when only part
 * of it can be seen. Its GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL can
 * be negative, and its GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW can be
 * above the first overscan row. It can also extend past the right or
 * bottom edge. Clip it to the area you draw. Most graphics APIs can do
 * this for you with a scissor or clip rectangle.
 *
 * For example, with no overscan, an image 4 rows tall whose top row
 * scrolled 2 rows above the viewport has a row of -2 and covers 4 rows.
 * Draw it at its full size starting 2 rows above the viewport, clipped
 * to the viewport. Its bottom 2 rows show at the top of the viewport.
 *
 * ### Kitty Graphics Fixed Placements
 *
 * A program can place a Kitty image at a cell on the screen. The image is
 * attached to that cell, so it moves when the text moves: when new output
 * scrolls the screen, when a program scrolls part of the screen, and when
 * the viewport scrolls through the scrollback.
 *
 * The render state finds the position of these images during each update,
 * so you don't need to track the cells yourself. This costs very little
 * on a typical frame, including frames where the viewport scrolls.
 *
 * Later versions may add more protocols and more kinds of placements.
 * Skip any placement whose protocol you don't support, so that your
 * renderer keeps working when that happens.
 *
 * ### Kitty Graphics Placeholders
 *
 * The Kitty graphics protocol lets a program place an image *with text*.
 * The program creates a virtual placement, which has no position of its
 * own, and then prints placeholder characters (U+10EEEE) wherever the
 * image should appear. Each placeholder cell says which image it shows
 * and which piece of that image belongs in the cell. Programs such as
 * tmux use this so that images scroll, move and disappear along with the
 * text around them.
 *
 * Since the cells decide where these images go, the Kitty graphics
 * storage alone can't tell you where to draw them. The render state
 * works this out for you during each update. It finds the placeholder
 * cells, groups neighboring cells that show the same image into runs,
 * and calculates which part of the image each run shows. It only looks
 * at rows that changed, so this costs very little on a typical frame.
 *
 * A virtual placement usually turns into several placements in the list,
 * one for each row of placeholder cells. For example, an image shown in
 * a block of 10 columns by 4 rows of placeholders gives 4 placements,
 * each 10 cells wide and 1 cell tall, and each drawing a quarter of the
 * image. Drawn together, they form the whole image.
 *
 * ### Kitty Graphics Relative Placements
 *
 * A program can also place a Kitty image relative to another placement,
 * its parent. The image is drawn a number of cells to the right of and
 * below its parent. Negative numbers move it left or up. The parent can
 * be relative to another placement too, so placements can form a chain.
 *
 * The render state follows the chain to the placement at its start and
 * positions the image from there:
 *
 *   - If the chain starts at an image placed at a cell, the image is
 *     drawn from that cell, and moves whenever that cell moves.
 *   - If the chain starts at a virtual placement, the image is drawn from
 *     the top-left corner of that placement's placeholder cells. If none
 *     of those cells are in the captured rows, the image is not in the
 *     list.
 *
 * For example, an image placed 3 columns right of and 2 rows below a
 * parent at column 2, row 1 is drawn at column 5, row 3. Like other
 * placements, it is in the list when any part of it is in the captured
 * rows, even if its parent isn't.
 *
 * ### Example
 *
 * @code{.c}
 * // Create the iterator once and reuse it for every frame.
 * GhosttyRenderStateImageIterator images = NULL;
 * ghostty_render_state_image_iterator_new(NULL, &images);
 *
 * // Each frame, after ghostty_render_state_update(). To skip this on
 * // frames where no image changed, see "Knowing When Images Changed"
 * // below.
 * ghostty_render_state_get(
 *     state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &images);
 *
 * while (ghostty_render_state_image_iterator_next(images)) {
 *   GhosttyImageProtocol protocol;
 *   GhosttyImageLayer layer;
 *   uint32_t image_id, offset_x, offset_y, width, height;
 *   uint32_t src_x, src_y, src_width, src_height;
 *   uint64_t generation;
 *   int32_t col, row, z;
 *
 *   GhosttyRenderStateImageData keys[] = {
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_Z,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH,
 *     GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT,
 *   };
 *   void* values[] = {
 *     &protocol, &image_id, &generation, &layer, &z, &col, &row,
 *     &offset_x, &offset_y, &width, &height,
 *     &src_x, &src_y, &src_width, &src_height,
 *   };
 *   ghostty_render_state_image_get_multi(images, 15, keys, values, NULL);
 *
 *   // Your renderer: find the texture for this image. Only read the
 *   // pixels when you don't have a texture for this protocol, ID and
 *   // generation yet.
 *   Texture* texture = texture_cache_find(protocol, image_id, generation);
 *   if (texture == NULL) {
 *     switch (protocol) {
 *     case GHOSTTY_IMAGE_PROTOCOL_KITTY:
 *       // Look up image_id with ghostty_kitty_graphics_image(), read its
 *       // pixels with ghostty_kitty_graphics_image_get(), and upload.
 *       texture = upload_kitty_image(image_id, generation);
 *       break;
 *     default:
 *       // A protocol this renderer doesn't support yet.
 *       continue;
 *     }
 *   }
 *
 *   // The destination rectangle in pixels, relative to the top-left
 *   // corner of the viewport. It can start above or left of the
 *   // viewport, so clip it when drawing.
 *   int32_t x = col * cell_width + (int32_t)offset_x;
 *   int32_t y = row * cell_height + (int32_t)offset_y;
 *
 *   // Queue the image. Sort the queue by layer and then z before
 *   // drawing, since iteration order is not drawing order.
 *   queue_image(texture, layer, z, x, y, width, height,
 *               src_x, src_y, src_width, src_height);
 * }
 *
 * // When you no longer need it:
 * ghostty_render_state_image_iterator_free(images);
 * @endcode
 *
 * ### Knowing When Images Changed
 *
 * Most frames don't change any image. A program prints text or moves the
 * cursor, and every image stays where it was. You don't need to read the
 * iterator again on those frames. After each update, read
 * GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION and compare it
 * with the value from the last time you read the list. If the two match,
 * the list is the same as before, and you can keep drawing what you built
 * last time:
 *
 * @code{.c}
 * // Kept by your renderer between frames. The flag makes sure the first
 * // frame always reads the list.
 * uint64_t last_generation = 0;
 * bool have_draw_list = false;
 *
 * // Each frame, after ghostty_render_state_update():
 * uint64_t generation = 0;
 * ghostty_render_state_get(
 *     state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION,
 *     &generation);
 * if (!have_draw_list || generation != last_generation) {
 *   last_generation = generation;
 *   have_draw_list = true;
 *
 *   // Your renderer: read the iterator as in the example above and
 *   // build a new queue of images to draw.
 *   rebuild_image_queue(state, images);
 * }
 * draw_image_queue();
 * @endcode
 *
 * The value changes when an update adds or removes an image, moves one,
 * changes which part of one is shown, or changes the pixels of one. It
 * stays the same when only text changes, as long as the changed rows had
 * no Kitty placeholder cells before or after the change. (See "Kitty
 * Graphics Placeholders" above for what those are.)
 *
 * A new value means "read the list again". It doesn't promise that
 * anything on screen moved. The value can change even when every image
 * ends up exactly where it was, for example:
 *
 *   - When a program rewrites a row that has placeholder cells.
 *   - When a program changes any image or placement while images shown
 *     with placeholder cells are on screen.
 *
 * Only compare the value for equality. It wraps around, so a larger value
 * doesn't mean a newer one. It is always 0 when Kitty graphics are
 * disabled.
 *
 * Don't confuse this value with
 * GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION. That one belongs to a
 * single image and tells you when to upload its pixels again. This one
 * belongs to the whole list and tells you when to read the list again.
 *
 * ### Things to Keep in Mind
 *
 *   - **Image pixels are not copied.** The render state only knows where
 *     to draw. Read pixels from the terminal while you still have access
 *     to it, for example right after the update while you hold your
 *     terminal lock. The image generation tells you when you need to
 *     read them again, so most frames don't touch the terminal at all.
 *   - **Some images are only partly visible.** Clip what you draw to the
 *     viewport, or to the captured rows if you draw overscan rows. See
 *     "Images Partly Outside the Captured Rows" above.
 *   - **The terminal needs a cell size.** Image sizes depend on the size
 *     of a cell in pixels, which you set with ghostty_terminal_resize().
 *     Without it there is nothing to draw and the iterator is empty.
 *   - **Results last until the next update.** Like rows, they belong to
 *     the render state and can be read without access to the terminal.
 *     After each update, fill the iterator again before you read it.
 *
 * ## Examples
 *
 * ### Creating and updating render state
 * @snippet c-vt-render/src/main.c render-state-update
 *
 * ### Checking dirty state
 * @snippet c-vt-render/src/main.c render-dirty-check
 *
 * ### Reading colors
 * @snippet c-vt-render/src/main.c render-colors
 *
 * ### Reading cursor state
 * @snippet c-vt-render/src/main.c render-cursor
 *
 * ### Iterating rows and cells
 * @snippet c-vt-render/src/main.c render-row-iterate
 *
 * ### Resetting dirty state after rendering
 * @snippet c-vt-render/src/main.c render-dirty-reset
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
 * update captured with GHOSTTY_RENDER_STATE_DATA_OVERSCAN. See "Overscan"
 * in the render state overview for how the extra rows are used.
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
 * See "Row Identity" in the render state overview for how to use ids.
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
   *  Returns GHOSTTY_INVALID_VALUE if no explicit cursor color is set;
   *  use COLOR_CURSOR_HAS_VALUE to check first. */
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
   *  If false, the cursor viewport position values are undefined. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE = 14,

  /** Cursor viewport x position in cells (uint16_t).
   *  Only valid when CURSOR_VIEWPORT_HAS_VALUE is true. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X = 15,

  /** Cursor viewport y position in cells (uint16_t).
   *  Only valid when CURSOR_VIEWPORT_HAS_VALUE is true. */
  GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y = 16,

  /** Whether the cursor is on the tail of a wide character (bool).
   *  Only valid when CURSOR_VIEWPORT_HAS_VALUE is true. */
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
   *  placements found by the last update. See "Images" in the render
   *  state overview. */
  GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR = 22,

  /** A value (uint64_t) that changes whenever an update changes the
   *  placements that GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR returns. If
   *  it matches the value from the last time you read the iterator, the
   *  placements are the same and you don't need to read them again. See
   *  "Knowing When Images Changed" in the render state overview for an
   *  example and for exactly when the value changes.
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
   *  change. See "Overscan" in the render state overview. */
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
   *  See "Kitty Graphics Relative Placements" in the @ref render
   *  documentation. */
  GHOSTTY_RENDER_STATE_KITTY_PLACEMENT_KIND_RELATIVE = 1,

  /** A placement at a cell on the screen. It scrolls with the text,
   *  like a line of output would. Its z-index is the one the program
   *  chose, so it can be in any layer.
   *
   *  It is included at its full size when any part of it is in the
   *  captured rows, so it may need to be clipped when drawn. See "Images
   *  Partly Outside the Captured Rows" in the @ref render documentation. */
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
   *  "Images Partly Outside the Captured Rows" in the @ref render
   *  documentation. */
  GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL = 6,

  /** The row of the top-left cell (int32_t), where 0 is the top row of
   *  the viewport. A placement in an overscan row above the viewport has
   *  a negative row, the same as GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y.
   *  Fixed and relative placements are reported at their full size, so
   *  they can also start above the first overscan row. Virtual
   *  placements are always inside the captured rows. See "Images Partly
   *  Outside the Captured Rows" in the @ref render documentation. */
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
   *  works with or without overscan. See "Row Identity" in the render
   *  state overview. */
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
 * querying GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION. See @ref sized_sec.
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
 * querying GHOSTTY_RENDER_STATE_DATA_CURSOR. See @ref sized_sec.
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
 * querying GHOSTTY_RENDER_STATE_DATA_COLORS. See @ref sized_sec.
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

/**
 * Create a new render state instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state Pointer to store the created render state handle
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
 * Callers must treat the render state as incomplete until
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

/**
 * Get a value from a render state.
 *
 * The `out` pointer must point to a value of the type corresponding to the
 * requested data kind (see GhosttyRenderStateData).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 *         `out` is NULL or a sized output struct is smaller than
 *         `sizeof(size_t)`, or GHOSTTY_UNSUPPORTED if `data` is not known to
 *         this version of the library
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
 *         failure
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
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `iterator` is
 *         NULL or the iterator is not positioned on a row, or
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
 *         failure
 *
 * @ingroup render
 */
GHOSTTY_API GhosttyResult ghostty_render_state_row_cells_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderStateRowCells* out_cells);

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
   *  style's bg_color. Returns GHOSTTY_INVALID_VALUE if the cell has
   *  no background color, in which case the caller should use whatever
   *  default background color it wants (e.g. the terminal background). */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR = 5,

  /** The resolved foreground color of the cell (GhosttyColorRgb).
   *  Resolves palette indices through the palette. Bold color handling
   *  is not applied; the caller should handle bold styling separately.
   *  Returns GHOSTTY_INVALID_VALUE if the cell has no explicit foreground
   *  color, in which case the caller should use whatever default foreground
   *  color it wants (e.g. the terminal foreground). */
  GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR = 6,

  /** Whether the cell is contained within the current selection (bool).
   *  This returns true when the cell's column is within the current row's
   *  row-local selection range, and false otherwise. Rendering policy for
   *  selected cells (colors, inversion, etc.) is left to the caller.
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
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `cells` is NULL
 *         or the iterator is not positioned on a cell, or GHOSTTY_UNSUPPORTED
 *         if `data` is not known to this version of the library
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

/**
 * Create a new image iterator.
 *
 * The iterator starts out empty. Fill it from a render state with
 * ghostty_render_state_get() and GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR.
 * You can keep one iterator for the lifetime of your renderer and fill it
 * again after every update. See "Images" in the render state overview for
 * a complete example.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure
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

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_RENDER_H */
