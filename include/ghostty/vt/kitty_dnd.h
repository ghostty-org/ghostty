/**
 * @file kitty_dnd.h
 *
 * Kitty drag and drop protocol (OSC 72)
 *
 * See @ref kitty_dnd for a full usage guide.
 */

#ifndef GHOSTTY_VT_KITTY_DND_H
#define GHOSTTY_VT_KITTY_DND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup kitty_dnd Kitty Drag and Drop
 *
 * Native drag and drop for programs running in the terminal, through the
 * [Kitty drag and drop protocol](https://sw.kovidgoyal.net/kitty/dnd-protocol/)
 * (OSC 72).
 *
 * The protocol works in both directions. A program can register to
 * accept drops: native drags over the terminal are then forwarded to it
 * and it requests the dropped data, instead of the traditional behavior
 * of pasting dropped paths or text. A program can also offer drags: when
 * the user starts a drag gesture over the terminal, the program supplies
 * the data, and optionally an image, of a native drag out of the
 * terminal.
 *
 * libghostty-vt implements the protocol; the embedder connects it to the
 * operating system's drag and drop. The terminal tells the embedder what
 * the program did through the @ref GHOSTTY_TERMINAL_OPT_KITTY_DND effect,
 * and the embedder reports what the user did with the functions below,
 * which write the protocol's messages to the pty through the
 * @ref GHOSTTY_TERMINAL_OPT_WRITE_PTY effect.
 *
 * The protocol is disabled until the kitty_dnd effect is set: without
 * it, OSC 72 is ignored entirely, so programs fall back to their
 * behavior without the protocol.
 *
 * All functions must be called from the thread that calls
 * ghostty_terminal_vt_write() and may be called from within the
 * kitty_dnd effect callback. Strings and data returned by these
 * functions are borrowed from the terminal and valid until the next call
 * to ghostty_terminal_vt_write() or a function in this group.
 *
 * Every client is treated as being on the local machine: remote file
 * transfer is not supported, though remote programs can exchange text
 * and other data.
 *
 * ## Accepting Drops
 *
 *   1. The program registers to accept drops, yielding
 *      @ref GHOSTTY_KITTY_DND_EVENT_REGISTRATION. Check
 *      @ref GHOSTTY_KITTY_DND_DATA_DROP_REGISTERED: while true, forward
 *      native drags over the terminal instead of handling them yourself.
 *   2. As a native drag moves over the terminal, call
 *      ghostty_kitty_dnd_drop_move() with its position, allowed
 *      operations, and MIME types. When it leaves, call
 *      ghostty_kitty_dnd_drop_leave().
 *   3. The program answers with the operation it accepts, yielding
 *      @ref GHOSTTY_KITTY_DND_EVENT_ACCEPTANCE: read
 *      @ref GHOSTTY_KITTY_DND_DATA_DROP_ACCEPTED for the OS drag feedback.
 *   4. On drop, call ghostty_kitty_dnd_drop() and keep the native drop
 *      open: its data is read on demand.
 *   5. The program requests data, yielding
 *      @ref GHOSTTY_KITTY_DND_EVENT_DATA_REQUEST. Read the request with
 *      @ref GHOSTTY_KITTY_DND_DATA_DROP_REQUEST, read that MIME type from
 *      the native drop, and answer with ghostty_kitty_dnd_drop_respond_data()
 *      and ghostty_kitty_dnd_drop_respond_end(), or
 *      ghostty_kitty_dnd_drop_respond_error(). Answering may be
 *      asynchronous. Requests are served one at a time: after each
 *      answer, check for the next request.
 *   6. The program concludes the drop, yielding one of the
 *      `GHOSTTY_KITTY_DND_EVENT_CONCLUDED_*` events: finish the native
 *      drop with that operation.
 *
 * @snippet c-vt-kitty-dnd/src/main.c kitty-dnd-drop
 *
 * ## Offering Drags
 *
 *   1. The program enables offering drags, yielding
 *      @ref GHOSTTY_KITTY_DND_EVENT_OFFERS. While
 *      @ref GHOSTTY_KITTY_DND_DATA_DRAG_ENABLED is true, when the user
 *      starts the platform's drag gesture over the terminal (typically
 *      dragging with the left button held), call
 *      ghostty_kitty_dnd_drag_gesture() instead of handling it yourself.
 *   2. The program offers a drag and asks to start it, yielding
 *      @ref GHOSTTY_KITTY_DND_EVENT_DRAG_START. Read the offer, copying
 *      what you need: its MIME types (ghostty_kitty_dnd_drag_mime()),
 *      pre-sent data (ghostty_kitty_dnd_drag_pre_sent()), images
 *      (ghostty_kitty_dnd_drag_image()), and allowed operations. Start
 *      the native drag and report the result with
 *      ghostty_kitty_dnd_drag_start_result(), which frees the pre-sent
 *      data and images on success.
 *   3. During the drag, report its progress with
 *      ghostty_kitty_dnd_drag_report(). When a drop target wants data
 *      that wasn't pre-sent, call ghostty_kitty_dnd_drag_request_data();
 *      the program's reply yields @ref GHOSTTY_KITTY_DND_EVENT_DRAG_DATA
 *      events and is read with ghostty_kitty_dnd_drag_take_data().
 *      @ref GHOSTTY_KITTY_DND_EVENT_DRAG_IMAGE asks to change the drag
 *      image to @ref GHOSTTY_KITTY_DND_DATA_DRAG_CURRENT_IMAGE, and
 *      @ref GHOSTTY_KITTY_DND_EVENT_DRAG_CANCEL to cancel the drag.
 *   4. Report the drag finished, which ends it.
 *
 * @snippet c-vt-kitty-dnd/src/main.c kitty-dnd-drag
 *
 * @{
 */

/**
 * A drag and drop state change, delivered through the kitty_dnd effect.
 * Details are read with ghostty_kitty_dnd_get() and the other functions
 * in this group.
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The program registered or unregistered to accept drops. */
  GHOSTTY_KITTY_DND_EVENT_REGISTRATION = 0,
  /** The program answered the drag over the terminal. */
  GHOSTTY_KITTY_DND_EVENT_ACCEPTANCE = 1,
  /** A drop data request needs serving. */
  GHOSTTY_KITTY_DND_EVENT_DATA_REQUEST = 2,
  /** The drop ended with no operation (the program canceled it). */
  GHOSTTY_KITTY_DND_EVENT_CONCLUDED_NONE = 3,
  /** The drop ended with the program copying the data. */
  GHOSTTY_KITTY_DND_EVENT_CONCLUDED_COPY = 4,
  /** The drop ended with the program moving the data. */
  GHOSTTY_KITTY_DND_EVENT_CONCLUDED_MOVE = 5,
  /** The program enabled or disabled offering drags. */
  GHOSTTY_KITTY_DND_EVENT_OFFERS = 6,
  /** The program asked to start its offered drag. */
  GHOSTTY_KITTY_DND_EVENT_DRAG_START = 7,
  /** The program changed the image of the started drag. */
  GHOSTTY_KITTY_DND_EVENT_DRAG_IMAGE = 8,
  /** Requested drag data arrived or failed. */
  GHOSTTY_KITTY_DND_EVENT_DRAG_DATA = 9,
  /** The native drag in progress must be canceled. */
  GHOSTTY_KITTY_DND_EVENT_DRAG_CANCEL = 10,
  GHOSTTY_KITTY_DND_EVENT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndEvent;

/** A drag and drop operation. */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_KITTY_DND_OPERATION_NONE = 0,
  GHOSTTY_KITTY_DND_OPERATION_COPY = 1,
  GHOSTTY_KITTY_DND_OPERATION_MOVE = 2,
  GHOSTTY_KITTY_DND_OPERATION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndOperation;

/** Bit for the copy operation in an operations bitmask. */
#define GHOSTTY_KITTY_DND_OPERATIONS_COPY 1u

/** Bit for the move operation in an operations bitmask. */
#define GHOSTTY_KITTY_DND_OPERATIONS_MOVE 2u

/** A POSIX error name used by the protocol. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Success. */
  GHOSTTY_KITTY_DND_ERRNO_OK = 0,
  GHOSTTY_KITTY_DND_ERRNO_EPERM = 1,
  GHOSTTY_KITTY_DND_ERRNO_ENOENT = 2,
  GHOSTTY_KITTY_DND_ERRNO_EIO = 3,
  GHOSTTY_KITTY_DND_ERRNO_EINVAL = 4,
  GHOSTTY_KITTY_DND_ERRNO_EMFILE = 5,
  GHOSTTY_KITTY_DND_ERRNO_ENOMEM = 6,
  GHOSTTY_KITTY_DND_ERRNO_EFBIG = 7,
  GHOSTTY_KITTY_DND_ERRNO_EISDIR = 8,
  GHOSTTY_KITTY_DND_ERRNO_ENOSPC = 9,
  GHOSTTY_KITTY_DND_ERRNO_EUNKNOWN = 10,
  GHOSTTY_KITTY_DND_ERRNO_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndErrno;

/** The phase of the drag the program offers. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** No drag is offered. */
  GHOSTTY_KITTY_DND_PHASE_NONE = 0,
  /** The program is building an offer. */
  GHOSTTY_KITTY_DND_PHASE_BUILDING = 1,
  /** The program asked to start the drag; report the result. */
  GHOSTTY_KITTY_DND_PHASE_STARTING = 2,
  /** The native drag is in progress. */
  GHOSTTY_KITTY_DND_PHASE_STARTED = 3,
  /** The native drag was dropped; the target may still request data. */
  GHOSTTY_KITTY_DND_PHASE_DROPPED = 4,
  GHOSTTY_KITTY_DND_PHASE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndPhase;

/** The format of a drag image. */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * UTF-8 text to render as the image. The width and height are the
   * numerator and denominator of the font size scale (0 meaning 1), and
   * the opacity is the background's.
   */
  GHOSTTY_KITTY_DND_IMAGE_FORMAT_TEXT = 0,
  /** 24-bit RGB pixels. Expanded to RGBA when the drag starts. */
  GHOSTTY_KITTY_DND_IMAGE_FORMAT_RGB = 24,
  /** 32-bit RGBA pixels. */
  GHOSTTY_KITTY_DND_IMAGE_FORMAT_RGBA = 32,
  /** A PNG image, to be decoded by the embedder. */
  GHOSTTY_KITTY_DND_IMAGE_FORMAT_PNG = 100,
  GHOSTTY_KITTY_DND_IMAGE_FORMAT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndImageFormat;

/** The kind of a drag progress report. */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * The drop target accepted the drag. The value is the index of the
   * offered MIME type it prefers, or -1 if unknown.
   */
  GHOSTTY_KITTY_DND_REPORT_ACCEPTED = 0,
  /** The drag's operation changed. The value is a GhosttyKittyDndOperation. */
  GHOSTTY_KITTY_DND_REPORT_OPERATION = 1,
  /** The drag was dropped onto a target. The value is ignored. */
  GHOSTTY_KITTY_DND_REPORT_DROPPED = 2,
  /**
   * The drag finished, which ends it. The value is nonzero if it was
   * canceled.
   */
  GHOSTTY_KITTY_DND_REPORT_FINISHED = 3,
  GHOSTTY_KITTY_DND_REPORT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndReport;

/** The status of drag data received from the program. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** More data may follow. */
  GHOSTTY_KITTY_DND_DATA_STATUS_PENDING = 0,
  /** All data has been received. */
  GHOSTTY_KITTY_DND_DATA_STATUS_COMPLETE = 1,
  /** The program failed to provide the data. */
  GHOSTTY_KITTY_DND_DATA_STATUS_FAILED = 2,
  GHOSTTY_KITTY_DND_DATA_STATUS_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndDataStatus;

/** Values readable with ghostty_kitty_dnd_get(). */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Invalid. Never results in any data. */
  GHOSTTY_KITTY_DND_DATA_INVALID = 0,

  /**
   * Whether the program is registered to accept drops.
   *
   * Output type: bool *
   */
  GHOSTTY_KITTY_DND_DATA_DROP_REGISTERED = 1,

  /**
   * The MIME types the program registered with, space-separated and
   * usually empty. Only needed to register types with the OS ahead of a
   * drag. GHOSTTY_NO_VALUE when not registered.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_KITTY_DND_DATA_DROP_REGISTERED_MIMES = 2,

  /**
   * The operation the program accepts for the drag over the terminal.
   * GHOSTTY_NO_VALUE until it answered; use your default (typically
   * copy) until then.
   *
   * Output type: GhosttyKittyDndOperation *
   */
  GHOSTTY_KITTY_DND_DATA_DROP_ACCEPTED = 3,

  /**
   * The MIME types the program accepts for the drag over the terminal,
   * most preferred first, each followed by a NUL byte. Empty when the
   * program didn't say. GHOSTTY_NO_VALUE until it answered.
   *
   * Output type: GhosttyString *
   */
  GHOSTTY_KITTY_DND_DATA_DROP_ACCEPTED_MIMES = 4,

  /**
   * The drop data request to serve. GHOSTTY_NO_VALUE when there is
   * none.
   *
   * Output type: GhosttyKittyDndDataRequest *
   */
  GHOSTTY_KITTY_DND_DATA_DROP_REQUEST = 5,

  /**
   * Whether the program offers drags.
   *
   * Output type: bool *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_ENABLED = 6,

  /**
   * The phase of the drag the program offers.
   *
   * Output type: GhosttyKittyDndPhase *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_PHASE = 7,

  /**
   * The operations the offered drag allows, as a bitmask of
   * GHOSTTY_KITTY_DND_OPERATIONS_COPY and GHOSTTY_KITTY_DND_OPERATIONS_MOVE.
   * GHOSTTY_NO_VALUE when no drag is offered.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_OPERATIONS = 8,

  /**
   * The number of MIME types of the offered drag.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_MIME_COUNT = 9,

  /**
   * The number of images of the offered drag. Zero once the drag
   * started.
   *
   * Output type: size_t *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_IMAGE_COUNT = 10,

  /**
   * The index of the image to show for the drag. GHOSTTY_NO_VALUE for
   * no image. Once the drag started this is not checked against the
   * images, which you copied when it started.
   *
   * Output type: uint32_t *
   */
  GHOSTTY_KITTY_DND_DATA_DRAG_CURRENT_IMAGE = 11,
  GHOSTTY_KITTY_DND_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKittyDndData;

/**
 * A position on the terminal.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;
  /** Grid cell column, zero-based from the left. */
  uint32_t cell_x;
  /** Grid cell row, zero-based from the top. */
  uint32_t cell_y;
  /** Pixels from the left of the terminal's content area. */
  int32_t pixel_x;
  /** Pixels from the top of the terminal's content area. */
  int32_t pixel_y;
  /**
   * The operations a native drag allows, as a bitmask of
   * GHOSTTY_KITTY_DND_OPERATIONS_COPY and GHOSTTY_KITTY_DND_OPERATIONS_MOVE.
   * Ignored by ghostty_kitty_dnd_drag_gesture().
   */
  uint32_t operations;
} GhosttyKittyDndPosition;

