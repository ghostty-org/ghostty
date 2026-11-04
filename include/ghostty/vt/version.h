/**
 * @file version.h
 *
 * Version - the version of the libghostty-vt headers.
 */

#ifndef GHOSTTY_VT_VERSION_H
#define GHOSTTY_VT_VERSION_H

/** @defgroup version Version
 *
 * Check which version of libghostty-vt you are using.
 *
 * libghostty-vt has two versions you may care about:
 *
 * - The version of the headers, which is fixed when your program is
 *   compiled. The macros in this file describe it.
 * - The version of the library your program loads when it runs.
 *   ghostty_version() and ghostty_build_info() report it.
 *
 * These are usually the same. They can differ when a program compiled
 * against one release runs on a system with another release installed.
 *
 * ## Compatibility
 *
 * Until 1.0, any 0.N release may change the ABI. A program compiled
 * against the 0.1 headers may not work with a 0.2 library, so the minor
 * versions must match.
 *
 * From 1.0, a release that changes the ABI increases the major version
 * and changes the name of the shared library (its SONAME, such as
 * `libghostty-vt.so.1`). The system will not load a library with a
 * different major version, so a program compiled against 1.x never runs
 * against 2.x by accident. Minor and patch releases only add to the ABI.
 *
 * ## Checking the Version at Compile Time
 *
 * Use GHOSTTY_VT_VERSION_AT_LEAST() to require a minimum version, or to
 * use newer functions only when the headers provide them:
 *
 * @snippet c-vt-build-info/src/main.c version-check
 *
 * ## Checking the Library at Runtime
 *
 * Every 0.x release has the same shared library name, so the system
 * will load a 0.2 library for a program compiled against 0.1. To catch
 * this, compare the version of the library with the version of the
 * headers when your program starts:
 *
 * @snippet c-vt-build-info/src/main.c version-compatible
 *
 * ## Development Builds
 *
 * Builds made between releases use the number of the release they are
 * working towards. For example, a development build before 0.2.0 sets
 * GHOSTTY_VT_VERSION to "0.2.0", while ghostty_version() returns the
 * full version, such as "0.2.0-dev+abc1234".
 *
 * ## Build Systems
 *
 * The CMake package and the pkg-config file installed with
 * libghostty-vt carry the same version, and are the easiest way to check
 * it from a build system. This header contains only macros and includes
 * no other files, so a build system can also read it directly.
 *
 * @{
 */

/** The major version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_MAJOR 0

/** The minor version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_MINOR 1

/** The patch version of the libghostty-vt headers. */
#define GHOSTTY_VT_VERSION_PATCH 0

/**
 * The version of the libghostty-vt headers as a string, such as "0.1.0".
 *
 * This is always three numbers separated by dots. It never has a
 * pre-release or build suffix such as "-dev". Use ghostty_version() for
 * the full version of the library.
 */
#define GHOSTTY_VT_VERSION "0.1.0"

/**
 * True if the headers are version maj.min.pat or newer.
 *
 * This works in `#if` directives as well as in regular code:
 *
 * @code
 * #if GHOSTTY_VT_VERSION_AT_LEAST(0, 2, 0)
 *   // Code that uses functions added in 0.2.0.
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
