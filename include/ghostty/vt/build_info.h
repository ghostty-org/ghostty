/**
 * @file build_info.h
 *
 * Build info - query compile-time build configuration of libghostty-vt.
 */

#ifndef GHOSTTY_VT_BUILD_INFO_H
#define GHOSTTY_VT_BUILD_INFO_H

/** @addtogroup build_info
 *
 * Build info is what this copy of the library knows about how it was compiled:
 * its version, its optimization mode, and which features it has.
 *
 * You need this when your program has to adapt to the library it loaded, such
 * as checking for Kitty graphics before you offer images. You don't need a
 * terminal. These values are constant for the lifetime of the process, so you
 * only have to read them once.
 *
 * ## Example
 *
 * @code{.c}
 * bool simd = false;
 * ghostty_build_info(GHOSTTY_BUILD_INFO_SIMD, &simd);
 * @endcode
 *
 * Full program: @ref c-vt-build-info/src/main.c
 *
 * To check the version of the headers rather than the library, see
 * @ref version "Version". To choose what a build contains, see @ref features.
 *
 * @{
 */

#include <stddef.h>
#include <stdbool.h>

#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Build optimization mode.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_OPTIMIZE_DEBUG = 0,
  GHOSTTY_OPTIMIZE_RELEASE_SAFE = 1,
  GHOSTTY_OPTIMIZE_RELEASE_SMALL = 2,
  GHOSTTY_OPTIMIZE_RELEASE_FAST = 3,
  GHOSTTY_OPTIMIZE_MODE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOptimizeMode;

/**
 * Build info data types that can be queried.
 *
 * Each variant documents the expected output pointer type.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_BUILD_INFO_INVALID = 0,

  /**
   * Whether SIMD-accelerated code paths are enabled.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_SIMD = 1,

  /**
   * Whether this build includes the `%kitty_graphics` feature, which
   * provides the Kitty graphics protocol and the `ghostty_kitty_graphics_*`
   * functions. It is always false on targets without an operating system,
   * such as wasm32-freestanding. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_KITTY_GRAPHICS = 2,

  /**
   * Whether tmux control mode support is available.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_TMUX_CONTROL_MODE = 3,

  /**
   * The optimization mode the library was built with.
   *
   * Output type: GhosttyOptimizeMode *
   */
  GHOSTTY_BUILD_INFO_OPTIMIZE = 4,

  /**
   * The full version string (e.g. "1.2.3" or "1.2.3-dev+abcdef").
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_BUILD_INFO_VERSION_STRING = 5,

  /**
   * The major version number.
   *
   * Output type: size_t *
   */
  GHOSTTY_BUILD_INFO_VERSION_MAJOR = 6,

  /**
   * The minor version number.
   *
   * Output type: size_t *
   */
  GHOSTTY_BUILD_INFO_VERSION_MINOR = 7,

  /**
   * The patch version number.
   *
   * Output type: size_t *
   */
  GHOSTTY_BUILD_INFO_VERSION_PATCH = 8,

  /**
   * The pre metadata string (e.g. "alpha", "beta", "dev"). Has zero length if
   * no pre metadata is present.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_BUILD_INFO_VERSION_PRE = 9,

  /**
   * The build metadata string (e.g. commit hash). Has zero length if
   * no build metadata is present.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_BUILD_INFO_VERSION_BUILD = 10,

  /**
   * Whether this build includes the `%snapshot` feature, which provides
   * the `ghostty_snapshot_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_SNAPSHOT = 11,

  /**
   * Whether this build includes the `%formatter` feature, which provides
   * the `ghostty_formatter_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_FORMATTER = 12,

  /**
   * Whether this build includes the `%selection` feature, which provides
   * the `ghostty_terminal_select_*`, `ghostty_terminal_selection_*` and
   * `ghostty_selection_gesture_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_SELECTION = 13,

  /**
   * Whether this build includes the `%search` feature, which provides the
   * `ghostty_search_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_SEARCH = 14,

  /**
   * Whether this build includes the `%render_state` feature, which provides
   * the `ghostty_render_state_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_RENDER_STATE = 15,

  /**
   * Whether this build includes the `%input_encode` feature, which provides
   * the key, mouse, focus and paste encoding functions. See
   * @ref features for the full list.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_INPUT_ENCODE = 16,

  /**
   * Whether this build includes the `%color` feature, which provides the
   * `ghostty_color_*` functions. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_COLOR = 17,

  /**
   * Whether this build includes the `%grid_introspection` feature, which
   * provides the `ghostty_grid_ref_*`, `ghostty_tracked_grid_ref_*`,
   * `ghostty_cell_get*` and `ghostty_row_get*` functions. See
   * @ref features for the full list.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_GRID_INTROSPECTION = 18,

  /**
   * Whether this build includes the `%glyph_protocol` feature, which lets
   * applications register custom glyphs with Ghostty's glyph protocol. It
   * has no functions of its own. See @ref features.
   *
   * Output type: bool *
   */
  GHOSTTY_BUILD_INFO_FEATURE_GLYPH_PROTOCOL = 19,
  GHOSTTY_BUILD_INFO_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyBuildInfo;

/**
 * Query a compile-time build configuration value.
 *
 * You must pass a pointer to the correct output type for the
 * requested data (see GhosttyBuildInfo variants for types).
 *
 * @snippet c-vt-build-info/src/main.c build-info-query
 *
 * Full program: @ref c-vt-build-info/src/main.c
 *
 * @param data The build info field to query
 * @param out Pointer to store the result (type depends on data parameter)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `data` is
 *         GHOSTTY_BUILD_INFO_INVALID or `out` is NULL, or GHOSTTY_UNSUPPORTED
 *         if `data` is not known to this version of the library
 *
 * @ingroup build_info
 */
GHOSTTY_API GhosttyResult ghostty_build_info(GhosttyBuildInfo data, void *out);

/**
 * Get the full version of the library as a string.
 *
 * This is the version of the library your program loaded, which can
 * differ from the GHOSTTY_VT_VERSION of the headers it was compiled
 * against. See @ref version "Version" for when that matters.
 *
 * A release returns its version, such as "1.0.0". A development build
 * also has a pre-release and build suffix, such as "1.1.0-dev+abc1234".
 *
 * This returns the same text as GHOSTTY_BUILD_INFO_VERSION_STRING, but
 * as a null-terminated string that you can pass straight to `printf` or
 * to other languages. To get the version as numbers, use
 * ghostty_build_info() with GHOSTTY_BUILD_INFO_VERSION_MAJOR and the
 * values that follow it.
 *
 * @code
 * printf("Using libghostty-vt %s\n", ghostty_version());
 * @endcode
 *
 * @return The version string. It is never NULL, is owned by the
 *         library, and stays valid for as long as the library is
 *         loaded. Do not free it.
 *
 * @ingroup build_info
 */
GHOSTTY_API const char *ghostty_version(void);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_BUILD_INFO_H */
