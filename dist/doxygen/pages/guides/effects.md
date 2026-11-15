# Effects {#guide-effects}

An effect is a callback the terminal calls when a program asks for something the
terminal can't do by itself. That means things like ringing the bell, changing
the window title, writing to the clipboard, or answering a query.

Why callbacks? libghostty-vt has no window, no clipboard and no pty. Those are
yours. When a program writes a BEL we know what it means, but we can't make a
sound. So we tell you, and you decide what a bell is.

By default, the VT write functions only process sequences that directly change
terminal state. Anything with a side effect or a reply is ignored until you
register a callback for it. That includes queries, so a program that asks a
question gets no answer.

If you're only feeding bytes into a terminal to read the result back, you can
skip this page. You need effects as soon as a real program runs in the terminal.

## Registering an effect {#guide-effects-registering}

Each effect has a `GhosttyTerminalOption` value. Register a callback by passing
it to ghostty_terminal_set(), and clear it by passing `NULL`, which turns the
effect off again:

```c
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL,
                     (const void *)on_bell);

// Later, stop listening for the bell.
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, NULL);
```

Set a userdata pointer with `GHOSTTY_TERMINAL_OPT_USERDATA` and we pass it to
every callback, so you can get back to your own application state without global
variables. There's one userdata pointer per terminal. You can't give different
callbacks different ones.

## The rules for callbacks {#guide-effects-rules}

Callbacks run synchronously, in the middle of ghostty_terminal_vt_write() or
ghostty_terminal_vt_write_until(). All of these rules come from that.

You can't write to the same terminal from a callback. The terminal is still
working through the first write, and it isn't reentrant. This applies to both
ghostty_terminal_vt_write() and ghostty_terminal_vt_write_until().

We don't check for this, and you won't get an error. Your bytes go into the
parser in whatever state the first write left it, so what happens depends on the
sequence that called you. Bytes written from a title callback are read as part
of the OSC that fired it, so text never reaches the screen, and a BEL or ESC in
them runs that OSC a second time. Bytes written from a bell callback land ahead
of the rest of the first write. Don't depend on any of this.

Don't block, and don't do anything expensive. Further IO processing waits until
your callback returns, so a slow callback is a slow terminal.

Copy what you want to keep. Strings and buffers passed to a callback are
borrowed, and they're only valid until it returns.

## The effects {#guide-effects-table}

There are 19 effects:

| Option                                     | Callback type                        | Trigger                                                                 |
| ------------------------------------------ | ------------------------------------ | ----------------------------------------------------------------------- |
| #GHOSTTY_TERMINAL_OPT_WRITE_PTY            | GhosttyTerminalWritePtyFn            | VT query and mode reports written back to the pty                       |
| #GHOSTTY_TERMINAL_OPT_BELL                 | GhosttyTerminalBellFn                | BEL character (0x07)                                                    |
| #GHOSTTY_TERMINAL_OPT_TITLE_CHANGED        | GhosttyTerminalTitleChangedFn        | Title change via OSC 0 / OSC 2                                          |
| #GHOSTTY_TERMINAL_OPT_PWD_CHANGED          | GhosttyTerminalPwdChangedFn          | Pwd change via OSC 7 / OSC 9 / OSC 1337                                 |
| #GHOSTTY_TERMINAL_OPT_ENQUIRY              | GhosttyTerminalEnquiryFn             | ENQ character (0x05)                                                    |
| #GHOSTTY_TERMINAL_OPT_XTVERSION            | GhosttyTerminalXtversionFn           | XTVERSION query (`CSI > q`)                                             |
| #GHOSTTY_TERMINAL_OPT_SIZE                 | GhosttyTerminalSizeFn                | XTWINOPS query (`CSI 14/16/18/19 t`) or mode 2048 enable                |
| #GHOSTTY_TERMINAL_OPT_COLOR_SCHEME         | GhosttyTerminalColorSchemeFn         | Color scheme query (`CSI ? 996 n`)                                      |
| #GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES    | GhosttyTerminalDeviceAttributesFn    | Device attributes query (`CSI c`, `CSI > c`, `CSI = c`)                 |
| #GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE      | GhosttyTerminalClipboardWriteFn      | Clipboard write via OSC 52 / OSC 1337 / OSC 5522                        |
| #GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ       | GhosttyTerminalClipboardReadFn       | Clipboard read via OSC 52 `?` / OSC 5522                                |
| #GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION | GhosttyTerminalDesktopNotificationFn | Desktop notification via OSC 9 / OSC 777                                |
| #GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT      | GhosttyTerminalProgressReportFn      | Progress report via OSC 9;4                                             |
| #GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS       | GhosttyTerminalProgramStatusFn       | Program status report via OSC 7501                                      |
| #GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE     | GhosttyTerminalUnknownSequenceFn     | APC or OSC sequence we don't implement. See @ref guide-custom-sequences |
| #GHOSTTY_TERMINAL_OPT_RENDER_HOLD          | GhosttyTerminalRenderHoldFn          | Synchronized output (mode 2026) begins or ends                          |
| #GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT      | GhosttyTerminalSemanticPromptFn      | Shell reports a prompt or command step via OSC 133                      |
| #GHOSTTY_TERMINAL_OPT_RESET                | GhosttyTerminalResetFn               | Full reset (RIS, `ESC c`)                                               |
| #GHOSTTY_TERMINAL_OPT_RESIZE_WINDOW        | GhosttyTerminalResizeWindowFn        | Window resize request (`CSI 8 t`)                                       |

## Common callbacks {#guide-effects-common}

These are the callbacks most terminals start with. Each one is from the same
example program, which prints what it receives.

### Replying to the program

Start with this one. Every reply the terminal generates comes through it, such
as the answer to a device status report or a mode query. Write the bytes to your
pty. The data is only valid during the call, so copy it if you can't write it
right away.

@snippet c-vt-effects/src/main.c effects-write-pty

Full program: @ref c-vt-effects/src/main.c

### The bell

The bell has no data at all. This one counts bells in the userdata pointer.

@snippet c-vt-effects/src/main.c effects-bell

Full program: @ref c-vt-effects/src/main.c

### Title changes

The callback tells you the title changed, but not what it changed to. You can
read the new title with `GHOSTTY_TERMINAL_DATA_TITLE` inside the callback.

@snippet c-vt-effects/src/main.c effects-title-changed

Full program: @ref c-vt-effects/src/main.c

### Clipboard writes

A write is a request, not a command. You should ask the person using your
terminal unless `granted` is set, and the stream waits until your callback
returns while you do.

Answer by calling `reply` before you return. If you return without replying, the
write is denied. Every entry in `contents` is a representation of the same
value, so commit them together. A `contents_len` of zero asks you to clear the
clipboard.

@snippet c-vt-effects/src/main.c effects-clipboard-write

Full program: @ref c-vt-effects/src/main.c

### Clipboard reads

Reads work the same way. Ask first unless `granted` is set, and call `reply`
before you return. If you return without replying, the program gets an empty
clipboard for OSC 52 and `EPERM` for OSC 5522.

@snippet c-vt-effects/src/main.c effects-clipboard-read

Full program: @ref c-vt-effects/src/main.c

### Sequences we don't implement

The callback for unknown sequences has more to it than the others, so it has its
own guide. See @ref guide-custom-sequences.

## Putting it together {#guide-effects-register}

This registers the callbacks above, along with the unknown sequence callback,
and then writes a sequence for each one so you can watch them fire.

@snippet c-vt-effects/src/main.c effects-register

Full program: @ref c-vt-effects/src/main.c
