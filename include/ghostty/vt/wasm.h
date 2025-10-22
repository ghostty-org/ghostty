/**
 * @file wasm.h
 *
 * WebAssembly utility functions for libghostty-vt.
 */

#ifndef GHOSTTY_VT_WASM_H
#define GHOSTTY_VT_WASM_H

#ifdef __wasm__

#include <stddef.h>
#include <stdint.h>

/** @defgroup wasm WebAssembly Utilities
 *
 * Convenience functions for allocating various types in WebAssembly builds.
 * **These are only available the libghostty-vt wasm module.**
 *
 * Ghostty relies on pointers to various types for ABI compatibility, and
 * creating those pointers in Wasm can be tedious. These functions provide
 * a purely additive set of utilities that simplify memory management in
 * Wasm environments without changing the core C library API.
 *
 * @note These functions always use the default allocator. If you need
 * custom allocation strategies, you should allocate types manually using
 * your custom allocator. This is a very rare use case in the WebAssembly
 * world so these are optimized for simplicity.
 *
 * ## Example Usage
 *
 * Here's a simple example of using the Wasm utilities with the key encoder:
 *
 * @code
 * const { exports } = wasmInstance;
 * const view = new DataView(wasmMemory.buffer);
 *
 * // Create key encoder
 * const encoderPtr = exports.ghostty_wasm_alloc_opaque();
 * exports.ghostty_key_encoder_new(null, encoderPtr);
 * const encoder = view.getUint32(encoder, true);
 *
 * // Configure encoder with Kitty protocol flags
 * const flagsPtr = exports.ghostty_wasm_alloc_u8();
 * view.setUint8(flagsPtr, 0x1F);
 * exports.ghostty_key_encoder_setopt(encoder, 5, flagsPtr);
 *
 * // Allocate output buffer and size pointer
 * const bufferSize = 32;
 * const bufPtr = exports.ghostty_wasm_alloc_buffer(bufferSize);
 * const writtenPtr = exports.ghostty_wasm_alloc_usize();
 *
 * // Encode the key event
 * exports.ghostty_key_encoder_encode(
 *     encoder, eventPtr, bufPtr, bufferSize, writtenPtr
 * );
 *
 * // Read encoded output
 * const bytesWritten = view.getUint32(writtenPtr, true);
 * const encoded = new Uint8Array(wasmMemory.buffer, bufPtr, bytesWritten);
 * @endcode
 *
 * @remark The code above is pretty ugly! This is the lowest level interface
 * to the libghostty-vt Wasm module. In practice, this should be wrapped
 * in a higher-level API that abstracts away all this.
 *
 * @{
 */

/**
 * Allocate an opaque pointer. This can be used for any opaque pointer
 * types such as GhosttyKeyEncoder, GhosttyKeyEvent, etc.
 *
 * @return Pointer to allocated opaque pointer, or NULL if allocation failed
 * @ingroup wasm
 */
void** ghostty_wasm_alloc_opaque(void);

/**
 * Free an opaque pointer allocated by ghostty_wasm_alloc_opaque().
 *
 * @param ptr Pointer to free, or NULL (NULL is safely ignored)
 * @ingroup wasm
 */
void ghostty_wasm_free_opaque(void **ptr);

/**
 * Allocate a buffer of the specified length.
 *
 * @param len Number of bytes to allocate
 * @return Pointer to allocated buffer, or NULL if allocation failed
 * @ingroup wasm
 */
uint8_t* ghostty_wasm_alloc_buffer(size_t len);

/**
 * Free a buffer allocated by ghostty_wasm_alloc_buffer().
 *
 * @param ptr Pointer to the buffer to free, or NULL (NULL is safely ignored)
 * @param len Length of the buffer (must match the length passed to alloc)
 * @ingroup wasm
 */
void ghostty_wasm_free_buffer(uint8_t *ptr, size_t len);

/**
 * Allocate a single uint8_t value.
 *
 * @return Pointer to allocated uint8_t, or NULL if allocation failed
 * @ingroup wasm
 */
uint8_t* ghostty_wasm_alloc_u8(void);

/**
 * Free a uint8_t allocated by ghostty_wasm_alloc_u8().
 *
 * @param ptr Pointer to free, or NULL (NULL is safely ignored)
 * @ingroup wasm
 */
void ghostty_wasm_free_u8(uint8_t *ptr);

/**
 * Allocate a single size_t value.
 *
 * @return Pointer to allocated size_t, or NULL if allocation failed
 * @ingroup wasm
 */
size_t* ghostty_wasm_alloc_usize(void);

/**
 * Free a size_t allocated by ghostty_wasm_alloc_usize().
 *
 * @param ptr Pointer to free, or NULL (NULL is safely ignored)
 * @ingroup wasm
 */
void ghostty_wasm_free_usize(size_t *ptr);

/** @} */

#endif /* __wasm__ */

#endif /* GHOSTTY_VT_WASM_H */
