# Example: `ghostty-vt` Render State

This contains an example of how to use the `ghostty-vt` render-state API
to create a render state, update it from terminal content, iterate rows
and cells, read styles and colors, inspect cursor state, and manage dirty
tracking.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
