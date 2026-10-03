# Example: `ghostty-vt` Kitty Drag and Drop

This contains a simple example of how to connect the
[Kitty drag and drop protocol](https://sw.kovidgoyal.net/kitty/dnd-protocol/)
(OSC 72) in a `ghostty-vt` terminal to native drag and drop. It plays
both sides: the program's escape sequences are fed to the terminal, and
native drag and drop activity is reported with the `ghostty_kitty_dnd_*`
functions. It shows a drop forwarded to a program that registered to
accept drops, with the program's data requests served from the native
drop, and a drag the program offers being started.

This uses a `build.zig` and `Zig` to build the C program so that we
can reuse a lot of our build logic and depend directly on our source
tree, but Ghostty emits a standard C library that can be used with any
C tooling.

## Usage

Run the program:

```shell-session
zig build run
```
