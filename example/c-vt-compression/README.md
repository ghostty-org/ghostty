# Example: Scrollback Compression in C

This example shows how a libghostty-vt embedding application can track
compression-relevant terminal activity and perform incremental scrollback
compression after its own idle delay.

libghostty-vt does not create a timer or background thread. The embedding
application remains responsible for scheduling compression and serializing it
with other access to the terminal.

## Usage

Run the example:

```shell-session
zig build run
```
