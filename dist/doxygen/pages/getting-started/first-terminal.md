# Your First Terminal {#first-terminal}

Let's create a simple terminal that processes real bytes and produces a rendered
screen. There's no GUI or real pty attached to it, to keep the example simple
and focused on libghostty-vt.

Every feature in libghostty-vt builds on the basics shown here: the function
call style, error handling, and option setting. If you go through this page,
then you'll be able to easily adopt the remainder of the library.

We'll walk through @ref c-vt-stream/src/main.c "c-vt-stream". @ref installing
shows how to build it, and in the repo it's one `zig build run`.

## Create a Terminal {#first-terminal-create}

@snippet c-vt-stream/src/main.c vt-stream-init

Full program: @ref c-vt-stream/src/main.c

ghostty_terminal_new() takes an allocator, a place to put the handle, and the
size in columns and rows. Pass NULL for the allocator unless you have a reason
not to. See @ref memory.

libghostty-vt functions never crash your program by design, given valid use of
the API. All failure scenarios including allocation failures are handled and
returned, and libghostty-vt never puts itself into a corrupt state. Always check
the GhosttyResult of every function.

## Write Bytes {#first-terminal-write}

@snippet c-vt-stream/src/main.c vt-stream-write

Full program: @ref c-vt-stream/src/main.c

ghostty_terminal_vt_write() takes the raw bytes a program wrote (e.g. from a
pty, session recording, network, etc.). libghostty-vt parses all escape
sequences and applies their logic appropriately to the terminal state. Above,
`\x1b[1;32m` turns on bold green. `\x1b[5B` moves the cursor down five rows.

This call never fails, which is why there's no result to check. You also don't
need to line your writes up with anything. A sequence or a UTF-8 character can
be split across two calls and the parser picks up where it left off.

It is safe to pass untrusted data to this function. Bad input gets skipped. By
default, without any @ref guide-effects "effects", untrusted data can't cause
any damage. Memory usage is bounded and no side effects are possible.
libghostty-vt is fuzzed 24/7 with multiple dedicated machines to keep this
function safe against all forms of data input.

Your program can widen this. Be careful with effects, such as clipboard reads,
and with the options that let Kitty images load from files or shared memory.
Anything you read back, such as the title, also came from untrusted data, so
treat it that way.

Note the end of each line is `\r\n`, not just `\n`. In terminal emulators, a
`\n` alone just moves the cursor down. It doesn't move it back to the first
column.

You rarely see this because a pty normally turns a program's `\n` into `\r\n` in
the kernel line discipline logic. But if you feed in bytes that didn't come
through a pty, such as a text file, that's now your job. Beware!

## Read the Screen {#first-terminal-read}

@warning The formatter is only for simple snapshots of the screen, such as
saving it to a file or printing it once. Don't use it for a real, live render.
Use a render state instead. See @ref first-terminal-render.

@snippet c-vt-stream/src/main.c vt-stream-read

Full program: @ref c-vt-stream/src/main.c

A terminal screen is a grid of cells with styles, wide characters, wrapped rows,
etc. The formatter processes this grid state and produces the screen state into
a format requested: plain text, HTML, VT sequences.

A new formatter by default emits plain text with trailing whitespace trimmed, so
the two ghostty_formatter_set() calls here only show you where those options
are.

The program prints this:

```
Top-left corner
Green Text




Moved down!
New content
Line A
Line B
Line C
```

Notice what's missing. We wrote `Hello, World!` first, but `Top-left corner`
went on top of it after the cursor moved to row 1. This shows that the
formatter is processing a real terminal screen.

## Draw the Screen {#first-terminal-render}

The RenderState API exists to build a high-performance, low-latency,
frame-by-frame renderer. It can be used as the foundation for CPU or GPU
rendering. It does dirty tracking, viewport handling, smooth scroll handling,
and more.

@snippet c-vt-stream/src/main.c vt-stream-render

Full program: @ref c-vt-stream/src/main.c

A real renderer repeats three steps for every frame: update, draw, clean. Create
the handles once, outside of that loop.

ghostty_render_state_update() is the only step that touches the terminal. After
that, you draw from the render state alone, so your renderer doesn't get in the
way of the program writing to the terminal. The update only redoes what changed.
Because only update needs access to the terminal, this is the only critical
area that requires a lock for multi-threaded terminal and renderers.

ghostty_render_state_row_iterator_next_dirty() skips the rows that didn't
change, which is most of them in most frames. Once you've drawn a complete
frame, ghostty_render_state_clean() marks it as done. An update never clears the
dirty state, so without this call every row stays dirty.

Row and cell data is only valid until the next update, so don't hold on to it.

This program draws by printing, so you see the same screen as the formatter
printed, except that `Green Text` is now bold. It's still not green, because we
didn't read the colors. See @ref guide-rendering for the colors, the cursor, and
how to share a terminal with a renderer thread.

## Free Everything {#first-terminal-free}

libghostty-vt does allocate at times, and those allocations need to be freed.

The buffer from ghostty_formatter_format_alloc() is yours. Free it with
ghostty_free() and the same allocator you gave the format call, not with the C
`free()`. See @ref memory-buffers.

The formatter borrows the terminal, so the terminal has to outlive it. Free the
formatter first with ghostty_formatter_free().

The render state and its iterators are yours too. Free the cells with
ghostty_render_state_row_cells_free(), the row iterator with
ghostty_render_state_row_iterator_free(), and then the render state with
ghostty_render_state_free().

The terminal goes last, with ghostty_terminal_free().

The rules for handles are the same across the whole library. See @ref
conventions-handles.

## What to Read Next {#first-terminal-next}

- @ref guide-effects - Answer the things a program asks of the terminal.
- @ref example-programs - Complete programs for everything else.
