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
 * +------------- CONTINUATION ---------------+
 * | unfinished VT/UTF-8 input, or ground     |
 * +------------------ READY -----------------+
 * | empty renderable-state marker            |  ready() returns here
 * +----------------- HISTORY ----------------+  repeated per screen
 * | scrollback manifest                      |
 * +------------------ PAGE ------------------+  next() consumes one page
 * | older screen rows                        |
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

  GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySnapshotDecoderOption;

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
   * Screen associated with the most recently decoded history page.
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
   * applied to the live terminal.
   *
   * Output type: size_t *
   */
  GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_ROWS = 6,

  /**
   * Page records remaining in the same screen's HISTORY sequence.
   *
   * This is not a count of all pages remaining in the snapshot.
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
 * Decode one history page into the terminal returned by READY.
 *
 * Each GHOSTTY_SUCCESS consumes and validates one PAGE record. Query the
 * GHOSTTY_SNAPSHOT_DECODER_DATA_PROGRESS_* values before calling next again.
 * GHOSTTY_NO_VALUE means FINISH was validated; repeated calls after FINISH
 * also return GHOSTTY_NO_VALUE.
 *
 * The terminal may be rendered, resized, and fed live PTY input between calls.
 * If a history page can no longer be applied safely, it is still consumed and
 * validated and progress reports zero rows. The decoder applies history
 * to the caller-owned terminal produced by its READY operation.
 *
 * A decoding error invalidates the decoder's source position. The terminal
 * remains caller-owned and usable with its already-restored history, but only
 * ghostty_snapshot_decoder_free() may subsequently be called on the decoder.
 *
 * @param decoder Decoder handle (must not be NULL)
 * @return GHOSTTY_SUCCESS for one page, GHOSTTY_NO_VALUE after FINISH, or an
 *         error code on failure
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
