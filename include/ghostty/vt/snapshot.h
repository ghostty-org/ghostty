/**
 * @file snapshot.h
 *
 * Encode and restore complete terminal snapshots.
 */

#ifndef GHOSTTY_VT_SNAPSHOT_H
#define GHOSTTY_VT_SNAPSHOT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <ghostty/vt/allocator.h>
#include <ghostty/vt/io.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup snapshot Terminal Snapshot
 *
 * Encode and restore the complete state of a terminal via a binary format.
 *
 * A snapshot is an ordered, CRC-protected record stream. Its READY marker
 * follows enough state to render and resume the terminal, including any
 * unfinished VT parser input. Older scrollback pages follow READY and the
 * FINISH marker terminates the complete snapshot.
 *
 * End-of-file before an operation's required READY or FINISH marker is
 * malformed, truncated snapshot data and returns GHOSTTY_INVALID_VALUE.
 * GHOSTTY_IO_ERROR is reserved for a reader callback that returns false.
 *
 * ## Examples
 *
 * The complete working example is available in `example/c-vt-snapshot`.
 *
 * ### Encode a terminal and its unfinished VT continuation
 * @snippet c-vt-snapshot/src/main.c snapshot-encode
 *
 * ### Restore a complete snapshot in one call
 * @snippet c-vt-snapshot/src/main.c snapshot-decode
 *
 * ### Adapt a byte source to GhosttyReader
 * @snippet c-vt-snapshot/src/main.c snapshot-buffer-reader
 *
 * ### Restore READY first, then incrementally prepend history
 * @snippet c-vt-snapshot/src/main.c snapshot-incremental
 *
 * ## Format
 *
 * Every integer is unsigned and little-endian. The stream begins with this
 * fixed ten-byte envelope:
 *
 * @code{.unparsed}
 * byte  0               8       10
 *       +---------------+--------+
 *       | "GHOSTSNP"    | version|
 *       | 8-byte magic  | u16    |
 *       +---------------+--------+
 * @endcode
 *
 * The envelope is followed by independently checksummed records. A record's
 * CRC32C covers its encoded tag and payload length followed by its payload; it
 * does not cover the CRC field itself.
 *
 * @code{.unparsed}
 * byte  0       2             6          10             10 + payload_len
 *       +-------+-------------+-----------+----------------+
 *       | tag   | payload_len | CRC32C    | payload        |
 *       | u16   | u32         | u32       | payload_len B  |
 *       +-------+-------------+-----------+----------------+
 *       \____________________/             \______________/
 *          CRC prefix                         CRC suffix
 * @endcode
 *
 * Record groups occur in this strict order. SCREEN and HISTORY groups contain
 * one entry for each screen declared by TERMINAL. Each manifest is followed
 * by the number of PAGE records it declares. Active SCREEN pages make the
 * terminal renderable; HISTORY pages are older scrollback ordered newest to
 * oldest so an incremental decoder can prepend them as they arrive.
 *
 * @code{.unparsed}
 * +---------------- TERMINAL ----------------+
 * | terminal-wide state and screen count     |
 * +----------------- SCREEN -----------------+  repeated per screen
 * | active-screen manifest                   |
 * +------------------ PAGE ------------------+  repeated per manifest
 * | active screen rows                       |
 * +---------- KITTY_IMAGE_STORAGE -----------+  optional, per screen
 * | images, placements, in-progress load     |
 * +------------- CONTINUATION ---------------+
 * | unfinished VT/UTF-8 input, or ground     |
 * +------------------ READY -----------------+
 * | empty renderable-state marker            |  ready() returns here
 * +---------- KITTY_IMAGE_PAYLOAD -----------+  optional, anywhere until FINISH,
 * | one image's or frame's pixels            |  next() consumes one
 * +----------------- HISTORY ----------------+  repeated per screen
 * | scrollback manifest                      |
 * +------------------ PAGE ------------------+  next() consumes one page
 * | older screen rows                        |
 * +------ KITTY_IMAGE_PAGE_PLACEMENTS -------+  optional, after a PAGE
 * | placements pinned to that page           |
 * +------------------ FINISH ----------------+
 * | empty end-of-snapshot marker              |  next() returns NO_VALUE
 * +------------------------------------------+
 * | trailing transport bytes (not consumed) |
 * +------------------------------------------+
 * @endcode
 *
 * READY separates the renderable prefix through CONTINUATION from history.
 * FINISH terminates the record sequence. Both are empty records protected by
 * CRC32C, like every other record. Declared record counts, tags, and strict
 * decoding enforce the stream's ordering and completeness.
 *
 * A decoder skips any record whose tag it does not know, wherever it
 * appears. This lets a newer library add optional kinds of records that
 * older libraries ignore, without changing the snapshot version. Skipped
 * records are still checked, so a damaged record fails decoding even when
 * its tag is unknown.
 *
 * The Kitty graphics records are optional in this way. A library built
 * without Kitty graphics skips them and restores the same terminal without
 * its images, and a terminal without images writes none of them.
 *
 * Images are restored at READY with their pixels pending, and the pixels
 * arrive later through ghostty_snapshot_decoder_next(). A pending image can
 * be placed and queried, but GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR returns
 * GHOSTTY_NO_VALUE for it until its pixels arrive. When they do, the
 * image keeps its GHOSTTY_KITTY_IMAGE_DATA_GENERATION, but
 * GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION changes, so a renderer that
 * watches that value picks up the new pixels on its next frame.
 *
 * Snapshot format version 1 is a work in progress and does not yet carry a
 * binary-compatibility guarantee.
 *
 * @see <a href="https://github.com/ghostty-org/ghostty/blob/main/src/terminal/snapshot/main.zig">Snapshot format and Zig codec documentation</a>
 *
 * @{
 */

/**
 * Configurable snapshot decoder options.
 *
 * Options may only be changed before decoding starts. Calling
 * ghostty_snapshot_decoder_set() after ghostty_snapshot_decoder_ready() or
 * ghostty_snapshot_decoder_decode() returns GHOSTTY_INVALID_VALUE.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Largest non-ground continuation the decoder will accept.
   *
   * A value of zero accepts only snapshots whose VT parser is in the ground
   * state. The decoder default matches the largest built-in APC protocol
   * buffer limit, currently 65 MiB.
   *
   * This is primarily an input validation limit. When
   * GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION is true, the same value
   * also becomes the continuation tracking limit on the returned terminal.
   *
   * Input type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES = 0,

  /**
   * Retain the decoded continuation on the returned terminal.
   *
   * When true, terminals returned by ghostty_snapshot_decoder_ready() and
   * ghostty_snapshot_decoder_decode() use
   * GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES as their continuation
   * tracking limit. The existing ghostty_terminal_continuation_* APIs can then
   * export the exact unfinished VT or UTF-8 input restored from the snapshot.
   *
   * This is false by default. A maximum continuation size of zero leaves
   * tracking disabled. With a nonzero maximum, tracking remains enabled even
   * when the decoded continuation is empty. Exporting an empty continuation
   * does not disable it. Callers that do not need ongoing tracking must still
   * set GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to zero after export and
   * before writing post-snapshot input.
   *
   * Input type: bool *
   */
  GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION = 1,

  /**
   * Compress scrollback history while it is restored.
   *
   * By default, restoring a snapshot leaves all of its scrollback history
   * uncompressed, even if the terminal that produced the snapshot had
   * compressed it. The history stays that size until the application calls
   * ghostty_terminal_compress(). For a terminal with a lot of scrollback,
   * that can be many times more memory than the terminal needed before.
   *
   * When this option is true, the decoder compresses each history page right
   * after restoring it. The restored terminal starts out compressed, and the
   * decode never holds more than one uncompressed history page at a time.
   * The result is the same as decoding normally and then calling
   * ghostty_terminal_compress() with GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL,
   * without the memory spike in between.
   *
   * A history page that is on screen when it is restored stays uncompressed.
   * This only happens if the viewport is scrolled to the top of the
   * scrollback during an incremental decode. Compressed history is
   * uncompressed automatically when it is accessed later, for example by
   * scrolling or searching.
   *
   * This only changes how the restored terminal stores its history in
   * memory. The snapshot format is unchanged, so it works with any snapshot.
   * On platforms that do not support scrollback compression, this option is
   * accepted and has no effect.
   *
   * This is false by default.
   *
   * Input type: bool *
   */
  GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY = 2,

  /**
   * Kitty graphics image storage limit, in bytes, for each restored screen.
   *
   * The limit of the terminal that wrote the snapshot is not part of the
   * snapshot, so the decoder always applies this one. Images are restored
   * oldest first, and an image that does not fit evicts older images,
   * exactly as a live transmission would. The newest images are kept, and
   * the placements of evicted images are dropped with them. Zero disables
   * Kitty graphics on the restored terminal.
   *
   * The default is the storage limit of a new terminal. Change the limit
   * of a restored terminal later with
   * GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT.
   *
   * Input type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT = 3,

  GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySnapshotDecoderOption;

/**
 * What the most recent successful ghostty_snapshot_decoder_next() call
 * decoded.
 *
 * Query it with GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND, then read the
 * progress values that apply to that kind.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * One history page, together with the Kitty graphics placements pinned
   * to it. GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS and
   * GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING describe it.
   */
  GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE = 0,

  /**
   * The pixels of one Kitty graphics image or animation frame. The
   * GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_* values describe it.
   */
  GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_IMAGE = 1,

  GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySnapshotDecoderProgressKind;

/**
 * Queryable snapshot decoder data.
 *
 * Each variant documents the output pointer type expected by
 * ghostty_snapshot_decoder_get().
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid data type. Never results in data extraction. */
  GHOSTTY_SNAPSHOT_DECODER_DATA_INVALID = 0,

  /**
   * Current maximum accepted continuation size.
   *
   * This value is available in every non-failed decoder state.
   *
   * Output type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_MAX_CONTINUATION_BYTES = 1,

  /**
   * Number of snapshot source bytes consumed so far.
   *
   * At FINISH this identifies the first byte after the snapshot. Trailing
   * bytes are not consumed. This value is unavailable after a decoding error,
   * because the decoder can no longer guarantee its source position.
   *
   * Output type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET = 2,

  /**
   * Advisory complete logical history extent for the primary screen.
   *
   * The value counts rows before the active area, including any resident
   * overlap carried before READY. It becomes available after READY validates.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY = 3,

  /**
   * Advisory complete logical history extent for the alternate screen.
   *
   * The value has the same semantics and lifetime as
   * GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY. Querying it returns
   * GHOSTTY_NO_VALUE when the snapshot does not declare an alternate screen.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_ALTERNATE = 4,

  /**
   * Screen associated with the most recently decoded history page or
   * image pixels.
   *
   * This value is available only after ghostty_snapshot_decoder_next()
   * returns GHOSTTY_SUCCESS. A later call to next replaces it or clears it
   * when FINISH is reached or an error occurs.
   *
   * Output type: GhosttyTerminalScreen *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN = 5,

  /**
   * Rows prepended by the most recently decoded history page.
   *
   * Zero means the page was consumed and validated but could not be
   * applied to the live terminal. Returns GHOSTTY_NO_VALUE unless the
   * progress kind is GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE.
   *
   * Output type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS = 6,

  /**
   * Page records remaining in the same screen's HISTORY sequence.
   *
   * This is not a count of all pages remaining in the snapshot. Returns
   * GHOSTTY_NO_VALUE unless the progress kind is
   * GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_REMAINING = 7,

  /**
   * Whether decoded continuation tracking is retained on returned terminals.
   *
   * This value is available in every non-failed decoder state.
   *
   * Output type: bool *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_RETAIN_CONTINUATION = 8,

  /**
   * Whether history is compressed while it is restored.
   *
   * See GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY. This value is
   * available in every non-failed decoder state.
   *
   * Output type: bool *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_COMPRESS_HISTORY = 9,

  /**
   * Kitty graphics image storage limit applied to each restored screen.
   *
   * See GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT. This value
   * is available in every non-failed decoder state.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGE_STORAGE_LIMIT = 10,

  /**
   * What the most recent successful ghostty_snapshot_decoder_next() call
   * decoded: a history page or the pixels of a Kitty graphics image.
   *
   * This value has the same lifetime as
   * GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN.
   *
   * Output type: GhosttySnapshotDecoderProgressKind *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND = 11,

  /**
   * ID of the Kitty graphics image whose pixels the most recent
   * ghostty_snapshot_decoder_next() call decoded.
   *
   * Returns GHOSTTY_NO_VALUE unless the progress kind is
   * GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_IMAGE.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_ID = 12,

  /**
   * Which frame of the image those pixels are for, numbered as the Kitty
   * graphics protocol numbers frames. 1 is the image itself, and 2 and up
   * are its animation frames.
   *
   * Returns GHOSTTY_NO_VALUE unless the progress kind is
   * GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_IMAGE.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_FRAME = 13,

  /**
   * Number of pixel bytes the most recent
   * ghostty_snapshot_decoder_next() call attached to its image.
   *
   * Zero means the pixels were consumed and validated but dropped. That
   * happens when live input deleted the image or sent a new image with the
   * same ID, when the image did not fit the storage limit, or when its
   * screen was removed or replaced. Returns GHOSTTY_NO_VALUE unless the
   * progress kind is GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_IMAGE.
   *
   * Output type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_BYTES = 14,

  /**
   * Number of Kitty graphics images restored for the primary screen at
   * READY.
   *
   * These images can be placed and queried right away, but their pixels
   * arrive later through ghostty_snapshot_decoder_next(). Until then,
   * GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR returns GHOSTTY_NO_VALUE for them.
   * This value becomes available after READY validates, and is zero in a
   * library built without Kitty graphics.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGES_PRIMARY = 15,

  /**
   * Number of Kitty graphics images restored for the alternate screen at
   * READY.
   *
   * Returns GHOSTTY_NO_VALUE when the snapshot does not declare an
   * alternate screen. See GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGES_PRIMARY.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_IMAGES_ALTERNATE = 16,

  /**
   * Bytes of Kitty graphics pixels for the primary screen that were still
   * to come at READY.
   *
   * Use it to size a progress indicator while the pixels arrive, adding
   * up GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_BYTES for the primary
   * screen after each call to ghostty_snapshot_decoder_next(), which has an
   * example. Pixels that are dropped report zero bytes, so the sum can end
   * up below this total. Pixels may arrive between history pages, so they
   * are only known to be done once next returns GHOSTTY_NO_VALUE. This
   * value becomes available after READY validates.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_PRIMARY = 17,

  /**
   * Bytes of Kitty graphics pixels for the alternate screen that were
   * still to come at READY.
   *
   * Returns GHOSTTY_NO_VALUE when the snapshot does not declare an
   * alternate screen. See
   * GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_PRIMARY.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_ALTERNATE = 18,

  GHOSTTY_SNAPSHOT_DECODER_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySnapshotDecoderData;

/**
 * Encode a complete terminal snapshot to a writer.
 *
 * The terminal's persistent VT stream supplies the continuation bytes needed
 * to reconstruct unfinished parser state. The caller must prevent concurrent
 * writes or other terminal mutation for the duration of this call. The writer
 * callback must not call terminal APIs with the same terminal handle.
 * A terminal can be encoded with tracking disabled when its VT parser and
 * UTF-8 decoder are both at ground. If either is unfinished, tracking must
 * have been enabled before the input that produced that state was written;
 * otherwise this returns GHOSTTY_INVALID_VALUE.
 *
 * Encoding begins at the writer's current position. If an error occurs, the
 * writer may contain a partial snapshot without a valid FINISH marker.
 * Calls to the writer are synchronous; this function does not flush or make
 * the caller's destination durable.
 *
 * @param terminal Terminal to encode (must not be NULL)
 * @param writer Destination writer whose write callback must not be NULL
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR if the writer rejects
 *         output, GHOSTTY_LIMIT_EXCEEDED if output accounting overflows, or
 *         another error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_encode(GhosttyTerminal terminal,
                                                  GhosttyWriter writer);

/**
 * Encode a complete terminal snapshot to a caller-provided buffer.
 *
 * Pass NULL for buf with buf_len zero to query the required size. If the
 * buffer is too small, this returns GHOSTTY_OUT_OF_SPACE and stores the
 * required capacity in out_written. A non-NULL undersized buffer may contain
 * a partial snapshot prefix. On success, out_written receives the number of
 * bytes encoded.
 *
 * A terminal can be encoded with tracking disabled when its VT parser and
 * UTF-8 decoder are both at ground. If either is unfinished, tracking must
 * have been enabled before the input that produced that state was written;
 * otherwise this returns GHOSTTY_INVALID_VALUE.
 *
 * @param terminal Terminal to encode (must not be NULL)
 * @param buf Destination buffer, or NULL when buf_len is zero
 * @param buf_len Destination buffer capacity in bytes
 * @param[out] out_written Bytes written, or required capacity on
 *             GHOSTTY_OUT_OF_SPACE (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_encode_buf(
    GhosttyTerminal terminal,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

/**
 * Encode a complete terminal snapshot to an allocated buffer.
 *
 * The returned buffer is allocated with allocator, or the default allocator
 * when allocator is NULL. The caller must release it with ghostty_free(),
 * passing the same allocator used here.
 *
 * A terminal can be encoded with tracking disabled when its VT parser and
 * UTF-8 decoder are both at ground. If either is unfinished, tracking must
 * have been enabled before the input that produced that state was written;
 * otherwise this returns GHOSTTY_INVALID_VALUE.
 *
 * @param terminal Terminal to encode (must not be NULL)
 * @param allocator Allocator for the output, or NULL for the default allocator
 * @param[out] out_ptr Allocated snapshot bytes (must not be NULL)
 * @param[out] out_len Number of allocated snapshot bytes (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_encode_alloc(
    GhosttyTerminal terminal,
    const GhosttyAllocator* allocator,
    uint8_t** out_ptr,
    size_t* out_len);

/**
 * Create a snapshot decoder that reads from a caller-provided reader.
 *
 * The decoder stores a copy of reader. Its read callback must not be NULL, and
 * both the callback and its caller-owned context must remain valid until
 * FINISH is reached or the decoder is freed. Reads are synchronous and occur
 * only during ready, next, or decode calls. A zero-byte successful read is
 * permanent end-of-file, not temporary starvation; nonblocking sources must
 * wait outside the decoder or block in their callback. The read callback must
 * not call APIs, including ghostty_snapshot_decoder_free(), on the decoder
 * that owns it. Returning false reports GHOSTTY_IO_ERROR; returning true with
 * zero bytes before a required marker reports truncated snapshot data as
 * GHOSTTY_INVALID_VALUE.
 *
 * @param allocator Allocator for decoder and decoded terminal state, or NULL
 *                  for the default allocator
 * @param decoder Pointer to receive the decoder handle (must not be NULL)
 * @param reader Snapshot source reader
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_new(
    const GhosttyAllocator* allocator,
    GhosttySnapshotDecoder* decoder,
    GhosttyReader reader);

/**
 * Create a snapshot decoder over a borrowed byte buffer.
 *
 * The bytes are not copied. ptr must remain valid and immutable until FINISH
 * is reached or the decoder is freed. Bytes after FINISH are not consumed;
 * query GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET to locate them.
 *
 * @param allocator Allocator for decoder and decoded terminal state, or NULL
 *                  for the default allocator
 * @param decoder Pointer to receive the decoder handle (must not be NULL)
 * @param ptr Snapshot source bytes
 * @param len Number of source bytes
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_new_buf(
    const GhosttyAllocator* allocator,
    GhosttySnapshotDecoder* decoder,
    const uint8_t* ptr,
    size_t len);

/**
 * Free a snapshot decoder.
 *
 * This does not release the caller's ownership of a terminal returned by
 * ready or decode. Abandoning an incremental decode leaves that terminal
 * usable with whatever history had already been restored.
 *
 * @param decoder Decoder to free (may be NULL)
 *
 * @ingroup snapshot
 */
GHOSTTY_API void ghostty_snapshot_decoder_free(GhosttySnapshotDecoder decoder);

/**
 * Set a snapshot decoder option.
 *
 * The value pointer must have the type documented by option. Options may only
 * be changed before decoding starts.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @param option Option to change
 * @param value Pointer to the option value (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if decoding has
 *         started or an argument is invalid, or another error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_set(
    GhosttySnapshotDecoder decoder,
    GhosttySnapshotDecoderOption option,
    const void* value);

/**
 * Decode and validate the renderable snapshot prefix through READY.
 *
 * On success, terminal receives a caller-owned terminal with its persistent
 * VT stream already restored from the snapshot continuation. The terminal is
 * immediately usable for rendering and live input. Older scrollback remains
 * to be restored with ghostty_snapshot_decoder_next().
 *
 * The restored parser state may be unfinished. By default, terminal
 * continuation tracking is disabled and
 * GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES returns zero. When
 * GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION is true, the decoder's
 * maximum continuation size is applied to the terminal, and the terminal
 * continuation APIs export the exact current continuation when that limit is
 * nonzero. Tracking remains enabled even if the exported continuation is
 * empty. Callers that do not need ongoing tracking must set
 * GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to zero after export and before
 * writing any post-snapshot bytes, because later input may change it.
 *
 * The caller must keep the returned terminal alive until FINISH validates or
 * the decoder is freed. The decoder borrows this terminal handle while it
 * restores history; ghostty_snapshot_decoder_next() uses it automatically.
 *
 * This operation may only be called once and only before decoding starts.
 * terminal is set to NULL on every error. A decoding, I/O, or allocation
 * error after input consumption begins poisons the decoder, after which it
 * must be freed. An invalid argument or lifecycle error detected before the
 * operation consumes input does not poison it.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @param[out] terminal Pointer to receive the terminal (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_ready(
    GhosttySnapshotDecoder decoder,
    GhosttyTerminal* terminal);

/**
 * Decode one history page, or the pixels of one Kitty graphics image, into
 * the terminal returned by READY.
 *
 * Each GHOSTTY_SUCCESS consumes and validates one record: a history page
 * together with the Kitty graphics placements pinned to it, or the pixels
 * of one image or animation frame. Pixels may arrive at any point, even
 * between history pages. Query GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND
 * and the progress values for that kind before calling next again.
 * GHOSTTY_NO_VALUE means FINISH was validated; repeated calls after FINISH
 * also return GHOSTTY_NO_VALUE.
 *
 * @code{.c}
 * // How many image bytes the primary screen is waiting for, to show
 * // progress while they arrive.
 * uint64_t pending = 0;
 * ghostty_snapshot_decoder_get(
 *     decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_KITTY_PENDING_BYTES_PRIMARY,
 *     &pending);
 * uint64_t received = 0;
 *
 * GhosttyResult result;
 * while ((result = ghostty_snapshot_decoder_next(decoder)) == GHOSTTY_SUCCESS) {
 *   GhosttySnapshotDecoderProgressKind kind;
 *   ghostty_snapshot_decoder_get(
 *       decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_KIND, &kind);
 *
 *   if (kind == GHOSTTY_SNAPSHOT_DECODER_PROGRESS_KIND_PAGE) {
 *     // Scrollback grew by this many rows.
 *     size_t rows = 0;
 *     ghostty_snapshot_decoder_get(
 *         decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS, &rows);
 *     continue;
 *   }
 *
 *   // An image's pixels arrived.
 *   GhosttyTerminalScreen screen;
 *   size_t bytes = 0;
 *   ghostty_snapshot_decoder_get(
 *       decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_SCREEN, &screen);
 *   ghostty_snapshot_decoder_get(
 *       decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_IMAGE_BYTES, &bytes);
 *   if (screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY) received += bytes;
 * }
 *
 * // GHOSTTY_NO_VALUE means the snapshot is complete. Dropped pixels report
 * // zero bytes, so received can end up below pending.
 * @endcode
 *
 * The terminal may be rendered, resized, and fed live PTY input between calls.
 * If a history page can no longer be applied safely, it is still consumed and
 * validated and progress reports zero rows. Image pixels work the same way:
 * if live input deleted the image, or sent a new image with the same ID, the
 * pixels are consumed and validated and progress reports zero bytes. The
 * decoder applies history and pixels to the caller-owned terminal produced
 * by its READY operation.
 *
 * If GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY is true, the page is
 * compressed before this function returns, unless it is visible in the
 * terminal's viewport.
 *
 * A decoding error invalidates the decoder's source position. The terminal
 * remains caller-owned and usable with its already-restored history, but only
 * ghostty_snapshot_decoder_free() may subsequently be called on the decoder.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @return GHOSTTY_SUCCESS for one page or image, GHOSTTY_NO_VALUE after
 *         FINISH, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_next(
    GhosttySnapshotDecoder decoder);

/**
 * Decode and validate one complete snapshot.
 *
 * This is the one-shot form of READY followed by all history pages through
 * FINISH. It may only be called before decoding starts. Bytes following FINISH
 * are left unread. On success terminal receives a caller-owned terminal with
 * its persistent VT stream restored. Continuation tracking on the returned
 * terminal is disabled by default. When
 * GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION is true, the decoder's
 * maximum continuation size is applied to the terminal, and the terminal
 * continuation APIs export the exact current continuation when that limit is
 * nonzero. Tracking remains enabled even if the exported continuation is
 * empty. Callers that do not need ongoing tracking must set
 * GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to zero after export and before
 * writing any post-snapshot bytes, because later input may change it.
 * terminal is set to NULL on every error.
 * A decoding, I/O, or allocation error after input consumption begins poisons
 * the decoder, after which it must be freed. An invalid argument or
 * lifecycle error detected before the operation consumes input does not
 * poison it.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @param[out] terminal Pointer to receive the terminal (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_decode(
    GhosttySnapshotDecoder decoder,
    GhosttyTerminal* terminal);

/**
 * Get typed data from a snapshot decoder.
 *
 * The output pointer must have the type documented by data. A phase-dependent
 * value that is not currently available returns GHOSTTY_NO_VALUE.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @param data Data kind to query
 * @param[out] out Pointer to receive the value (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the requested data
 *         is unavailable, or another error code on failure
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_get(
    GhosttySnapshotDecoder decoder,
    GhosttySnapshotDecoderData data,
    void* out);

/**
 * Get multiple snapshot decoder data fields in a single call.
 *
 * Each keys element selects a data kind and the corresponding values element
 * points to storage of the documented output type. Processing stops at the
 * first error. On success out_written is set to count; on error it is set to
 * the number of values written before the failing key. Invalid array arguments
 * report zero values written.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers corresponding to keys
 * @param[out] out_written Number of successfully written values (may be NULL)
 * @return GHOSTTY_SUCCESS if every query succeeds, or the first error
 *
 * @ingroup snapshot
 */
GHOSTTY_API GhosttyResult ghostty_snapshot_decoder_get_multi(
    GhosttySnapshotDecoder decoder,
    size_t count,
    const GhosttySnapshotDecoderData* keys,
    void** values,
    size_t* out_written);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SNAPSHOT_H */
