# Scrollback {#guide-scrollback}

Scrollback is the history that has scrolled off the top of the screen, kept so
you can scroll back and read it.

It's also where a terminal's memory goes. Most of what a terminal holds is its
screen contents and scrollback, and a program can write forever. So you need to
decide how much history to keep, and if you're running a lot of terminals, what
to do about the memory it takes.

The default limit is small, so nearly every terminal wants to set its own. The
scrollbar and the compression sections are only for those who need them. Most
programs never need compression.

## Limits {#guide-scrollback-limits}

Scrollback has two limits, and both are set with ghostty_terminal_set(). If you
set both, the first one reached is used.

| Option                                     | Default      | `SIZE_MAX` | `NULL`               |
| ------------------------------------------ | ------------ | ---------- | -------------------- |
| #GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES | 10,000 bytes | No limit   | Restores the default |
| #GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES | No limit     | No limit   | No limit             |

```c
// Keep up to 10 MB of history.
size_t max_bytes = 10 * 1024 * 1024;
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                     &max_bytes);
```

They're useful together, because each one depends on things you don't control.
The byte limit is reached with fewer lines if the program uses more styles, and
the line limit is reached sooner with a narrower terminal.

Both limits are estimates. History lives in pages, the smallest unit of grid
space we allocate, and we only prune whole pages. A page is about 400 KB at the
time of writing, so the byte limit is accurate to about that much, and the
default of 10,000 bytes is one page in practice. The line limit almost always
keeps more lines than you asked for, usually somewhere from dozens to a hundred
or so.

Lowering a limit removes eligible complete pages right away. A byte limit of
zero disables scrollback and erases the history you have.

Read the limits back with `GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES` and
`GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES`. They return `GHOSTTY_NO_VALUE`
when the limit is unlimited, and they always report the primary screen's value,
even while the alternate screen is active.

## Scrolling the viewport {#guide-scrollback-viewport}

The viewport is the part of the terminal you're showing. Move it with
ghostty_terminal_scroll_viewport(), which takes a tagged union:

| Tag                                            | Value field    | What it does                                         |
| ---------------------------------------------- | -------------- | ---------------------------------------------------- |
| #GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP          |                | Scroll to the top of the scrollback                  |
| #GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM       |                | Scroll to the bottom (the active area)               |
| #GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA        | `delta`        | Scroll by a number of rows, negative for up          |
| #GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW          | `row`          | Scroll so that this row is the first one visible     |
| #GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT | `delta_prompt` | Scroll by a number of prompts, negative for backward |

```c
GhosttyTerminalScrollViewport behavior = {
  .tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA,
  .value = { .delta = -5 },
};
ghostty_terminal_scroll_viewport(terminal, behavior); // up 5 rows
```

Row 0 is the top of the scrollback. The row is clamped so the viewport never
scrolls past the top of the active area. With no scrollback, such as on the
alternate screen, the viewport stays on the active area.

Scrolling by prompts needs semantic prompt markers from the shell. Without a
matching prompt it does nothing.

`GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE` tells you if the viewport is following
the active area, or if someone has scrolled up into history.

## The scrollbar {#guide-scrollback-scrollbar}

Read `GHOSTTY_TERMINAL_DATA_SCROLLBAR` to get a GhosttyTerminalScrollbar, which
has the three numbers you need to draw one: `total` rows in the scrollable area,
the `offset` of the viewport into them, and the `len` of the visible area.

There's no notification when these change, and that's on purpose. Poll once per
frame or once per write batch and compare the result with the last one. This is
what Ghostty's own renderer does. It's cheap, because we keep the total up to
date as the terminal changes and cache the offset. The one exception is the
first read after the viewport moves somewhere that isn't an absolute row, which
can cost O(pages).

The `offset` is the same row space as `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW`, so
when someone drags your scrollbar you can scroll straight to the position you
drew.

```c
GhosttyTerminalScrollbar bar;
ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);

// Someone dragged the scrollbar halfway down.
GhosttyTerminalScrollViewport behavior = {
  .tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW,
  .value = { .row = (size_t)((bar.total - bar.len) / 2) },
};
ghostty_terminal_scroll_viewport(terminal, behavior);
```

