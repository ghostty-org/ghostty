# Search {#guide-search}

A GhosttySearch finds a string in a terminal. It covers the active area and
scrollback of both the primary and alternate screens.

Terminal search is harder than searching a string, because the text won't hold
still. Scrollback can be huge, and a program can keep writing while you search.
We handle that part. Results stay in sync with the live screens. They survive
primary and alternate screen switches, so opening and closing a fullscreen app
such as vim doesn't restart a scrollback search. And they recover from resize,
reflow, resets and scrollback pruning.

What's left to you is deciding when the work happens. If you want a one-shot
search, ghostty_search_run() does all of it, and you can go straight to the
example. If you're building a find bar for a terminal with a lot of scrollback,
read the first section.

## Driving a search {#guide-search-driving}

A search starts idle. Setting a needle with #GHOSTTY_SEARCH_OPT_NEEDLE starts
it, changing the needle restarts it from scratch, and clearing it returns the
search to idle. Setting the needle it already has keeps the results, so a find
bar can resubmit freely.

Matching is byte-exact, except for ASCII letters, which compare
case-insensitively.

Searching a large scrollback takes time, so the work is split into small steps
you drive yourself. That gives you direct control over the performance:

| Function              | What it does                                                                                                      | Needs the terminal |
| --------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------ |
| ghostty_search_tick() | Makes a bounded amount of progress on data the search has already copied.                                         | No                 |
| ghostty_search_feed() | Reads the terminal to copy in more data and pick up changes.                                                      | Yes                |
| ghostty_search_run()  | Blocks, feeding and ticking until the search is caught up. Interactive programs should use the other two instead. | Yes                |

Tick while the status is #GHOSTTY_SEARCH_STATUS_RUNNING, and feed when it
becomes #GHOSTTY_SEARCH_STATUS_FEED_REQUIRED. That's also the status right after
a needle is set, because the search hasn't seen the terminal yet.

Feeding is the only way a search learns that the terminal changed. So keep
feeding periodically while the search is in use, even after it reports complete.

#GHOSTTY_SEARCH_STATUS_COMPLETE means the search is caught up with the terminal
as of the last feed. It never means finished forever, because later writes need
another feed to be seen.

## Matches are selections {#guide-search-matches}

Every match is a GhosttySelection snapshot with `rectangle` set to false. So
everything in @ref guide-selection works on matches:

- To copy the matched text, use a GhosttyFormatter with
  #GHOSTTY_FORMATTER_OPT_SELECTION.
- To position highlight rectangles, use ghostty_terminal_point_from_grid_ref()
  with #GHOSTTY_POINT_TAG_VIEWPORT.
- To hit test, use ghostty_terminal_selection_contains().
- To make a match the terminal's selection, use ghostty_terminal_set() with
  #GHOSTTY_TERMINAL_OPT_SELECTION.

Matches follow the usual snapshot rule. They're only valid until the next
operation that changes the terminal, including ghostty_terminal_vt_write(),
resize, reset and free. Read matches after a feed, use them before the terminal
changes again, and read them again rather than caching them.

We keep the selected match accurate across terminal changes. So the safe way to
follow a match is to read #GHOSTTY_SEARCH_DATA_SELECTED_MATCH again after each
feed.

## Lifetime {#guide-search-lifetime}

A search borrows the terminal it was created with and never frees it. Any number
of searches can share one terminal, alongside other readers such as formatters
and render states.

You can free the search and its terminal in either order. Freeing the search
first releases the tracked state it holds in the terminal. If the terminal goes
first, the search detects that:

- Calls that need the terminal, and ghostty_search_tick(), return
  #GHOSTTY_INVALID_VALUE.
- Reads return whatever the search last saw.
- ghostty_search_free() releases only the search's own memory.

A search can't be rebound. To search another terminal, create a new search.

## Threads {#guide-search-threads}

The library creates no threads. Calls on one GhosttySearch aren't safe to make
concurrently with each other, so you have to serialize them.

The functions that touch the terminal also have to be serialized with all other
access to that terminal:

- ghostty_search_new() and ghostty_search_free()
- ghostty_search_feed() and ghostty_search_run()
- ghostty_search_select_next() and ghostty_search_select_prev()
- ghostty_search_set() with the needle option

Everything else, meaning ghostty_search_tick(), ghostty_search_get() and
ghostty_search_get_multi(), only touches memory the search owns. Those are safe
to call while another thread changes the terminal.

That split is how Ghostty runs search on a background thread: tick freely, and
take the terminal lock only to feed.

Reading a returned match value is always safe. Passing one to a function that
takes the terminal follows the terminal's serialization rule above.

## Example {#guide-search-example}

This creates a search, runs it, steps through the matches like a find bar, and
reads the viewport matches to draw highlights.

@snippet c-vt-search/src/main.c search-main

Full program: @ref c-vt-search/src/main.c
