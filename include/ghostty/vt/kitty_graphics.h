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
 * API for inspecting images and placements stored via the
 * [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
 *
 * The central object is @ref GhosttyKittyGraphics, an opaque handle to
 * the image storage associated with a terminal's active screen. From it
 * you can iterate over placements and look up individual images.
 *
 * ## Obtaining a KittyGraphics Handle
 *
 * A @ref GhosttyKittyGraphics handle is obtained from a terminal via
 * ghostty_terminal_get() with @ref GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS.
 * The handle is borrowed from the terminal and remains valid until the
 * next mutating terminal call (e.g. ghostty_terminal_vt_write() or
 * ghostty_terminal_reset()).
 *
 * Before images can be stored, Kitty graphics must be enabled on the
 * terminal by setting a non-zero storage limit with
 * @ref GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, and a PNG
 * decoder callback must be installed via ghostty_sys_set() with
 * @ref GHOSTTY_SYS_OPT_DECODE_PNG.
 *
 * @snippet c-vt-kitty-graphics/src/main.c kitty-graphics-decode-png
 *
 * ## Iterating Placements
 *
 * Placements are inspected through a @ref GhosttyKittyGraphicsPlacementIterator.
 * The typical workflow is:
 *
 *   1. Create an iterator with ghostty_kitty_graphics_placement_iterator_new().
 *   2. Populate it from the storage with ghostty_kitty_graphics_get() using
 *      @ref GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR.
 *   3. Optionally filter by z-layer with
 *      ghostty_kitty_graphics_placement_iterator_set().
 *   4. Advance with ghostty_kitty_graphics_placement_next() and read
 *      per-placement data with ghostty_kitty_graphics_placement_get().
 *   5. For each placement, look up its image with
 *      ghostty_kitty_graphics_image() to access pixel data and dimensions.
 *   6. Free the iterator with ghostty_kitty_graphics_placement_iterator_free().
 *
 * ## Looking Up Images
 *
 * Given an image ID (obtained from a placement via
 * @ref GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID), call
 * ghostty_kitty_graphics_image() to get a @ref GhosttyKittyGraphicsImage
 * handle. From this handle, ghostty_kitty_graphics_image_get() provides
 * the image dimensions, pixel format, compression, and a borrowed pointer
 * to the raw pixel data.
 *
 * ## Rendering Helpers
 *
 * Several functions assist with rendering a placement:
 *
 * - ghostty_kitty_graphics_placement_pixel_size() — rendered pixel
 *   dimensions accounting for source rect and aspect ratio.
 * - ghostty_kitty_graphics_placement_grid_size() — number of grid
 *   columns and rows the placement occupies.
 * - ghostty_kitty_graphics_placement_viewport_pos() — viewport-relative
 *   grid position (may be negative for partially scrolled placements).
 * - ghostty_kitty_graphics_placement_source_rect() — resolved source
 *   rectangle in pixels, clamped to image bounds.
 * - ghostty_kitty_graphics_placement_rect() — bounding rectangle as a
 *   @ref GhosttySelection.
 *
 * ## Lifetime and Thread Safety
 *
 * All handles borrowed from the terminal (GhosttyKittyGraphics,
 * GhosttyKittyGraphicsImage) are invalidated by any mutating terminal
 * call. The placement iterator is independently owned and must be freed
 * by the caller, but the data it yields is only valid while the
 * underlying terminal is not mutated.
 *
 * ## Example
 *
 * The following example creates a terminal, sends a Kitty graphics
 * image, then iterates placements and prints image metadata:
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
   * Whether this is a virtual placement (unicode placeholder).
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
 * Z-layer classification for kitty graphics placements.
 *
 * Based on the kitty protocol z-index conventions:
 * - BELOW_BG:   z < INT32_MIN/2  (drawn below cell background)
 * - BELOW_TEXT:  INT32_MIN/2 <= z < 0  (above background, below text)
 * - ABOVE_TEXT:  z >= 0  (above text)
 * - ALL:         no filtering (current behavior)
 *
 * @ingroup kitty_graphics
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_KITTY_PLACEMENT_LAYER_ALL = 0,
  GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG = 1,
  GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT = 2,
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
   * Set the z-layer filter for the iterator.
   *
   * Input type: GhosttyKittyPlacementLayer *
   */
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER = 0,
  GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsPlacementIteratorOption;

/**
 * Pixel format of a Kitty graphics image.
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
   * Pixel format of the image.
   *
   * Output type: GhosttyKittyImageFormat *
   */
  GHOSTTY_KITTY_IMAGE_DATA_FORMAT = 5,

  /**
   * Compression of the image.
   *
   * Output type: GhosttyKittyImageCompression *
   */
  GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION = 6,

  /**
   * Borrowed pointer to the raw pixel data. Valid as long as the
   * underlying terminal is not mutated.
   *
   * Output type: const uint8_t **
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR = 7,

  /**
   * Length of the raw pixel data in bytes.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN = 8,

  GHOSTTY_KITTY_IMAGE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyGraphicsImageData;

/**
 * Combined rendering geometry for a placement in a single sized struct.
 *
 * Combines the results of ghostty_kitty_graphics_placement_pixel_size(),
 * ghostty_kitty_graphics_placement_grid_size(),
 * ghostty_kitty_graphics_placement_viewport_pos(), and
 * ghostty_kitty_graphics_placement_source_rect() into one call. This is
 * an optimization over calling those four functions individually,
 * particularly useful in environments with high per-call overhead such
 * as FFI or Cgo.
 *
 * This struct uses the sized-struct ABI pattern. Initialize with
 * GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo) before calling
 * ghostty_kitty_graphics_placement_render_info().
 *
 * @ingroup kitty_graphics
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyKittyGraphicsPlacementRenderInfo). */
  size_t size;
  /** Rendered width in pixels. */
  uint32_t pixel_width;
  /** Rendered height in pixels. */
  uint32_t pixel_height;
  /** Number of grid columns the placement occupies. */
  uint32_t grid_cols;
  /** Number of grid rows the placement occupies. */
  uint32_t grid_rows;
  /** Viewport-relative column (may be negative for partially visible placements). */
  int32_t viewport_col;
  /** Viewport-relative row (may be negative for partially visible placements). */
  int32_t viewport_row;
  /** False when the placement is fully off-screen or virtual. */
  bool viewport_visible;
  /** Resolved source rectangle x origin in pixels. */
  uint32_t source_x;
  /** Resolved source rectangle y origin in pixels. */
  uint32_t source_y;
  /** Resolved source rectangle width in pixels. */
  uint32_t source_width;
  /** Resolved source rectangle height in pixels. */
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
 * Get the viewport-relative grid position of the current placement.
 *
 * Converts the placement's internal pin to viewport-relative column and
 * row coordinates. The returned coordinates represent the top-left
 * corner of the placement in the viewport's grid coordinate space.
 *
 * The row value can be negative when the placement's origin has
 * scrolled above the top of the viewport. For example, a 4-row
 * image that has scrolled up by 2 rows returns row=-2, meaning
 * its top 2 rows are above the visible area but its bottom 2 rows
 * are still on screen. Embedders should use these coordinates
 * directly when computing the destination rectangle for rendering;
 * the embedder is responsible for clipping the portion of the image
 * that falls outside the viewport.
 *
 * Returns GHOSTTY_SUCCESS for any placement that is at least
 * partially visible in the viewport. Returns GHOSTTY_NO_VALUE when
 * the placement is completely outside the viewport (its bottom edge
 * is above the viewport or its top edge is at or below the last
 * viewport row), or when the placement is a virtual (unicode
 * placeholder) placement.
 *
 * @param iterator The placement iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_col On success, receives the viewport-relative column
 * @param[out] out_row On success, receives the viewport-relative row
 *             (may be negative for partially visible placements)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if fully
 *         off-screen or virtual, GHOSTTY_INVALID_VALUE if any handle
 *         is NULL or the iterator is not positioned
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
 * Get all rendering geometry for a placement in a single call.
 *
 * Combines pixel size, grid size, viewport position, and source
 * rectangle into one struct. Initialize with
 * GHOSTTY_INIT_SIZED(GhosttyKittyGraphicsPlacementRenderInfo).
 *
 * When viewport_visible is false, the placement is fully off-screen
 * or is a virtual placement; viewport_col and viewport_row may
 * contain meaningless values in that case.
 *
 * @param iterator The iterator positioned on a placement
 * @param image The image handle for this placement's image
 * @param terminal The terminal handle
 * @param[out] out_info Pointer to receive the rendering geometry
 * @return GHOSTTY_SUCCESS on success
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
