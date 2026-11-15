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

/** @addtogroup wasm
 *
 * These are helpers for calling the C API from WebAssembly, and they only exist
 * in the wasm module.
 *
 * The C API passes a lot of pointers, and creating those in Wasm can be tedious.
 * Use ghostty_wasm_alloc() and ghostty_wasm_free() for buffers and ABI values,
 * and the `_opaque` functions for handles. They only add to the C API. They
 * don't change it.
 *
 * ghostty_key_event_get_utf8() returns a GhosttyString by value. A Wasm
 * function can't return a struct, so the export takes an extra first argument:
 * a pointer to memory that receives the result.
 *
 * @code
 * const out = exports.ghostty_wasm_alloc(8); // Pointer and length, 4 bytes each.
 * exports.ghostty_key_event_get_utf8(out, event);
 *
 * const view = new DataView(memory.buffer);
 * const ptr = view.getUint32(out, true);
 * const len = view.getUint32(out + 4, true);
 * const text = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len));
 *
 * exports.ghostty_wasm_free(out, 8);
 * @endcode
 *
 * ## Example
 *
 * This creates a terminal, writes bytes, and safely handles memory growth. It's
 * the lowest level interface to the module and it's pretty ugly. In practice,
 * you should wrap it in a higher-level API.
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
 * See [wasm-vt](https://github.com/ghostty-org/ghostty/tree/main/example/wasm-vt)
 * for a full program, and @ref installing-wasm for how to build the module.
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
 * exact same length. Do not mix allocation families: buffers returned by
 * libghostty-vt allocating APIs must still be released with ghostty_free(),
 * and opaque handles must be released with their type-specific destructor.
 *
 * This always uses the default allocator. If you need a custom allocation
 * strategy, allocate types manually with your own allocator. That's very rare
 * in WebAssembly, so these are optimized for simplicity.
 *
 * Dynamic-language hosts can use ghostty_type_json() to discover pointer and
 * size_t widths, maximum alignment, byte order, and the size and alignment of
 * public C structs.
 *
 * An exported function may grow Wasm linear memory when it allocates. Numeric
 * pointers and handles remain valid, but JavaScript ArrayBuffer, DataView, and
 * typed-array objects created before the growth may no longer cover the live
 * memory. Reacquire `exports.memory.buffer` immediately before every host-side
 * memory access. A host that caches views should recreate them whenever either
 * the buffer identity or its byte length changes.
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
