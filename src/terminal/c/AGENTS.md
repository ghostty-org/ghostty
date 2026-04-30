# libghostty-vt C API

- C API must be designed with ABI compatibility in mind
- Zig tagged unions must be converted to C ABI compatible unions
  via `lib.TaggedUnion`.
- Any functions must be updated all the way through from here to
  `src/terminal/c/main.zig` to `src/lib_vt.zig` and the headers
  in `include/ghostty/vt.h`. Specifically:
  1. Define the function in `src/terminal/c/<module>.zig`.
  2. Re-export it via a `pub const` in `src/terminal/c/main.zig`.
  3. Add an `@export` call in `src/lib_vt.zig` with the
     `ghostty_` prefixed symbol name.
  4. Declare it in the corresponding header under `include/ghostty/vt/`.
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
