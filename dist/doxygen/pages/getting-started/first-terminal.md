# Your First Terminal {#first-terminal}

A terminal is a grid of cells and a parser that changes it. This page makes one, writes bytes into it, reads the screen back, and frees it. There's no window and no pty yet.

Why start here? Everything else in the library builds on these four steps. They're also all you need for a tool that only reads terminal output, such as a replay viewer or a CI log viewer. If that's what you're building, this page may be the only one you need.

We'll walk through @ref c-vt-stream/src/main.c "c-vt-stream". @ref installing shows how to build it, and in the repo it's one `zig build run`.

## Create a Terminal {#first-terminal-create}

@snippet c-vt-stream/src/main.c vt-stream-init

Full program: @ref c-vt-stream/src/main.c

ghostty_terminal_new() takes an allocator, a place to put the handle, and the size in columns and rows. Pass NULL for the allocator unless you have a reason not to. See @ref memory.

The result matters here. This call allocates, so it can fail. The example uses `assert` to stay short. Your program should handle it.

## Write Bytes {#first-terminal-write}

@snippet c-vt-stream/src/main.c vt-stream-write

Full program: @ref c-vt-stream/src/main.c

ghostty_terminal_vt_write() takes the bytes a program wrote. Text lands at the cursor, and escape sequences change the state of the terminal. `\x1b[1;32m` turns on bold green. `\x1b[5B` moves the cursor down five rows.

This call never fails, which is why there's no result to check. The bytes come from programs you don't control, so bad input gets logged and skipped. You also don't need to line your writes up with anything. A sequence or a UTF-8 character can be split across two calls and the parser picks up where it left off.

Look at the end of each line. It's `\r\n`, not `\n`, and that's the mistake everyone makes first. A line feed moves the cursor down one row and leaves it in the same column. A carriage return is what moves it back to column 0. So `"one\ntwo\nthree\n"` comes out as a staircase:

```
one
   two
      three
```

You rarely see this because a pty normally turns a program's `\n` into `\r\n` on the way out. If you feed in bytes that didn't come through a pty, such as a text file, that's now your job.

Queries are the other surprise. A sequence that asks the terminal a question gets no answer until you register a callback for it. See @ref guide_effects.

## Read the Screen {#first-terminal-read}

@snippet c-vt-stream/src/main.c vt-stream-read

Full program: @ref c-vt-stream/src/main.c

Why a formatter? The screen isn't a string. It's a grid of cells with styles, wide characters and wrapped rows, so something has to decide what that grid looks like as text. That's the formatter. It can emit plain text, VT sequences or HTML. A new formatter already emits plain text with trailing whitespace trimmed, so the two ghostty_formatter_set() calls here only show you where those options are.

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

Notice what's missing. We wrote `Hello, World!` first, but `Top-left corner` went on top of it after the cursor moved to row 1. This is a screen, not a log.

A formatter is the right tool for getting text out. It's the wrong tool for drawing. For that you want a render state, which @ref building-a-terminal covers.

## Free Everything {#first-terminal-free}

Three things in this program need freeing, and each one has a rule.

The buffer from ghostty_formatter_format_alloc() is yours. Free it with ghostty_free() and the same allocator you gave the format call, not with the C `free()`. See @ref memory-buffers.

The formatter borrows the terminal, so the terminal has to outlive it. Free the formatter first with ghostty_formatter_free().

The terminal goes last, with ghostty_terminal_free().

The rules for handles are the same across the whole library. See @ref conventions-handles.

## What to Read Next {#first-terminal-next}

- @ref building-a-terminal - Connect this to a pty, a renderer and a keyboard.
- @ref guide_effects - Answer the things a program asks of the terminal.
- @ref example-programs - Complete programs for everything else.
