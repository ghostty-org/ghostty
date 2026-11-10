# Example: `ghostty-vt` Build Info

Query compile-time build configuration with the `ghostty-vt` build info API.
It also checks the version of the headers when compiling, and checks at
runtime that the library your program loaded matches those headers.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
