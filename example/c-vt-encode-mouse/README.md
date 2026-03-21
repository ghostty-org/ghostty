# Example: `ghostty-vt` C Mouse Encoding

This example demonstrates how to use the `ghostty-vt` C library to encode mouse
events into terminal escape sequences.

This example specifically shows how to:

1. Create a mouse encoder with the C API
2. Configure tracking mode and output format (this example uses SGR)
3. Set terminal geometry for pixel-to-cell coordinate mapping
4. Create and configure a mouse event
5. Encode the mouse event into a terminal escape sequence

The example encodes a left button press at pixel position (50, 40) using SGR
format, producing an escape sequence like `\x1b[<0;6;3M`.

## Usage

Run the program:

```shell-session
zig build run
```
