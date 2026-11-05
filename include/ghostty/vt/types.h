/**
 * @file types.h
 *
 * Common types, macros, and utilities for libghostty-vt.
 */

#ifndef GHOSTTY_VT_TYPES_H
#define GHOSTTY_VT_TYPES_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>

// Symbol visibility for shared library builds. On Windows, functions
// are exported from the DLL when building and imported when consuming.
// On other platforms with GCC/Clang, functions are marked with default
// visibility so they remain accessible when the library is built with
// -fvisibility=hidden. For static library builds, define GHOSTTY_STATIC
// before including this header to make this a no-op.
#ifndef GHOSTTY_API
#if defined(GHOSTTY_STATIC)
  #define GHOSTTY_API
#elif defined(_WIN32) || defined(_WIN64)
  #ifdef GHOSTTY_BUILD_SHARED
    #define GHOSTTY_API __declspec(dllexport)
  #else
    #define GHOSTTY_API __declspec(dllimport)
  #endif
#elif defined(__GNUC__) && __GNUC__ >= 4
  #define GHOSTTY_API __attribute__((visibility("default")))
#else
  #define GHOSTTY_API
#endif
#endif

/**
 * Mark a function or type as deprecated.
 *
 * A deprecated declaration still works, but it will be removed in a future
 * major release. Code that uses it gets a compiler warning that includes
 * @p msg, so the message should say what to use instead.
 *
 * Put the macro before GHOSTTY_API on the declaration:
 *
 * @code
 * GHOSTTY_DEPRECATED("use ghostty_foo_new() instead")
 * GHOSTTY_API GhosttyResult ghostty_foo_create(GhosttyFoo* out);
 * @endcode
 *
 * A program that calls ghostty_foo_create() then gets a warning like this
 * one from GCC or Clang:
 *
 * @code{.unparsed}
 * warning: 'ghostty_foo_create' is deprecated: use ghostty_foo_new() instead
 * @endcode
 *
 * The macro uses `__attribute__((deprecated))` on GCC and Clang and
 * `__declspec(deprecated)` on MSVC. On other compilers it does nothing.
 *
 * To turn the warnings off while you migrate, pass
 * `-Wno-deprecated-declarations` to GCC or Clang. You can also define
 * GHOSTTY_DEPRECATED yourself before including any libghostty-vt header,
 * and the header keeps your definition:
 *
 * @code
 * #define GHOSTTY_DEPRECATED(msg)
 * #include <ghostty/vt.h>
 * @endcode
 */
#ifndef GHOSTTY_DEPRECATED
#if defined(__GNUC__) || defined(__clang__)
  #define GHOSTTY_DEPRECATED(msg) __attribute__((deprecated(msg)))
#elif defined(_MSC_VER)
  #define GHOSTTY_DEPRECATED(msg) __declspec(deprecated(msg))
#else
  #define GHOSTTY_DEPRECATED(msg)
#endif
#endif

/**
 * Enum int-sizing helpers.
 *
 * The Zig side backs all C enums with c_int, so the C declarations
 * must use int as their underlying type to maintain ABI compatibility.
 *
 * In C++11 and later and in C23, GHOSTTY_ENUM_TYPED expands to `: int`,
 * which sets the enum's type to int directly.
 *
 * C before C23 has no way to set an enum's type. Clang and GCC 13+ accept
 * `: int` there as an extension, but `-Wpedantic` warns about it, so the
 * macro expands to nothing in these modes. This keeps the headers free of
 * warnings under `-std=c11 -Wpedantic`.
 *
 * Without `: int`, the C compiler picks a type that can hold every value
 * of the enum (C11 §6.7.2.2). To make sure that type is as large as int,
 * every enum ends with a sentinel set to INT_MAX. The compiler still
 * chooses the exact type, and whether it is signed.
 *
 * INT_MAX is used rather than a fixed constant like 0xFFFFFFFF
 * because enum constants must have type int in pre-C23 C. Values above
 * INT_MAX are a constraint violation there; compilers that accept them
 * may interpret them as negative values via two's complement, which can
 * collide with legitimate negative enum values.
 *
 * Usage:
 * @code
 * typedef enum GHOSTTY_ENUM_TYPED {
 *     FOO_A = 0,
 *     FOO_B = 1,
 *     FOO_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
 * } Foo;
 * @endcode
 */
#if defined(__cplusplus) && \
    (__cplusplus >= 201103L || (defined(_MSC_VER) && _MSC_VER >= 1700))
#define GHOSTTY_ENUM_TYPED : int
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L
#define GHOSTTY_ENUM_TYPED : int
#else
#define GHOSTTY_ENUM_TYPED
#endif
#define GHOSTTY_ENUM_MAX_VALUE INT_MAX

