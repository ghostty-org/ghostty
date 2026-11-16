# Example: `ghostty-vt` Tracked Grid References

Keep a long-lived reference to a cell as the terminal scrolls with the
`ghostty-vt` tracked grid reference APIs. The program detects when that
reference loses its meaningful location and moves the same tracked handle to
a new point.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
