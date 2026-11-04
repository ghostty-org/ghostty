/**
 * @file kitty_graphics.h
 *
 * Kitty graphics protocol 
 *
 * See @ref kitty_graphics for a full usage guide.
 */

#ifndef GHOSTTY_VT_KITTY_GRAPHICS_H
#define GHOSTTY_VT_KITTY_GRAPHICS_H

#include <stdbool.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup kitty_graphics Kitty Graphics
 *
 * API for the images that programs send with the
 * [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
 *
 * The terminal keeps every image a program sends, and every placement
 * of an image on screen, in an image storage. Each screen (main and
 * alternate) has its own. @ref GhosttyKittyGraphics is a handle to the
 * storage of the active screen. Use it to:
 *
 *   - Read the pixels of an image so you can draw it.
 *   - Play animated images.
 *   - Inspect the images and placements the storage holds.
 *
 * This API doesn't tell you where to draw images. The render state does
 * that. See "Drawing Images" below.
 *
 * ## Setting Up
 *
 * Kitty graphics are off until you give the terminal a storage limit
 * with @ref GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT. To accept PNG
 * images, also install a PNG decoder with ghostty_sys_set() and
 * @ref GHOSTTY_SYS_OPT_DECODE_PNG, as in this example:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png
 *
 * Get the storage handle with ghostty_terminal_get() and
 * @ref GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS. The handle is borrowed from
 * the terminal. It stays valid until the next call that changes the
 * terminal, such as ghostty_terminal_vt_write() or
 * ghostty_terminal_reset(), so get it again after each of those.
 *
 * ## Drawing Images
 *
 * Use the render state's image list to find what to draw. It lists
 * every Kitty image on screen, however the program placed it:
 *
 *   - At a cell, so the image scrolls with the text.
 *   - With placeholder cells (see "Unicode Placeholders" below).
 *   - Relative to another image.
 *
 * Each entry already has its position, size, source rectangle, layer
 * and z-index worked out, so one drawing routine handles all of them.
 * See "Images" in the @ref render documentation for the details.
 *
 * The storage only provides the pixels. Each entry in the list has an
 * image ID. Look it up with ghostty_kitty_graphics_image(), then read
 * the image's size, pixel format and pixels with
 * ghostty_kitty_graphics_image_get(). The pixels are always decoded and
 * uncompressed, so you can upload them as they are:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-draw
 *
 * Don't also draw images from this API's placement iterator. The render
 * state's list already includes those placements, so they would be
 * drawn twice. See "Inspecting the Storage" below for what the iterator
 * is for.
 *
 * ## Knowing What Changed
 *
 * Most frames don't change any image, so a renderer can skip most of
 * its image work. Two values tell you what to redo:
 *
 *   - @ref GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION belongs
 *     to the render state's whole list. It tells you when to read the
 *     list again, for example after an image moved because the text
 *     scrolled.
 *   - @ref GHOSTTY_KITTY_IMAGE_DATA_GENERATION belongs to a single image.
 *     It tells you when to upload that image's pixels again. It changes
 *     when a program sends the image again and on every animation frame.
 *     The render state reports the same value for each entry as
 *     @ref GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, so you can
 *     check your texture cache without touching the storage.
 *
 * Use the image generation as part of your texture cache key. Don't rely
 * on the image's size or data length instead: a program can send new
 * pixels with the same size under the same ID.
 *
 * Here is a frame loop that reads the list only when it changed:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-frame
 *
 * The storage also has a generation of its own,
 * @ref GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION. It changes whenever a
 * program sends, places or deletes an image, but not when images only
 * move on screen. It can't tell you when to read the render state's list
 * again. It is useful for work that only depends on what the storage
 * holds, such as freeing textures of images that were deleted.
 *
 * The two storage generations are never reused, not even across the
 * main and alternate screens, terminal resets, or different terminals.
 * That makes either one safe to use as a cache key on its own. The
 * render state's placements generation is different: only compare it
 * with the last value you read from the same render state.
 *
 * ## Animation
 *
 * The Kitty graphics protocol lets programs send images with several
 * frames and ask the terminal to play them, much like an animated GIF.
 * The terminal stores every frame, but it does not keep its own timer.
 * Your application drives playback by calling
 * ghostty_kitty_graphics_animation_tick().
 *
 * Each call shows whichever frame is due at the time you pass in. When
 * an image moves to a new frame, two things change:
 *
 * - @ref GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR returns the pixels of the
 *   new frame.
 * - @ref GHOSTTY_KITTY_IMAGE_DATA_GENERATION returns a new value.
 *
 * If you already cache textures by image generation (see "Knowing What
 * Changed" above), new frames appear without any extra work.
 *
 * The tick also tells you when the next frame is due. Use that time to
 * schedule a single redraw instead of calling the tick in a loop:
 *
 * 1. Call the tick each time you prepare a frame to draw, as long as
 *    the storage holds at least one image.
 * 2. If it returns GHOSTTY_SUCCESS, schedule one redraw at the returned
 *    time. Don't schedule it sooner than your shortest frame interval
 *    (for example 8 ms for a 120 Hz display).
 * 3. If it returns GHOSTTY_NO_VALUE, nothing is playing. Don't schedule
 *    anything.
 *
 * You never need to watch for animations starting. A program starts or
 * resumes playback by writing a command to the terminal, and that write
 * already gives you a reason to redraw. The tick on that redraw picks
 * up the animation. A terminal with no playing animations costs nothing
 * extra.
 *
 * Here is a helper that follows these steps. A renderer calls it once
 * per frame and uses the result to schedule the next redraw:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-animation-tick
 *
 * The example below plays a two-frame animation with that helper. It
 * uses a pretend clock so that it runs instantly:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-animation-play
 *
 * ## Unicode Placeholders
 *
 * A program can place an image with text instead of at a cell. It
 * creates a virtual placement, which has no position of its own, and
 * prints placeholder characters (U+10EEEE) where the image should
 * appear. The image then moves with those characters, like text.
 * Programs such as tmux use this so that images scroll, move and
 * disappear along with the text around them.
 *
 * Only the cells know where these images are, so the storage can't tell
 * you. The render state finds the placeholder cells and lists each part
 * of the image like any other entry, so you draw them the same way as
 * every other image. See "Kitty Graphics Placeholders" in the
 * @ref render documentation.
 *
 * ## Inspecting the Storage
 *
 * A @ref GhosttyKittyGraphicsPlacementIterator lists every placement in
 * the storage, including placements that are off screen and virtual
 * placements. Use it for tools such as debuggers or tests that need to
 * see what the storage holds. A renderer doesn't need it.
 *
 *   1. Create an iterator with ghostty_kitty_graphics_placement_iterator_new().
 *   2. Fill it from the storage with ghostty_kitty_graphics_get() and
 *      @ref GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR.
 *   3. Optionally limit it to one layer with
 *      ghostty_kitty_graphics_placement_iterator_set().
 *   4. Move to each placement with ghostty_kitty_graphics_placement_next()
 *      and read its values with ghostty_kitty_graphics_placement_get().
 *   5. Free the iterator with ghostty_kitty_graphics_placement_iterator_free().
 *
 * These functions work out the geometry of the iterator's current
 * placement from the storage:
 *
 *   - ghostty_kitty_graphics_placement_pixel_size(): the size to draw
 *     the image at, in pixels.
 *   - ghostty_kitty_graphics_placement_grid_size(): the number of
 *     columns and rows of cells it covers.
 *   - ghostty_kitty_graphics_placement_viewport_pos(): the top-left
 *     cell, relative to the viewport.
 *   - ghostty_kitty_graphics_placement_source_rect(): the part of the
 *     image to draw, in image pixels.
 *   - ghostty_kitty_graphics_placement_rect(): the cells it covers, as a
 *     @ref GhosttySelection.
 *   - ghostty_kitty_graphics_placement_render_info(): all of the above
 *     except the selection, in one call.
 *
 * They only know about placements at a cell, and placements relative to
 * one. They can't find virtual placements, or placements relative to a
 * virtual placement, because those depend on the cells. The render
 * state gives the same values for every entry in its list, so prefer it
 * whenever you are drawing.
 *
 * ## Lifetime and Thread Safety
 *
 * All handles borrowed from the terminal (GhosttyKittyGraphics,
 * GhosttyKittyGraphicsImage) become invalid after any call that changes
 * the terminal. The placement iterator belongs to you and must be freed,
 * but the values it returns are only valid until the terminal changes.
 *
 * ## Example
 *
 * The following example creates a terminal, places one image at a cell
 * and another with placeholder cells, lists both from the render state,
 * and reads each image's pixels from the storage:
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-main
 *
 * @{
 */

/**
 * Queryable data kinds for ghostty_kitty_graphics_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_GRAPHICS_DATA_INVALID = 0,

  /**
   * Populate a pre-allocated placement iterator with placement data from
   * the storage. Iterator data is only valid as long as the underlying
   * terminal is not mutated.
   *
   * Output type: GhosttyKittyGraphicsPlacementIterator *
   */
  GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR = 1,

  /**
   * A value that changes whenever a program sends, replaces, places or
   * deletes an image. It is 0 if nothing has changed the storage yet,
   * which means the storage is empty.
   *
   * If the value matches the last one you read, the storage holds the
   * same images and placements as before. The placements may still have
   * moved on screen, because scrolling and resizing move them without
   * changing the storage. So this value can't tell you when to read the
   * render state's image list again. For that, use
   * GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION. See "Knowing
   * What Changed" in the @ref kitty_graphics documentation.
   *
   * A value is never reused, not even by another screen, after a reset,
   * or by another terminal. You can use it as a cache key on its own.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION = 2,
  GHOSTTY_KITTY_GRAPHICS_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsData;

/**
 * Queryable data kinds for ghostty_kitty_graphics_placement_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_INVALID = 0,

  /**
   * The image ID this placement belongs to.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID = 1,

  /**
   * The placement ID.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID = 2,

  /**
   * Whether this is a virtual placement, which a program shows with
   * Unicode placeholder cells.
   *
   * A virtual placement appears wherever its placeholder cells are, so
   * the storage has no position for it. The render state's image list
   * positions it from its cells like any other placement, so a renderer
   * doesn't need to check this. See "Unicode Placeholders" in the
   * @ref kitty_graphics documentation.
   *
   * Output type: bool *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL = 3,

  /**
   * Pixel offset from the left edge of the cell.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET = 4,

  /**
   * Pixel offset from the top edge of the cell.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET = 5,

  /**
   * Source rectangle x origin in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_X = 6,

  /**
   * Source rectangle y origin in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_Y = 7,

  /**
   * Source rectangle width in pixels (0 = full image width).
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_WIDTH = 8,

  /**
   * Source rectangle height in pixels (0 = full image height).
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_SOURCE_HEIGHT = 9,

  /**
   * Number of columns this placement occupies.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS = 10,

  /**
   * Number of rows this placement occupies.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS = 11,

  /**
   * Z-index for this placement.
   *
   * Output type: int32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z = 12,

  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsPlacementData;

/**
 * A layer to limit the storage placement iterator to, set with
 * GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER.
 *
 * The Kitty graphics protocol picks a placement's layer from its
 * z-index, as each value below describes. This filter is only for the
 * storage iterator. To draw, use the layer the render state gives each
 * entry (GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER). It follows the same
 * rules, and it also covers virtual placements, which are always drawn
 * below the text.
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Every placement. This is the default. */
  GHOSTTY_KITTY_PLACEMENT_LAYER_ALL = 0,

  /** Placements drawn below the cell backgrounds: z < INT32_MIN / 2. */
  GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG = 1,

  /** Placements drawn above the cell backgrounds and below the text:
   *  INT32_MIN / 2 <= z < 0. */
  GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT = 2,

  /** Placements drawn above the text: z >= 0. */
  GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT = 3,
  GHOSTTY_KITTY_PLACEMENT_LAYER_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyPlacementLayer;

/**
 * Settable options for ghostty_kitty_graphics_placement_iterator_set().
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Only return placements in one layer. See GhosttyKittyPlacementLayer.
   *
   * Input type: GhosttyKittyPlacementLayer *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER = 0,
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsPlacementIteratorOption;

/**
 * Pixel format of a Kitty graphics image.
 *
 * Note that stored images are always fully decoded:
 * GHOSTTY_KITTY_IMAGE_FORMAT_PNG is never returned by
 * ghostty_kitty_graphics_image_get() because PNG payloads are decoded
 * to GHOSTTY_KITTY_IMAGE_FORMAT_RGBA before storage. The PNG value
 * exists only for protocol-level completeness.
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_KITTY_IMAGE_FORMAT_RGB = 0,
  GHOSTTY_KITTY_IMAGE_FORMAT_RGBA = 1,
  GHOSTTY_KITTY_IMAGE_FORMAT_PNG = 2,
  GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA = 3,
  GHOSTTY_KITTY_IMAGE_FORMAT_GRAY = 4,
  GHOSTTY_KITTY_IMAGE_FORMAT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyImageFormat;

/**
 * Compression of a Kitty graphics image.
 *
 * Note that stored images are always decompressed:
 * GHOSTTY_KITTY_IMAGE_COMPRESSION_ZLIB_DEFLATE payloads are inflated
 * before storage, so ghostty_kitty_graphics_image_get() always reports
 * GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE. Consumers never need to
 * inflate image data themselves.
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE = 0,
  GHOSTTY_KITTY_IMAGE_COMPRESSION_ZLIB_DEFLATE = 1,
  GHOSTTY_KITTY_IMAGE_COMPRESSION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyImageCompression;

/**
 * Queryable data kinds for ghostty_kitty_graphics_image_get().
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid / sentinel value. */
  GHOSTTY_KITTY_IMAGE_DATA_INVALID = 0,

  /**
   * The image ID.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_ID = 1,

  /**
   * The image number.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_NUMBER = 2,

  /**
   * Image width in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_WIDTH = 3,

  /**
   * Image height in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_HEIGHT = 4,

  /**
   * Pixel format of the image. Never GHOSTTY_KITTY_IMAGE_FORMAT_PNG;
   * PNG payloads are decoded to RGBA before storage.
   *
   * Output type: GhosttyKittyImageFormat *
   */
  GHOSTTY_KITTY_IMAGE_DATA_FORMAT = 5,

  /**
   * Compression of the image. Always
   * GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE; compressed payloads are
   * inflated before storage.
   *
   * Output type: GhosttyKittyImageCompression *
   */
  GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION = 6,

  /**
   * Borrowed pointer to the raw pixel data. Valid as long as the
   * underlying terminal is not mutated. Returns GHOSTTY_NO_VALUE when
   * the image metadata is resident but its pixel payload is pending.
   *
   * The data is always fully decoded, uncompressed pixels in the
   * format reported by GHOSTTY_KITTY_IMAGE_DATA_FORMAT: zlib payloads
   * are inflated and PNG payloads are decoded to RGBA at transmission
   * time, before the image is stored. Consumers can upload this
   * directly to the GPU without any decode step.
   *
   * For an animated image (Kitty graphics animation, actions a=f/a=a)
   * this is the pixel data of the current animation frame. The
   * image's GHOSTTY_KITTY_IMAGE_DATA_GENERATION changes whenever the
   * current frame changes, so generation-keyed caches remain
   * coherent.
   *
   * Output type: const uint8_t **
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR = 7,

  /**
   * Length of the raw pixel data in bytes. Always equal to
   * width * height * bytes-per-pixel for the reported format. For a
   * pending image, this is the expected length reserved against the
   * storage limit even though DATA_PTR is not available yet.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN = 8,

  /**
   * A value that changes whenever this image's pixels may have changed:
   * when a program sends the image or replaces it, and when an animation
   * moves to a new frame. Use it as part of your texture cache key. If
   * it matches the texture you have, you don't need to read the pixels
   * again. The render state reports the same value for each of its
   * entries as GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION.
   *
   * Don't use the image's size or data length to detect changes instead.
   * A program can send new pixels of the same size under the same ID.
   *
   * A value is never reused, not even by another image, another screen,
   * or another terminal. It is never 0 for a stored image, so you can
   * use 0 to mean "no texture yet".
   *
   * One case doesn't change this value. When a program finishes sending
   * an image whose pixels were still on the way, the image keeps its
   * value, and GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR starts returning the
   * pixels. GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION changes when that
   * happens, so read DATA_PTR again then.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_GENERATION = 9,

  GHOSTTY_KITTY_IMAGE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsImageData;

/**
 * The geometry of a storage placement, filled in by
 * ghostty_kitty_graphics_placement_render_info().
 *
 * It holds the results of ghostty_kitty_graphics_placement_pixel_size(),
 * ghostty_kitty_graphics_placement_grid_size(),
 * ghostty_kitty_graphics_placement_viewport_pos() and
 * ghostty_kitty_graphics_placement_source_rect(), so you can get all of
 * them in one call. That helps most when each call is expensive, such
 * as through FFI or Cgo.
 *
 * This is for inspecting the storage. To draw, use the render state's
 * image list, which gives the same values for every image on screen.
 * See "Drawing Images" in the @ref kitty_graphics documentation.
 *
 * Later versions may add fields to the end of this struct. Set `size`
 * with GHOSTTY_INIT_SIZED before each call, so the library knows which
 * fields you have:
 *
 * @code{.c}
 * GhosttyKittyGraphicsPlacementRenderInfo info =
 *     GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo);
 * ghostty_kitty_graphics_placement_render_info(iter, image, terminal, &info);
 * @endcode
 *
 * @ingroup kitty_graphics
 */
typedef struct {
  /** The size of this struct in bytes. Set it with GHOSTTY_INIT_SIZED. */
  size_t size;
  /** The width to draw the image at, in pixels. */
  uint32_t pixel_width;
  /** The height to draw the image at, in pixels. */
  uint32_t pixel_height;
  /** The number of columns of cells the placement covers. */
  uint32_t grid_cols;
  /** The number of rows of cells the placement covers. */
  uint32_t grid_rows;
  /** The column of the top-left cell, where 0 is the leftmost column of
   *  the viewport. Only meaningful when `viewport_visible` is true. */
  int32_t viewport_col;
  /** The row of the top-left cell, where 0 is the top row of the
   *  viewport. It is negative when the top of the placement scrolled
   *  above the viewport. Only meaningful when `viewport_visible` is
   *  true. */
  int32_t viewport_row;
  /** True when any part of the placement is in the viewport. False when
   *  it is entirely outside the viewport, or when the storage can't find
   *  its position: a virtual placement, or a placement relative to one. */
  bool viewport_visible;
  /** The left edge of the part of the image to draw, in image pixels. */
  uint32_t source_x;
  /** The top edge of the part of the image to draw, in image pixels. */
  uint32_t source_y;
  /** The width of the part of the image to draw, in image pixels. */
  uint32_t source_width;
  /** The height of the part of the image to draw, in image pixels. */
  uint32_t source_height;
} GhosttyKittyGraphicsPlacementRenderInfo;

/**
 * Get data from a kitty graphics storage instance.
 *
 * The output pointer must be of the appropriate type for the requested
 * data kind.
 *
 * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
 *
 * @param graphics The kitty graphics handle
 * @param data The type of data to extract
 * @param[out] out Pointer to store the extracted data
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_get(
    GhosttyKittyGraphics graphics,
    GhosttyKittyGraphicsData data,
    void* out);

/**
 * Advance playing animations and get the time of the next frame.
 *
 * Every playing animation moves to the frame that is due at `now_ms`.
 * An animation moves forward at most one frame per call. If calls
 * arrive late, playback slows down rather than skipping frames.
 *
 * Images that moved to a new frame get a new
 * @ref GHOSTTY_KITTY_IMAGE_DATA_GENERATION, and their
 * @ref GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR returns the new frame's pixels.
 *
 * Time is measured in milliseconds on a clock you choose, such as the
 * time since your application started. The clock must only move
 * forward, and you must keep using the same clock with the same
 * starting point for as long as the terminal exists. The time written
 * to `next_ms` uses the same clock.
 *
 * This call changes the image storage. Like ghostty_terminal_vt_write(),
 * it invalidates any @ref GhosttyKittyGraphicsImage handles and image
 * data pointers you are holding, so look images up again afterwards.
 * The @ref GhosttyKittyGraphics handle itself stays valid.
 *
 * Call this once each time you prepare a frame to draw, not in a loop.
 * The "Animation" section of @ref kitty_graphics explains how to
 * schedule redraws with the returned time and includes an example.
 *
 * @param graphics The kitty graphics handle
 * @param now_ms The current time in milliseconds
 * @param[out] next_ms Set to the time the next frame is due, in
 *   milliseconds on the same clock as `now_ms`. Only written when the
 *   function returns GHOSTTY_SUCCESS.
 * @return GHOSTTY_SUCCESS if an animation is playing and `next_ms` was
 *   set, GHOSTTY_NO_VALUE if nothing is playing or Kitty graphics are
 *   disabled at build time, GHOSTTY_INVALID_VALUE if `next_ms` is NULL
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_animation_tick(
    GhosttyKittyGraphics graphics,
    uint64_t now_ms,
    uint64_t* next_ms);

/**
 * Look up a Kitty graphics image by its image ID.
 *
 * Returns NULL if no image with the given ID exists or if Kitty graphics
 * are disabled at build time.
 *
 * @param graphics The kitty graphics handle
 * @param image_id The image ID to look up
 * @return An opaque image handle, or NULL if not found
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyKittyGraphicsImage ghostty_kitty_graphics_image(
    GhosttyKittyGraphics graphics,
    uint32_t image_id);

/**
 * Get data from a Kitty graphics image.
 *
 * The output pointer must be of the appropriate type for the requested
 * data kind.
 *
 * @param image The image handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get(
    GhosttyKittyGraphicsImage image,
    GhosttyKittyGraphicsImageData data,
    void* out);

/**
 * Get multiple data fields from a Kitty graphics image in a single call.
 *
 * This is an optimization over calling ghostty_kitty_graphics_image_get()
 * repeatedly, particularly useful in environments with high per-call
 * overhead such as FFI or Cgo.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 * The type of each values[i] pointer must match the output type
 * documented for keys[i].
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param image The image handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return GHOSTTY_SUCCESS if all queries succeed
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get_multi(
    GhosttyKittyGraphicsImage image,
    size_t count,
    const GhosttyKittyGraphicsImageData* keys,
    void** values,
    size_t* out_written);

/**
 * Create a new placement iterator instance.
 *
 * All fields except the allocator are left undefined until populated
 * via ghostty_kitty_graphics_get() with
 * GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyKittyGraphicsPlacementIterator* out_iterator);

/**
 * Free a placement iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API void ghostty_kitty_graphics_placement_iterator_free(
    GhosttyKittyGraphicsPlacementIterator iterator);

/**
 * Set an option on a placement iterator.
 *
 * Use GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER with a
 * GhosttyKittyPlacementLayer value to filter placements by z-layer.
 * The filter is applied during iteration: ghostty_kitty_graphics_placement_next()
 * will skip placements that do not match the configured layer.
 *
 * The default layer is GHOSTTY_KITTY_PLACEMENT_LAYER_ALL (no filtering).
 *
 * @param iterator The iterator handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param value Pointer to the value (type depends on option; NULL returns
 *              GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_iterator_set(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsPlacementIteratorOption option,
    const void* value);

/**
 * Advance the placement iterator to the next placement.
 *
 * If a layer filter has been set via
 * ghostty_kitty_graphics_placement_iterator_set(), only placements
 * matching that layer are returned.
 *
 * @param iterator The iterator handle (may be NULL)
 * @return true if advanced to the next placement, false if at the end
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API bool ghostty_kitty_graphics_placement_next(
    GhosttyKittyGraphicsPlacementIterator iterator);

/**
 * Get data from the current placement in a placement iterator.
 *
 * Call ghostty_kitty_graphics_placement_next() at least once before
 * calling this function.
 *
 * @param iterator The iterator handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data The data kind to query
 * @param[out] out Pointer to receive the queried value
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the
 *         iterator is NULL or not positioned on a placement
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsPlacementData data,
    void* out);

/**
 * Get multiple data fields from the current placement in a single call.
 *
 * This is an optimization over calling ghostty_kitty_graphics_placement_get()
 * repeatedly, particularly useful in environments with high per-call
 * overhead such as FFI or Cgo.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 * The type of each values[i] pointer must match the output type
 * documented for keys[i].
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
 * @return GHOSTTY_SUCCESS if all queries succeed
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get_multi(
    GhosttyKittyGraphicsPlacementIterator iterator,
    size_t count,
    const GhosttyKittyGraphicsPlacementData* keys,
    void** values,
    size_t* out_written);

/**
 * Compute the grid rectangle occupied by the current placement.
 *
 * Uses the placement's pin, the image dimensions, and the terminal's
 * cell/pixel geometry to calculate the bounding rectangle. Virtual
 * placements (unicode placeholders) return GHOSTTY_NO_VALUE.
 *
 * @param terminal The terminal handle
 * @param image The image handle for this placement's image
 * @param iterator The placement iterator positioned on a placement
 * @param[out] out_selection On success, receives the bounding rectangle
 *             as a selection with rectangle=true
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE for
 *         virtual placements or when Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_rect(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    GhosttySelection* out_selection);

/**
 * Compute the rendered pixel size of the current placement.
 *
 * Takes into account the placement's source rectangle, specified
 * columns/rows, and aspect ratio to calculate the final rendered
 * pixel dimensions.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_width On success, receives the width in pixels
 * @param[out] out_height On success, receives the height in pixels
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE when
 *         Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_pixel_size(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    uint32_t* out_width,
    uint32_t* out_height);

/**
 * Compute the grid cell size of the current placement.
 *
 * Returns the number of columns and rows that the placement occupies
 * in the terminal grid. If the placement specifies explicit columns
 * and rows, those are returned directly; otherwise they are calculated
 * from the pixel size and cell dimensions.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_cols On success, receives the number of columns
 * @param[out] out_rows On success, receives the number of rows
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned, GHOSTTY_NO_VALUE when
 *         Kitty graphics are disabled
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_grid_size(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    uint32_t* out_cols,
    uint32_t* out_rows);

/**
 * Get the top-left cell of the current placement, relative to the
 * viewport.
 *
 * This is for inspecting the storage. To draw, use the render state's
 * image list instead. It positions every image on screen, including
 * virtual placements and placements relative to them, and covers
 * overscan rows. If you draw from both, images are drawn twice. See
 * "Drawing Images" in the @ref kitty_graphics documentation.
 *
 * The row is negative when the top of the placement scrolled above the
 * viewport. For example, an image 4 rows tall that scrolled up by 2
 * rows has a row of -2. Its top 2 rows are above the viewport and its
 * bottom 2 rows are still visible.
 *
 * @param iterator The placement iterator, moved to a placement
 * @param image The image of this placement
 * @param terminal The terminal the storage belongs to
 * @param[out] out_col On success, receives the column
 * @param[out] out_row On success, receives the row, which can be
 *             negative
 * @return GHOSTTY_SUCCESS if any part of the placement is in the
 *         viewport. GHOSTTY_NO_VALUE if it is entirely outside the
 *         viewport, if it is a virtual placement or relative to one, or
 *         if Kitty graphics are disabled at build time.
 *         GHOSTTY_INVALID_VALUE if any handle is NULL or the iterator is
 *         not on a placement.
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_viewport_pos(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    int32_t* out_col,
    int32_t* out_row);

/**
 * Get the resolved source rectangle for the current placement.
 *
 * Applies kitty protocol semantics: a width or height of 0 in the
 * placement means "use the full image dimension", and the resulting
 * rectangle is clamped to the actual image bounds. The returned
 * values are in pixels and are ready to use for texture sampling.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param[out] out_x Source rect x origin in pixels
 * @param[out] out_y Source rect y origin in pixels
 * @param[out] out_width Source rect width in pixels
 * @param[out] out_height Source rect height in pixels
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if any
 *         handle is NULL or the iterator is not positioned
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_source_rect(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    uint32_t* out_x,
    uint32_t* out_y,
    uint32_t* out_width,
    uint32_t* out_height);

/**
 * Get all of the geometry of the current placement in one call.
 *
 * This fills in a GhosttyKittyGraphicsPlacementRenderInfo with the pixel
 * size, grid size, viewport position and source rectangle. Set its
 * `size` with GHOSTTY_INIT_SIZED first.
 *
 * This is for inspecting the storage. To draw, use the render state's
 * image list instead. It gives the same values for every image on
 * screen, including virtual placements and placements relative to them.
 * If you draw from both, images are drawn twice. See "Drawing Images"
 * in the @ref kitty_graphics documentation.
 *
 * The call succeeds even when the placement isn't in the viewport.
 * Check `viewport_visible` before using `viewport_col` and
 * `viewport_row`.
 *
 * @param iterator The placement iterator, moved to a placement
 * @param image The image of this placement
 * @param terminal The terminal the storage belongs to
 * @param[out] out_info Receives the geometry
 * @return GHOSTTY_SUCCESS on success. GHOSTTY_INVALID_VALUE if any
 *         handle or `out_info` is NULL, the iterator is not on a
 *         placement, or `out_info->size` is too small.
 *         GHOSTTY_NO_VALUE if Kitty graphics are disabled at build time.
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_render_info(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    GhosttyKittyGraphicsPlacementRenderInfo* out_info);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_KITTY_GRAPHICS_H */