/**
 * Result codes for libghostty-vt operations.
 *
 * Functions that can fail return one of these codes. GHOSTTY_SUCCESS is
 * zero and every error is negative, so `result < 0` tests for any error.
 *
 * Functions that read or write values by key, such as
 * ghostty_terminal_get(), return GHOSTTY_UNSUPPORTED for a key that this
 * version of the library does not know. See @ref keys_sec for how to use
 * that to support older versions of the library. Functions of an
 * optional feature that this build leaves out return it too. See
 * @ref features_sec.
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /** Operation completed successfully */
    GHOSTTY_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_OUT_OF_MEMORY = -1,
    /**
     * An argument is not valid.
     *
     * For example, a NULL pointer where a value is required, an enum value
     * that is out of range, or a sized struct whose size is too small.
     * When a key is involved, this means the library knows the key but a
     * value passed with it is wrong. Compare GHOSTTY_UNSUPPORTED.
     */
    GHOSTTY_INVALID_VALUE = -2,
    /** Operation failed because the provided buffer was too small */
    GHOSTTY_OUT_OF_SPACE = -3,
    /** The requested value has no value */
    GHOSTTY_NO_VALUE = -4,
    /** Operation failed while reading from or writing to external I/O */
    GHOSTTY_IO_ERROR = -5,
    /** Operation failed because encoded input exceeded a configured limit */
    GHOSTTY_LIMIT_EXCEEDED = -6,
    /**
     * Operation was rejected by a safety check (e.g. pasted text that could
     * inject commands). Nothing was done. Confirm with the user and retry
     * with the operation's allow flag set.
     */
    GHOSTTY_REJECTED = -7,
    /**
     * This library cannot do what was asked.
     *
     * Returned by the functions that read or write values by key when the
     * key is newer than the library. Nothing is read or written. This
     * usually means the program was built with a newer header than the
     * library it is running with. Check for it to fall back gracefully, as
     * shown in @ref keys_compat_sec.
     *
     * Also returned by every function of an optional feature that this
     * build leaves out. For example, ghostty_snapshot_encode() returns it
     * when the library was built without the `%snapshot` feature. See
     * @ref features_sec.
     */
    GHOSTTY_UNSUPPORTED = -8,
    GHOSTTY_RESULT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyResult;

/* ---- Opaque handles ---- */

/**
 * Opaque handle to a terminal instance.
 *
 * @ingroup terminal
 */
typedef struct GhosttyTerminalImpl* GhosttyTerminal;

/**
 * Opaque handle to an incremental terminal snapshot decoder.
 *
 * @ingroup snapshot
 */
typedef struct GhosttySnapshotDecoderImpl* GhosttySnapshotDecoder;

/**
 * Opaque handle to a tracked grid reference.
 *
 * A tracked grid reference is owned by the caller and must be freed with
 * ghostty_tracked_grid_ref_free(). If the terminal that created it is freed
 * first, the handle remains valid only for tracked-grid-ref APIs: it reports no
 * value and can still be freed.
 *
 * @ingroup grid_ref
 */
typedef struct GhosttyTrackedGridRefImpl* GhosttyTrackedGridRef;

/**
 * Opaque handle to a Kitty graphics image storage.
 *
 * Obtained via ghostty_terminal_get() with
 * GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS. The pointer is borrowed from
 * the terminal and remains valid until the next mutating terminal call
 * (e.g. ghostty_terminal_vt_write() or ghostty_terminal_reset()).
 *
 * @ingroup kitty_graphics
 */
typedef struct GhosttyKittyGraphicsImpl* GhosttyKittyGraphics;

/**
 * Opaque handle to a Kitty graphics image.
 *
 * Obtained via ghostty_kitty_graphics_image() with an image ID. The
 * pointer is borrowed from the storage and remains valid until the next
 * mutating terminal call.
 *
 * @ingroup kitty_graphics
 */
typedef const struct GhosttyKittyGraphicsImageImpl* GhosttyKittyGraphicsImage;

/**
 * Opaque handle to a Kitty graphics placement iterator.
 *
 * @ingroup kitty_graphics
 */
typedef struct GhosttyKittyGraphicsPlacementIteratorImpl* GhosttyKittyGraphicsPlacementIterator;

