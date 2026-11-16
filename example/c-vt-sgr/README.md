# Example: `ghostty-vt` SGR Parser

Parse terminal styling sequences and extract text attributes with the
`ghostty-vt` SGR parser.

The sequence comes from Kakoune. It includes curly underline, RGB
foreground/background colors, and RGB underline color with mixed semicolon
and colon separators.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
