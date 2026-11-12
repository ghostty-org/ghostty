# The Grid {#guide-grid}

The grid is what's on the terminal: rows of cells, each holding text and a
style. This page is how you read it.

The hard part isn't reading a cell. It's naming one. "Row 3" means one thing to
a program moving its cursor, another to someone scrolled back through history,
and another to a tool walking the whole scrollback. And the grid moves under
you. A write can scroll a row into history, a resize can reflow it, and pruning
can throw it away.

So there are two ideas here. A point names a position in one of four coordinate
systems. A grid reference is what a point resolves to: one actual cell. An
untracked reference is a snapshot that dies on the next change to the terminal.
A tracked reference follows its cell, and the terminal pays a little for that on
every change.

This isn't how you draw. Grid references aren't built to sustain the framerates
needed to render a large screen. Use @ref render for that. If you only want the
text out, use @ref formatter. This page is for reading particular cells, and for
anything that has to keep pointing at one.

## Coordinates {#guide-grid-coordinates}

A GhosttyPoint is a coordinate plus a tag that says which coordinate system it's
in:

| Tag                         | Top-left is                    | What it covers                                                      |
| --------------------------- | ------------------------------ | ------------------------------------------------------------------- |
| #GHOSTTY_POINT_TAG_ACTIVE   | The top of the active area     | The area where the cursor can move, at the terminal's full height.  |
| #GHOSTTY_POINT_TAG_VIEWPORT | The top of what you're showing | The visible viewport. This changes when it's scrolled.              |
| #GHOSTTY_POINT_TAG_SCREEN   | The oldest row of scrollback   | The full screen including scrollback, through the last written row. |
| #GHOSTTY_POINT_TAG_HISTORY  | The oldest row of scrollback   | Scrollback only. It ends at the row just before the active area.    |

Here's how they line up on a 24-row terminal with 100 rows of scrollback:

```
                    screen y   history y   active y
+----------------+
| scrollback     |         0           0
|                |       ...         ...
|                |        99          99
+----------------+
| active area    |       100                      0
|                |       ...                    ...
|                |       123                     23
+----------------+
```

The viewport is a 24-row window onto all of that. Scrolled to the bottom, it's
the same rows as the active area. See @ref guide-scrollback for moving it.

`x` is the column and `y` is the row, and both start at zero. `y` is 32 bits
wide because a row in scrollback can be a long way from the top.

ghostty_terminal_grid_ref() resolves a point to a grid reference:

```c
GhosttyGridRef ref = {0};
GhosttyPoint point = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = {.coordinate = {.x = 4, .y = 0}},
};

if (ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS) {
  GhosttyCell cell;
  ghostty_grid_ref_cell(&ref, &cell);
}
```

A point that's out of bounds returns #GHOSTTY_INVALID_VALUE. Lookups with the
active and viewport tags are fast. The screen and history tags may have to walk
the full scrollback page list to find the row, so they can be expensive with a
large scrollback.

ghostty_terminal_point_from_grid_ref() goes the other way. Not every cell exists
in every coordinate system, though. A cell in scrollback has no active
coordinates, and a cell that has scrolled out of view has no viewport
coordinates. In those cases you get #GHOSTTY_NO_VALUE. This is the only way to
get a cell's position: the `x` and `y` fields of a GhosttyGridRef describe
internal storage, not the screen.

## Cells, rows and styles {#guide-grid-cells}

A grid reference gets you everything about its cell:

| Function                         | What you get                                                    |
| -------------------------------- | --------------------------------------------------------------- |
| ghostty_grid_ref_cell()          | The GhosttyCell. Read its fields with ghostty_cell_get().       |
| ghostty_grid_ref_row()           | The GhosttyRow it's on. Read its fields with ghostty_row_get(). |
| ghostty_grid_ref_graphemes()     | The full grapheme cluster, as codepoints.                       |
| ghostty_grid_ref_hyperlink_uri() | The hyperlink URI, if it has one.                               |
| ghostty_grid_ref_style()         | The GhosttyStyle.                                               |

