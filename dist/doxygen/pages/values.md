# Getting and Setting Values {#values}

libghostty-vt has hundreds of values you may want to read or change.
In order to provide long-term ABI compatibility and to avoid a massive
symbol surface area, most values go through the same small set of functions
using a standard getter and setter format.

The key is an enum value that names what you want. The value itself goes
through a `void *`, and each key documents its type. This reads the terminal's
column count, for example:

```c
uint16_t cols = 0;
GhosttyResult result =
    ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols);
```

Every function whose name ends in `_get`, `_set` or `_get_multi` works this way,
such as ghostty_terminal_get(), ghostty_render_state_set() and
ghostty_key_encoder_set().

## Newer Headers, Older Libraries {#values-older-libraries}

We add new keys over time. A program built with a newer header can end up
running against an older copy of the library, for example when the library is
installed separately as a shared library.

If you pass a key that the loaded library doesn't know, the call returns
GHOSTTY_UNSUPPORTED and doesn't touch your output. This works the same way in
debug and release builds of the library.

That lets you use a newer key when it's there and fall back when it isn't. In
this example, imagine that GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING was added
in a later release than the library your program loads:

```c
bool blinking = false;
switch (ghostty_render_state_get(state,
                                 GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING,
                                 &blinking)) {
case GHOSTTY_SUCCESS:
  break;
case GHOSTTY_UNSUPPORTED:
  // This library predates the key. Use a sensible default instead.
  blinking = true;
  break;
default:
  // A real error, such as a NULL state. Handle it as usual.
  return;
}
```

GHOSTTY_UNSUPPORTED and GHOSTTY_INVALID_VALUE mean different things.
GHOSTTY_UNSUPPORTED means the library doesn't know the key at all.
GHOSTTY_INVALID_VALUE means the library knows the key, but something you passed
with it is wrong, such as a NULL pointer or an enum value that is out of range.

The same check applies to enum values you pass as plain arguments or inside
option values, such as a GhosttyKeyAction or the tag of a GhosttyPoint. A value
the library doesn't recognize returns GHOSTTY_INVALID_VALUE and leaves the
object unchanged.

## Reading Several Values at Once {#values-multi}

The `_get_multi` functions read several keys in one call. They help when each
call is expensive, such as across FFI. For example, in the libghostty-vt
[Go bindings](https://tangled.org/mitchellh.com/go-libghostty), `_get_multi`
APIs improve performance massively.

They process keys in order and stop at the first one that fails. Values for the
keys before it have already been written, and `out_written` receives the index
of the key that failed. So you can see exactly which key the library rejected:

```c
GhosttyTerminalData keys[] = {
    GHOSTTY_TERMINAL_DATA_COLS,
    GHOSTTY_TERMINAL_DATA_ROWS,
};
uint16_t cols = 0, rows = 0;
void *values[] = { &cols, &rows };
size_t written = 0;

GhosttyResult result =
    ghostty_terminal_get_multi(terminal, 2, keys, values, &written);
if (result != GHOSTTY_SUCCESS) {
  // keys[written] failed. Every value before it is valid.
}
```
