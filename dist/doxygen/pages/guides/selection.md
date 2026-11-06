# Selection {#guide-selection}

A selection is a range of terminal content: a word someone double-clicked, a
line, a command's output, or a block dragged out with the mouse. You make one to
highlight text and to copy it.

Selecting text in a terminal takes more than two cells. What counts as a word,
where a line really starts, which rows are a command's output, and what a
double-click-and-drag should do when the pointer is between words are all
questions we've already answered in Ghostty. These functions give you the same
answers.

If you don't let anyone select text, you can skip this page. If you do, the
gesture section is the one you want. It turns raw pointer events into selections
so you don't have to write that logic.

## What a selection is {#guide-selection-what}

A GhosttySelection is two cells, `start` and `end`, and both are included. By
default it's linear: it runs from `start` to `end` the way text flows, wrapping
from the end of one row to the start of the next. Set `rectangle` to true for a
rectangular block instead, with `start` and `end` at opposite corners.

The ends keep the direction of the selection. If someone drags up or to the
left, `start` comes after `end` in the terminal, so don't assume `start` is the
top-left end. ghostty_terminal_selection_ordered() gives you the ends in the
order you ask for.

Both ends are GhosttyGridRef values, so a selection is an untracked snapshot and
follows the same rule as any untracked reference. It's only valid until the next
call that changes the terminal, including freeing it. See @ref
guide-grid-lifetime.

To keep a selection across changes, you have two choices. Install it as the
terminal's selection, or keep tracked references for the ends and build a new
GhosttySelection from fresh snapshots when you need one.

### The terminal's selection

The active screen has a selection, and the terminal owns it. Passing a selection
to ghostty_terminal_set() with #GHOSTTY_TERMINAL_OPT_SELECTION copies it right
away and converts it to tracked state, so what you passed doesn't need to
outlive the call. Passing `NULL` clears it.

Read it back with `GHOSTTY_TERMINAL_DATA_SELECTION`, which returns
#GHOSTTY_NO_VALUE if there's no active selection. The struct you get is yours to
keep, but the references in it are untracked again. They're only valid until the
next call that changes the terminal.

Nothing in this guide installs a selection for you. Every function below returns
a snapshot, and you decide what to do with it.

## Making a selection {#guide-selection-making}

You can fill in a selection by hand. This selects the first ten cells of the
second row and makes that the terminal's selection:

```c
GhosttyPoint start_pt = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = {.coordinate = {.x = 0, .y = 1}},
};
GhosttyPoint end_pt = {
    .tag = GHOSTTY_POINT_TAG_ACTIVE,
    .value = {.coordinate = {.x = 9, .y = 1}},
};

GhosttySelection selection = {0};
ghostty_terminal_grid_ref(terminal, start_pt, &selection.start);
ghostty_terminal_grid_ref(terminal, end_pt, &selection.end);
ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
```

Usually you want the terminal's rules instead:

| Function                               | What it selects                                                                    |
| -------------------------------------- | ---------------------------------------------------------------------------------- |
| ghostty_terminal_select_word()         | The word under a grid reference.                                                   |
| ghostty_terminal_select_word_between() | The nearest word between two grid references, searching from `start` toward `end`. |
| ghostty_terminal_select_line()         | The line under a grid reference.                                                   |
| ghostty_terminal_select_output()       | The command output under a grid reference. This needs OSC 133 prompt markers.      |
| ghostty_terminal_select_all()          | All selectable content.                                                            |

Each returns #GHOSTTY_NO_VALUE when there's nothing to select there.

The word functions use Ghostty's default word boundaries unless you pass your
own codepoints. The line function trims Ghostty's default whitespace unless you
pass your own. Set `semantic_prompt_boundary` and the line stops at semantic
prompt changes, so a line at a shell prompt selects the input and leaves out the
`$ `.

@snippet c-vt-selection/src/main.c selection-main

Full program: @ref c-vt-selection/src/main.c

### Double-click and drag

Word-granular dragging needs ghostty_terminal_select_word_between(). If someone
double-clicks a word and drags across spaces or punctuation toward another word,
selecting only the word under the pointer flickers or collapses whenever the
pointer is between words. So ask for the nearest word between the click and the
drag point, ask again in the other direction, and combine the two. The gesture
API below does this for you.

@snippet c-vt-selection/src/main.c selection-word-between

Full program: @ref c-vt-selection/src/main.c

### Working with a selection

