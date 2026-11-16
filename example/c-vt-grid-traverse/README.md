# Example: `ghostty-vt` Grid Traversal

Create a terminal, write content into it, and traverse the entire grid
cell-by-cell using grid refs to inspect codepoints, row state, and styles.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
