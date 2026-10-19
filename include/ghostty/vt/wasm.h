/**
 * @file wasm.h
 *
 * WebAssembly utility functions for libghostty-vt.
 */

#ifndef GHOSTTY_VT_WASM_H
#define GHOSTTY_VT_WASM_H

#ifdef __wasm__

#include <stddef.h>
#include <ghostty/vt/types.h>

/** @defgroup wasm WebAssembly Utilities
 *
 * Convenience functions for working with the low-level C ABI in WebAssembly
 * builds.
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
 * Use ghostty_wasm_alloc() and ghostty_wasm_free() for host-owned scratch
 * buffers and ABI values. Dynamic-language hosts can use ghostty_type_json()
 * to discover pointer and size_t widths, maximum alignment, byte order, and
 * the size and alignment of public C structs. Do not mix allocation families:
 * buffers returned by libghostty-vt allocating APIs must still be released
 * with ghostty_free(), and opaque handles must be released with their
 * type-specific destructor.
 *
 * ## Memory growth
 *
 * An exported function may grow Wasm linear memory when it allocates. Numeric
 * pointers and handles remain valid, but JavaScript ArrayBuffer, DataView, and
 * typed-array objects created before the growth may no longer cover the live
 * memory. Reacquire `exports.memory.buffer` immediately before every host-side
 * memory access. A host that caches views should recreate them whenever either
 * the buffer identity or its byte length changes.
 *
 * ## Example Usage
 *
 * Here's a simple example that creates a terminal, writes bytes, and safely
 * handles memory growth:
 *
 * @code
 * const { exports } = wasmInstance;
 * const memory = exports.memory;
 * let cachedBuffer = null;
 * let cachedLength = 0;
 * let cachedBytes = null;
 *
 * function bytes() {
 *   const buffer = memory.buffer;
 *   if (buffer !== cachedBuffer || buffer.byteLength !== cachedLength) {
 *     cachedBuffer = buffer;
 *     cachedLength = buffer.byteLength;
 *     cachedBytes = new Uint8Array(buffer);
 *   }
 *   return cachedBytes;
 * }
 *
 * function check(result) {
 *   if (result !== 0) throw new Error(`libghostty-vt error: ${result}`);
 * }
 *
 * // One slot can be reused for every opaque-handle constructor.
 * const slot = exports.ghostty_wasm_alloc_opaque();
 * if (slot === 0) throw new Error("out of memory");
 * check(exports.ghostty_terminal_new(0, slot, 80, 24));
 * const terminal = exports.ghostty_wasm_take_opaque(slot);
 *
 * const input = new TextEncoder().encode("Hello, world!");
 * const inputPtr = exports.ghostty_wasm_alloc(input.length);
 * if (inputPtr === 0) throw new Error("out of memory");
 * bytes().set(input, inputPtr); // Acquires the current memory after alloc.
 * exports.ghostty_terminal_vt_write(terminal, inputPtr, input.length);
 *
 * exports.ghostty_wasm_free(inputPtr, input.length);
 * exports.ghostty_terminal_free(terminal);
 * exports.ghostty_wasm_free_opaque(slot);
 * @endcode
 *
 * @remark The code above is pretty ugly! This is the lowest level interface
 * to the libghostty-vt Wasm module. In practice, this should be wrapped
 * in a higher-level API that abstracts away all this.
 *
 * @{
 */

/**
 * Allocate caller-owned storage for a Wasm ABI value or scratch buffer.
 *
 * The returned address is aligned to the target's maximum C ABI alignment,
 * reported as `abi.max_alignment` by ghostty_type_json(). The memory is
 * uninitialized. A zero-length request returns NULL.
 *
 * The returned pointer must be released with ghostty_wasm_free() using the
 * exact same length.
 *
 * @param len Number of bytes to allocate
 * @return Pointer to allocated storage, or NULL if len is zero or allocation
 *         failed
 * @ingroup wasm
 */
GHOSTTY_API void* ghostty_wasm_alloc(size_t len);

/**
 * Free storage allocated by ghostty_wasm_alloc().
 *
 * @param ptr Pointer to free, or NULL (NULL is safely ignored)
 * @param len Original allocation length passed to ghostty_wasm_alloc()
 * @ingroup wasm
 */
GHOSTTY_API void ghostty_wasm_free(void *ptr, size_t len);

/**
 * Allocate an opaque pointer. This can be used for any opaque pointer
 * types such as GhosttyKeyEncoder, GhosttyKeyEvent, etc. The allocated slot
 * is initialized to NULL and may be reused across constructors.
 *
 * @return Pointer to allocated opaque pointer, or NULL if allocation failed
 * @ingroup wasm
 */
GHOSTTY_API void** ghostty_wasm_alloc_opaque(void);

/**
 * Free an opaque pointer allocated by ghostty_wasm_alloc_opaque().
 *
 * @param ptr Pointer to free, or NULL (NULL is safely ignored)
 * @ingroup wasm
 */
GHOSTTY_API void ghostty_wasm_free_opaque(void **ptr);

/**
 * Take an opaque handle from an out-parameter slot.
 *
 * Returns the handle currently stored in @p slot and resets the slot to NULL.
 * This function does not allocate, free the returned handle, or free the slot.
 * Always check the GhosttyResult returned by the function that populated the
 * slot before calling this function.
 *
 * @param slot Pointer to an opaque out-parameter slot, or NULL
 * @return Stored opaque handle, or NULL if slot or its value is NULL
 * @ingroup wasm
 */
GHOSTTY_API void* ghostty_wasm_take_opaque(void **slot);

/** @} */

#endif /* __wasm__ */

#endif /* GHOSTTY_VT_WASM_H */
