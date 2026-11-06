# Memory {#memory}

libghostty-vt may allocate memory and fully supports custom allocators.

Most programs never need to think about this. Any function that takes a
`const GhosttyAllocator*` accepts NULL, which selects the default allocator.
Pass your own when you want memory to come from a specific place, such as an
arena, a pool, a tracking allocator, or a platform without a C library.

The library handles allocation failure. When an allocator returns NULL, the
function that needed the memory returns an error such as GHOSTTY_OUT_OF_MEMORY.
It doesn't crash.

## The Default Allocator {#memory-default}

Passing NULL uses:

- libc `malloc` and `free` when the library is linked against libc.
- A built-in allocator when it isn't. This is currently Zig's SMP allocator, or
  Zig's WebAssembly allocator on WebAssembly.
- An allocator that always fails on native freestanding targets, which have no
  heap. On these targets you must pass your own allocator to any function that
  allocates.

## Writing a Custom Allocator {#memory-custom}

A custom allocator is two structs:

- A GhosttyAllocatorVtable with your functions. It's usually a `static const`
  shared by every allocator of the same kind.
- A GhosttyAllocator that pairs the vtable with a `ctx` pointer. The library
  passes `ctx` back to every function, so it can point at whatever state your
  allocator needs.

Only `alloc` and `free` are required. Leave `resize` and `remap` NULL unless
your allocator can grow memory more cheaply than allocating new memory and
copying. Initialize the vtable with designated initializers (or `memset` it to
zero) so every field you don't set, including the reserved slots, is NULL.

The library may call an allocator's functions from any thread that uses a handle
created with it. If handles that share one allocator are used on different
threads, its functions must be thread-safe. The default allocator is.

This allocator is built on plain `malloc` and `free`:

@snippet c-vt-allocator/src/main.c allocator-vtable

Pair it with a context and pass it to any function that takes an allocator:

@snippet c-vt-allocator/src/main.c allocator-use

Full program: @ref c-vt-allocator/src/main.c

## Alignment {#memory-alignment}

Every vtable function receives an `alignment` argument. It's an exponent, not a
byte count. The address you return must be a multiple of `1 << alignment` bytes.

| `alignment` | Address must be a multiple of |
| ----------- | ----------------------------- |
| 0           | 1 byte                        |
| 3           | 8 bytes                       |
| 4           | 16 bytes                      |
| 12          | 4096 bytes                    |

`malloc` already returns memory aligned for any built-in C type, which covers
anything up to `alignof(max_align_t)` (usually 8 or 16 bytes). For larger
values, use `aligned_alloc` or `posix_memalign` with `1 << alignment`, or
over-allocate as the example above does. This is the same encoding as Zig's
`std.mem.Alignment`.

## Allocating and Freeing Buffers {#memory-buffers}

ghostty_alloc() and ghostty_free() allocate and free plain byte buffers through
an allocator. Use them when:

- You need a buffer to hand to a libghostty-vt function, such as input for
  ghostty_terminal_vt_write().
- You need to free a buffer that a libghostty-vt function returned, such as the
  output of ghostty_formatter_format_alloc().

Don't free library memory with the C `free()`. On some platforms the library and
your program use different heaps. On Windows, for example, Zig's libc and MSVC's
C runtime each keep their own, so freeing memory from one with the other is
undefined behavior. ghostty_free() always uses the right one.

Always free a buffer with the same allocator (or NULL) that allocated it.

## Allocators Passed to Callbacks {#memory-callbacks}

Some callbacks receive an allocator from the library, such as the PNG decoder
set with GHOSTTY_SYS_OPT_DECODE_PNG. Use that allocator only through
ghostty_alloc() and ghostty_free(). Don't read its vtable or call its functions
directly. A future release may fill in vtable slots that your code doesn't know
about, and calling the functions directly would skip them.