/**
 * Opaque handle to a render state instance.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateImpl* GhosttyRenderState;

/**
 * Opaque handle to a render-state row iterator.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateRowIteratorImpl* GhosttyRenderStateRowIterator;

/**
 * Opaque handle to render-state row cells.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateRowCellsImpl* GhosttyRenderStateRowCells;

/**
 * Opaque handle to an iterator over the image placements of a render
 * state.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateImageIteratorImpl* GhosttyRenderStateImageIterator;

/**
 * Opaque handle to a terminal search.
 *
 * A search is bound to the terminal it was created with. It borrows the
 * terminal, so it never frees it, and the search must be freed with
 * ghostty_search_free(). If the terminal is freed first, the search
 * detects this: calls that need the terminal fail cleanly and the
 * search can still be freed.
 *
 * @ingroup search
 */
typedef struct GhosttySearchImpl* GhosttySearch;

/**
 * Opaque handle to an SGR parser instance.
 *
 * This handle represents an SGR (Select Graphic Rendition) parser that can
 * be used to parse SGR sequences and extract individual text attributes.
 *
 * @ingroup sgr
 */
typedef struct GhosttySgrParserImpl* GhosttySgrParser;

/**
 * Opaque handle to a formatter instance.
 *
 * @ingroup formatter
 */
typedef struct GhosttyFormatterImpl* GhosttyFormatter;

/**
 * Opaque handle to an OSC parser instance.
 *
 * This handle represents an OSC (Operating System Command) parser that can
 * be used to parse the contents of OSC sequences.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscParserImpl* GhosttyOscParser;

/**
 * Opaque handle to a single OSC command.
 *
 * This handle represents a parsed OSC (Operating System Command) command.
 * The command can be queried for its type and associated data.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscCommandImpl* GhosttyOscCommand;

/* ---- Common value types ---- */

/**
 * Terminal content output format.
 *
 * @ingroup formatter
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Plain text (no escape sequences). */
  GHOSTTY_FORMATTER_FORMAT_PLAIN = 0,

  /** VT sequences preserving colors, styles, URLs, etc. */
  GHOSTTY_FORMATTER_FORMAT_VT = 1,

  /** HTML with inline styles. */
  GHOSTTY_FORMATTER_FORMAT_HTML = 2,
  GHOSTTY_FORMATTER_FORMAT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyFormatterFormat;

/**
 * The shape of the cursor.
 *
 * Programs change the cursor's shape with the DECSCUSR escape sequence
 * (CSI Ps SP q). Set the shape that DECSCUSR 0 restores with
 * GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE. Read the shape to draw with
 * GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Bar cursor (DECSCUSR 5, 6). */
  GHOSTTY_CURSOR_STYLE_BAR = 0,

  /** Block cursor (DECSCUSR 1, 2). */
  GHOSTTY_CURSOR_STYLE_BLOCK = 1,

  /** Underline cursor (DECSCUSR 3, 4). */
  GHOSTTY_CURSOR_STYLE_UNDERLINE = 2,

  /** Hollow block cursor. */
  GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW = 3,
  GHOSTTY_CURSOR_STYLE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyCursorStyle;

/**
 * Where an image is drawn relative to the terminal's text.
 *
 * Draw each frame from the bottom up, in this order:
 *
 * 1. Images in GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND.
 * 2. Cell background colors.
 * 3. Images in GHOSTTY_IMAGE_LAYER_BELOW_TEXT.
 * 4. Text.
 * 5. Images in GHOSTTY_IMAGE_LAYER_ABOVE_TEXT.
 *
 * Within a layer, draw images in order of their z-index, lowest first.
 *
 * A Kitty graphics placement's layer comes from its z-index. Each value
 * below lists its z-index range. For example, a placement with z-index -1
 * is in GHOSTTY_IMAGE_LAYER_BELOW_TEXT.
 *
 * The render state reports each image's layer with
 * GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER. To visit only some layers with
 * the Kitty graphics placement iterator, build a mask from the
 * GHOSTTY_IMAGE_LAYER_MASK_* macros and set it with
 * GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER.
 *
 * @ingroup render
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Below the cell background colors. Kitty z-index below INT32_MIN / 2
   *  (-1,073,741,824). */
  GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND = 0,

  /** Above the cell background colors and below the text. Kitty z-index
   *  from INT32_MIN / 2 up to -1. */
  GHOSTTY_IMAGE_LAYER_BELOW_TEXT = 1,

  /** Above the text. Kitty z-index 0 and above. */
  GHOSTTY_IMAGE_LAYER_ABOVE_TEXT = 2,
  GHOSTTY_IMAGE_LAYER_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyImageLayer;

/**
 * Mask bit for GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND.
 *
 * The GHOSTTY_IMAGE_LAYER_MASK_* macros select layers in a filter such
 * as GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPT_LAYER. Combine them
 * with `|`.
 */
