# Building a Terminal Emulator {#building-a-terminal}

A terminal emulator is a loop. Bytes come in from a program, the screen changes, you draw it, and your input goes back to the program. libghostty-vt is the middle of that loop. The pty, the window, the font and the keyboard are yours.

This page shows how those pieces connect, so you know what you're signing up for before you read the guides. If you only read terminal output and never draw it, @ref first-terminal is enough and you can skip this.

[Ghostling](https://github.com/ghostty-org/ghostling) is the whole loop in one C file, and we refer to it throughout. It's a demo and not a daily driver, but it runs real programs. It also builds against an older libghostty-vt, so you'll see a few older function names in it.

```
                  ┌───────────────────────┐
                  │  the running program  │
                  └───────────┬───────────┘
                              │
                             pty
                              │
      ┌───────────────┬───────┴────────────────┐
      │ 1. output     ▲ 2. replies             ▲ 4. input
      ▼               │                        │
 ┌────────────────────┴──┐               ┌─────┴─────┐
 │       terminal        │               │ encoders  │
 └───────────┬───────────┘               └─────▲─────┘
             │ 3. update                       │
             ▼                                 │
 ┌───────────────────────┐               keys and mouse
 │     render state      │
 └───────────┬───────────┘
             ▼
       your renderer
```

Each numbered arrow is a section below.

## 1. Bytes from the Pty {#building-pty}

A pty is a pair of file descriptors the operating system gives you. The program runs with one end as its stdin, stdout and stderr, so it believes it's talking to a terminal. You hold the other end. The library doesn't create ptys, so that part is up to you. See `pty_spawn` in Ghostling for how to do it with `forkpty`.

Everything you read from your end goes straight into ghostty_terminal_vt_write(). Ghostling does it like this:

```c
uint8_t buf[4096];
ssize_t n = read(pty_fd, buf, sizeof(buf));
if (n > 0) ghostty_terminal_vt_write(terminal, buf, (size_t)n);
```

You don't need to find sequence boundaries first. Feed in whatever `read` gave you. See @ref first-terminal-write.

## 2. Effects Back to the Pty {#building-effects}

Programs ask the terminal questions. Vim and tmux both do it at startup. The answers have to go back to the program, so you register a callback that writes them to the pty:

@snippet c-vt-effects/src/main.c effects-write-pty

Full program: @ref c-vt-effects/src/main.c

The example prints the bytes so you can see them. Your callback writes them to the pty. Use #GHOSTTY_TERMINAL_OPT_USERDATA to get at your file descriptor.

Don't skip this one. Without it, queries get no answer, and a program can hang waiting for one.

Some questions need information only you have, such as the size in pixels or whether you're in dark mode. Ghostling registers five more callbacks for those and for title changes: #GHOSTTY_TERMINAL_OPT_SIZE, #GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, #GHOSTTY_TERMINAL_OPT_XTVERSION, #GHOSTTY_TERMINAL_OPT_COLOR_SCHEME and #GHOSTTY_TERMINAL_OPT_TITLE_CHANGED. That's a good first set.

Callbacks run in the middle of ghostty_terminal_vt_write(), so you can't write to the same terminal from one, and you shouldn't block in one. Ghostling's pty is non-blocking, so if the pty is full it drops the reply. See @ref guide-effects for all 19 effects and the rules.

## 3. Render State to Your Renderer {#building-render}

You don't draw from the terminal. You draw from a render state, which is a copy of what you need for one frame. The library stops there. It doesn't shape text or touch a GPU. Ghostling draws with Raylib, and you can use anything that can put glyphs on a screen.

Create one with ghostty_render_state_new() and keep it. Then for each frame, call ghostty_render_state_update() and read from the render state. It tells you how much changed:

@snippet c-vt-render/src/main.c render-dirty-check

Full program: @ref c-vt-render/src/main.c

Walk the rows and cells and draw what's dirty. After you finish the frame, clear the dirty state yourself. The update call never does:

@snippet c-vt-render/src/main.c render-dirty-reset

Full program: @ref c-vt-render/src/main.c

The update is the only step that needs the terminal. If your IO and your renderer are on different threads, hold a lock around the update and draw without it. Ghostling is single-threaded, so it doesn't bother. See @ref guide-rendering and @ref conventions-threads.

## 4. Encoders Back to the Pty {#building-input}

A key press isn't a byte. The same key is encoded differently depending on which modes the program has turned on, such as application cursor keys or the Kitty keyboard protocol. The encoders know these rules. You tell them what happened, and they give you the bytes to write to the pty:

@snippet c-vt-encode-key/src/main.c key-encode

Full program: @ref c-vt-encode-key/src/main.c

The example sets the Kitty flags by hand because it has no terminal. You do have one, so call ghostty_key_encoder_set_from_terminal() before you encode. That's how a mode the program just changed reaches the encoder. Ghostling does it every frame. Then write the bytes to the pty, not to stdout.

The mouse works the same way, with ghostty_mouse_encoder_set_from_terminal(). That call doesn't set the size, so also give the encoder your screen and cell sizes with #GHOSTTY_MOUSE_ENCODER_OPT_SIZE. It needs them to turn pixels into cells. See @ref c-vt-encode-mouse/src/main.c "c-vt-encode-mouse".

Focus and paste are smaller. Only send focus events when the program has turned on #GHOSTTY_MODE_FOCUS_EVENT, and use ghostty_focus_encode() to get the bytes. Send pastes through ghostty_terminal_paste().

See @ref guide-input.

## Resizing {#building-resize}

The diagram leaves out one thing. When your window changes size, two things need to know: call ghostty_terminal_resize() so the text reflows, and tell the pty so the program finds out. On Unix that's the `TIOCSWINSZ` ioctl.

Call ghostty_terminal_resize() once right after you create the terminal too. ghostty_terminal_new() doesn't take a cell size in pixels, and images and size reports need one.

## The Whole Loop {#building-loop}

Put together, one frame of Ghostling does this:

1. If the window changed size, resize the terminal and the pty.
2. If focus changed and the program asked to know, send a focus event.
3. Read everything from the pty into the terminal. Effects run here.
4. Encode keys and mouse events and write them to the pty.
5. Update the render state.
6. Draw it.

That's a terminal emulator. Everything else, such as tabs, splits and configuration, is built on top of this loop and belongs to you.

From here, the @ref guides "Guides" go deeper on each part.
