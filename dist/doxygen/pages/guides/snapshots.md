# Snapshots {#guide-snapshots}

A snapshot is the complete state of a terminal as bytes. Encode one, keep it or
send it somewhere, and restore a terminal from it later.

The problem with a big terminal is scrollback. A complete snapshot can be large,
and you don't want someone staring at nothing while old history loads. So a
snapshot is ordered: first comes enough state to render and resume the terminal,
including any unfinished VT parser input, and then the older scrollback. You can
show a restored terminal and feed it live input while the history is still
arriving.

Most programs never need this. If you do, you can restore a snapshot in one
call, or in pieces if you want the terminal on screen first.

The format isn't stable yet. Snapshot format version 1 is a work in progress and
doesn't carry a binary-compatibility guarantee.

## Encoding {#guide-snapshots-encoding}

There are three ways to encode, and they differ only in where the bytes go:

| Function                        | Where the bytes go                                                     |
| ------------------------------- | ---------------------------------------------------------------------- |
| ghostty_snapshot_encode()       | A GhosttyWriter.                                                       |
| ghostty_snapshot_encode_buf()   | A buffer you provide. Pass `NULL` and zero to ask for the size.        |
| ghostty_snapshot_encode_alloc() | A new buffer. Free it with ghostty_free(), passing the same allocator. |

A snapshot includes unfinished input, such as half of an escape sequence. To
capture it, the terminal has to have been keeping track of that input, which you
turn on with #GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES. Turn it on before the
input is written. If tracking is off and the VT parser and UTF-8 decoder are
both at ground, encoding still works. If either one is unfinished, encoding
returns #GHOSTTY_INVALID_VALUE.

@snippet c-vt-snapshot/src/main.c snapshot-encode

Full program: @ref c-vt-snapshot/src/main.c

ghostty_snapshot_encode() needs the terminal to hold still. Don't write to it or
change it for the duration of the call, and don't call terminal functions on the
same terminal from your writer. Encoding begins at the writer's current
position, and calls to the writer are synchronous. We don't flush, or make your
destination durable. If an error occurs, the writer may hold a partial snapshot
with no valid FINISH marker.

## Restoring in one call {#guide-snapshots-restoring}

Create a decoder over your bytes with ghostty_snapshot_decoder_new_buf(), then
call ghostty_snapshot_decoder_decode(). You get back a terminal that you own,
with its VT stream restored. It's safe to free the decoder right away.

The bytes aren't copied. They have to stay valid and unchanged until FINISH is
reached or the decoder is freed. Bytes after FINISH aren't consumed, and
#GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET tells you where they start.

@snippet c-vt-snapshot/src/main.c snapshot-decode

Full program: @ref c-vt-snapshot/src/main.c

### Options

Set options with ghostty_snapshot_decoder_set() before decoding starts. After
that it returns #GHOSTTY_INVALID_VALUE. A `NULL` value restores an option's
default.

| Option                                                  | What it does                                                                                       |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| #GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES    | The largest unfinished input the decoder accepts. Zero accepts only snapshots at ground.           |
| #GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION       | Keep tracking unfinished input on the restored terminal. Tracking is off by default.               |
| #GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY          | Compress each history page right after restoring it.                                               |
| #GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT | The image storage limit for each restored screen. The snapshot doesn't carry the original's limit. |

If you retain the continuation and don't need tracking after you've exported it,
set #GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to zero before you write any
new input. Exporting an empty continuation doesn't turn tracking off.

Without #GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, restored scrollback is
uncompressed, even if the original terminal had compressed it. That can be many
times more memory than the terminal needed before, and it stays that way until
you call ghostty_terminal_compress(). With the option on, the decode never holds
more than one uncompressed history page at a time. The snapshot format doesn't
change, so this works with any snapshot.

@snippet c-vt-snapshot/src/main.c snapshot-compress-history

Full program: @ref c-vt-snapshot/src/main.c

### Errors

End-of-file before a required READY or FINISH marker means the snapshot is
truncated, and you get #GHOSTTY_INVALID_VALUE. #GHOSTTY_IO_ERROR is reserved for
a reader callback that returns false.

A decoding, I/O or allocation error after the decoder has started consuming
input poisons it, and all you can do is free it. An invalid argument or
lifecycle error caught before any input is consumed doesn't. The output terminal
is set to `NULL` on every error.

## Restoring in pieces {#guide-snapshots-pieces}

This is the path that gets a terminal on screen first:

1. ghostty_snapshot_decoder_ready() decodes through READY and gives you a
   terminal. It's usable right away for rendering and live input. You can only
   call it once, and only before decoding starts.
2. ghostty_snapshot_decoder_next() decodes one record per call: a history page
   with the Kitty graphics placements pinned to it, or the pixels of one image
   or animation frame. Check #GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND and
   read the progress values for that kind before you call it again.
3. #GHOSTTY_NO_VALUE from ghostty_snapshot_decoder_next() means FINISH was
   validated. Calling it again returns the same thing.

History pages arrive newest to oldest, so each one is prepended to the
scrollback.