#define GHOSTTY_IMAGE_LAYER_MASK_BELOW_BACKGROUND \
  (1u << GHOSTTY_IMAGE_LAYER_BELOW_BACKGROUND)

/** Mask bit for GHOSTTY_IMAGE_LAYER_BELOW_TEXT. */
#define GHOSTTY_IMAGE_LAYER_MASK_BELOW_TEXT \
  (1u << GHOSTTY_IMAGE_LAYER_BELOW_TEXT)

/** Mask bit for GHOSTTY_IMAGE_LAYER_ABOVE_TEXT. */
#define GHOSTTY_IMAGE_LAYER_MASK_ABOVE_TEXT \
  (1u << GHOSTTY_IMAGE_LAYER_ABOVE_TEXT)

/**
 * A borrowed byte string (pointer + length).
 *
 * The memory is not owned by this struct. The pointer is only valid
 * for the lifetime documented by the API that produces or consumes it.
 * Empty strings produced by the library have a non-NULL pointer to valid
 * storage.
 */
typedef struct {
  /** Pointer to the string bytes. */
  const uint8_t* ptr;

  /** Length of the string in bytes. */
  size_t len;
} GhosttyString;

/**
 * A caller-provided byte buffer.
 *
 * APIs that write to this type use `len` for the number of bytes written on
 * GHOSTTY_SUCCESS and the required byte capacity on GHOSTTY_OUT_OF_SPACE.
 */
typedef struct {
  /** Destination buffer for bytes. May be NULL when cap is 0 to query required size. */
  uint8_t* ptr;

  /** Capacity of ptr in bytes. */
  size_t cap;

  /** Bytes written on success, or required byte capacity on GHOSTTY_OUT_OF_SPACE. */
  size_t len;
} GhosttyBuffer;

/**
 * A surface-space position in pixels.
 *
 * This is not a terminal grid coordinate. It represents an x/y position in the
 * rendered surface coordinate space, with (0, 0) at the top-left of the
 * surface.
 */
typedef struct {
  /** X position in surface pixels. */
  double x;

  /** Y position in surface pixels. */
  double y;
} GhosttySurfacePosition;

/**
 * A borrowed list of Unicode scalar values.
 *
 * Values are encoded as uint32_t scalar values. The memory is not owned by this
 * struct. The pointer is only valid for the lifetime documented by the API that
 * consumes or produces it.
 *
 * APIs may document special handling for NULL + len 0, such as “use defaults”.
 */
typedef struct {
  /** Pointer to Unicode scalar values. */
  const uint32_t* ptr;

  /** Number of entries in ptr. */
  size_t len;
} GhosttyCodepoints;

/**
 * A buffer you provide for the library to fill with Unicode codepoints.
 *
 * Set ptr to an array of uint32_t and cap to the number of elements it
 * holds. The library writes up to cap codepoints and sets len to the total
 * number available. When len is greater than cap, the call returns
 * GHOSTTY_OUT_OF_SPACE and ptr holds only the first cap codepoints.
 *
 * To learn the count without copying anything, set ptr to NULL and cap to
 * 0, then read len.
 *
 * This struct has a frozen layout and will not gain fields in future
 * versions.
 */
typedef struct {
  /** Where codepoints are written. May be NULL when cap is 0. */
  uint32_t* ptr;

  /** Number of uint32_t elements ptr can hold. */
  size_t cap;

  /** Set by the library to the total number of codepoints, whether or not
   *  they all fit. */
  size_t len;
} GhosttyCodepointBuffer;

/**
 * Initialize a sized struct to zero and set its size field.
 *
 * Sized structs use a `size` field as the first member for ABI
 * compatibility. This macro zero-initializes the struct and sets the
 * size field to `sizeof(type)`, which allows the library to detect
 * which version of the struct the caller was compiled against.
 *
 * @param type The struct type to initialize
 * @return A zero-initialized struct with the size field set
 *
 * Example:
 * @code
 * GhosttyTerminalSelectLineOptions opts =
 *     GHOSTTY_INIT_SIZED(GhosttyTerminalSelectLineOptions);
 * opts.ref = ref;
 * @endcode
 */
#ifdef __cplusplus
#define GHOSTTY_INIT_SIZED(type)                                      \
  ([]() noexcept {                                                    \
    type value{};                                                     \
    value.size = sizeof(value);                                       \
    return value;                                                     \
  }())
#else
#define GHOSTTY_INIT_SIZED(type) \
  ((type){ .size = sizeof(type) })
#endif

