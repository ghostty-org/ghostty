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

/** @defgroup allocator Memory Management
 *
 * libghostty-vt does require memory allocation for various operations,
 * but is resilient to allocation failures and will gracefully handle
 * out-of-memory situations by returning error codes.
 *
 * The exact memory management semantics are documented in the relevant
 * functions and data structures.
 *
 * libghostty-vt uses explicit memory allocation via an allocator
 * interface provided by GhosttyAllocator. The interface is based on the
 * [Zig](https://ziglang.org) allocator interface, since this has been
 * shown to be a flexible and powerful interface in practice and enables
 * a wide variety of allocation strategies.
 *
 * **For the common case, you can pass NULL as the allocator for any
 * function that accepts one,** and libghostty will use a default allocator.
 * The default allocator will be libc malloc/free if libc is linked. 
 * Otherwise, a custom allocator is used (currently Zig's SMP allocator)
 * that doesn't require any external dependencies.
 *
 * ## Basic Usage
 *
 * For simple use cases, you can ignore this interface entirely by passing NULL
 * as the allocator parameter to functions that accept one. This will use the
 * default allocator (typically libc malloc/free, if libc is linked, but
 * we provide our own default allocator if libc isn't linked).
 *
 * To use a custom allocator:
 * 1. Implement the GhosttyAllocatorVtable function pointers
 * 2. Create a GhosttyAllocator struct with your vtable and context
 * 3. Pass the allocator to functions that accept one
 *
 * @{
 */

/**
 * Function table for custom memory allocator operations.
 * 
 * This vtable defines the interface for a custom memory allocator. All
 * function pointers must be valid and non-NULL.
 *
 * @ingroup allocator
 *
 * If you're not going to use a custom allocator, you can ignore all of
 * this. All functions that take an allocator pointer allow NULL to use a
 * default allocator.
 *
 * The interface is based on the Zig allocator interface. I'll say up front
 * that it is easy to look at this interface and think "wow, this is really
 * overcomplicated". The reason for this complexity is well thought out by
 * the Zig folks, and it enables a diverse set of allocation strategies
 * as shown by the Zig ecosystem. As a consolation, please note that many
 * of the arguments are only needed for advanced use cases and can be
 * safely ignored in simple implementations. For example, if you look at 
 * the Zig implementation of the libc allocator in `lib/std/heap.zig`
 * (search for CAllocator), you'll see it is very simple.
 *
 * We chose to align with the Zig allocator interface because:
 *
 *   1. It is a proven interface that serves a wide variety of use cases
 *      in the real world via the Zig ecosystem. It's shown to work.
 *
 *   2. Our core implementation itself is Zig, and this lets us very
 *      cheaply and easily convert between C and Zig allocators.
 *
 * NOTE(mitchellh): In the future, we can have default implementations of
 * resize/remap and allow those to be null.
 */
typedef struct {
    /**
     * Return a pointer to `len` bytes with specified `alignment`, or return
     * `NULL` indicating the allocation failed.
     *
     * @param ctx The allocator context
     * @param len Number of bytes to allocate
     * @param alignment Required alignment for the allocation. Guaranteed to
     *   be a power of two between 1 and 16 inclusive.
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return Pointer to allocated memory, or NULL if allocation failed
     */
    void* (*alloc)(void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr);
    
    /**
     * Attempt to expand or shrink memory in place.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * `new_len` must be greater than zero.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to resize
     * @param memory_len Current size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param new_len New requested size
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return true if resize was successful in-place, false if relocation would be required
     */
    bool (*resize)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);
    
    /**
     * Attempt to expand or shrink memory, allowing relocation.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * A non-`NULL` return value indicates the resize was successful. The
     * allocation may have same address, or may have been relocated. In either
     * case, the allocation now has size of `new_len`. A `NULL` return value
     * indicates that the resize would be equivalent to allocating new memory,
     * copying the bytes from the old memory, and then freeing the old memory.
     * In such case, it is more efficient for the caller to perform the copy.
     *
     * `new_len` must be greater than zero.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to remap
     * @param memory_len Current size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param new_len New requested size
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return Pointer to resized memory (may be relocated), or NULL if manual copy is needed
     */
    void* (*remap)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);
    
    /**
     * Free and invalidate a region of memory.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to free
     * @param memory_len Size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     */
    void (*free)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, uintptr_t ret_addr);
} GhosttyAllocatorVtable;

/**
 * Custom memory allocator.
 *
 * For functions that take an allocator pointer, a NULL pointer indicates
 * that the default allocator should be used. The default allocator will 
 * be libc malloc/free if we're linking to libc. If libc isn't linked,
 * a custom allocator is used (currently Zig's SMP allocator).
 *
 * @ingroup allocator
 *
 * Usage example:
 * @code
 * GhosttyAllocator allocator = {
 *     .vtable = &my_allocator_vtable,
 *     .ctx = my_allocator_state
 * };
 * @endcode
 */
typedef struct GhosttyAllocator {
    /**
     * Opaque context pointer passed to all vtable functions.
     * This allows the allocator implementation to maintain state
     * or reference external resources needed for memory management.
     */
    void *ctx;

    /**
     * Pointer to the allocator's vtable containing function pointers
     * for memory operations (alloc, resize, remap, free).
     */
    const GhosttyAllocatorVtable *vtable;
} GhosttyAllocator;

/** @} */

#endif /* GHOSTTY_VT_ALLOCATOR_H */
