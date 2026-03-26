/**
 * @file clipboard.h
 *
 * Clipboard encoding - encode OSC 52 clipboard sequences.
 */

#ifndef GHOSTTY_VT_CLIPBOARD_H
#define GHOSTTY_VT_CLIPBOARD_H

/** @defgroup clipboard Clipboard Encoding
 *
 * Utilities for encoding OSC 52 clipboard read response sequences.
 *
 * ## Basic Usage
 *
 * Use ghostty_clipboard_encode_osc52_read() to encode a clipboard read
 * response into a caller-provided buffer. If the buffer is too small,
 * the function returns GHOSTTY_OUT_OF_SPACE and sets the required size
 * in the output parameter.
 *
 * @{
 */

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

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_CLIPBOARD_H */
