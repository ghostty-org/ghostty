# Example: `ghostty-vt` Terminal Colors

This contains a simple example of how to set default terminal colors,
read effective and default color values, and observe how OSC overrides
layer on top of defaults using the `ghostty-vt` C library.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but this repo emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
