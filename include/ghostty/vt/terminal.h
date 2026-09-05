/**
 * @file terminal.h
 *
 * Complete terminal emulator state and rendering.
 */

#ifndef GHOSTTY_VT_TERMINAL_H
#define GHOSTTY_VT_TERMINAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/device.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/size_report.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/io.h>
#include <ghostty/vt/kitty_graphics.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/style.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup terminal Terminal
 *
 * Complete terminal emulator state and rendering.
 *
 * A terminal instance manages the full emulator state including the screen,
 * scrollback, cursor, styles, modes, and VT stream processing.
 *
 * Once a terminal session is up and running, you can configure a key encoder
 * to write keyboard input via ghostty_key_encoder_setopt_from_terminal().
 *
 * ### Example: VT stream processing
 * @snippet c-vt-stream/src/main.c vt-stream-init
 * @snippet c-vt-stream/src/main.c vt-stream-write
 *
 * ## Scrollback Compression
 *
 * Scrollback compression is caller-driven. The terminal exposes an opaque
 * activity token so an embedding application can restart an idle timer only
 * when compression-relevant state changes. Once idle, call incremental
 * compression until it no longer reports pending work. libghostty-vt does not
 * create a timer or background thread.
 *
 * @snippet c-vt-compression/src/main.c compression-activity
 * @snippet c-vt-compression/src/main.c compression-idle-step
 *
 * ## Effects
 *
 * By default, terminal sequence processing with the VT write functions only
 * processes sequences that directly affect terminal state and
 * ignores sequences that have side effect behavior or require responses.
 * These sequences include things like bell characters, title changes, device
 * attributes queries, and more. To handle these sequences, the embedder
 * must configure "effects."
 *
 * Effects are callbacks that the terminal invokes in response to VT
 * sequences processed during VT writes. They let the embedding application
 * react to terminal-initiated events such as bell characters, title changes,
 * device status report responses, and more.
 *
 * Each effect is registered with ghostty_terminal_set() using the
 * corresponding `GhosttyTerminalOption` identifier. A `NULL` value
 * pointer clears the callback and disables the effect.
 *
 * A userdata pointer can be attached via `GHOSTTY_TERMINAL_OPT_USERDATA`
 * and is passed to every callback, allowing callers to route events
 * back to their own application state without global variables.
 * You cannot specify different userdata for different callbacks.
 *
 * All callbacks are invoked synchronously during VT writes. Callbacks
 * **must not** call ghostty_terminal_vt_write() or
 * ghostty_terminal_vt_write_until_ground() on the same terminal
 * (no reentrancy).
 * And callbacks must be very careful to not block for too long or perform 
 * expensive operations, since they are blocking further IO processing.
 *
 * The available effects are:
 *
 * | Option                                  | Callback Type                     | Trigger                                   |
 * |-----------------------------------------|-----------------------------------|-------------------------------------------|
 * | `GHOSTTY_TERMINAL_OPT_WRITE_PTY`        | `GhosttyTerminalWritePtyFn`       | VT query and mode reports written back to the PTY |
 * | `GHOSTTY_TERMINAL_OPT_BELL`             | `GhosttyTerminalBellFn`           | BEL character (0x07)                      |
 * | `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED`    | `GhosttyTerminalTitleChangedFn`   | Title change via OSC 0 / OSC 2            |
 * | `GHOSTTY_TERMINAL_OPT_PWD_CHANGED`      | `GhosttyTerminalPwdChangedFn`     | Pwd change via OSC 7 / OSC 9 / OSC 1337   |
 * | `GHOSTTY_TERMINAL_OPT_ENQUIRY`          | `GhosttyTerminalEnquiryFn`        | ENQ character (0x05)                      |
 * | `GHOSTTY_TERMINAL_OPT_XTVERSION`        | `GhosttyTerminalXtversionFn`      | XTVERSION query (CSI > q)                 |
 * | `GHOSTTY_TERMINAL_OPT_SIZE`             | `GhosttyTerminalSizeFn`           | XTWINOPS query (CSI 14/16/18 t) or mode 2048 enable |
 * | `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME`     | `GhosttyTerminalColorSchemeFn`    | Color scheme query (CSI ? 996 n)          |
 * | `GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES`| `GhosttyTerminalDeviceAttributesFn`| Device attributes query (CSI c / > c / = c)|
 * | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE`  | `GhosttyTerminalClipboardWriteFn` | Clipboard write via OSC 52 / OSC 1337 / OSC 5522 |
 * | `GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ`   | `GhosttyTerminalClipboardReadFn`  | Clipboard read via OSC 52 "?" / OSC 5522  |
 * | `GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION`| `GhosttyTerminalDesktopNotificationFn` | Desktop notification via OSC 9 / OSC 777 |
 * | `GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT`  | `GhosttyTerminalProgressReportFn` | Progress report via OSC 9;4               |
 * | `GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE` | `GhosttyTerminalUnknownSequenceFn` | Unsupported sequence identifier          |
 *
 * ### Defining a write_pty callback
 * @snippet c-vt-effects/src/main.c effects-write-pty
 *
 * ### Defining a bell callback
 * @snippet c-vt-effects/src/main.c effects-bell
 *
 * ### Defining a title_changed callback
 * @snippet c-vt-effects/src/main.c effects-title-changed
 *
 * ### Defining a clipboard_write callback
 * @snippet c-vt-effects/src/main.c effects-clipboard-write
 *
 * ### Defining a clipboard_read callback
 * @snippet c-vt-effects/src/main.c effects-clipboard-read
 *
 * ### Defining an unknown_sequence callback
 * @snippet c-vt-effects/src/main.c effects-unknown-sequence
 *
 * ### Registering effects and processing VT data
 * @snippet c-vt-effects/src/main.c effects-register
 *
 * ## Color Theme
 *
 * The terminal maintains a set of colors used for rendering: a foreground
 * color, a background color, a cursor color, and a 256-color palette. Each
 * of these has two layers: a **default** value set by the embedder, and an
 * **override** value that programs running in the terminal can set via OSC
 * escape sequences (e.g. OSC 10/11/12 for foreground/background/cursor,
 * OSC 4 for individual palette entries).
 *
 * ### Default Colors
 *
 * Use ghostty_terminal_set() with the color options to configure the
 * default colors. These represent the theme or configuration chosen by
 * the embedder. Passing `NULL` clears the default, leaving the color
 * unset.
 *
 * | Option                                  | Input Type              | Description                          |
 * |-----------------------------------------|-------------------------|--------------------------------------|
 * | `GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND` | `GhosttyColorRgb*`      | Default foreground color             |
 * | `GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND` | `GhosttyColorRgb*`      | Default background color             |
 * | `GHOSTTY_TERMINAL_OPT_COLOR_CURSOR`     | `GhosttyColorRgb*`      | Default cursor color                 |
 * | `GHOSTTY_TERMINAL_OPT_COLOR_PALETTE`    | `GhosttyColorRgb[256]*` | Default 256-color palette            |
 *
 * For the palette, passing `NULL` resets to the built-in default palette.
 * The palette set operation preserves any per-index OSC overrides that
 * programs have applied; only unmodified indices are updated.
 *
 * ### Reading colors
 *
 * Use ghostty_terminal_get() to read colors. There are two variants for
 * each color: the **effective** value (which returns the OSC override if
 * one is active, otherwise the default) and the **default** value (which
 * ignores any OSC overrides).
 *
 * | Data                                              | Output Type             | Description                                    |
 * |---------------------------------------------------|-------------------------|------------------------------------------------|
 * | `GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND`          | `GhosttyColorRgb*`      | Effective foreground (override or default)      |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND`          | `GhosttyColorRgb*`      | Effective background (override or default)      |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_CURSOR`              | `GhosttyColorRgb*`      | Effective cursor (override or default)          |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_PALETTE`             | `GhosttyColorRgb[256]*` | Current palette (with any OSC overrides)        |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT`  | `GhosttyColorRgb*`      | Default foreground only (ignores OSC override)  |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT`  | `GhosttyColorRgb*`      | Default background only (ignores OSC override)  |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT`      | `GhosttyColorRgb*`      | Default cursor only (ignores OSC override)      |
 * | `GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT`     | `GhosttyColorRgb[256]*` | Default palette only (ignores OSC overrides)    |
 *
 * For foreground, background, and cursor colors, the getters return
 * `GHOSTTY_NO_VALUE` if no color is configured (neither a default nor an
 * OSC override). The palette getters always succeed since the palette
 * always has a value (the built-in default if nothing else is set).
 *
 * ### Setting a color theme
 * @snippet c-vt-colors/src/main.c colors-set-defaults
 *
 * ### Reading effective and default colors
 * @snippet c-vt-colors/src/main.c colors-read
 *
 * ### Full example with OSC overrides
 * @snippet c-vt-colors/src/main.c colors-main
 *
 * @{
 */

/**
 * Amount of compression work to perform before returning.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Perform one bounded compression step suitable for idle scheduling. */
  GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL = 0,

  /** Synchronously inspect every currently eligible page. */
  GHOSTTY_TERMINAL_COMPRESSION_MODE_FULL = 1,
  GHOSTTY_TERMINAL_COMPRESSION_MODE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalCompressionMode;

/**
 * Scheduling result from terminal compression.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Retained-mapping reclamation is unavailable on this target. */
  GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED = 0,

  /** More incremental compression work remains. */
  GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING = 1,

  /** The pass has no continuation to schedule. */
  GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE = 2,
  GHOSTTY_TERMINAL_COMPRESSION_RESULT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalCompressionResult;

/**
 * Scroll viewport behavior tag.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Scroll to the top of the scrollback. */
  GHOSTTY_SCROLL_VIEWPORT_TOP,

  /** Scroll to the bottom (active area). */
  GHOSTTY_SCROLL_VIEWPORT_BOTTOM,

  /** Scroll by a delta amount (up is negative). */
  GHOSTTY_SCROLL_VIEWPORT_DELTA,

  /**
   * Scroll to an absolute row offset from the top of the scrollable
   * area. Row 0 is the top of the scrollback and the requested row
   * becomes the first visible row of the viewport. The value is
   * clamped so the viewport never scrolls beyond the top of the
   * active area. If the terminal has no scrollback (e.g. the
   * alternate screen is active), the viewport always remains on the
   * active area.
   *
   * This is the same row space as the offset field of
   * GhosttyTerminalScrollbar, so a scrollbar position obtained from
   * GHOSTTY_TERMINAL_DATA_SCROLLBAR round-trips cleanly.
   */
  GHOSTTY_SCROLL_VIEWPORT_ROW,
  GHOSTTY_SCROLL_VIEWPORT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalScrollViewportTag;

/**
 * Scroll viewport value.
 *
 * @ingroup terminal
 */
typedef union {
  /** Scroll delta (only used with GHOSTTY_SCROLL_VIEWPORT_DELTA). Up is negative. */
  intptr_t delta;

  /** Absolute row offset (only used with GHOSTTY_SCROLL_VIEWPORT_ROW). */
  size_t row;

  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[2];
} GhosttyTerminalScrollViewportValue;

/**
 * Tagged union for scroll viewport behavior.
 *
 * @ingroup terminal
 */
typedef struct {
  GhosttyTerminalScrollViewportTag tag;
  GhosttyTerminalScrollViewportValue value;
} GhosttyTerminalScrollViewport;

/**
 * Terminal screen identifier.
 *
 * Identifies which screen buffer is active in the terminal.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The primary (normal) screen. */
  GHOSTTY_TERMINAL_SCREEN_PRIMARY = 0,

  /** The alternate screen. */
  GHOSTTY_TERMINAL_SCREEN_ALTERNATE = 1,
  GHOSTTY_TERMINAL_SCREEN_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalScreen;

/**
 * Visual style of the terminal cursor.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Bar cursor (DECSCUSR 5, 6). */
  GHOSTTY_TERMINAL_CURSOR_STYLE_BAR = 0,

  /** Block cursor (DECSCUSR 1, 2). */
  GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK = 1,

  /** Underline cursor (DECSCUSR 3, 4). */
  GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE = 2,

  /** Hollow block cursor. */
  GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW = 3,
  GHOSTTY_TERMINAL_CURSOR_STYLE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalCursorStyle;

/**
 * Scrollbar state for the terminal viewport.
 *
 * Represents the scrollable area dimensions needed to render a scrollbar.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Total size of the scrollable area in rows. */
  uint64_t total;

  /** Offset into the total area that the viewport is at. */
  uint64_t offset;

  /** Length of the visible area in rows. */
  uint64_t len;
} GhosttyTerminalScrollbar;

/**
 * Callback function type for bell.
 *
 * Called when the terminal receives a BEL character (0x07).
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalBellFn)(GhosttyTerminal terminal,
                                      void* userdata);

/**
 * Unsupported terminal sequence tags.
 *
 * Only APC sequences are currently reported. Additional sequence types may
 * be added without changing the callback shape.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Application Program Command (APC). */
  GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_APC = 0,
  GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalUnknownSequenceTag;

/**
 * An unsupported string terminal sequence.
 *
 * The content is borrowed and valid only for the callback duration. It
 * contains the bytes between the sequence introducer and terminator, may
 * contain arbitrary binary data, and is not null-terminated.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Whether content was shortened by the byte limit or allocation failure. */
  bool truncated;

  /** Retained sequence content. */
  GhosttyString content;
} GhosttyTerminalUnknownStringSequence;

/**
 * Unsupported terminal sequence value.
 *
 * @ingroup terminal
 */
typedef union {
  /** Application Program Command (APC). */
  GhosttyTerminalUnknownStringSequence apc;

  /**
   * Padding for ABI compatibility. Do not use.
   *
   * 128 bytes leaves room for future structured sequence payloads, such as
   * CSI with borrowed parameter, separator, and intermediate arrays, without
   * changing the tagged union's ABI.
   */
  uint64_t _padding[16];
} GhosttyTerminalUnknownSequenceValue;

/**
 * An unsupported terminal sequence.
 *
 * @ingroup terminal
 */
typedef struct {
  GhosttyTerminalUnknownSequenceTag tag;
  GhosttyTerminalUnknownSequenceValue value;
} GhosttyTerminalUnknownSequence;

/**
 * Callback function type for unsupported terminal sequences.
 *
 * Called synchronously for normally terminated sequences whose identifier is
 * not supported by the active terminal handler. Aborted sequences, malformed
 * recognized commands, and explicitly disabled known protocols are ignored.
 *
 * Capture must also be enabled with a nonzero
 * GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES value. Installing this callback alone
 * does not retain sequence content or allocate memory.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param sequence Borrowed unsupported sequence
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalUnknownSequenceFn)(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyTerminalUnknownSequence* sequence);

/**
 * Clipboard destination for a clipboard write.
 *
 * Protocol-specific destination identifiers are normalized to these values
 * before the clipboard write callback is invoked.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The standard system clipboard. */
  GHOSTTY_CLIPBOARD_LOCATION_STANDARD = 0,

  /** The selection clipboard. */
  GHOSTTY_CLIPBOARD_LOCATION_SELECTION = 1,

  /** The primary selection clipboard. */
  GHOSTTY_CLIPBOARD_LOCATION_PRIMARY = 2,
  GHOSTTY_CLIPBOARD_LOCATION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyClipboardLocation;

/**
 * One MIME representation in a clipboard write.
 *
 * Both strings are borrowed and valid only for the duration of the callback.
 * The data is binary-safe and has already been decoded from any protocol-level
 * encoding. A zero-length data string is an explicit empty representation; it
 * does not clear the clipboard.
 *
 * This struct has a frozen layout and will not gain fields in future versions.
 *
 * @ingroup terminal
 */
typedef struct {
  /** MIME type of the representation. */
  GhosttyString mime;

  /** Decoded, binary-safe representation data. */
  GhosttyString data;
} GhosttyClipboardContent;

/**
 * Result of a clipboard write reply.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The clipboard write completed successfully. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS = 0,

  /** The clipboard write was denied by policy or the user. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED = 1,

  /** The destination or one or more representations are unsupported. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED = 2,

  /** The clipboard is temporarily unavailable. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY = 3,

  /** One or more representations contain invalid data. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA = 4,

  /** The clipboard write failed due to an I/O error. */
  GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR = 5,
  GHOSTTY_CLIPBOARD_WRITE_RESULT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyClipboardWriteResult;

/**
 * The reply to a clipboard write request.
 *
 * This is a sized struct; set `size` to `sizeof(GhosttyClipboardWriteReply)`.
 * The reply is borrowed only for the duration of the reply call and may be
 * freed as soon as it returns.
 *
 * The result answers the program with the matching protocol status for
 * protocols with a write acknowledgement (OSC 5522: DONE, EPERM, ENOSYS,
 * EBUSY, EINVAL, EIO); protocols without one (OSC 52, OSC 1337 Copy)
 * discard the reply. `remember` is ignored on any result other than
 * GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** Outcome of the write. */
  GhosttyClipboardWriteResult result;

  /**
   * Record a session grant so future requests from the same program skip
   * the permission prompt. Only honored on success when
   * GhosttyClipboardWrite::can_remember is set.
   */
  bool remember;
} GhosttyClipboardWriteReply;

typedef struct GhosttyClipboardWrite GhosttyClipboardWrite;

/**
 * Function type used to answer a clipboard write request. Obtained from
 * GhosttyClipboardWrite::reply; see that struct for the contract.
 *
 * @param write The request being answered
 * @param reply The reply, borrowed only for the duration of this call
 *
 * @ingroup terminal
 */
typedef void (*GhosttyClipboardWriteReplyFn)(
    const GhosttyClipboardWrite* write,
    const GhosttyClipboardWriteReply* reply);

/**
 * A synchronous request to write clipboard contents.
 *
 * This is a sized struct. The callback must only access fields present in the
 * size reported by `size`. The request, contents array, MIME strings, and
 * data strings are all borrowed and valid only for the callback duration.
 *
 * All entries in `contents` are representations of the same logical value
 * and must be committed atomically. A `contents_len` of zero requests that
 * the destination be cleared. This is distinct from a content entry whose data
 * has zero length.
 *
 * The write is answered by calling `reply` with this request and a
 * GhosttyClipboardWriteReply. This must happen within the clipboard write
 * request callback. This struct is only valid during that time. Calling 
 * `reply` more than once is safely ignored. Returning without replying 
 * denies the write.
 *
 * @ingroup terminal
 */
struct GhosttyClipboardWrite {
  /** Size of this struct in bytes. */
  size_t size;

  /** Clipboard destination. */
  GhosttyClipboardLocation location;

  /** Borrowed array of MIME representations. */
  const GhosttyClipboardContent* contents;

  /** Number of entries in contents; zero means clear the destination. */
  size_t contents_len;

  /**
   * Name of the writing program for permission prompts, if the protocol
   * carries one. Empty otherwise.
   */
  GhosttyString name;

  /**
   * True if the terminal already holds a session grant for this request
   * The embedder should skip any permission prompt and perform the write.
   */
  bool granted;

  /**
   * True if the program supplied a session password, so the embedder may
   * offer to remember the user's decision through
   * GhosttyClipboardWriteReply::remember. When false, remember is ignored.
   */
  bool can_remember;

  /** Terminal-owned reply state. Do not access. */
  const void* ctx;

  /** Answer the write; see the struct documentation. */
  GhosttyClipboardWriteReplyFn reply;
};

/**
 * Callback function type for clipboard_write.
 *
 * The embedder may ask for permission to write or perform the write 
 * async, but the callback itself is synchronous and the reply function
 * must be called during the lifetime of this function. While this callback
 * is active the VT stream is paused.
 *
 * Answer by calling `write->reply(write, &reply)` before returning. See
 * GhosttyClipboardWrite for the full contract. 
 *
 * The request may carry an optional program name requesting the write
 * and the state of prior permission granted. If `can_remember` is set
 * the response may set the `remember` flag and future requests from this
 * same program will be "granted" and the embedder can skip permission
 * requests.
 *
 * Clipboard read requests (OSC 52 "?" and OSC 5522 reads) are delivered
 * to GhosttyTerminalClipboardReadFn instead.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param write Borrowed atomic clipboard write request
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalClipboardWriteFn)(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyClipboardWrite* write);

/**
 * Result of a clipboard read reply.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The clipboard was read; the reply carries its contents. */
  GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS = 0,

  /** The clipboard read was denied by policy or the user. */
  GHOSTTY_CLIPBOARD_READ_RESULT_DENIED = 1,

  /** The embedder cannot read this clipboard. */
  GHOSTTY_CLIPBOARD_READ_RESULT_UNSUPPORTED = 2,

  /** The clipboard is temporarily unavailable. */
  GHOSTTY_CLIPBOARD_READ_RESULT_BUSY = 3,

  /** Reading the clipboard failed due to an I/O error. */
  GHOSTTY_CLIPBOARD_READ_RESULT_IO_ERROR = 4,
  GHOSTTY_CLIPBOARD_READ_RESULT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyClipboardReadResult;

/**
 * The reply to a clipboard read request.
 *
 * This is a sized struct; set `size` to `sizeof(GhosttyClipboardReadReply)`.
 * All arrays and the strings they point to are borrowed only for the
 * duration of the reply call and may be freed as soon as it returns.
 *
 * Any result other than GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS answers the
 * program with an empty clipboard (OSC 52) or the matching protocol status
 * (OSC 5522: EPERM, ENOSYS, EBUSY, EIO); the other fields are ignored in
 * that case. On success, `contents` should carry one representation per
 * requested MIME type (GhosttyClipboardRead::mimes) that the clipboard
 * has; unrequested representations are ignored. Protocols that carry a
 * single text value (OSC 52) use the first entry with a text MIME type
 * such as "text/plain".
 *
 * @ingroup terminal
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** Outcome of the read. */
  GhosttyClipboardReadResult result;

  /** Borrowed array of MIME representations of the clipboard contents. */
  const GhosttyClipboardContent* contents;

  /** Number of entries in contents. */
  size_t contents_len;

  /**
   * Borrowed array of all MIME types available on the clipboard. Only
   * used when GhosttyClipboardRead::list is set; may be NULL otherwise.
   */
  const GhosttyString* available;

  /** Number of entries in available. */
  size_t available_len;

  /**
   * Record a session grant so future requests from the same program skip
   * the permission prompt. Only honored on success when
   * GhosttyClipboardRead::can_remember is set.
   */
  bool remember;
} GhosttyClipboardReadReply;

typedef struct GhosttyClipboardRead GhosttyClipboardRead;

/**
 * Function type used to answer a clipboard read request. Obtained from
 * GhosttyClipboardRead::reply; see that struct for the contract.
 *
 * @param read The request being answered
 * @param reply The reply, borrowed only for the duration of this call
 *
 * @ingroup terminal
 */
typedef void (*GhosttyClipboardReadReplyFn)(
    const GhosttyClipboardRead* read,
    const GhosttyClipboardReadReply* reply);

/**
 * A synchronous request to read clipboard contents.
 *
 * This is a sized struct. The callback must only access fields present in the
 * size reported by `size`. The request is borrowed and valid only for the
 * callback duration.
 *
 * The read is answered by calling `reply` with this request and a
 * GhosttyClipboardReadReply. This must happen before the callback returns;
 * the request is invalid afterwards. Calling `reply` more than once is
 * ignored. Returning without replying answers the program with an empty
 * clipboard (OSC 52) or EPERM (OSC 5522).
 *
 * @ingroup terminal
 */
struct GhosttyClipboardRead {
  /** Size of this struct in bytes. */
  size_t size;

  /** Clipboard to read. */
  GhosttyClipboardLocation location;

  /**
   * Borrowed array of the MIME types the program wants, in order of
   * preference. Protocols that only carry text (OSC 52) request
   * "text/plain". NULL when mimes_len is zero.
   */
  const GhosttyString* mimes;

  /** Number of entries in mimes. */
  size_t mimes_len;

  /**
   * True if the program also wants the list of MIME types available on the
   * clipboard, delivered through GhosttyClipboardReadReply::available.
   */
  bool list;

  /**
   * Name of the requesting program for permission prompts, if the protocol
   * carries one. Empty otherwise.
   */
  GhosttyString name;

  /**
   * True if the terminal already holds a session grant for this request
   * (kitty clipboard protocol passwords). The embedder should skip any
   * permission prompt and serve the read.
   *
   * Always false when mimes_len is zero: such a request is served
   * without a prompt (see the callback docs), so the terminal never
   * consults grants for it and a one-time password is preserved for
   * the follow-up data read.
   */
  bool granted;

  /**
   * True if the program supplied a session password, so the embedder may
   * offer to remember the user's decision through
   * GhosttyClipboardReadReply::remember. When false, remember is ignored.
   */
  bool can_remember;

  /** Terminal-owned reply state. Do not access. */
  const void* ctx;

  /** Answer the read; see the struct documentation. */
  GhosttyClipboardReadReplyFn reply;
};

/**
 * Callback function type for clipboard_read.
 *
 * Called synchronously when the running program requests clipboard contents
 * via OSC 52 with a "?" payload or a Kitty clipboard (OSC 5522) read.
 * Answering lets the program read the user's clipboard, so the embedder is
 * expected to mediate consent. Because the read is synchronous, an embedder
 * that needs to ask the user must block (for example by running a modal
 * prompt) until it has an answer; the VT stream waits until the callback
 * returns.
 *
 * Answer by calling `read->reply(read, &reply)` before returning. See
 * GhosttyClipboardRead for the full contract.
 *
 * OSC 5522 requests carry the program's MIME list, name, and password grant
 * state; a reply that sets `remember` records a session grant so later
 * requests with the same password arrive with `granted` set. Kitty itself
 * serves a request for only the targets listing (`list` with no `mimes`)
 * without prompting, and embedders are expected to do the same; the
 * terminal never consults grants for such requests (`granted` is false
 * and one-time passwords are not consumed).
 *
 * Installing this callback also enables Kitty paste events (mode 5522):
 * ghostty_terminal_paste() sends the program an event instead of the text,
 * and the program's follow-up read arrives here with `granted` set since
 * the user already pasted. See ghostty_terminal_paste().
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param read Borrowed clipboard read request
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalClipboardReadFn)(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyClipboardRead* read);

/**
 * A request to show a desktop notification.
 *
 * This is a sized struct. The callback must only access fields present in the
 * size reported by `size`. Both strings are borrowed and valid only for the
 * duration of the callback.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** Notification title, or an empty string when the protocol omits it. */
  GhosttyString title;

  /** Notification body. */
  GhosttyString body;
} GhosttyTerminalDesktopNotification;

/**
 * Callback function type for desktop notifications.
 *
 * Called synchronously when the terminal receives OSC 9 or OSC 777.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param notification Borrowed desktop notification request
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalDesktopNotificationFn)(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyTerminalDesktopNotification* notification);

/**
 * State of a terminal progress report.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Remove any visible progress indication. */
  GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE = 0,

  /** Show determinate progress. */
  GHOSTTY_TERMINAL_PROGRESS_STATE_SET = 1,

  /** Show a failed progress state. */
  GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR = 2,

  /** Show indeterminate progress. */
  GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE = 3,

  /** Show paused progress. */
  GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE = 4,
  GHOSTTY_TERMINAL_PROGRESS_STATE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalProgressState;

/**
 * A progress report emitted by the running program.
 *
 * This is a sized struct. The callback must only access fields present in the
 * size reported by `size`.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;

  /** Literal progress state reported by the running program. */
  GhosttyTerminalProgressState state;

  /** Progress percentage from 0 through 100, or -1 when omitted. */
  int8_t progress;
} GhosttyTerminalProgressReport;

/**
 * Callback function type for progress reports.
 *
 * Called synchronously when the terminal receives OSC 9;4.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param report Borrowed progress report
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalProgressReportFn)(
    GhosttyTerminal terminal,
    void* userdata,
    const GhosttyTerminalProgressReport* report);

/**
 * Callback function type for color scheme queries (CSI ? 996 n).
 *
 * Called when the terminal receives a color scheme device status report
 * query. Return true and fill *out_scheme with the current color scheme,
 * or return false to silently ignore the query.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param[out] out_scheme Pointer to store the current color scheme
 * @return true if the color scheme was filled, false to ignore the query
 *
 * @ingroup terminal
 */
typedef bool (*GhosttyTerminalColorSchemeFn)(GhosttyTerminal terminal,
                                             void* userdata,
                                             GhosttyColorScheme* out_scheme);

/**
 * Callback function type for device attributes queries (DA1/DA2/DA3).
 *
 * Called when the terminal receives a device attributes query (CSI c,
 * CSI > c, or CSI = c). Return true and fill *out_attrs with the
 * response data, or return false to silently ignore the query.
 *
 * The terminal uses whichever sub-struct (primary, secondary, tertiary)
 * matches the request type, but all three should be filled for simplicity.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param[out] out_attrs Pointer to store the device attributes response
 * @return true if attributes were filled, false to ignore the query
 *
 * @ingroup terminal
 */
typedef bool (*GhosttyTerminalDeviceAttributesFn)(GhosttyTerminal terminal,
                                                   void* userdata,
                                                   GhosttyDeviceAttributes* out_attrs);

/**
 * Callback function type for enquiry (ENQ, 0x05).
 *
 * Called when the terminal receives an ENQ character. Return the
 * response bytes as a GhosttyString. The memory must remain valid
 * until the callback returns. Return a zero-length string to send
 * no response.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @return The response bytes to write back to the pty
 *
 * @ingroup terminal
 */
typedef GhosttyString (*GhosttyTerminalEnquiryFn)(GhosttyTerminal terminal,
                                                   void* userdata);

/**
 * Callback function type for terminal size reports.
 *
 * Called in response to XTWINOPS size queries (CSI 14/16/18 t) and when VT
 * input enables in-band size reports (mode 2048).
 * Return true and fill *out_size with the current terminal geometry,
 * or return false to suppress the report.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param[out] out_size Pointer to store the terminal size information
 * @return true if size was filled, false to suppress the XTWINOPS response or
 * mode 2048 report
 *
 * @ingroup terminal
 */
typedef bool (*GhosttyTerminalSizeFn)(GhosttyTerminal terminal,
                                      void* userdata,
                                      GhosttySizeReportSize* out_size);

/**
 * Callback function type for title_changed.
 *
 * Called when the terminal title changes via escape sequences
 * (e.g. OSC 0 or OSC 2). The new title can be queried from the
 * terminal after the callback returns.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalTitleChangedFn)(GhosttyTerminal terminal,
                                              void* userdata);

/**
 * Callback function type for pwd_changed.
 *
 * Called when the terminal pwd (current working directory) changes via
 * escape sequences: OSC 7 (file:// URI), OSC 9 (ConEmu CurrentDir), or
 * OSC 1337 CurrentDir (iTerm2). Use ghostty_terminal_get() with
 * GHOSTTY_TERMINAL_DATA_PWD inside the callback to read the new value.
 *
 * The terminal stores whatever bytes the shell emitted, without parsing.
 * That means for OSC 7 the value is the raw URI (typically file://...);
 * for OSC 9/OSC 1337 it is typically a bare path. The embedder is
 * responsible for decoding any URI scheme or host if it cares about them.
 *
 * The callback also fires when the shell clears the pwd (e.g. an empty
 * OSC 7). In that case GHOSTTY_TERMINAL_DATA_PWD returns a zero-length
 * string.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalPwdChangedFn)(GhosttyTerminal terminal,
                                            void* userdata);

/**
 * Callback function type for write_pty.
 *
 * Called when the terminal needs to write data back to the pty, for
 * example in response to a device status report, mode query, or VT-driven
 * mode 2048 enable. The data is only valid for the duration of the call;
 * callers must copy it if it needs to persist.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param data Pointer to the response bytes
 * @param len Length of the response in bytes
 *
 * @ingroup terminal
 */
typedef void (*GhosttyTerminalWritePtyFn)(GhosttyTerminal terminal,
                                          void* userdata,
                                          const uint8_t* data,
                                          size_t len);

/**
 * Callback function type for XTVERSION.
 *
 * Called when the terminal receives an XTVERSION query (CSI > q).
 * Return the version string (e.g. "myterm 1.0") as a GhosttyString.
 * The memory must remain valid until the callback returns. Return a
 * zero-length string to report the default "libghostty" version.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @return The version string to report
 *
 * @ingroup terminal
 */
typedef GhosttyString (*GhosttyTerminalXtversionFn)(GhosttyTerminal terminal,
                                                     void* userdata);

/**
 * A terminal mode and boolean value used for mode configuration and queries.
 *
 * For GHOSTTY_TERMINAL_DATA_MODE, initialize `mode` before calling
 * ghostty_terminal_get(). On success, `value` contains the current mode value.
 *
 * This struct has a frozen layout and will not gain fields in future versions.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Mode to configure or query. */
  GhosttyMode mode;

  /** Value to set, or the current value returned by a query. */
  bool value;
} GhosttyTerminalModeConfig;

/**
 * Terminal option identifiers.
 *
 * These values are used with ghostty_terminal_set() to configure
 * terminal callbacks and associated state.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Opaque userdata pointer passed to all callbacks.
   *
   * Input type: void*
   */
  GHOSTTY_TERMINAL_OPT_USERDATA = 0,

  /**
   * Callback invoked when the terminal needs to write data back
   * to the pty (e.g. in response to a DECRQM query, device status
   * report, or VT-driven mode 2048 enable). Set to NULL to ignore such
   * sequences.
   *
   * Input type: GhosttyTerminalWritePtyFn
   */
  GHOSTTY_TERMINAL_OPT_WRITE_PTY = 1,

  /**
   * Callback invoked when the terminal receives a BEL character
   * (0x07). Set to NULL to ignore bell events.
   *
   * Input type: GhosttyTerminalBellFn
   */
  GHOSTTY_TERMINAL_OPT_BELL = 2,

  /**
   * Callback invoked when the terminal receives an ENQ character
   * (0x05). Set to NULL to send no response.
   *
   * Input type: GhosttyTerminalEnquiryFn
   */
  GHOSTTY_TERMINAL_OPT_ENQUIRY = 3,

  /**
   * Callback invoked when the terminal receives an XTVERSION query
   * (CSI > q). Set to NULL to report the default "libghostty" string.
   *
   * Input type: GhosttyTerminalXtversionFn
   */
  GHOSTTY_TERMINAL_OPT_XTVERSION = 4,

  /**
   * Callback invoked when the terminal title changes via escape
   * sequences (e.g. OSC 0 or OSC 2). Set to NULL to ignore title
   * change events.
   *
   * Input type: GhosttyTerminalTitleChangedFn
   */
  GHOSTTY_TERMINAL_OPT_TITLE_CHANGED = 5,

  /**
   * Callback invoked in response to XTWINOPS size queries
   * (CSI 14/16/18 t). Set to NULL to silently ignore size queries.
   *
   * Input type: GhosttyTerminalSizeFn
   */
  GHOSTTY_TERMINAL_OPT_SIZE = 6,

  /**
   * Callback invoked in response to a color scheme device status
   * report query (CSI ? 996 n). Return true and fill the out pointer
   * to report the current scheme, or return false to silently ignore.
   * Set to NULL to ignore color scheme queries.
   *
   * Input type: GhosttyTerminalColorSchemeFn
   */
  GHOSTTY_TERMINAL_OPT_COLOR_SCHEME = 7,

  /**
   * Callback invoked in response to a device attributes query
   * (CSI c, CSI > c, or CSI = c). Return true and fill the out
   * pointer with response data, or return false to silently ignore.
   * Set to NULL to ignore device attributes queries.
   *
   * Input type: GhosttyTerminalDeviceAttributesFn
   */
  GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES = 8,

  /**
   * Set the terminal title manually.
   *
   * The string data is copied into the terminal. A NULL value pointer
   * clears the title (equivalent to setting an empty string).
   *
   * Input type: GhosttyString*
   */
  GHOSTTY_TERMINAL_OPT_TITLE = 9,

  /**
   * Set the terminal working directory manually.
   *
   * The string data is copied into the terminal. A NULL value pointer
   * clears the pwd (equivalent to setting an empty string).
   *
   * Input type: GhosttyString*
   */
  GHOSTTY_TERMINAL_OPT_PWD = 10,

  /**
   * Set the default foreground color.
   *
   * A NULL value pointer clears the default (unset).
   *
   * Input type: GhosttyColorRgb*
   */
  GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND = 11,

  /**
   * Set the default background color.
   *
   * A NULL value pointer clears the default (unset).
   *
   * Input type: GhosttyColorRgb*
   */
  GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND = 12,

  /**
   * Set the default cursor color.
   *
   * A NULL value pointer clears the default (unset).
   *
   * Input type: GhosttyColorRgb*
   */
  GHOSTTY_TERMINAL_OPT_COLOR_CURSOR = 13,

  /**
   * Set the default 256-color palette.
   *
   * The value must point to an array of exactly 256 GhosttyColorRgb values.
   * A NULL value pointer resets to the built-in default palette.
   *
   * Input type: GhosttyColorRgb[256]*
   */
  GHOSTTY_TERMINAL_OPT_COLOR_PALETTE = 14,

  /**
   * Set the Kitty image storage limit in bytes.
   *
   * Applied to all initialized screens (primary and alternate).
   * A value of zero disables the Kitty graphics protocol entirely,
   * deleting all stored images and placements. A NULL value pointer
   * is equivalent to zero (disables). Has no effect when Kitty graphics
   * are disabled at build time.
   *
   * Input type: uint64_t*
   */
  GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT = 15,

  /**
   * Enable or disable Kitty image loading via the file medium.
   *
   * A NULL value pointer is a no-op. Has no effect when Kitty graphics
   * are disabled at build time.
   *
   * Input type: bool*
   */
  GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE = 16,

  /**
   * Enable Kitty image loading via the temporary file medium, restricted to
   * the provided directory. The string data is copied into the terminal.
   *
   * A NULL value pointer disables the temporary file medium. Has no effect
   * when Kitty graphics are disabled at build time.
   *
   * Input type: GhosttyString*
   */
  GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE = 17,

  /**
   * Enable or disable Kitty image loading via the shared memory medium.
   *
   * A NULL value pointer is a no-op. Has no effect when Kitty graphics
   * are disabled at build time.
   *
   * Input type: bool*
   */
  GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM = 18,

  /**
   * Set the maximum bytes the APC handler will buffer for all protocols.
   * This prevents malicious input from causing unbounded memory allocation.
   * A NULL value pointer removes all overrides, reverting to the built-in
   * defaults.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES = 19,

  /**
   * Set the maximum bytes the APC handler will buffer for Kitty graphics
   * protocol data. A NULL value pointer removes the override, reverting
   * to the built-in default.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY = 20,

  /**
   * Set the active screen selection.
   *
   * The value must point to a GhosttySelection whose grid references are
   * valid for this terminal's active screen at the time of the call. The
   * terminal copies the selection immediately and converts it to
   * terminal-owned tracked state, so the GhosttySelection struct and its
   * untracked grid references do not need to outlive this call.
   *
   * Passing NULL clears the active screen selection.
   *
   * Input type: GhosttySelection*
   */
  GHOSTTY_TERMINAL_OPT_SELECTION = 21,

  /**
   * Set the default cursor style used by DECSCUSR reset (CSI 0 q).
   *
   * A NULL value pointer resets to the built-in default block cursor.
   *
   * Input type: GhosttyTerminalCursorStyle*
   */
  GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE = 22,

  /**
   * Set whether the default cursor should blink when reset by DECSCUSR
   * (CSI 0 q).
   *
   * A NULL value pointer resets to the built-in default of not blinking.
   *
   * Input type: bool*
   */
  GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK = 23,

  /**
   * Enable or disable Glyph Protocol APC handling.
   *
   * When disabled, Glyph Protocol APC sequences are ignored and no
   * support/query/register/clear responses are emitted. Disabling also clears
   * the terminal session's glyph glossary. A NULL value pointer is a no-op.
   *
   * Input type: bool*
   */
  GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL = 24,

  /**
   * Callback invoked when the terminal pwd changes via escape
   * sequences (OSC 7, OSC 9, or OSC 1337 CurrentDir). Set to NULL
   * to ignore pwd change events.
   *
   * Input type: GhosttyTerminalPwdChangedFn
   */
  GHOSTTY_TERMINAL_OPT_PWD_CHANGED = 25,

  /**
   * Callback invoked when the running program performs a clipboard write.
   * OSC 52, iTerm2 OSC 1337 Copy, and Kitty clipboard (OSC 5522) writes
   * are normalized to an atomic set of decoded MIME representations. Set
   * to NULL to ignore clipboard writes (Kitty clipboard writes are then
   * refused with ENOSYS). Clipboard read requests are delivered to
   * GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ instead.
   *
   * Input type: GhosttyTerminalClipboardWriteFn
   */
  GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE = 26,

  /**
   * Set the maximum scrollback allocation in bytes.
   *
   * This is an estimate. Internally, libghostty only prunes bytes up 
   * to a "page"-granularity. A page is the minimum allocated unit of
   * grid space within Ghostty. A page at the time of writing these docs
   * is about 400KB, so the byte limit will be within this delta.
   *
   * This works alongside the line limit configuration. If both are set,
   * the first-reached limit is used first. Both limits are dependent
   * on external state (byte limit can be reached with less lines if
   * more styles are used for example, line limit can be reached with
   * a narrower terminal viewport). So, they are useful together.
   *
   * Lowering the limit immediately removes eligible complete historical
   * pages. A value of zero disables scrollback and erases retained history.
   * A NULL value pointer removes the byte limit.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES = 27,

  /**
   * Set the maximum number of physical lines retained in scrollback.
   *
   * This is an estimate. Internally, libghostty only prunes lines up 
   * to a "page"-granularity. A page is the minimum allocated unit of
   * grid space within Ghostty. As a result, the actual available scrollback
   * lines will almost always be higher than configured. The magnitude 
   * of the difference depends on the number of used styles, graphemes, etc.
   * since the row-count in a page is dynamic based on that. In general,
   * it ranges from dozens to a hundred or so lines.
   *
   * This works alongside the line limit configuration. If both are set,
   * the first-reached limit is used first. Both limits are dependent
   * on external state (byte limit can be reached with less lines if
   * more styles are used for example, line limit can be reached with
   * a narrower terminal viewport). So, they are useful together.
   *
   * Lowering the limit immediately removes eligible complete historical
   * pages. A NULL value pointer removes the line limit.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES = 28,

  /**
   * Callback invoked when the running program requests a desktop
   * notification via OSC 9 or OSC 777. Set to NULL to ignore desktop
   * notification requests.
   *
   * Input type: GhosttyTerminalDesktopNotificationFn
   */
  GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION = 29,

  /**
   * Callback invoked when the running program reports progress via OSC 9;4.
   * Set to NULL to ignore progress reports.
   *
   * Input type: GhosttyTerminalProgressReportFn
   */
  GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT = 30,

  /**
   * Set the maximum number of replay-safe VT continuation bytes retained.
   *
   * Continuation bytes reconstruct an escape sequence or UTF-8 codepoint
   * which was unfinished at the end of the most recent
   * VT write call. They are used automatically by terminal snapshots and may
   * also be exported directly with the continuation APIs.
   *
   * Tracking is disabled by default. A nonzero value enables tracking and
   * sets its byte limit. Passing NULL or a pointer to zero disables tracking.
   * Lowering the limit below an already-retained
   * continuation, or enabling tracking while the parser is already
   * unfinished, makes the current continuation unavailable because earlier
   * bytes cannot be reconstructed. Tracking recovers automatically after a
   * later write reaches the ground state or contains a fresh replay start.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES = 31,

  /**
   * Enable window title reports in response to CSI 21 t.
   *
   * This is disabled by default because a running program can set a title and
   * query it back into the pty input stream, potentially injecting commands
   * that execute after user interaction. Passing NULL or a pointer to false
   * disables title reporting.
   *
   * Input type: bool*
   */
  GHOSTTY_TERMINAL_OPT_TITLE_REPORT = 32,

  /**
   * Set the reset default for a terminal mode.
   *
   * This unconditionally updates both the current value and the value restored
   * by a full terminal reset (RIS).
   *
   * Some recognized modes represent transitions or mirror additional terminal
   * state and cannot safely be configured as reset defaults. Those modes return
   * GHOSTTY_INVALID_VALUE. A NULL value pointer also returns
   * GHOSTTY_INVALID_VALUE.
   *
   * Input type: GhosttyTerminalModeConfig*
   */
  GHOSTTY_TERMINAL_OPT_MODE_DEFAULT = 33,

  /**
   * Set the current value of a terminal mode.
   *
   * This does not change the value restored by a full terminal reset (RIS).
   * A NULL value pointer or unknown mode returns GHOSTTY_INVALID_VALUE.
   *
   * Input type: GhosttyTerminalModeConfig*
   */
  GHOSTTY_TERMINAL_OPT_MODE = 34,

  /**
   * Callback invoked for unsupported terminal sequence identifiers. Set to
   * NULL to ignore unsupported sequences. Capture must also be enabled with
   * GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES.
   *
   * Input type: GhosttyTerminalUnknownSequenceFn
   */
  GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE = 35,

  /**
   * Set the maximum content bytes retained for each unsupported terminal
   * sequence. A NULL value pointer or zero disables capture and prevents
   * unknown-sequence callbacks.
   *
   * When this limit is hit, the unknown sequence callback will still
   * be invoked but `truncated` will be set to true.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES = 36,

  /**
   * Set the name of the terminfo entry this terminal runs as, reported
   * in response to an XTGETTCAP query for "TN" (e.g. "xterm-256color").
   *
   * The string data is copied into the terminal. A NULL value pointer
   * clears the name (equivalent to setting an empty string). A name
   * longer than 128 bytes returns GHOSTTY_INVALID_VALUE.
   *
   * If this is unset then we don't report anything for an XTGETTCAP
   * TN query, because we don't know what the embedding terminal around
   * libghostty is advertising itself as.
   *
   * Input type: GhosttyString*
   */
  GHOSTTY_TERMINAL_OPT_TERMINFO_NAME = 37,

  /**
   * Callback invoked when the running program requests clipboard contents
   * via OSC 52 with a "?" payload or a Kitty clipboard (OSC 5522) read. The
   * read is synchronous and must be answered before the callback returns.
   * Set to NULL (the default) to ignore OSC 52 read requests and refuse
   * OSC 5522 reads with EPERM.
   *
   * Input type: GhosttyTerminalClipboardReadFn
   */
  GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ = 38,

  /**
   * Set the maximum total decoded bytes a single Kitty clipboard protocol
   * (OSC 5522) write transaction may accumulate. The limit is captured
   * when a transaction begins; an in-flight transaction keeps the limit
   * it started with.
   *
   * Data beyond the limit fails the whole transaction with EFBIG. The
   * transaction is discarded, later write-related packets are ignored
   * until a new write begins, and nothing reaches the clipboard write
   * callback.
   *
   * Transactions are buffered in memory, so this limit bounds how much
   * memory a single write can make the terminal allocate. Pass SIZE_MAX
   * to remove the limit. A NULL value pointer reverts to the built-in
   * default of 64MiB, the minimum required by the protocol.
   *
   * This limit doesn't apply to OSC 52 writes, which are bounded by the
   * maximum length of an escape sequence instead.
   *
   * Input type: size_t*
   */
  GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES = 39,
  GHOSTTY_TERMINAL_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalOption;

/**
 * Terminal data types.
 *
 * These values specify what type of data to extract from a terminal
 * using `ghostty_terminal_get`.
 *
 * @ingroup terminal
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_TERMINAL_DATA_INVALID = 0,

  /**
   * Terminal width in cells.
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_COLS = 1,

  /**
   * Terminal height in cells.
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_ROWS = 2,

  /**
   * Cursor column position (0-indexed).
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_X = 3,

  /**
   * Cursor row position within the active area (0-indexed).
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_Y = 4,

  /**
   * Whether the cursor has a pending wrap (next print will soft-wrap).
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP = 5,

  /**
   * The currently active screen.
   *
   * Output type: GhosttyTerminalScreen *
   */
  GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN = 6,

  /**
   * Whether the cursor is visible (DEC mode 25).
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE = 7,

  /**
   * Current Kitty keyboard protocol flags.
   *
   * Output type: GhosttyKittyKeyFlags * (uint8_t *)
   */
  GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS = 8,

  /**
   * Scrollbar state for the terminal viewport.
   *
   * This is amortized O(1): the total is maintained incrementally as
   * the terminal is modified and the viewport offset is cached. The
   * first read after the viewport moves to an arbitrary position that
   * isn't an absolute row (e.g. scrolling to a selection) may cost
   * O(pages) to compute the offset, after which it is cached again.
   *
   * There is intentionally no change notification for scroll state.
   * Callers building scrollbars should poll this once per frame or
   * per write batch and diff the result to detect changes; this is
   * what Ghostty's own renderer does.
   *
   * Output type: GhosttyTerminalScrollbar *
   */
  GHOSTTY_TERMINAL_DATA_SCROLLBAR = 9,

  /**
   * The current SGR style of the cursor.
   *
   * This is the style that will be applied to newly printed characters.
   *
   * Output type: GhosttyStyle *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_STYLE = 10,

  /**
   * Whether any mouse tracking mode is active.
   *
   * Returns true if any of the mouse tracking modes (X10, normal, button,
   * or any-event) are enabled.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING = 11,

  /**
   * The terminal title as set by escape sequences (e.g. OSC 0/2).
   *
   * Returns a borrowed string. The pointer is valid until the next mutating
   * terminal call. An empty string (len=0) is returned when no title has been
   * set.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_TERMINAL_DATA_TITLE = 12,

  /**
   * The terminal's current working directory as set by escape sequences
   * (e.g. OSC 7).
   *
   * Returns a borrowed string. The pointer is valid until the next mutating
   * terminal call. An empty string (len=0) is returned when no pwd has been
   * set.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_TERMINAL_DATA_PWD = 13,

  /**
   * The total number of rows in the active screen including scrollback.
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_TOTAL_ROWS = 14,

  /**
   * The number of scrollback rows (total rows minus viewport rows).
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS = 15,

  /**
   * The total width of the terminal in pixels.
   *
   * This is cols * cell_width_px as set by ghostty_terminal_resize().
   *
   * Output type: uint32_t *
   */
  GHOSTTY_TERMINAL_DATA_WIDTH_PX = 16,

  /**
   * The total height of the terminal in pixels.
   *
   * This is rows * cell_height_px as set by ghostty_terminal_resize().
   *
   * Output type: uint32_t *
   */
  GHOSTTY_TERMINAL_DATA_HEIGHT_PX = 17,

  /**
   * The effective foreground color (override or default).
   *
   * Returns GHOSTTY_NO_VALUE if no foreground color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND = 18,

  /**
   * The effective background color (override or default).
   *
   * Returns GHOSTTY_NO_VALUE if no background color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND = 19,

  /**
   * The effective cursor color (override or default).
   *
   * Returns GHOSTTY_NO_VALUE if no cursor color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_CURSOR = 20,

  /**
   * The current 256-color palette.
   *
   * Output type: GhosttyColorRgb[256] *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_PALETTE = 21,

  /**
   * The default foreground color (ignoring any OSC override).
   *
   * Returns GHOSTTY_NO_VALUE if no default foreground color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT = 22,

  /**
   * The default background color (ignoring any OSC override).
   *
   * Returns GHOSTTY_NO_VALUE if no default background color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT = 23,

  /**
   * The default cursor color (ignoring any OSC override).
   *
   * Returns GHOSTTY_NO_VALUE if no default cursor color is set.
   *
   * Output type: GhosttyColorRgb *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT = 24,

  /**
   * The default 256-color palette (ignoring any OSC overrides).
   *
   * Output type: GhosttyColorRgb[256] *
   */
  GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT = 25,

  /**
   * The Kitty image storage limit in bytes for the active screen.
   *
   * A value of zero means the Kitty graphics protocol is disabled.
   * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
   *
   * Output type: uint64_t *
   */
  GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT = 26,

  /**
   * Whether the file medium is enabled for Kitty image loading on the
   * active screen.
   *
   * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE = 27,

  /**
   * The directory allowed for Kitty image loading via the temporary file
   * medium on the active screen. The string is empty when the medium is
   * disabled.
   *
   * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE = 28,

  /**
   * Whether the shared memory medium is enabled for Kitty image loading
   * on the active screen.
   *
   * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM = 29,

  /**
   * The Kitty graphics image storage for the active screen.
   *
   * Returns a borrowed pointer to the image storage. The pointer is valid
   * until the next mutating terminal call (e.g. ghostty_terminal_vt_write()
   * or ghostty_terminal_reset()).
   *
   * Returns GHOSTTY_NO_VALUE when Kitty graphics are disabled at build time.
   *
   * Output type: GhosttyKittyGraphics *
   */
  GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS = 30,

  /**
   * The active screen's current selection.
   *
   * On success, writes an untracked snapshot of the terminal-owned selection
   * to the caller-provided GhosttySelection. The GhosttySelection struct is
   * caller-owned and may be kept, but the grid references inside it are
   * untracked borrowed references into the active screen. They are only valid
   * until the next mutating terminal call, such as ghostty_terminal_set(),
   * ghostty_terminal_vt_write(), ghostty_terminal_resize(), or
   * ghostty_terminal_reset().
   *
   * Returns GHOSTTY_NO_VALUE when there is no active selection.
   *
   * Output type: GhosttySelection *
   */
  GHOSTTY_TERMINAL_DATA_SELECTION = 31,

  /**
   * Whether the viewport is currently pinned to the active area.
   *
   * This is true when the viewport is following the active terminal area,
   * and false when the user has scrolled into history.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE = 32,

  /**
   * Whether VT processing encountered a non-gracefully handled error that may
   * have prevented a terminal-owned semantic update.
   *
   * Processing remains best-effort, and ghostty_terminal_reset() does not 
   * clear it. Gracefully handled protocol failures, configured limits, 
   * malformed or unsupported input, and failures limited to external effects 
   * or query responses do not set it.
   *
   * This can't currently be unset. This is purely informational to consumers
   * if there was some error that happened at some point during VT processing.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR = 33,

  /**
   * The configured maximum scrollback allocation in bytes.
   *
   * This always reports the primary screen's configured value, including
   * while an alternate screen is active. Returns GHOSTTY_NO_VALUE when the
   * configured byte limit is unlimited.
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_BYTES = 34,

  /**
   * The configured maximum number of physical scrollback lines.
   *
   * This always reports the primary screen's configured value, including
   * while an alternate screen is active. Returns GHOSTTY_NO_VALUE when the
   * configured line limit is unlimited.
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_SCROLLBACK_MAX_LINES = 35,

  /**
   * The configured maximum retained VT continuation size in bytes.
   *
   * A value of zero means continuation tracking is disabled. This reports the
   * configured limit even when a current unfinished continuation is
   * temporarily unavailable.
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_CONTINUATION_MAX_BYTES = 36,

  /**
   * Get the current value of a terminal mode.
   *
   * The caller must initialize the `mode` field. On success, the `value` field
   * is updated with the current value. A NULL pointer or unknown mode returns
   * GHOSTTY_INVALID_VALUE.
   *
   * Input/output type: GhosttyTerminalModeConfig *
   */
  GHOSTTY_TERMINAL_DATA_MODE = 37,

  /**
   * Whether VT processing is at ground.
   *
   * Ground is when the stream isn't in the middle of any type of sequence:
   * UTF-8, ESC, CSI, OSC, etc. It is the stateless point of the stream.
   *
   * This is useful to know because it is a point at which you can
   * safely insert out-of-band VT sequences. For example, while reading
   * from a pty if you want to make your own changes, you can wait until
   * the pty input reaches ground, then write yours.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_VT_GROUND = 38,

  /**
   * Whether the cursor is currently at a semantic shell prompt or input area.
   *
   * This depends on semantic prompt markers such as OSC 133. Returns false
   * when semantic prompt information is unavailable or the alternate screen
   * is active.
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT = 39,

  /**
   * The configured maximum decoded bytes per Kitty clipboard protocol
   * (OSC 5522) write transaction. See
   * GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES.
   *
   * Output type: size_t *
   */
  GHOSTTY_TERMINAL_DATA_CLIPBOARD_WRITE_MAX_BYTES = 40,
  GHOSTTY_TERMINAL_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyTerminalData;

/**
 * Create a new terminal instance.
 *
 * The terminal starts with various reasonable defaults e.g. around
 * scrollback limits. Use ghostty_terminal_set() to change any options
 * prior to using the terminal.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param terminal Pointer to store the created terminal handle
 * @param cols Terminal width in cells (must be greater than zero)
 * @param rows Terminal height in cells (must be greater than zero)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_new(const GhosttyAllocator* allocator,
                                               GhosttyTerminal* terminal,
                                               uint16_t cols,
                                               uint16_t rows);

/**
 * Free a terminal instance.
 *
 * Releases all resources associated with the terminal. After this call,
 * the terminal handle becomes invalid and must not be used.
 *
 * @param terminal The terminal handle to free (may be NULL)
 *
 * @ingroup terminal
 */
GHOSTTY_API void ghostty_terminal_free(GhosttyTerminal terminal);

/**
 * Perform a full reset of the terminal (RIS).
 *
 * Resets all terminal state back to its initial configuration, including
 * modes, scrollback, scrolling region, and screen contents. The terminal
 * dimensions are preserved.
 *
 * @param terminal The terminal handle (may be NULL, in which case this is a no-op)
 *
 * @ingroup terminal
 */
GHOSTTY_API void ghostty_terminal_reset(GhosttyTerminal terminal);

/**
 * Resize the terminal to the given dimensions.
 *
 * Changes the number of columns and rows in the terminal. The primary
 * screen will reflow content if wraparound mode is enabled; the alternate
 * screen does not reflow. If the dimensions are unchanged, this is a no-op.
 *
 * This also updates the terminal's pixel dimensions (used for image
 * protocols and size reports), disables synchronized output mode (allowed
 * by the spec so that resize results are shown immediately), and sends an
 * in-band size report if mode 2048 is enabled.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param cols New width in cells (must be greater than zero)
 * @param rows New height in cells (must be greater than zero)
 * @param cell_width_px Width of a single cell in pixels
 * @param cell_height_px Height of a single cell in pixels
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal,
                                      uint16_t cols,
                                      uint16_t rows,
                                      uint32_t cell_width_px,
                                      uint32_t cell_height_px);

/**
 * Set an option on the terminal.
 *
 * Configures terminal callbacks and associated state such as the
 * write_pty callback and userdata pointer. The value is passed
 * directly for pointer types (callbacks, userdata) or as a pointer
 * to the value for non-pointer types (e.g. GhosttyString*).
 * The behavior of a NULL value is specific to each option and is
 * documented by the corresponding GhosttyTerminalOption value.
 *
 * Callbacks are invoked synchronously during VT writes. Callbacks must not
 * call ghostty_terminal_vt_write() or
 * ghostty_terminal_vt_write_until_ground() on the same terminal
 * (no reentrancy).
 *
 * @param terminal The terminal handle (may be NULL, in which case this is a no-op)
 * @param option The option to set
 * @param value Pointer to the value to set (type depends on the option),
 *              or NULL to clear the option
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_set(GhosttyTerminal terminal,
                                   GhosttyTerminalOption option,
                                   const void* value);

/**
 * Write VT-encoded data to the terminal for processing.
 *
 * Feeds raw bytes through the terminal's VT stream parser, updating
 * terminal state accordingly. By default, sequences that require output
 * (queries, device status reports) are silently ignored. Use
 * ghostty_terminal_set() with GHOSTTY_TERMINAL_OPT_WRITE_PTY to install
 * a callback that receives response data.
 *
 * This never fails. Any erroneous input or errors in processing the
 * input are logged internally but do not cause this function to fail
 * because this input is assumed to be untrusted and from an external
 * source; so the primary goal is to keep the terminal state consistent and 
 * not allow malformed input to corrupt or crash.
 *
 * @param terminal The terminal handle
 * @param data Pointer to the data to write
 * @param len Length of the data in bytes
 *
 * @ingroup terminal
 */
GHOSTTY_API void ghostty_terminal_vt_write(GhosttyTerminal terminal,
                                const uint8_t* data,
                                size_t len);

/**
 * Write VT-encoded data, but only the shortest prefix needed to reach ground.
 *
 * Ground is when the stream isn't in the middle of any type of sequence:
 * UTF-8, ESC, CSI, OSC, etc. It is the stateless point of the stream.
 *
 * This is useful to know because it is a point at which you can
 * safely insert out-of-band VT sequences. For example, while reading
 * from a pty if you want to make your own changes, you can wait until
 * the pty input reaches ground, then write yours.
 *
 * If the stream is already at ground then this consumes nothing and returns
 * GHOSTTY_SUCCESS. On success, out_consumed is the number of bytes consumed
 * before reaching ground, including the byte that reaches it.
 * GHOSTTY_NO_VALUE means the full slice was consumed without reaching ground.
 *
 * @param terminal The terminal handle (must not be NULL)
 * @param data Pointer to the data to write, or NULL when len is zero
 * @param len Length of the data in bytes
 * @param[out] out_consumed Number of bytes consumed (must not be NULL)
 * @return GHOSTTY_SUCCESS if ground was reached, GHOSTTY_NO_VALUE if all input
 *         was consumed without reaching ground, or GHOSTTY_INVALID_VALUE if
 *         an argument is invalid
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_vt_write_until_ground(
    GhosttyTerminal terminal,
    const uint8_t* data,
    size_t len,
    size_t* out_consumed);

/**
 * Write the terminal's replay-safe VT continuation to a callback writer.
 *
 * The continuation is the exact byte suffix needed to reconstruct unfinished
 * VT parser or UTF-8 decoder state in an equivalent terminal. It is empty
 * when the stream is at ground. The callback is invoked synchronously and
 * may be called more than once. It must not call terminal APIs with the same
 * terminal handle.
 *
 * Continuation tracking must have been enabled by setting
 * GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to a nonzero value before the
 * input that produced the continuation was written.
 *
 * The caller must serialize this operation with both VT write functions and
 * all other access to the same terminal.
 *
 * @param terminal Terminal to read from (must not be NULL)
 * @param writer Destination writer whose write callback must not be NULL
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR if the callback rejects
 *         a write, GHOSTTY_LIMIT_EXCEEDED if output accounting overflows, or
 *         GHOSTTY_INVALID_VALUE if an argument is invalid, tracking is
 *         disabled, or the current continuation is unavailable
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_write(
    GhosttyTerminal terminal,
    GhosttyWriter writer);

/**
 * Copy the terminal's replay-safe VT continuation into a caller buffer.
 *
 * Pass NULL for buf with buf_len zero to query the required size. A size query
 * returns GHOSTTY_OUT_OF_SPACE and stores the required size in out_written,
 * including zero when the stream is at ground. If a non-NULL buffer is too
 * small, the function has the same result and reports the full required size.
 * Continuation tracking must have been enabled by setting
 * GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to a nonzero value before the
 * input that produced the continuation was written.
 *
 * The caller must serialize this operation with all other access to the same
 * terminal.
 *
 * @param terminal Terminal to read from (must not be NULL)
 * @param buf Destination buffer, or NULL when buf_len is zero
 * @param buf_len Destination buffer capacity in bytes
 * @param[out] out_written Bytes written, or required size on
 *             GHOSTTY_OUT_OF_SPACE (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE for a size query or
 *         insufficient buffer, or GHOSTTY_INVALID_VALUE if an argument is
 *         invalid, tracking is disabled, or the current continuation is
 *         unavailable
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_buf(
    GhosttyTerminal terminal,
    uint8_t* buf,
    size_t buf_len,
    size_t* out_written);

/**
 * Return an allocated copy of the terminal's replay-safe VT continuation.
 *
 * The returned bytes are allocated with allocator, or the default allocator
 * when allocator is NULL. The caller must release them with ghostty_free(),
 * passing the same allocator and returned length. An empty continuation is a
 * successful zero-length allocation.
 * Continuation tracking must have been enabled by setting
 * GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES to a nonzero value before the
 * input that produced the continuation was written.
 *
 * The caller must serialize this operation with all other access to the same
 * terminal.
 *
 * @param terminal Terminal to read from (must not be NULL)
 * @param allocator Allocator for the output, or NULL for the default allocator
 * @param[out] out_ptr Allocated continuation bytes (must not be NULL)
 * @param[out] out_len Number of continuation bytes (must not be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, or GHOSTTY_INVALID_VALUE if an argument is invalid,
 *         tracking is disabled, or the current continuation is unavailable
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_continuation_alloc(
    GhosttyTerminal terminal,
    const GhosttyAllocator* allocator,
    uint8_t** out_ptr,
    size_t* out_len);

/**
 * Scroll the terminal viewport.
 *
 * Scrolls the terminal's viewport according to the given behavior.
 * When using GHOSTTY_SCROLL_VIEWPORT_DELTA, set the delta field in
 * the value union to specify the number of rows to scroll (negative
 * for up, positive for down). When using GHOSTTY_SCROLL_VIEWPORT_ROW,
 * set the row field to the absolute row offset from the top of the
 * scrollable area (the same row space as the offset field of
 * GhosttyTerminalScrollbar). For other behaviors, the value is ignored.
 *
 * @param terminal The terminal handle (may be NULL, in which case this is a no-op)
 * @param behavior The scroll behavior as a tagged union
 *
 * @ingroup terminal
 */
GHOSTTY_API void ghostty_terminal_scroll_viewport(GhosttyTerminal terminal,
                                       GhosttyTerminalScrollViewport behavior);

/**
 * Return the current compression activity token.
 *
 * The token is opaque and only equality comparisons are meaningful. An
 * embedding application should cache it and restart its compression idle
 * delay whenever the value changes. The value may wrap and changes in either
 * direction have the same meaning.
 *
 * This function only observes terminal state. It does not perform or schedule
 * compression.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_activity Receives the current activity token
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if an argument
 *         is NULL
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_compression_activity(
    GhosttyTerminal terminal,
    uint64_t* out_activity);

/**
 * Compress eligible terminal scrollback.
 *
 * Incremental mode performs bounded work suitable for an idle callback. A
 * pending result means the application should invoke another step while the
 * terminal remains idle. A complete result means no continuation is needed
 * until ghostty_terminal_compression_activity() changes. Full mode performs
 * one synchronous scan and can stall on large scrollback buffers.
 *
 * Compression is opportunistic. Complete means the pass has finished, not
 * that every page was compressed: pages may be unprofitable or encounter an
 * allocation or reclamation failure. Compression changes only the terminal's
 * storage representation and never its logical contents or scrollback limit.
 * Accessing compressed history restores it transparently.
 *
 * This function is not thread-safe with other operations on the same
 * terminal. The caller must serialize it with writes, rendering, searches,
 * and other terminal access.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param mode The amount of compression work to perform
 * @param[out] out_result Receives the compression scheduling result
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if an argument
 *         or mode is invalid
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_compress(
    GhosttyTerminal terminal,
    GhosttyTerminalCompressionMode mode,
    GhosttyTerminalCompressionResult* out_result);

/**
 * Get data from a terminal instance.
 *
 * Extracts typed data from the given terminal based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `GhosttyTerminalData` enum.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the data type is invalid
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_get(GhosttyTerminal terminal,
                                    GhosttyTerminalData data,
                                    void *out);

/**
 * Get multiple data fields from a terminal in a single call.
 *
 * This is an optimization over calling ghostty_terminal_get()
 * repeatedly, particularly useful in environments with high per-call
 * overhead such as FFI or Cgo.
 *
 * Each element in the keys array specifies a data kind, and the
 * corresponding element in the values array receives the result.
 * The type of each values[i] pointer must match the output type
 * documented for keys[i].
 *
 * Processing stops at the first error; on success out_written
 * is set to count, on error it is set to the index of the
 * failing key (i.e. the number of values successfully written).
 *
 * @param terminal The terminal handle (may be NULL)
 * @param count Number of key/value pairs
 * @param keys Array of data kinds to query
 * @param values Array of output pointers (types must match each key's
 *               documented output type)
 * @param[out] out_written On return, receives the number of values
 *             successfully written (may be NULL)
 * @return GHOSTTY_SUCCESS if all queries succeed
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_get_multi(GhosttyTerminal terminal,
                                    size_t count,
                                    const GhosttyTerminalData* keys,
                                    void** values,
                                    size_t* out_written);

/**
 * Resolve a point in the terminal grid to a grid reference.
 *
 * Resolves the given point (which can be in active, viewport, screen,
 * or history coordinates) to a grid reference for that location. Use
 * ghostty_grid_ref_cell() and ghostty_grid_ref_row() to extract the cell
 * and row.
 *
 * Lookups using the `active` and `viewport` tags are fast. The `screen`
 * and `history` tags may require traversing the full scrollback page list
 * to resolve the y coordinate, so they can be expensive for large
 * scrollback buffers.
 *
 * This function isn't meant to be used as the core of render loop. It
 * isn't built to sustain the framerates needed for rendering large screens.
 * Use the render state API for that. This API is instead meant for less
 * strictly performance-sensitive use cases.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param point The point specifying which cell to look up
 * @param[out] out_ref On success, set to the grid reference at the given point (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the point is out of bounds
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_grid_ref(GhosttyTerminal terminal,
                                        GhosttyPoint point,
                                        GhosttyGridRef *out_ref);

/**
 * Create an owned tracked grid reference for a terminal point.
 *
 * This is the tracked variant of ghostty_terminal_grid_ref(). The returned
 * handle follows the referenced cell as the terminal's page list is modified:
 * scrolling, pruning, resize/reflow, and other page-list operations update the
 * tracked reference automatically.
 *
 * The reference is attached to the terminal screen/page-list that is active at
 * creation time.
 *
 * If the point is outside the requested coordinate space, this returns
 * GHOSTTY_INVALID_VALUE and writes NULL to out_ref.
 *
 * The returned handle must be freed with ghostty_tracked_grid_ref_free(). If
 * the terminal is freed first, the handle remains valid only for
 * tracked-grid-ref APIs: it reports no value and can still be freed.
 *
 * @param terminal Terminal instance.
 * @param point Point to track.
 * @param[out] out_ref On success, receives the tracked reference handle.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if terminal,
 *         point, or out_ref is invalid, or GHOSTTY_OUT_OF_MEMORY if allocation
 *         fails.
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_grid_ref_track(
    GhosttyTerminal terminal,
    GhosttyPoint point,
    GhosttyTrackedGridRef *out_ref);

/**
 * Convert a grid reference back to a point in the given coordinate system.
 *
 * This is the inverse of ghostty_terminal_grid_ref(): given a grid reference,
 * it returns the x/y coordinates in the requested coordinate system (active,
 * viewport, screen, or history).
 *
 * The grid reference must have been obtained from the same terminal instance.
 * Like all grid references, it is only valid until the next mutating terminal
 * call.
 *
 * Not every grid reference is representable in every coordinate system. For
 * example, a cell in scrollback history cannot be expressed in active
 * coordinates, and a cell that has scrolled off the visible area cannot be
 * expressed in viewport coordinates. In these cases, the function returns
 * GHOSTTY_NO_VALUE.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param ref Pointer to the grid reference to convert
 * @param tag The target coordinate system
 * @param[out] out On success, set to the coordinate in the requested system (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         or ref is NULL/invalid, GHOSTTY_NO_VALUE if the ref falls outside
 *         the requested coordinate system
 *
 * @ingroup terminal
 */
GHOSTTY_API GhosttyResult ghostty_terminal_point_from_grid_ref(
    GhosttyTerminal terminal,
    const GhosttyGridRef *ref,
    GhosttyPointTag tag,
    GhosttyPointCoordinate *out);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_TERMINAL_H */
