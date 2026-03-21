/**
 * @file paste.h
 *
 * Paste utilities - validate and encode paste data for terminal input.
 */

#ifndef GHOSTTY_VT_PASTE_H
#define GHOSTTY_VT_PASTE_H

/** @defgroup paste Paste Utilities
 *
 * Utilities for validating paste data safety.
 *
 * ## Basic Usage
 *
 * Use ghostty_paste_is_safe() to check if paste data contains potentially
 * dangerous sequences before sending it to the terminal.
 *
 * ## Example
 *
 * @snippet c-vt-paste/src/main.c paste-safety
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Check if paste data is safe to paste into the terminal.
 *
 * Data is considered unsafe if it contains:
 * - Newlines (`\n`) which can inject commands
 * - The bracketed paste end sequence (`\x1b[201~`) which can be used
 *   to exit bracketed paste mode and inject commands
 *
 * This check is conservative and considers data unsafe regardless of
 * current terminal state.
 *
 * @param data The paste data to check (must not be NULL)
 * @param len The length of the data in bytes
 * @return true if the data is safe to paste, false otherwise
 */
bool ghostty_paste_is_safe(const char* data, size_t len);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_PASTE_H */
