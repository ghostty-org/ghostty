# Example: VT Stream Processing in C

This contains a simple example of how to use `ghostty_terminal_vt_write`
to parse and process VT sequences in C. This is the C equivalent of
the `zig-vt-stream` example, ideal for read-only terminal applications
such as replay tooling, CI log viewers, and PaaS builder output.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but this repo emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