/**
 * A drop data request to serve.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;
  /**
   * Identifies the request when answering it. Requests are never
   * reused, so an answer to a request the program abandoned is
   * rejected rather than answering another.
   */
  uint32_t id;
  /** Zero-based index into the MIME types given to ghostty_kitty_dnd_drop(). */
  uint32_t mime_index;
  /** The MIME type to read from the native drop. */
  GhosttyString mime;
} GhosttyKittyDndDataRequest;

/**
 * A drag image.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;
  /** The image format. */
  GhosttyKittyDndImageFormat format;
  /** Width in pixels, or the font scale numerator for text. */
  uint32_t width;
  /** Height in pixels, or the font scale denominator for text. */
  uint32_t height;
  /** Background opacity for text, 0 (transparent) to 1024 (opaque). */
  uint32_t opacity;
  /** The image data. */
  const uint8_t* data;
  /** The length of the image data in bytes. */
  size_t data_len;
} GhosttyKittyDndImage;

/**
 * Drag data received from the program.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 */
typedef struct {
  /** Size of this struct in bytes. */
  size_t size;
  /** Data received since the last call. */
  const uint8_t* data;
  /** The length of the data in bytes. */
  size_t data_len;
  /** Whether more data may follow, all has arrived, or it failed. */
  GhosttyKittyDndDataStatus status;
  /** The program's error when the status is failed. */
  GhosttyKittyDndErrno error;
} GhosttyKittyDndDragData;