A GhosttyCell is a single grid cell and a GhosttyRow is a single row.
ghostty_cell_get() is the portable way to read a cell. You can also decode one
from the packed layout in ghostty_type_json(), which is authoritative for the
build you linked. Hardcoding bit positions is unsupported. Rows are opaque, so
ghostty_row_get() is the only way to read one.

A GhosttyStyle describes how a cell looks: its foreground, background and
underline colors, plus flags for bold, italic, underline and other decorations.
A cell only holds a style id, #GHOSTTY_CELL_DATA_STYLE_ID. Use
ghostty_grid_ref_style() to get the full style.

This walks the whole grid, reading each cell's text, each row's wrap state, and
a style:

@snippet c-vt-grid-traverse/src/main.c grid-ref-traverse

Full program: @ref c-vt-grid-traverse/src/main.c

## Untracked references {#guide-grid-untracked}

A GhosttyGridRef is untracked. It's a value that snapshots one cell, and you
don't free it.

It's only valid until the next call that changes the terminal. That includes
ghostty_terminal_vt_write(), ghostty_terminal_resize() and
ghostty_terminal_free(). There's no guarantee it survives any change, even one
to a part of the grid that looks unrelated. So get one, read what you need, and
cache the values. Don't keep the reference.

An untracked reference costs you the initial lookup and nothing after that. It's
a one-time snapshot, so it has no effect on the terminal's ongoing performance.

## Tracked references {#guide-grid-tracked}

A GhosttyTrackedGridRef follows its cell. Scrolling, scrollback pruning, resize
and reflow, and other terminal changes all update it automatically. Create one
with ghostty_terminal_grid_ref_track().

Each tracked reference adds bookkeeping to every terminal change, so use them
sparingly. They're for long-lived anchors such as selections, search state,
marks and bookmarks in your application.

To read cell data, snapshot it first with ghostty_tracked_grid_ref_snapshot().
What you get back is an untracked reference with the same short life as any
other. ghostty_tracked_grid_ref_point() gets you the position without that step.

@snippet c-vt-grid-ref-tracked/src/main.c grid-ref-tracked

Full program: @ref c-vt-grid-ref-tracked/src/main.c

### When a tracked reference loses its cell

A tracked reference can still lose its place. That happens when the grid under
it is reset, pruned, or otherwise discarded in a way that can't be mapped to a
meaningful new cell. ghostty_tracked_grid_ref_has_value() then returns false,
and ghostty_tracked_grid_ref_snapshot() and ghostty_tracked_grid_ref_point()
return #GHOSTTY_NO_VALUE.

The handle is still valid. Move it to a new point with
ghostty_tracked_grid_ref_set().

### Primary and alternate screens

A tracked reference belongs to the screen that was active when you created it or
last set it. Converting it to a point uses that screen, even if the terminal has
since switched between primary and alternate. ghostty_tracked_grid_ref_set()
resolves the new point against the screen that's active now, so it can move the
reference from one screen to the other.

### Freeing

Tracked references are yours, and you free them with
ghostty_tracked_grid_ref_free(). You can do that after the terminal is gone. If
the terminal is freed first, the handle stays valid for the tracked reference
functions only: it reports no value, and it can still be freed.

## When a reference dies {#guide-grid-lifetime}

|                       | Untracked                      | Tracked                                                        |
| --------------------- | ------------------------------ | -------------------------------------------------------------- |
| Terminal changes      | Invalid. Don't touch it again. | Follows the cell.                                              |
| Its cell is discarded | Invalid.                       | Valid, but has no value until you set it again.                |
| Terminal is freed     | Invalid.                       | Valid, but has no value. You still have to free it.            |
| Freeing               | Nothing to free.               | ghostty_tracked_grid_ref_free().                               |
| Cost                  | One lookup.                    | Bookkeeping on every terminal change for as long as it exists. |
