# Example: `ghostty-vt` Color Scheme Report Encoding

Encode terminal color scheme reports into escape sequences with the
`ghostty-vt` color scheme report encoding API.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
