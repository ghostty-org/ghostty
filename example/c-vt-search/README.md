# Example: `ghostty-vt` Terminal Search

This contains a simple example of how to use the `ghostty-vt` search
API from C. It writes content into a terminal, searches it for a
string, navigates between the matches like a find bar, and reads the
viewport matches an embedder would use to draw highlights.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
