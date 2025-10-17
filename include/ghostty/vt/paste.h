/**
 * @file paste.h
 *
 * Paste utilities - validate and encode paste data for terminal input.
 */

#ifndef GHOSTTY_VT_PASTE_H
#define GHOSTTY_VT_PASTE_H

/** @defgroup paste Paste Utilities
 *
 * Utilities for validating paste data safety and encoding data to be pasted.
 *
 * ## Basic Usage
 *
 *1. Use ghostty_paste_is_safe() to check if paste data contains potentially
 * dangerous sequences before sending it to the terminal.
 * 2. Create a GhosttyPasteEncoder instance using ghostty_paste_encoder_new().
 * 3. Configure the encoder using ghostty_paste_encoder_set_bracketed() to set
 *   bracketed paste mode if desired.
 * 4. Use ghostty_paste_encoder_encode() to encode the paste data into a buffer
 * 5. Free the encoder using ghostty_paste_encoder_free() when done.
 *
 * ## Paste Safety Check Example
 *
 * @code{.c}
 * #include <stdio.h>
 * #include <string.h>
 * #include <ghostty/vt.h>
 *
 * int main() {
 *   const char* safe_data = "hello world";
 *   const char* unsafe_data = "rm -rf /\n";
 *
 *   if (ghostty_paste_is_safe(safe_data, strlen(safe_data))) {
 *     printf("Safe to paste\n");
 *   }
 *
 *   if (!ghostty_paste_is_safe(unsafe_data, strlen(unsafe_data))) {
 *     printf("Unsafe! Contains newline\n");
 *   }
 *
 *   return 0;
 * }
 * @endcode
 *
 * Use ghostty_paste_encoder_encode() with a GhosttyPasteEncoder to encode
 * the paste data to be sent to the terminal.
 * There are two modes:
 * bracketed paste mode, which wraps the data in \x1b[200~ ... \x1b[201~,
 * and non-bracketed mode, which replaces newlines with carriage returns.
 *
 * ## Encoding Paste Data Example
 *
 * @code{.c}
 * #include <ghostty/vt.h>
 * #include <stdbool.h>
 * #include <stdio.h>
 * #include <string.h>
 *
 * int main() {
 * // Create a paste encoder
 * GhosttyPasteEncoder encoder;
 * if (ghostty_paste_encoder_new(NULL, &encoder) != GHOSTTY_SUCCESS) {
 *   printf("Failed to create paste encoder\n");
 *   return 1;
 * }
*
 * // Enable bracketed paste mode
 * ghostty_paste_encoder_set_bracketed(encoder, true);
 *
 * // we could use this to find out the required size, or just use a large
 * // enough buffer
 * size_t required;
 * char simple_paste[] = "pasted content";
 * char encoded[128];
 *
 * if (ghostty_paste_encoder_encode(simple_paste, strlen(simple_paste), encoder,
 *                                  encoded, sizeof(encoded),
 *                                  &required) != GHOSTTY_SUCCESS) {
 *   printf("Failed to encode paste data\n");
 *   return 1;
 * }
 *
 * printf("Encoded paste data: ");
 * for (size_t i = 0; i < strlen(encoded); i++) {
 *   if (encoded[i] == 0x1b) {
 *     printf("\\x1b");
 *   } else {
 *     printf("%c", encoded[i]);
 *   }
 * }

 *
 *  // free resources
 *  ghostty_paste_encoder_free(encoder);
 * }
 * @endcode
 *
 *
 * @{
 */

#include <stdbool.h>
#include <stddef.h>

#include <ghostty/vt/allocator.h>
#include <ghostty/vt/result.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Opaque handle to a Paste Encoder instance.
 *
 * This handle represents a Paste Encoder that can
 * be used to encode data to be pasted into the terminal.
 *
 * @ingroup paste
 */
typedef struct GhosttyPasteEncoder* GhosttyPasteEncoder;

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

/**
 * Create a new Paste Encoder instance.
 *
 * Creates a new Paste Encoder instance using the provided
 * allocator. The encoder must be freed using ghostty_paste_encoder_free() when
 * no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or
 * NULL to use the default allocator
 * @param options Pointer to store the created paste encoder handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup paste
 */
GhosttyResult ghostty_paste_encoder_new(const GhosttyAllocator* allocator,
                                        GhosttyPasteEncoder* encoder);

/**
 * Free an Paste Options instance.
 *
 * After this call, the options handle becomes invalid and must not be used.
 *
 * @param allocator The allocator used to create the options, or NULL if the
 * default allocator was used
 *
 * @param options The paste encoder handle to free (may be NULL)
 *
 * @ingroup paste
 */
void ghostty_paste_encoder_free(GhosttyPasteEncoder encoder);

/**
 * Enable or disable bracketed paste mode.
 *
 * When enabled, pasted data will be wrapped in the appropriate
 * escape sequences.
 *
 * Default is disabled.
 *
 * @param options The paste encoder handle, must not be NULL
 * @param enabled true to enable bracketed paste mode, false to disable
 *
 * @ingroup paste
 */
void ghostty_paste_encoder_set_bracketed(GhosttyPasteEncoder encoder,
                                         bool enabled);

/** Encode data for pasting into the terminal.
 *
 * Encodes the given data according to the specified options, writing
 * the encoded paste sequence into the provided output buffer.
 *
 * If the output buffer is too small, the function returns
 * GHOSTTY_OUT_OF_MEMORY and sets `out_written` to the required
 * size. The caller can then allocate a larger buffer and call again.
 *
 * > WARNING: The input data is not checked for safety. See the
 * ghostty_paste_is_safe() function to check if the data is safe to paste.
 *
 * @param data The paste data to encode (must not be NULL)
 * @param len The length of the data in bytes
 * @param encoder The paste encoder handle, (must not be NULL)
 * @param out The output buffer to write the encoded data into (must not be
 * NULL)
 * @param out_len The length of the output buffer in bytes
 * @param out_written Pointer to store the number of bytes required or written
 * (may be NULL)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup paste
 */
GhosttyResult ghostty_paste_encoder_encode(char* data,
                                           size_t len,
                                           GhosttyPasteEncoder encoder,
                                           char* out,
                                           size_t out_len,
                                           size_t* out_written);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_PASTE_H */
