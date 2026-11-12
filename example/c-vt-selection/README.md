# Example: `ghostty-vt` Selection

Derive selections such as a word, semantic command line, command output, and
all visible content with the `ghostty-vt` terminal, grid reference,
selection, and formatter APIs.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
