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
 * Use ghostty_paste_encode() to encode
 * the paste data to be sent to the terminal.
 * There are two modes:
 * bracketed paste mode, which wraps the data in \x1b[200~ ... \x1b[201~,
 * and non-bracketed mode, which replaces newlines with carriage returns.
 *
 * ## Example
 *
 * @code{.c}
 * #include <ghostty/vt.h>
 * #include <stdbool.h>
 * #include <stdio.h>
 * #include <string.h>
 *
 * int main() {
 *  // Create options for paste encoding
 *  GhosttyPasteOptions options;
 *  if (ghostty_paste_options_new(NULL, &options) != GHOSTTY_SUCCESS) {
 *    printf("Failed to create paste options\n");
 *    return 1;
 *  }
 *
 *  // Enable bracketed paste mode
 *  ghostty_paste_options_set_bracketed(options, true);
 *
 *  char* simple_paste = "pasted content";
 *  char* encoded;
 *  if (ghostty_paste_encode(NULL, simple_paste, strlen(simple_paste), options,
 *                           &encoded) != GHOSTTY_SUCCESS) {
 *    printf("Failed to encode paste data\n");
 *    return 1;
 *  }
 *
 *  printf("Encoded paste data: ");
 *  for (size_t i = 0; i < strlen(encoded); i++) {
 *    if (encoded[i] == 0x1b) {
 *      printf("\\x1b");
 *    } else {
 *      printf("%c", encoded[i]);
 *    }
 *  }
 *  printf("\n");
 *
 *  // free resources
 *  ghostty_paste_encode_free(NULL, encoded, strlen(encoded));
 *  ghostty_paste_options_free(NULL, options);
 *}
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
 * Opaque handle to a Paste Options instance.
 *
 * This handle represents Options that can
 * be used to encode data to be pasted into the terminal.
 *
 * @ingroup paste
 */
typedef struct GhosttyPasteOptions* GhosttyPasteOptions;

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
 * Create a new Paste Options instance.
 *
 * Creates a new Paste Options instance using the provided
 * allocator. The options must be freed using ghostty_paste_options_free() when
 * no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or
 * NULL to use the default allocator
 * @param options Pointer to store the created paste options handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup paste
 */
GhosttyResult ghostty_paste_options_new(const GhosttyAllocator* allocator,
                                        GhosttyPasteOptions* options);

/**
 * Free an Paste Options instance.
 *
 * After this call, the options handle becomes invalid and must not be used.
 *
 * @param allocator The allocator used to create the options, or NULL if the
 * default allocator was used
 *
 * @param options The parser handle to free (may be NULL)
 *
 * @ingroup paste
 */
void ghostty_paste_options_free(const GhosttyAllocator* allocator,
                                GhosttyPasteOptions options);

/**
 * Enable or disable bracketed paste mode in the given options.
 *
 * When enabled, pasted data will be wrapped in the appropriate
 * escape sequences to enter and exit bracketed paste mode.
 *
 * Default is disabled.
 *
 * @param options The paste options handle, must not be NULL
 * @param enabled true to enable bracketed paste mode, false to disable
 *
 * @ingroup paste
 */
void ghostty_paste_options_set_bracketed(GhosttyPasteOptions options,
                                         bool enabled);

/**
 * Encode data for pasting into the terminal.
 *
 * Encodes the given data according to the specified options, producing
 * a new buffer containing the encoded paste sequence. The caller is
 * responsible for freeing the returned buffer using ghostty_paste_encode_free()
 * when no longer needed.
 *
 *
 * WARNING: The input data is not checked for safety. See the
 * `ghostty_paste_is_safe` function to check if the data is safe to paste.
 *
 * @param allocator Pointer to the allocator to use for memory management, or
 * NULL to use the default allocator
 * @param data The paste data to encode (may be NULL)
 * @param len The length of the data in bytes
 * @param options The paste options handle, (may be NULL)
 * @param out Pointer to store the allocated encoded data buffer
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup paste
 */
GhosttyResult ghostty_paste_encode(GhosttyAllocator* allocator,
                                   char* data,
                                   size_t len,
                                   GhosttyPasteOptions options,
                                   char** out);

/**
 * Free encoded paste data returned by ghostty_paste_encode().
 *
 * @param allocator The allocator used to create the encoded data, or NULL if
 * the default allocator was used
 * @param encoded The encoded data to free (may be NULL)
 * @param len The length of the encoded data in bytes
 *
 * @ingroup paste
 */
void ghostty_paste_encode_free(GhosttyAllocator* allocator,
                               char* encoded,
                               size_t len);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_PASTE_H */
