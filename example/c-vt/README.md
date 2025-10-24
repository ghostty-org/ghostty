# Example: `ghostty-vt` C Program

This contains a simple example of how to use the `ghostty-vt` C library
with a C program.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
