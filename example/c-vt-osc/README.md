# Example: `ghostty-vt` OSC Parser

Parse an OSC sequence and read the window title out of it with the
`ghostty-vt` OSC parser.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
