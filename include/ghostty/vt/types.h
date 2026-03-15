/**
 * @file types.h
 *
 * Common types, macros, and utilities for libghostty-vt.
 */

#ifndef GHOSTTY_VT_TYPES_H
#define GHOSTTY_VT_TYPES_H

/**
 * Result codes for libghostty-vt operations.
 */
typedef enum {
    /** Operation completed successfully */
    GHOSTTY_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_OUT_OF_MEMORY = -1,
    /** Operation failed due to invalid value */
    GHOSTTY_INVALID_VALUE = -2,
    /** Operation failed because the provided buffer was too small */
    GHOSTTY_OUT_OF_SPACE = -3,
} GhosttyResult;

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
 * GhosttyFormatterTerminalOptions opts = GHOSTTY_INIT_SIZED(GhosttyFormatterTerminalOptions);
 * opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
 * opts.trim = true;
 * @endcode
 */
#define GHOSTTY_INIT_SIZED(type) \
  ((type){ .size = sizeof(type) })

#endif /* GHOSTTY_VT_TYPES_H */
