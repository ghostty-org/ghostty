# Example: Hello, World

The smallest complete libghostty-vt program. It creates a terminal, writes
text with a color sequence in it, and prints what ended up on the screen.
This is the program on the main page of the documentation, so it leaves out
error checks to stay short. Use `c-vt-stream` as a starting point instead.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
