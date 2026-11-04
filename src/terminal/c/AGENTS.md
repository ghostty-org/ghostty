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
- Every new public C struct, union, enum, and opaque handle must be
  registered in `type_decls` in `src/terminal/c/types.zig`. The parity
  test in `src/terminal/c/abi_test.zig` fails if a header type is not
  registered, or if it does not match its Zig type. Run it with
  `zig build test-lib-vt -Dtest-filter="C header"`.

## Sized Structs

Sized structs follow the rule documented on `sizedCheck` in
`src/lib/struct.zig`. When you add or change one:

- Declare the last field of its first released layout:
  `pub const sized_base = "<field>";`. Never change it after release.
- Call `lib.sizedCheck(.input, ptr)` or `lib.sizedCheck(.output, ptr)`
  before you touch any other field.
- Read input fields with `lib.sizedField` once they come after the base.
  Write output fields with `lib.sizedSet` or `lib.sizedWrite`.
- Never read or assign the whole struct. The caller's struct may be
  smaller than ours.
- Add new fields only at the end, starting at or after the previous
  version's `@sizeOf`. Never place a new field in trailing padding.
- Never nest sized structs, put them in arrays or pass them by value.

## Enums From C

C can pass any integer where a header declares an enum. Reading an
out-of-range integer as an exhaustive Zig enum is undefined behavior, so
every enum value that comes from C must be checked in every build mode.
Never guard the check with `std.debug.runtime_safety`.

- Get/set keys: declare the C-facing key enum non-exhaustive (`_,` as the
  last field) and give the dispatch switch a `_ => .unsupported` prong
  ahead of `inline else`. Inner switches on a comptime key use
  `_ => comptime unreachable`. Check the key before dereferencing the
  handle where the code allows it, so callers can check for a key
  without a handle.
- Enum values passed as arguments: take `lib.CEnum(E)` and convert with
  `lib.enumFromC(E, value) orelse return .invalid_value`.
- Enum values inside option values or input structs: use
  `lib.enumFromPtr(E, ptr) orelse return .invalid_value`.
- Keep shared Zig enums from the core exhaustive. Convert at the C API
  instead of adding `_` to them.
- `_get`, `_set` and `_setopt` functions return `Result`, even when every
  current option always succeeds, so new options can report errors.
- A NULL value to a `_set` or `_setopt` resets that option to its
  documented default and returns `.success`. Document each option's
  default in the header.