If you only want counts, `GHOSTTY_TERMINAL_DATA_TOTAL_ROWS` is the rows in the
active screen including scrollback, and `GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS`
is the rows in scrollback.

## Resizing {#guide-scrollback-resize}

By default, a resize can pull rows out of scrollback and back into the active
area. Growing the rows reveals scrollback if the cursor is on the bottom row,
and a column reflow that needs fewer rows reveals it too.

Most programs want this and can skip this section. But if your pty keeps its own
screen buffer without scrollback, it can't pull rows back, and it will disagree
with the terminal about the screen after a resize. Windows ConPTY is the case
that needs this. Set `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK` to false:

```c
bool pull_scrollback = false;
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK,
                     &pull_scrollback);
```

Now growing the rows always appends blank rows at the bottom, and a column
reflow keeps the top of the active area on the same content. A line that's fully
in scrollback stays there, but a soft-wrapped line with at least one row still
in the active area can still unwrap back into view. The setting survives a full
reset (RIS), and passing `NULL` restores the default of true.

## Memory use {#guide-scrollback-memory}

Read `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE` to see how much memory a terminal
holds. This is for applications that host many terminals and have to stay inside
a budget, for example by compressing or closing whichever ones hold the most.

GhosttyTerminalMemoryUsage is a sized struct, so initialize it with
GHOSTTY_INIT_SIZED(). If `size` is too small, the read returns
`GHOSTTY_INVALID_VALUE` and leaves the struct alone. The read never decompresses
scrollback, but it does look at every page, so don't do it after every write.

Budget against the resident bytes. That's the physical memory the pages use
right now. Virtual bytes are the address space reserved for pages.

Each screen has its own fields, with a `primary_` or `alternate_` prefix, so add
them together for the terminal's total. The primary screen holds shell output
and all of the scrollback. The alternate screen is used by full-screen programs
such as text editors, and its fields are zero until a program first switches to
it.

Colors, styles and hyperlinks are stored in pages, so they're already in the
page figures. Images are stored separately and have their own fields. Small
things outside of pages, such as the window title and internal bookkeeping,
aren't counted. They're small next to the pages once a terminal has any
scrollback.

On macOS, the system takes back memory freed by compression lazily, when
something else needs it. Until then, the memory the system reports for your
process (its RSS) can be higher than the resident figures here.

@snippet c-vt-compression/src/main.c memory-usage

Full program: @ref c-vt-compression/src/main.c

## Compression {#guide-scrollback-compression}

Old scrollback is mostly sitting there, so we can compress it. This changes how
the history is stored and nothing else. The contents and the scrollback limit
stay the same, and reading compressed history restores it transparently.

You drive it. libghostty-vt doesn't create a timer or a background thread, so
nothing is compressed until you ask. The shape is an idle timer: restart it when
the terminal changes, and when it fires, compress a step at a time until there's
nothing left to do.

ghostty_terminal_compression_activity() returns an opaque token. Only compare it
for equality, because it can wrap, and a change in either direction means the
same thing. It changes only when compression-relevant state changes, so restart
your idle timer when it does.

@snippet c-vt-compression/src/main.c compression-activity

Full program: @ref c-vt-compression/src/main.c

When the timer fires, call ghostty_terminal_compress() with
`GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL`, which does a bounded amount of
work. There are three results:

- `GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING` means there's more to do.
  Schedule another step while the terminal stays idle.
- `GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE` means you're done until the
  activity token changes.
- `GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED` means this platform can't
  free memory this way. The `compression_supported` field of
  GhosttyTerminalMemoryUsage tells you the same thing, and to lower memory there
  you have to do something else, such as closing a terminal.

@snippet c-vt-compression/src/main.c compression-idle-step

Full program: @ref c-vt-compression/src/main.c

Complete means the pass finished, not that every page was compressed.
Compression is opportunistic. A page can be unprofitable to compress, or hit an
allocation or reclamation failure.

`GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL` does one synchronous scan of every
eligible page instead. It can stall on large scrollback.

ghostty_terminal_compress() isn't thread-safe with anything else on the same
terminal, so serialize it with your writes, rendering, searches and other
terminal access.

Compression lowers the resident figure but not the virtual one, because each
page's space stays reserved for decompression.
