# Input {#guide-input}

Input is everything a person does that a program needs to hear about: keys,
mouse events, focus changes and pastes. All of it reaches the program the same
way, as bytes on the pty. These functions produce those bytes.

The catch is that the right bytes keep changing. The up arrow is `ESC [ A` until
a program turns on cursor key application mode, and then it's `ESC O A`. A
program can turn on the Kitty keyboard protocol and get a different encoding for
its keys. A click is nothing at all until a program turns on mouse tracking, and
then it's one of five formats. A paste is framed differently under bracketed
paste.

So an encoder has to follow the terminal's modes, or it writes the wrong bytes.

If you have a GhosttyTerminal, following its modes takes one call per encoder.
That's the first section, and it's the one thing on this page you have to get
right. If you only feed a terminal output and read the result, you can skip this
page. You need it as soon as a person can type into your terminal.

## Following the terminal's modes {#guide-input-modes}

Each kind of input follows the terminal in its own way:

| Input | How it follows the terminal                                                                     |
| ----- | ----------------------------------------------------------------------------------------------- |
| Keys  | ghostty_key_encoder_set_from_terminal() copies the modes into the encoder.                      |
| Mouse | ghostty_mouse_encoder_set_from_terminal() copies the tracking mode and format into the encoder. |
| Focus | There's no encoder. You check the mode yourself.                                                |
| Paste | ghostty_terminal_paste() reads the modes itself.                                                |

The two `set_from_terminal` calls read the terminal's state when you make them.
They don't stay attached to it, and a program can change its modes in any write.
So sync the encoder after you write to the terminal, or right before you encode.

```c
// Create a terminal and feed it some VT data that changes modes.
GhosttyTerminal terminal;
ghostty_terminal_new(NULL, &terminal, 80, 24);

// The program might enable the Kitty keyboard protocol here.
ghostty_terminal_vt_write(terminal, vt_data, vt_len);

// Create an encoder and sync its options from the terminal.
GhosttyKeyEncoder encoder;
ghostty_key_encoder_new(NULL, &encoder);
ghostty_key_encoder_set_from_terminal(encoder, terminal);

// Encode a key event using the terminal's modes.
uint8_t buf[128];
size_t written = 0;
ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);

ghostty_key_encoder_free(encoder);
ghostty_terminal_free(terminal);
```

The mouse works the same way with ghostty_mouse_encoder_new(),
ghostty_mouse_encoder_set_from_terminal() and ghostty_mouse_encoder_encode().

Each sync leaves some options to you:

- The key sync replaces all of the encoder's options. That covers cursor key
  application mode, keypad mode, ignoring the keypad with numlock, the alt
  escape prefix, backarrow key mode, modifyOtherKeys state and the Kitty
  keyboard flags. It can't know your macOS option key setting, so it resets
  #GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT to #GHOSTTY_OPTION_AS_ALT_FALSE.
  If you use that option, set it again with ghostty_key_encoder_set() after
  every sync.
- The mouse sync sets the tracking mode and output format. It doesn't touch the
  size or whether a button is held. Those are yours. See @ref guide-input-mouse.

Without a terminal, there's nothing to follow. Set the options yourself with
ghostty_key_encoder_set() and ghostty_mouse_encoder_set(), as the examples below
do.

## Keys {#guide-input-keys}

We encode keys with the legacy encoding or the Kitty keyboard protocol,
depending on the encoder's options.

1. Create an encoder with ghostty_key_encoder_new().
2. Configure it with ghostty_key_encoder_set_from_terminal(), or with
   ghostty_key_encoder_set() if you don't have a terminal.
3. For each key event, create an event with ghostty_key_event_new(), set its
   action, key, modifiers and so on, and encode it with
   ghostty_key_encoder_encode(). Then free it with ghostty_key_event_free(), or
   change its properties and use it again.
4. Free the encoder with ghostty_key_encoder_free() when you're done.

This one has no terminal, so it turns on the Kitty keyboard protocol by hand:

@snippet c-vt-encode-key/src/main.c key-encode

Full program: @ref c-vt-encode-key/src/main.c

Not every key event produces output. An unmodified modifier key usually doesn't,
for example. Those events return #GHOSTTY_SUCCESS with zero bytes written, so
check the count before you write to the pty.

Most sequences are short, so a fixed buffer of 128 bytes usually does. If it's
too small, you get #GHOSTTY_OUT_OF_SPACE with the size you need. Discard what's
in the buffer and encode again with a bigger one.

## Mouse {#guide-input-mouse}

We encode mouse events in the X10, UTF-8, SGR, URxvt and SGR-Pixels formats. The
steps are the same as for keys:

1. Create an encoder with ghostty_mouse_encoder_new().
2. Configure it with ghostty_mouse_encoder_set_from_terminal(), or with
   ghostty_mouse_encoder_set() if you don't have a terminal.
