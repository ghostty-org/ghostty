/**
 * @file kitty_graphics.h
 *
 * Kitty graphics protocol 
 *
 * See @ref guide-images for a full usage guide.
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

/** @addtogroup kitty_graphics
 *
 * GhosttyKittyGraphics is a handle to the image storage of the active screen,
 * where the terminal keeps every image a program sends with the
 * [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
 *
 * Read it from a terminal with #GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS. Use it to
 * read pixels, play animations, and inspect what the storage holds. It doesn't
 * tell you where to draw. The render state does that.
 *
 * ## Example
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-animation-tick
 *
 * Full program: @ref c-vt-kitty-graphics/src/main.c
 *
 * See @ref guide-images for how to set up, decode PNGs, and draw images.
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
   * GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION. See
   * @ref guide-images-changes.
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
   * doesn't need to check this. See @ref guide-images-placeholders.
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
 * Settable options for ghostty_kitty_graphics_placement_iterator_set().
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real option. ghostty_kitty_graphics_placement_iterator_set()
   * returns GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real option.
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_INVALID = 0,

  /**
   * Only visit placements in the chosen layers.
   *
   * The value is a mask with one bit for each GhosttyImageLayer. Combine
   * the GHOSTTY_IMAGE_LAYER_MASK_* macros with `|` to choose layers. For
   * example, this visits every placement except the ones drawn below the
   * cell backgrounds:
   *
   * @code{.c}
   * uint32_t mask = GHOSTTY_IMAGE_LAYER_MASK_BELOW_TEXT |
   *                 GHOSTTY_IMAGE_LAYER_MASK_ABOVE_TEXT;
   * ghostty_kitty_graphics_placement_iterator_set(
   *     iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER, &mask);
   * @endcode
   *
   * A mask of 0 or a NULL value turns the filter off, and the iterator
   * visits every placement. This is the default. A mask with a bit that
   * matches no layer returns GHOSTTY_INVALID_VALUE and keeps the current
   * filter.
   *
   * Each placement's layer comes from its z-index, using the ranges listed
   * in GhosttyImageLayer. This filter only applies to the storage
   * iterator. To draw images, use the layer the render state reports for
   * each entry (GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER). The render state
   * uses the same ranges and also includes virtual placements, which are
   * always drawn below the text.
   *
   * Input type: const uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER = 1,
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
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
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_INVALID = 0,

  /**
   * The image ID.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_ID = 1,

  /**
   * The image number.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_NUMBER = 2,

  /**
   * Image width in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_WIDTH = 3,

  /**
   * Image height in pixels.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_HEIGHT = 4,

  /**
   * Pixel format of the image. Never GHOSTTY_KITTY_IMAGE_FORMAT_PNG;
   * PNG payloads are decoded to RGBA before storage.
   *
   * Output type: GhosttyKittyImageFormat *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT = 5,

  /**
   * Compression of the image. Always
   * GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE; compressed payloads are
   * inflated before storage.
   *
   * Output type: GhosttyKittyImageCompression *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_COMPRESSION = 6,

  /**
   * The image's pixel data. The string points into memory owned by the
   * terminal and stays valid until the terminal is next modified. Its
   * length is always width * height * bytes per pixel for the reported
   * format.
   *
   * Returns GHOSTTY_NO_VALUE if the image's pixels have not arrived yet.
   * The expected size is still available through
   * GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_EXPECTED_LEN.
   *
   * The data is always fully decoded, uncompressed pixels in the
   * format reported by GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_FORMAT: zlib payloads
   * are inflated and PNG payloads are decoded to RGBA at transmission
   * time, before the image is stored. Consumers can upload this
   * directly to the GPU without any decode step.
   *
   * For an animated image (Kitty graphics animation, actions a=f/a=a)
   * this is the pixel data of the current animation frame. The
   * image's GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION changes whenever the
   * current frame changes, so generation-keyed caches remain
   * coherent.
   *
   * @code{.c}
   * GhosttyString pixels;
   * if (ghostty_kitty_graphics_image_get(
   *         image, GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS, &pixels) ==
   *     GHOSTTY_SUCCESS) {
   *   upload_texture(pixels.ptr, pixels.len);
   * }
   * @endcode
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS = 7,

  /**
   * The size of the image's pixel data in bytes, which is
   * width * height * bytes per pixel for the reported format.
   *
   * This is available even before the pixels arrive, when
   * GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS still returns
   * GHOSTTY_NO_VALUE. In that case the image already counts this many
   * bytes against the storage limit. Once the pixels arrive, this equals
   * the length of GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_EXPECTED_LEN = 8,

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
   * value, and GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS starts returning the
   * pixels. GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION changes when that
   * happens, so read PIXELS again then.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION = 9,

  GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
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
 * See @ref guide-images-drawing.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED() before
 * each call. See @ref sized-structs.
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

/** @name Storage
 * @{
 */

