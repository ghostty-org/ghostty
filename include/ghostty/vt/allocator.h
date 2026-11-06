/**
 * @file allocator.h
 *
 * Memory management interface for libghostty-vt.
 */

#ifndef GHOSTTY_VT_ALLOCATOR_H
#define GHOSTTY_VT_ALLOCATOR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

/** @addtogroup allocator
 *
 * An allocator is the set of functions libghostty-vt calls to get and free
 * memory.
 *
 * Most programs never need this. Any function that takes a
 * `const GhosttyAllocator*` accepts NULL, which selects the default
 * allocator. You only need your own to run the library on memory you control.
 *
 * ## Example
 *
 * @snippet c-vt-allocator/src/main.c allocator-use
 *
 * Full program: @ref c-vt-allocator/src/main.c
 *
 * See @ref memory for what the default is, how to write your own allocator,
 * and how to free memory the library gives you.
 *
 * @{
 */

/**
 * The functions that make up a custom allocator.
 *
 * `alloc` and `free` are required. `resize` and `remap` are optional, and
 * when they are NULL the library grows memory by allocating a new block,
 * copying, and freeing the old one. See @ref memory-custom for a complete
 * example and @ref memory-alignment for an explanation of `alignment`.
 *
 * Every function receives the `ctx` pointer from the GhosttyAllocator it
 * belongs to. When the library resizes, remaps, or frees memory, it always
 * passes the same `alignment` it used for the original allocation and the
 * current length of the block, so your allocator does not need to record
 * either.
 *
 * Every function also receives `ret_addr`, the address of the code that
 * requested the memory, or 0 if it is unknown. Allocators that track
 * leaks or report where memory came from can use it. Most allocators
 * ignore it.
 *
 * Initialize the whole struct to zero before setting the fields you use,
 * so the reserved slots are NULL.
 *
 * The interface matches Zig's `std.mem.Allocator`. The library is written
 * in Zig, so this lets it use your allocator directly, and it is an
 * interface already proven by a wide range of allocators in the Zig
 * ecosystem. Simple allocators can ignore most of the arguments. Zig's
 * own libc allocator (CAllocator in `lib/std/heap.zig`) is a good short
 * reference.
 *
 * @ingroup allocator
 */
typedef struct {
    /**
     * Allocate `len` bytes aligned to `1 << alignment` bytes.
     *
     * Required.
     *
     * @param ctx The allocator's context pointer
     * @param len Number of bytes to allocate
     * @param alignment Alignment as a power of two exponent. See
     *   @ref memory-alignment for details.
     * @param ret_addr Address of the requesting code, or 0. Safe to ignore.
     * @return Pointer to the new memory, or NULL if it could not be
     *   allocated
     */
    void* (*alloc)(void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr);

    /**
     * Try to grow or shrink a block without moving it.
     *
     * Optional. A NULL `resize` is the same as one that always returns
     * false.
     *
     * Return true only if the block at `memory` is now `new_len` bytes long
     * at the same address. Return false if that would require moving it.
     * The library then decides whether to allocate a new block and copy.
     *
     * @param ctx The allocator's context pointer
     * @param memory Start of a block returned by `alloc` or `remap`
     * @param memory_len Current length of the block
     * @param alignment The alignment the block was allocated with
     * @param new_len Requested length, always greater than zero
     * @param ret_addr Address of the requesting code, or 0. Safe to ignore.
     * @return true if the block was resized in place, false otherwise
     */
    bool (*resize)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);

    /**
     * Grow or shrink a block, moving it if that is cheaper than a copy.
     *
     * Optional. A NULL `remap` is the same as one that always returns NULL.
     *
     * Return a pointer to a block of `new_len` bytes holding the old
     * contents. It may be the same address or a new one, for example after
     * remapping virtual memory pages. If you return a new address, the old
     * one is no longer valid.
     *
     * Return NULL when the only way to do it would be to allocate, copy,
     * and free. The library does that itself in that case, so there is no
     * benefit in doing it here.
     *
     * @param ctx The allocator's context pointer
     * @param memory Start of a block returned by `alloc` or `remap`
     * @param memory_len Current length of the block
     * @param alignment The alignment the block was allocated with
     * @param new_len Requested length, always greater than zero
     * @param ret_addr Address of the requesting code, or 0. Safe to ignore.
     * @return The resized block, or NULL to let the library copy instead
     */
    void* (*remap)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);

    /**
     * Free a block.
     *
     * Required. After this returns, the library never uses `memory` again.
     *
     * @param ctx The allocator's context pointer
     * @param memory Start of a block returned by `alloc` or `remap`
     * @param memory_len Current length of the block
     * @param alignment The alignment the block was allocated with
     * @param ret_addr Address of the requesting code, or 0. Safe to ignore.
     */
    void (*free)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, uintptr_t ret_addr);

    /**
     * Reserved for future versions. Must be NULL.
     *
     * These slots let a future release add new allocator functions
     * without changing the size of this struct. The library ignores any
     * slot it does not know about, so leaving them NULL keeps your code
     * working with future versions.
     *
     * Debug builds of the library stop with an error if a reserved slot
     * is not NULL, to catch a vtable that was not zero-initialized.
     */
    void* reserved[4];
} GhosttyAllocatorVtable;

/**
 * A custom allocator: a vtable and the context it operates on.
 *
 * Pass a pointer to one of these to any function that takes an allocator,
 * or pass NULL to use the default allocator described in @ref memory-default.
 * The library does not copy the allocator. It must stay valid for as long
 * as anything allocated with it is in use.
 *
 * @ingroup allocator
 */
typedef struct GhosttyAllocator {
    /**
     * Your allocator's state, passed unchanged to every vtable function.
     * May be NULL if your allocator has no state.
     */
    void *ctx;

    /**
     * The functions that implement this allocator. Must not be NULL.
     */
    const GhosttyAllocatorVtable *vtable;
} GhosttyAllocator;

/**
 * Allocate a buffer of `len` bytes.
 *
 * Uses the provided allocator, or the default allocator if NULL is passed.
 * The returned buffer must be freed with ghostty_free() using the same
 * allocator.
 *
 * @param allocator Pointer to the allocator to use, or NULL for the default
 * @param len Number of bytes to allocate
 * @return Pointer to the allocated buffer, or NULL if len is zero or
 *         allocation failed
 *
 * @ingroup allocator
 */
GHOSTTY_API uint8_t* ghostty_alloc(const GhosttyAllocator* allocator, size_t len);

/**
 * Free memory that was allocated by a libghostty-vt function.
 *
 * Use this to free buffers returned by functions such as
 * ghostty_formatter_format_alloc(). Pass the same allocator that was
 * used for the allocation, or NULL if the default allocator was used.
 *
 * Use this instead of the C `free()`, which can use a different heap than
 * the library. See @ref memory-buffers for why.
 *
 * Passing a NULL `ptr` does nothing.
 *
 * @param allocator Pointer to the allocator that was used to allocate the
 *   memory, or NULL if the default allocator was used
 * @param ptr Pointer to the memory to free (may be NULL)
 * @param len Length of the allocation in bytes (must match the original
 *   allocation size)
 *
 * @ingroup allocator
 */
GHOSTTY_API void ghostty_free(const GhosttyAllocator* allocator, uint8_t* ptr, size_t len);

/** @} */

#endif /* GHOSTTY_VT_ALLOCATOR_H */