/**
 * Initialize a sized struct at runtime.
 *
 * This does the same thing as GHOSTTY_INIT_SIZED(). It sets every byte of
 * the struct to zero and then stores `size` in the struct's `size` field.
 * It is meant for language bindings that cannot use a C macro. Pass the
 * size of the struct as your binding lays it out, which is `sizeof` of the
 * struct in the header the binding was built from. See @ref sized_sec.
 *
 * @code{.c}
 * GhosttyRenderStateCursor cursor;
 * ghostty_sized_init(&cursor, sizeof(cursor));
 * @endcode
 *
 * If `ptr` is NULL, or `size` is too small to hold the `size` field
 * itself, this function does nothing.
 *
 * @param ptr The struct to initialize, or NULL
 * @param size The size of the struct in bytes
 */
GHOSTTY_API void ghostty_sized_init(void* ptr, size_t size);

/**
 * Return the versioned libghostty-vt C type manifest for the current target.
 *
 * The manifest defines all the public types available in the linked
 * build. The types contain their layouts, enum values, union fields, and more.
 *
 * Language bindings, such as WebAssembly hosts, should obtain offsets,
 * sizes, alignments, array shapes, enum constants, and tagged-union arms from
 * this manifest rather than hardcoding them. Consumers should reject unknown
 * schema versions and verify the descriptors they require at initialization.
 *
 * Packed type descriptors define fields using `lsb` and `width`. `lsb` is
 * relative to bit zero of the containing numerical value; for nested packed
 * layouts it is relative to the immediate containing field. Tagged packed
 * unions select an inline arm layout using the named tag field. These layouts
 * describe the current linked build and are not a cross-version stability
 * promise.
 *
 * Every key enum also has a `keys` object. A key enum is the enum that a
 * `_get`, `_set` or `_get_multi` function takes to pick a value, such as
 * GhosttyTerminalData or GhosttyTerminalOption. Each key lists its
 * `direction` and the `type` that its `void *` value points at:
 *
 * - An `"out"` key is read. Pass a pointer to storage of `type`, and the
 *   library writes the value there.
 * - An `"in"` key is set. Pass a pointer to a value of `type`, and the
 *   library reads it. ghostty_formatter_get() also takes these keys, and
 *   writes a value of the same `type`.
 * - A `type` of `opaque` is an untyped pointer, such as userdata. Pass the
 *   pointer itself.
 * - A `type` that names a `callback` descriptor sets a callback. Pass the
 *   function pointer itself, not a pointer to it.
 *
 * Callback descriptors, such as GhosttyTerminalBellFn, describe a function
 * pointer typedef. `params` lists the parameter types in order and `return`
 * gives the return type. Both use the same type references as struct fields.
 *
 * The formal format is defined by the
 * <a href="types.schema.json">libghostty-vt ABI manifest JSON Schema</a>.
 *
 * Example (abbreviated):
 * @code{.json}
 * {
 *   "schema": 1,
 *   "abi": {
 *     "target": "wasm32", "os": "freestanding", "environment": "none",
 *     "pointer_size": 4, "usize_size": 4, "max_alignment": 16,
 *     "endian": "little"
 *   },
 *   "types": {
 *     "GhosttyRenderStateData": {
 *       "kind": "enum", "size": 4, "align": 4,
 *       "underlying": "i32", "prefix": "GHOSTTY_RENDER_STATE_DATA_",
 *       "values": { "INVALID": 0, "DIRTY": 3, "MAX_VALUE": 2147483647 },
 *       "keys": {
 *         "DIRTY": { "direction": "out", "type": "GhosttyRenderStateDirty" }
 *       }
 *     },
 *     "GhosttyTerminalBellFn": {
 *       "kind": "callback", "size": 4, "align": 4,
 *       "params": [
 *         { "type": "GhosttyTerminal" },
 *         { "type": "pointer", "elem": "opaque", "const": false,
 *           "nullable": true }
 *       ],
 *       "return": { "type": "void" }
 *     },
 *     "GhosttyStyleColor": {
 *       "kind": "struct", "size": 4, "align": 1,
 *       "fields": {
 *         "tag": { "offset": 0, "size": 1,
 *                  "type": "GhosttyStyleColorTag" },
 *         "value": { "offset": 1, "size": 3,
 *                    "type": "GhosttyStyleColorValue", "tag": "tag",
 *                    "arms": { "NONE": null, "PALETTE": "palette",
 *                              "RGB": "rgb" } }
 *       }
 *     }
 *   }
 * }
 * @endcode
 *
 * The returned pointer is valid for the lifetime of the process.
 *
 * @return Pointer to the null-terminated JSON string.
 */
GHOSTTY_API const char *ghostty_type_json(void);

#endif /* GHOSTTY_VT_TYPES_H */
