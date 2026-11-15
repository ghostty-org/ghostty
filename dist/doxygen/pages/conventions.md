# API Conventions {#conventions}

The libghostty-vt API follows the same few rules everywhere. Learn them once and
every bit of functionality in the library behaves in a predictable, regular
way.

Four of the rules are short and they're on this page. The others have pages of
their own:

- @subpage values
- @subpage sized-structs
- @subpage memory
- @subpage features
- @subpage stability

## Results {#conventions-results}

Functions that can fail return a GhosttyResult. GHOSTTY_SUCCESS is zero and
every error is negative, so `result < 0` tests for any error.

| Result                      | What it means                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| @ref GHOSTTY_SUCCESS        | It worked.                                                                                                          |
| @ref GHOSTTY_OUT_OF_MEMORY  | An allocation failed.                                                                                               |
| @ref GHOSTTY_INVALID_VALUE  | An argument is wrong, such as a NULL pointer where a value is required or an enum value that is out of range.       |
| @ref GHOSTTY_OUT_OF_SPACE   | The buffer you gave us is too small. See @ref conventions-buffers.                                                  |
| @ref GHOSTTY_NO_VALUE       | The value you asked for has no value.                                                                               |
| @ref GHOSTTY_IO_ERROR       | Reading from or writing to external I/O failed.                                                                     |
| @ref GHOSTTY_LIMIT_EXCEEDED | Encoded input went past a configured limit.                                                                         |
| @ref GHOSTTY_REJECTED       | A safety check refused the operation, such as pasted text that could inject commands. Nothing was done.             |
| @ref GHOSTTY_UNSUPPORTED    | This library can't do what you asked. The key is newer than the library, or the feature was left out of this build. |

A NULL handle or NULL output pointer returns GHOSTTY_INVALID_VALUE, unless the
documentation says the pointer may be NULL. A function that can't return a
result does nothing with NULL, or returns false, 0 or NULL. This applies to
function arguments. Fields inside a struct must follow that struct's
documentation.

GHOSTTY_UNSUPPORTED is how a program handles a library that isn't the one it was
built for. See @ref values-older-libraries and @ref features.

## Handles {#conventions-handles}

Much of the libghostty-vt API is handle-based. A handle isan opaque pointer
to something the library manages; the structure of the thing is not public
API for you to dig into. For example: GhosttyTerminal.

A handle you create is yours. Most come from a `_new` function, such as
ghostty_terminal_new(), which takes an allocator first and writes the handle to
the pointer you pass next. Pass NULL for the allocator unless you have a reason
not to. See @ref memory.

Free your handles with the `_free` function that matches, such as
ghostty_terminal_free(). The handle is invalid after that. Every `_free`
function accepts NULL and does nothing, so your cleanup code doesn't need to
check.

A borrowed handle belongs to something else, so you don't free it. It also
doesn't last. The GhosttyKittyGraphics handle you get from
ghostty_terminal_get() is only valid until the next call that changes the
terminal, such as ghostty_terminal_vt_write(). Each borrowed handle documents
how long it lasts.

Some handles you create still point at a terminal, and it matters which one you
free first:

- A GhosttyFormatter borrows its terminal. The terminal must outlive the
  formatter.
- A GhosttySearch or a GhosttyTrackedGridRef can outlive its terminal. If the
  terminal is freed first, a search fails cleanly on any call that needs the
  terminal, a tracked reference reports no value, and you can still free both.

Memory works the same way as handles. A GhosttyString is a pointer and a length
that owns nothing, and it's valid for as long as the function that gave it to
you says. A buffer the library allocates for you, such as the output of
ghostty_formatter_format_alloc(), is yours to free with ghostty_free(). See @ref
memory-buffers.

## Threads {#conventions-threads}

The library creates no threads on its own. In general, calls on one handle
are never thread-safe. But calls across multiple handles are. It is possible
to build a multi-threaded terminal on libghostty-vt and is how many terminals
are built.

Every callback runs on the thread whose call triggered it. libghostty-vt
has no concept at all of main threads or routing calls to different threads;
you must solve this yourself as the caller.

Calls on one handle, and on any handle borrowed from it, must not run at the
same time unless a function's documentation says otherwise. Handles that share
nothing can be used on different threads.

A common example: render state can run on a separate thread from terminal IO,
so that IO can continue while rendering happens. There is only one function
in render state that uses the terminal and requires a lock.

## Output Buffers {#conventions-buffers}

Functions that write bytes for you take a buffer, its length and an
`out_written` pointer. You usually don't know how much space the output needs,
so you can ask. Pass NULL with a length of 0 and the call tells you the size.

When there's nothing to write, the call returns GHOSTTY_SUCCESS and sets
`out_written` to 0, even for a size query.

When the buffer is too small, the call returns GHOSTTY_OUT_OF_SPACE and sets
`out_written` to the size needed. The contents of the buffer are then
unspecified unless the function says otherwise. Throw them away and retry with a
larger buffer.
