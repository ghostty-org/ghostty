/**
 * @file clipboard.h
 *
 * Clipboard encoding and paste utilities.
 */

#ifndef GHOSTTY_VT_CLIPBOARD_H
#define GHOSTTY_VT_CLIPBOARD_H

/** @defgroup clipboard Clipboard Encoding
 *
 * Utilities for encoding OSC 52 clipboard read response sequences
 * and validating paste data safety.
 *
 * ## Basic Usage
 *
 * Use ghostty_clipboard_encode_osc52_read() to encode a clipboard read
 * response into a caller-provided buffer. If the buffer is too small,
 * the function returns GHOSTTY_OUT_OF_SPACE and sets the required size
 * in the output parameter.
 *
 * ## Examples
 *
 * ### Paste Safety Check
 *
 * @snippet c-vt-paste/src/main.c paste-safety
 *
 * ### Paste Encoding
 *
 * @snippet c-vt-paste/src/main.c paste-encode
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Clipboard type for OSC 52 operations.
 */
typedef enum {
    /** Standard clipboard (ctrl+c/v, OSC 52 kind byte 'c') */
    GHOSTTY_CLIPBOARD_STANDARD = 0,
    /** Selection clipboard (OSC 52 kind byte 's') */
    GHOSTTY_CLIPBOARD_SELECTION = 1,
    /** Primary clipboard (OSC 52 kind byte 'p') */
    GHOSTTY_CLIPBOARD_PRIMARY = 2,
} GhosttyClipboard;

/**
 * Encode an OSC 52 clipboard read response.
 *
 * Encodes the given data as a base64-encoded OSC 52 read response
 * sequence: `ESC ] 52 ; <kind> ; <base64> ESC \`
 *
 * If the buffer is too small, the function returns GHOSTTY_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param clipboard The clipboard type to encode
 * @param data Pointer to the raw clipboard data to encode (may be NULL)
 * @param data_len Length of the clipboard data in bytes
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GhosttyResult ghostty_clipboard_encode_osc52_read(
    GhosttyClipboard clipboard,
    const uint8_t* data,
    size_t data_len,
    char* buf,
    size_t buf_len,
    size_t* out_written);

/**
 * Encode paste data for writing to the terminal.
 *
 * Encodes the given data for pasting into the terminal. In bracketed
 * paste mode, the data is wrapped in bracketed paste fenceposts
 * (`ESC[200~` ... `ESC[201~`). In non-bracketed mode, newlines are
 * replaced with carriage returns.
 *
 * Unsafe control characters (NUL, ESC, DEL, etc.) are always replaced
 * with spaces, matching xterm behavior. The input @p data buffer is
 * modified in place. The caller must provide a mutable copy if the
 * original data must be preserved.
 *
 * If the buffer is too small, the function returns GHOSTTY_OUT_OF_SPACE
 * and writes the required buffer size to @p out_written. The caller can
 * then retry with a sufficiently sized buffer.
 *
 * @param data Mutable pointer to the paste data (modified in place, may be NULL)
 * @param data_len Length of the paste data in bytes
 * @param bracketed Whether bracketed paste mode is active
 * @param buf Output buffer to write the encoded sequence into (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_written On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if the buffer
 *         is too small
 */
GhosttyResult ghostty_clipboard_encode_paste(
    uint8_t* data,
    size_t data_len,
    bool bracketed,
    char* buf,
    size_t buf_len,
    size_t* out_written);

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

#endif /* GHOSTTY_VT_CLIPBOARD_H */