/**
 * Get data from a kitty graphics storage instance.
 *
 * The output pointer must be of the appropriate type for the requested
 * data kind.
 *
 * Returns GHOSTTY_UNSUPPORTED when Kitty graphics are disabled at build time.
 *
 * @param graphics The kitty graphics handle
 * @param data The type of data to extract
 * @param[out] out Pointer to store the extracted data
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_UNSUPPORTED if `data` is
 *         not known to this version of the library or Kitty graphics are
 *         disabled at build time
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
 * @ref GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, and their
 * @ref GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS returns the new frame's pixels.
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
 * @ref guide-images-animation explains how to
 * schedule redraws with the returned time and includes an example.
 *
 * @param graphics The kitty graphics handle
 * @param now_ms The current time in milliseconds
 * @param[out] next_ms Set to the time the next frame is due, in
 *   milliseconds on the same clock as `now_ms`. Only written when the
 *   function returns GHOSTTY_SUCCESS.
 * @return GHOSTTY_SUCCESS if an animation is playing and `next_ms` was
 *   set, GHOSTTY_NO_VALUE if nothing is playing, GHOSTTY_UNSUPPORTED if
 *   Kitty graphics are disabled at build time, GHOSTTY_INVALID_VALUE if
 *   `next_ms` is NULL
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_animation_tick(
    GhosttyKittyGraphics graphics,
    uint64_t now_ms,
    uint64_t* next_ms);

/** @} */

/** @name Images
 * @{
 */

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
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_UNSUPPORTED if `data` is
 *         not known to this version of the library or Kitty graphics are
 *         disabled at build time
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
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_kitty_graphics_image_get() once per key,
 * so use whichever reads better.
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
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_image_get_multi(
    GhosttyKittyGraphicsImage image,
    size_t count,
    const GhosttyKittyGraphicsImageData* keys,
    void** values,
    size_t* out_written);

/** @} */

/** @name Placements
 * @{
 */

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
 * Use GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER to visit only
 * the placements in some layers. ghostty_kitty_graphics_placement_next()
 * then skips every placement outside those layers. By default, the
 * iterator visits every placement.
 *
 * @param iterator The iterator handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param value Pointer to the value. Its type depends on the option. NULL
 *              resets the option to its default.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the value is
 *         out of range, or GHOSTTY_UNSUPPORTED if `option` is not known to
 *         this version of the library or Kitty graphics are disabled at
 *         build time
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
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the iterator is
 *         NULL or not positioned on a placement, or GHOSTTY_UNSUPPORTED if
 *         `data` is not known to this version of the library
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
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_kitty_graphics_placement_get() once per
 * key, so use whichever reads better.
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
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_get_multi(
    GhosttyKittyGraphicsPlacementIterator iterator,
    size_t count,
    const GhosttyKittyGraphicsPlacementData* keys,
    void** values,
    size_t* out_written);

/** @} */

/** @name Placement Geometry
 * @{
 */

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
 *         virtual placements, GHOSTTY_UNSUPPORTED when Kitty graphics are
 *         disabled at build time
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
 *         is NULL or the iterator is not positioned, GHOSTTY_UNSUPPORTED
 *         when Kitty graphics are disabled at build time
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
 *         is NULL or the iterator is not positioned, GHOSTTY_UNSUPPORTED
 *         when Kitty graphics are disabled at build time
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
 * @ref guide-images-drawing.
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
 *         viewport or if it is a virtual placement or relative to one.
 *         GHOSTTY_UNSUPPORTED if Kitty graphics are disabled at build
 *         time.
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
 * If you draw from both, images are drawn twice. See
 * @ref guide-images-drawing.
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
 *         GHOSTTY_UNSUPPORTED if Kitty graphics are disabled at build
 *         time.
 *
 * @ingroup kitty_graphics
 */
GHOSTTY_API GhosttyResult ghostty_kitty_graphics_placement_render_info(
    GhosttyKittyGraphicsPlacementIterator iterator,
    GhosttyKittyGraphicsImage image,
    GhosttyTerminal terminal,
    GhosttyKittyGraphicsPlacementRenderInfo* out_info);

/** @} */

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_KITTY_GRAPHICS_H */
