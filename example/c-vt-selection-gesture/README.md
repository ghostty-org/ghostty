# Example: `ghostty-vt` Selection Gestures

Turn synthetic press, drag, release, and deep-press events into selections
with the `ghostty-vt` selection gesture API, then format the resulting
selection snapshots.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
