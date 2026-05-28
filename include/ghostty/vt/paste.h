/**
 * @file paste.h
 *
 * Paste utilities - validate and encode paste data for terminal input.
 */

#ifndef GHOSTTY_VT_PASTE_H
#define GHOSTTY_VT_PASTE_H

/** @defgroup paste Paste Utilities
 *
 * Utilities for validating and encoding paste data for terminal input.
 *
 * ## Basic Usage
 *
 * Use ghostty_paste_is_safe() to check if paste data contains potentially
 * dangerous sequences before sending it to the terminal.
 *
 * Use ghostty_paste_encode() to encode paste data for writing to the pty,
 * including bracketed paste wrapping and unsafe byte stripping.
 *
 * ## Examples
 *
 * ### Safety Check
 *
 * @snippet c-vt-paste/src/main.c paste-safety
 *
 * ### Encoding
 *
 * @snippet c-vt-paste/src/main.c paste-encode
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <ghostty/vt/types.h>

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
GHOSTTY_API bool ghostty_paste_is_safe(const char* data, size_t len);

/**
 * Encode paste data for writing to the terminal pty.
 *
 * This function prepares paste data for terminal input by:
 * - Stripping unsafe control bytes (NUL, ESC, DEL, etc.) by replacing
 *   them with spaces
 * - Wrapping the data in bracketed paste sequences if @p bracketed is true
 * - Replacing newlines with carriage returns if @p bracketed is false
 *
 * The input @p data buffer is modified in place during encoding. The
 * encoded result (potentially with bracketed paste prefix/suffix) is
 * written to the output buffer.
 *
 * If the output buffer is too small, the function returns
 * GHOSTTY_OUT_OF_SPACE and sets the required size in @p out_written.
 * The caller can then retry with a sufficiently sized buffer.
 *
 * @param data The paste data to encode (modified in place, may be NULL)
 * @param data_len The length of the input data in bytes
 * @param bracketed Whether bracketed paste mode is active
 * @param buf Output buffer to write the encoded result into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GHOSTTY_API GhosttyResult ghostty_paste_encode(
    char* data,
    size_t data_len,
    bool bracketed,
    char* buf,
    size_t buf_len,
    size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_PASTE_H */