The source can be a GhosttyReader instead of a buffer. Create that decoder with
ghostty_snapshot_decoder_new(). It stores a copy of your reader, and the
callback and its context have to stay valid until FINISH is reached or the
decoder is freed. Reads are synchronous and only happen during ready, next and
decode calls.

A successful read of zero bytes is permanent end-of-file, not temporary
starvation. If your source is nonblocking, wait outside the decoder or block in
your callback. Your callback can't call functions on the decoder that owns it,
including ghostty_snapshot_decoder_free().

@snippet c-vt-snapshot/src/main.c snapshot-buffer-reader

Full program: @ref c-vt-snapshot/src/main.c

@snippet c-vt-snapshot/src/main.c snapshot-incremental

Full program: @ref c-vt-snapshot/src/main.c

### Between calls

You can render, resize and feed live pty input to the terminal between calls.
The decoder borrows your terminal while it restores history, so keep the
terminal alive until FINISH validates or the decoder is freed.

If a history page can't be applied safely anymore, it's still consumed and
validated, and progress reports zero rows. Image pixels work the same way, and
report zero bytes. That happens if live input deleted the image or sent a new
image with the same id, if the image didn't fit the storage limit, or if its
screen was removed or replaced.

#GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING counts the page records left
in the same screen's history, not in the whole snapshot.

You can stop early. Freeing the decoder leaves you a usable terminal with
whatever history was already restored. After a decoding error the terminal is
also still yours and usable, but the only thing you can do with the decoder is
free it.

### Images

Images are restored at READY with their pixels pending. A pending image can be
placed and queried, but #GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_PIXELS returns
#GHOSTTY_NO_VALUE for it until its pixels arrive through
ghostty_snapshot_decoder_next().

When they arrive, the image keeps its
#GHOSTTY_KITTY_GRAPHICS_IMAGE_DATA_GENERATION, but
#GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION changes. A renderer that watches that
value picks up the new pixels on its next frame.

Pixels can arrive between history pages, so they're only known to be done when
next returns #GHOSTTY_NO_VALUE. To show progress, compare
#GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_PRIMARY with what arrives.
ghostty_snapshot_decoder_next() has an example.

## The format {#guide-snapshots-format}

You only need this if you're writing your own tools for snapshots. The
[Zig codec documentation](https://github.com/ghostty-org/ghostty/blob/main/src/terminal/snapshot/main.zig)
has the rest.

A snapshot is an ordered, CRC-protected record stream. Every integer is unsigned
and little-endian. The stream begins with this fixed ten-byte envelope:

```
byte  0               8       10
      +---------------+--------+
      | "GHOSTSNP"    | version|
      | 8-byte magic  | u16    |
      +---------------+--------+
```

After that come independently checksummed records. A record's CRC32C covers its
encoded tag and payload length, followed by its payload. It doesn't cover the
CRC field itself.

```
byte  0       2             6          10             10 + payload_len
      +-------+-------------+-----------+----------------+
      | tag   | payload_len | CRC32C    | payload        |
      | u16   | u32         | u32       | payload_len B  |
      +-------+-------------+-----------+----------------+
      \____________________/             \______________/
         CRC prefix                         CRC suffix
```

Record groups occur in this strict order. SCREEN and HISTORY groups contain one
entry for each screen declared by TERMINAL. Each manifest is followed by the
number of PAGE records it declares. Active SCREEN pages make the terminal
renderable. HISTORY pages are older scrollback, ordered newest to oldest so an
incremental decoder can prepend them as they arrive.

```
+---------------- TERMINAL ----------------+
| terminal-wide state and screen count     |
+----------------- SCREEN -----------------+  repeated per screen
| active-screen manifest                   |
+------------------ PAGE ------------------+  repeated per manifest
| active screen rows                       |
+---------- KITTY_IMAGE_STORAGE -----------+  optional, per screen
| images, placements, in-progress load     |
+------------- CONTINUATION ---------------+
| unfinished VT/UTF-8 input, or ground     |
+------------------ READY -----------------+
| empty renderable-state marker            |  ready() returns here
+---------- KITTY_IMAGE_PAYLOAD -----------+  optional, anywhere until FINISH,
| one image's or frame's pixels            |  next() consumes one
+----------------- HISTORY ----------------+  repeated per screen
| scrollback manifest                      |
+------------------ PAGE ------------------+  next() consumes one page
| older screen rows                        |
+------ KITTY_IMAGE_PAGE_PLACEMENTS -------+  optional, after a PAGE
| placements pinned to that page           |
+------------------ FINISH ----------------+
| empty end-of-snapshot marker             |  next() returns NO_VALUE
+------------------------------------------+
| trailing transport bytes (not consumed)  |
+------------------------------------------+
```

READY separates the renderable prefix through CONTINUATION from history. FINISH
terminates the record sequence. Both are empty records protected by CRC32C, like
every other record. Declared record counts, tags and strict decoding enforce the
stream's ordering and completeness.

A decoder skips any record whose tag it doesn't know, wherever it appears. That
lets a newer library add optional kinds of records that older libraries ignore,
without changing the snapshot version. Skipped records are still checked, so a
damaged record fails decoding even when its tag is unknown.

The Kitty graphics records are optional in this way. A library built without
Kitty graphics skips them and restores the same terminal without its images, and
a terminal without images writes none of them.
