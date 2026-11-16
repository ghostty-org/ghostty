# Example: `ghostty-vt` Custom Allocator

This example shows how to give libghostty-vt your own allocator, built
on plain `malloc` and `free`. It:

1. Defines a `GhosttyAllocatorVtable` that sets only `alloc` and `free`.
   The other fields are left NULL. Without `resize` and `remap`, the
   library grows memory by allocating a new block, copying, and freeing
   the old one.
2. Pairs the vtable with a context pointer in a `GhosttyAllocator`. Here
   the context counts allocations and live bytes.
3. Creates a terminal with the allocator and writes 20,000 lines of
   colored output, so the terminal has to grow its memory.
4. Frees the terminal and checks that every byte came back.

## Alignment

The library passes alignment as an exponent: the address must be a
multiple of `1 << alignment` bytes, so 3 means 8 bytes and 4 means 16.
`malloc` already handles anything up to `alignof(max_align_t)`. For
larger alignments, the example allocates extra room, rounds the address
up, and stores the original `malloc` pointer just before the block so
`free` can find it.

## Building

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
