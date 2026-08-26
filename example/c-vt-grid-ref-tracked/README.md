# Example: `ghostty-vt` Tracked Grid References

This contains a simple example of how to use the `ghostty-vt` terminal and
tracked grid reference APIs to keep a long-lived reference to a cell as the
terminal scrolls, detect when that reference loses its meaningful location,
and move the same tracked handle to a new point.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
