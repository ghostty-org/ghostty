# Example: `ghostty-vt` Terminal Effects

This contains a simple example of how to register and use terminal
effect callbacks (`write_pty`, `bell`, `title_changed`) with the
`ghostty-vt` C library.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but this repo emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
