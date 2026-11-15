# Example: `ghostty-vt` C Key Encoding

Encode key events into terminal escape sequences with the `ghostty-vt` C
library.

This example specifically shows how to:

1. Create a key encoder with the C API
2. Configure Kitty keyboard protocol flags (this example uses KKP)
3. Create and configure a key event
4. Encode the key event into a terminal escape sequence

The example encodes a Ctrl key release event with the Ctrl modifier set,
producing the escape sequence `\x1b[57442;5:3u`.

## Usage

Run the program:

```shell-session
zig build run
```
