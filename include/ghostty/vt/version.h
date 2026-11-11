/**
 * @file version.h
 *
 * Version - the version of the libghostty-vt headers.
 */

#ifndef GHOSTTY_VT_VERSION_H
#define GHOSTTY_VT_VERSION_H

/** @addtogroup version
 *
 * libghostty-vt has two versions you may care about: the version of the headers
 * your program compiled against, and the version of the library it loads when
 * it runs.
 *
 * The macros here describe the headers. ghostty_version() and
 * ghostty_build_info() report the library. These are usually the same. They can
 * differ when a program compiled against one release runs on a system with
 * another release installed. A library with the same major version works
 * as long as it is at least as new as the headers.
 *
 * ## Example
 *
 * @snippet c-vt-build-info/src/main.c version-check
 *
 * Full program: @ref c-vt-build-info/src/main.c
 *
 * See @ref stability for what each release may break, and
 * @ref stability-check for how to check the library when your program starts.
 *
 * @{
 */

/** The major version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_MAJOR 1

/** The minor version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_MINOR 0

/** The patch version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_PATCH 1

/**
 * The version of the libghostty-vt headers as a string, such as "1.0.0".
 *
 * This is always three numbers separated by dots. It never has a
 * pre-release or build suffix such as "-dev". Use ghostty_version() for
 * the full version of the library.
 *
 * Builds made between releases use the number of the release they are
 * working towards. For example, a development build before 1.1.0 sets
 * GHOSTTY_VT_VERSION to "1.1.0", while ghostty_version() returns the
 * full version, such as "1.1.0-dev+abc1234".
 *
 * The CMake package and the pkg-config file installed with
 * libghostty-vt carry the same version, and are the easiest way to check
 * it from a build system. This header contains only macros and includes
 * no other files, so a build system can also read it directly.
 */
#define GHOSTTY_VT_VERSION "1.0.1"

/**
 * True if the headers are version maj.min.pat or newer.
 *
 * This works in `#if` directives as well as in regular code:
 *
 * @code
 * #if GHOSTTY_VT_VERSION_AT_LEAST(1, 1, 0)
 *   // Code that uses functions added in 1.1.0.
 * #endif
 * @endcode
 *
 * @param maj The major version to compare against
 * @param min The minor version to compare against
 * @param pat The patch version to compare against
 */
#define GHOSTTY_VT_VERSION_AT_LEAST(maj, min, pat)                   \
  (GHOSTTY_VT_VERSION_MAJOR > (maj) ||                               \
   (GHOSTTY_VT_VERSION_MAJOR == (maj) &&                             \
    (GHOSTTY_VT_VERSION_MINOR > (min) ||                             \
     (GHOSTTY_VT_VERSION_MINOR == (min) &&                           \
      GHOSTTY_VT_VERSION_PATCH >= (pat)))))

/** @} */

#endif /* GHOSTTY_VT_VERSION_H */
