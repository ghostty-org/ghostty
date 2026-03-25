# libghostty-vt C API

- C API must be designed with ABI compatibility in mind
- Zig tagged unions must be converted to C ABI compatible unions
  via `lib.TaggedUnion`.
- Any functions must be updated all the way through from here to
  `src/terminal/c/main.zig` to `src/lib_vt.zig` and the headers
  in `include/ghostty/vt.h`.
- In `include/ghostty/vt.h`, always sort the header contents by:
  (1) macros, (2) forward declarations, (3) types, (4) functions

## ABI Compatibility

- Prefer opaque pointers for long-lived objects, such as
  `GhosttyTerminal`.
- Structs:
  - May contain padding bytes if we're confident we'll never grow
    beyond a certain size.
  - May use the "sized struct" pattern: an `extern struct` with
    `size: usize = @sizeOf(Self)` as the first field. In the C header,
    callers use `GHOSTTY_INIT_SIZED` from `types.h` to zero-initialize and
    set the size.