These all take a selection whose references are valid for the terminal's active
screen. They have to come from that terminal and that screen, with no change to
the terminal since. We don't check, so a stale reference is on you.

| Function                              | What it does                                                                             |
| ------------------------------------- | ---------------------------------------------------------------------------------------- |
| ghostty_terminal_selection_adjust()   | Moves the selection's logical end, as keyboard selection does. The result is a snapshot. |
| ghostty_terminal_selection_order()    | Tells you which way the ends are ordered.                                                |
| ghostty_terminal_selection_ordered()  | Returns a new snapshot with the ends in the order you ask for.                           |
| ghostty_terminal_selection_contains() | Tests whether a point is inside, for rectangular selections too.                         |
| ghostty_terminal_selection_equal()    | Tests whether two selections have the same ends and shape.                               |

## Mouse gestures {#guide-selection-gestures}

A selection gesture is a state machine that turns pointer events into
selections. It handles click counts, dragging, and what each click count
selects. You feed it events and it hands back snapshots.

Create one GhosttySelectionGesture per stream of pointer events with
ghostty_selection_gesture_new(). It isn't bound to a terminal, so the functions
that need one take it as an argument. Then create a GhosttySelectionGestureEvent
for each event type you use with ghostty_selection_gesture_event_new(). The type
is fixed, but the object is reusable: change its options with
ghostty_selection_gesture_event_set() and apply it with
ghostty_selection_gesture_event().

| Event type                                            | Required options   | Optional                                |
| ----------------------------------------------------- | ------------------ | --------------------------------------- |
| #GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS           | Ref                | The rest use their defaults.            |
| #GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG            | Ref, geometry      | Position, rectangle, word boundaries.   |
| #GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE         | None               | Ref. Unset means it wasn't over a cell. |
| #GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK | Viewport, geometry | Position, rectangle, word boundaries.   |
| #GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS      | None               | Word boundaries.                        |

A press only gets repeat clicks if you give it
#GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS. Without a time, only single-click
behavior is available. By default a single click selects by cell, a double click
by word and a triple click by line. Change that with
#GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS, which can also select command
output.

#GHOSTTY_NO_VALUE from ghostty_selection_gesture_event() isn't an error. It
means this event doesn't produce a selection right now, as with a normal single
press. A release never produces one. When you do get a selection, it isn't
installed anywhere. You decide whether to draw it, copy it, or install it as the
terminal's selection.

@snippet c-vt-selection-gesture/src/main.c selection-gesture-main

Full program: @ref c-vt-selection-gesture/src/main.c

### Dragging past the edge

When a drag reaches the top or bottom of the surface, the gesture wants the
viewport to scroll. Read #GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL after each
drag. While it's up or down, run a timer of your own that sends
#GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK events. Each tick scrolls
the viewport one row and continues the drag. The interval is up to you, and
about 15 milliseconds is a reasonable default. Scroll faster by ticking faster.
If a tick returns #GHOSTTY_NO_VALUE, the gesture has cancelled itself, so stop
the timer.

### Rules for gestures

Calls that use a gesture aren't safe to run concurrently, and they have to be
serialized with changes to the terminal.

ghostty_selection_gesture_reset() cancels the current click sequence and
releases the gesture's tracked state without freeing it.

Free a gesture with ghostty_selection_gesture_free(), passing the terminal you
last used with it. If that terminal is already gone, pass `NULL`.

## Copying it out {#guide-selection-copying}

A selection names cells. To get the text, use a @ref formatter "formatter" with
#GHOSTTY_FORMATTER_OPT_SELECTION. For the same text Ghostty puts on the
clipboard, use plain output with #GHOSTTY_FORMATTER_OPT_UNWRAP and
#GHOSTTY_FORMATTER_OPT_TRIM both true:

```c
GhosttySelection selection = {0};
if (ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION,
                         &selection) != GHOSTTY_SUCCESS) {
  return;
}

GhosttyFormatter formatter;
ghostty_formatter_terminal_new(NULL, &formatter, terminal);

GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_PLAIN;
bool yes = true;
ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes);
ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes);
ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection);

uint8_t *buf = NULL;
size_t len = 0;
ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);

// Put buf on the clipboard.

ghostty_free(NULL, buf, len);
ghostty_formatter_free(formatter);
```

The formatter keeps its own copy of the selection, but that copy is still only
valid until the next change to the terminal. After a change, set the selection
again before you format, or clear it.