/**
 * Callback function type for drag and drop state changes.
 *
 * Called when the running program changes drag and drop state in a way
 * the embedder may need to act on. The functions in @ref kitty_dnd may be
 * called from within this callback.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param event What changed
 */
typedef void (*GhosttyTerminalKittyDndFn)(GhosttyTerminal terminal,
                                          void* userdata,
                                          GhosttyKittyDndEvent event);

/**
 * Read drag and drop state.
 *
 * @param terminal The terminal handle
 * @param data The value to read
 * @param out Pointer to the output, of the type documented for @p data
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if the value doesn't apply
 *         now, or GHOSTTY_INVALID_VALUE for invalid arguments
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_get(GhosttyTerminal terminal,
                                                GhosttyKittyDndData data,
                                                void* out);

/**
 * Report a native drag moving over the terminal.
 *
 * @param terminal The terminal handle
 * @param position The pointer position and the drag's allowed operations
 * @param mimes The MIME types of the drag
 * @param mimes_len The number of MIME types
 * @param out_discarded Optional; set true when the drag entering
 *        discarded an unconcluded previous drop, which you must finish
 *        natively with no operation
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if the program isn't
 *         registered to accept drops, GHOSTTY_OUT_OF_MEMORY, or
 *         GHOSTTY_INVALID_VALUE for invalid arguments or no write_pty
 *         effect
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop_move(
    GhosttyTerminal terminal,
    const GhosttyKittyDndPosition* position,
    const GhosttyString* mimes,
    size_t mimes_len,
    bool* out_discarded);

/**
 * Report a native drag leaving the terminal without dropping.
 *
 * @param terminal The terminal handle
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if the program isn't
 *         registered to accept drops, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop_leave(GhosttyTerminal terminal);

/**
 * Report a native drop onto the terminal. Keep the native drop open to
 * serve the program's data requests until it concludes the drop.
 *
 * @param terminal The terminal handle
 * @param position The pointer position and the drag's allowed operations
 * @param mimes The MIME types the data can be requested as
 * @param mimes_len The number of MIME types
 * @param out_discarded Optional; as for ghostty_kitty_dnd_drop_move()
 * @return As for ghostty_kitty_dnd_drop_move()
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop(
    GhosttyTerminal terminal,
    const GhosttyKittyDndPosition* position,
    const GhosttyString* mimes,
    size_t mimes_len,
    bool* out_discarded);

/**
 * Send some of the data for the drop data request being served. Data is
 * sent as given, so it can be passed on as the native drop delivers it.
 *
 * @param terminal The terminal handle
 * @param id The request's id
 * @param data The data
 * @param data_len The length of the data
 * @return GHOSTTY_SUCCESS, GHOSTTY_REJECTED if @p id is not the request
 *         being served, GHOSTTY_NO_VALUE, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop_respond_data(
    GhosttyTerminal terminal,
    uint32_t id,
    const uint8_t* data,
    size_t data_len);

/**
 * Finish the drop data request being served. The next request, if any,
 * is then available with GHOSTTY_KITTY_DND_DATA_DROP_REQUEST.
 *
 * @param terminal The terminal handle
 * @param id The request's id
 * @return As for ghostty_kitty_dnd_drop_respond_data()
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop_respond_end(
    GhosttyTerminal terminal,
    uint32_t id);

/**
 * Fail the drop data request being served, e.g. because reading it from
 * the native drop failed. The next request, if any, is then available
 * with GHOSTTY_KITTY_DND_DATA_DROP_REQUEST.
 *
 * @param terminal The terminal handle
 * @param id The request's id
 * @param error The error to report
 * @return As for ghostty_kitty_dnd_drop_respond_data()
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drop_respond_error(
    GhosttyTerminal terminal,
    uint32_t id,
    GhosttyKittyDndErrno error);

/**
 * Read a MIME type of the offered drag.
 *
 * @param terminal The terminal handle
 * @param index The zero-based index of the MIME type
 * @param out The MIME type
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if out of range, or
 *         GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_mime(GhosttyTerminal terminal,
                                                      size_t index,
                                                      GhosttyString* out);

/**
 * Read the data the program pre-sent for a MIME type of the offered
 * drag. Only available until the drag starts.
 *
 * @param terminal The terminal handle
 * @param index The zero-based index of the MIME type
 * @param out The data
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if none was pre-sent, or
 *         GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_pre_sent(
    GhosttyTerminal terminal,
    size_t index,
    GhosttyString* out);

/**
 * Read an image of the offered drag. Only available until the drag
 * starts.
 *
 * @param terminal The terminal handle
 * @param index The zero-based index of the image
 * @param out The image
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if out of range, or
 *         GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_image(
    GhosttyTerminal terminal,
    size_t index,
    GhosttyKittyDndImage* out);

/**
 * Ask the program to offer a drag, when the user started the platform's
 * drag gesture over the terminal.
 *
 * @param terminal The terminal handle
 * @param position Where the gesture started; operations are ignored
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if the program doesn't offer
 *         drags, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_gesture(
    GhosttyTerminal terminal,
    const GhosttyKittyDndPosition* position);

/**
 * Report the result of starting the native drag the program asked for.
 * Copy the offer's pre-sent data and images first: a successful start
 * frees them.
 *
 * @param terminal The terminal handle
 * @param error GHOSTTY_KITTY_DND_ERRNO_OK if the drag started, otherwise
 *        why not (GHOSTTY_KITTY_DND_ERRNO_EPERM when the user already
 *        released the drag)
 * @return GHOSTTY_SUCCESS, GHOSTTY_REJECTED if no start was asked for,
 *         GHOSTTY_NO_VALUE, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_start_result(
    GhosttyTerminal terminal,
    GhosttyKittyDndErrno error);

/**
 * Report the progress of the native drag to the program. Ignored unless
 * the drag started.
 *
 * @param terminal The terminal handle
 * @param kind What happened
 * @param value Depends on @p kind; see GhosttyKittyDndReport
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_report(
    GhosttyTerminal terminal,
    GhosttyKittyDndReport kind,
    int32_t value);

/**
 * Request the data for a MIME type of the started drag from the
 * program, for a drop target that wants it. Sent once until the data is
 * complete or failed and taken.
 *
 * @param terminal The terminal handle
 * @param index The zero-based index of the MIME type
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if no drag is in progress or
 *         the index is out of range, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_request_data(
    GhosttyTerminal terminal,
    size_t index);

/**
 * Take the data received for a requested MIME type of the started drag.
 *
 * @param terminal The terminal handle
 * @param index The zero-based index of the MIME type
 * @param out The data received since the last call and its status
 * @return GHOSTTY_SUCCESS, GHOSTTY_NO_VALUE if no drag is in progress or
 *         the index is out of range, or GHOSTTY_INVALID_VALUE
 */
GHOSTTY_API GhosttyResult ghostty_kitty_dnd_drag_take_data(
    GhosttyTerminal terminal,
    size_t index,
    GhosttyKittyDndDragData* out);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_KITTY_DND_H */
