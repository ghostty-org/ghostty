# Example: `ghostty-vt` Paste

This contains a simple example of how to paste into a `ghostty-vt`
terminal with `ghostty_terminal_paste`: plain and bracketed (mode 2004)
text pastes, the unsafe-paste confirmation flow, and Kitty clipboard
protocol paste events (mode 5522) including the program's follow-up
clipboard read. The clipboard's data is produced on demand through a
read callback, so only what is actually pasted is ever read, and the
result streams to the pty in chunks. It also shows the terminal-free
building blocks for checking paste safety and encoding paste data.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