3. For each mouse event, create an event with ghostty_mouse_event_new(), set its
   action, button, modifiers and position, and encode it with
   ghostty_mouse_encoder_encode(). Then free it with ghostty_mouse_event_free(),
   or reuse it.
4. Free the encoder with ghostty_mouse_encoder_free() when you're done.

Event positions are in surface-space pixels, so the encoder has to know your
geometry to turn them into cells. Set it with #GHOSTTY_MOUSE_ENCODER_OPT_SIZE
and a GhosttyMouseEncoderSize. The default is a 1x1 pixel screen with 1x1 pixel
cells, which is never what you have. Set
#GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED as well, to say whether a button
is held. Neither one comes from the terminal.

@snippet c-vt-encode-mouse/src/main.c mouse-encode

Full program: @ref c-vt-encode-mouse/src/main.c

As with keys, not every event produces output, so check the count. And as with
keys, a 128-byte buffer is enough for typical events.

If you turn on #GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, the encoder
deduplicates motion by the last cell. ghostty_mouse_encoder_reset() clears that
state.

## Focus {#guide-input-focus}

A program that turns on focus reporting (mode 1004) wants to know when your
terminal gains or loses focus. ghostty_focus_encode() encodes that as `CSI I` or
`CSI O`. There's no encoder to create and no options to set.

It also doesn't look at the terminal, so it's up to you to check the mode first:

```c
GhosttyTerminalModeConfig focus = {.mode = GHOSTTY_MODE_FOCUS_EVENT};
ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &focus);
if (focus.value) {
  // Encode the event and write it to the pty.
}
```

If the buffer is too small, you get #GHOSTTY_OUT_OF_SPACE and the size you need.

@snippet c-vt-encode-focus/src/main.c focus-encode

Full program: @ref c-vt-encode-focus/src/main.c

## Paste {#guide-input-paste}

What a paste writes to the pty depends on the terminal's state, so the way to
paste is ghostty_terminal_paste(). You give it the MIME types the clipboard
holds (just `text/plain` for an ordinary paste), a GhosttyMimeReader that
produces the data of any one of them, and where the paste came from. The
terminal decides how its current modes apply.

The bytes come out of the #GHOSTTY_TERMINAL_OPT_WRITE_PTY callback, so you need
one installed. See @ref guide-effects.

### What gets written

The terminal sends the program a paste event instead of the data if all three of
these are true:

- Kitty clipboard protocol paste events (mode 5522, #GHOSTTY_MODE_KITTY_PASTE_EVENTS)
  are on.
- The person pasted from a clipboard (#GHOSTTY_PASTE_SOURCE_CLIPBOARD).
- You've installed a clipboard read callback.

A paste event lists the clipboard's MIME types with a one-time password. No data
is read for it. The program then reads what it wants through your clipboard read
callback, which arrives with `granted` set, so you don't need to ask for
permission.

Otherwise the terminal writes the first text representation. Unsafe control
bytes are replaced with spaces. If mode 2004 (#GHOSTTY_MODE_BRACKETED_PASTE) is
on, the text is wrapped in bracketed paste sequences. If it's off, newlines are
converted to carriage returns.

We only pull data through GhosttyPaste::reader when a representation is actually
pasted, so a clipboard holding a large image next to some text costs nothing.
The encoded bytes stream to your callback in chunks as they're produced, never
in one piece. It may run several times for one paste, and you have to write the
pieces to the pty in order.

### Unsafe pastes

Some text could inject commands: a newline or carriage return when the paste
isn't bracketed, or the bracketed paste terminator when it is. We refuse that
text with #GHOSTTY_REJECTED and write nothing, unless GhosttyPaste::allow_unsafe
is set.

The usual flow is to call once, confirm with the person on #GHOSTTY_REJECTED,
and call again with `allow_unsafe` set. Each call reads the text at most once
and buffers it whole while the rule is applied. So your source doesn't have to
stay the same between reads. The confirmed retry just pastes whatever the source
holds by then, and a refused or failed paste writes nothing at all.

@snippet c-vt-paste/src/main.c terminal-paste

Full program: @ref c-vt-paste/src/main.c

### Without a terminal

If you encode without a terminal, there are two building blocks.
ghostty_paste_is_safe() checks whether paste data contains potentially dangerous
sequences. It's conservative, and it ignores terminal state.

@snippet c-vt-paste/src/main.c paste-safety

Full program: @ref c-vt-paste/src/main.c

ghostty_paste_encode() encodes paste data for the pty, including bracketed paste
wrapping and unsafe byte stripping. It modifies your input buffer in place.

@snippet c-vt-paste/src/main.c paste-encode

Full program: @ref c-vt-paste/src/main.c
