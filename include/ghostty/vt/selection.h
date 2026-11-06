/**
 * @file selection.h
 *
 * Selection range type for specifying a region of terminal content.
 */

#ifndef GHOSTTY_VT_SELECTION_H
#define GHOSTTY_VT_SELECTION_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @addtogroup selection
 *
 * A selection is a range of terminal content between two cells. It is a
 * snapshot, only valid until the next change to the terminal.
 *
 * You need a terminal, and usually a grid reference to start from.
 *
 * ## Example
 *
 * @code{.c}
 * GhosttyTerminalSelectWordOptions word =
 *     GHOSTTY_INIT_SIZED(GhosttyTerminalSelectWordOptions);
 * word.ref = ref;
 *
 * GhosttySelection selection = {0};
 * if (ghostty_terminal_select_word(terminal, &word, &selection) ==
 *     GHOSTTY_SUCCESS) {
 *   ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
 * }
 * @endcode
 *
 * Full program: @ref c-vt-selection/src/main.c
 *
 * The @ref guide-selection "Selection guide" covers making one, turning pointer
 * gestures into one, and copying it out.
 *
 * @{
 */

/**
 * Opaque handle to state for interpreting terminal selection gestures.
 *
 * The gesture owns only the state required to interpret pointer events. Calls
 * that use a gesture are not concurrency-safe and must be serialized with
 * terminal mutations.
 *
 * @ingroup selection
 */
typedef struct GhosttySelectionGestureImpl* GhosttySelectionGesture;

/**
 * Opaque handle to reusable input data for selection gesture operations.
 *
 * Event options are set with ghostty_selection_gesture_event_set(). Individual
 * gesture operations document which options are required or optional.
 *
 * @ingroup selection
 */
typedef struct GhosttySelectionGestureEventImpl* GhosttySelectionGestureEvent;

/**
 * A range of terminal content between two cells.
 *
 * A selection is described by the two cells at its ends, `start` and `end`.
 * Both ends are included in the selection. By default the selection is
 * linear: it runs from `start` to `end` the way text flows, wrapping from
 * the end of one row to the start of the next. Set `rectangle` to true to
 * select a rectangular block instead, with `start` and `end` at opposite
 * corners.
 *
 * The ends keep the direction the user selected in. If the user dragged
 * up or to the left, `start` comes after `end` in the terminal. Don't
 * assume `start` is the top-left end. Use
 * ghostty_terminal_selection_ordered() when you need the ends in order.
 *
 * Both ends are untracked grid references, so a selection is only valid
 * until the next call that changes the terminal. To keep a selection
 * across changes, track its ends with GhosttyTrackedGridRef and build a new
 * GhosttySelection from fresh snapshots when you need one.
 *
 * Start with a zero-initialized value. The example below selects the first
 * ten cells of the second row and makes that the terminal's active
 * selection.
 *
 * @code{.c}
 * GhosttyPoint start_pt = {
 *     .tag = GHOSTTY_POINT_TAG_ACTIVE,
 *     .value = { .coordinate = { .x = 0, .y = 1 } },
 * };
 * GhosttyPoint end_pt = {
 *     .tag = GHOSTTY_POINT_TAG_ACTIVE,
 *     .value = { .coordinate = { .x = 9, .y = 1 } },
 * };
 *
 * GhosttySelection selection = {0};
 * ghostty_terminal_grid_ref(terminal, start_pt, &selection.start);
 * ghostty_terminal_grid_ref(terminal, end_pt, &selection.end);
 * ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
 * @endcode
 *
 * The layout of this struct is frozen. It is 40 bytes on 64-bit targets
 * and 20 bytes on 32-bit targets such as wasm32. If it ever needs to hold
 * more, that will be a new type.
 *
 * @ingroup selection
 */
typedef struct {
  /** The cell where the selection starts. It is included in the selection. */
  GhosttyGridRef start;

  /** The cell where the selection ends. It is included in the selection. */
  GhosttyGridRef end;

  /**
   * Whether this is a rectangular selection. When true, `start` and `end`
   * are opposite corners of a block of cells.
   */
  bool rectangle;
} GhosttySelection;

/**
 * A caller-provided buffer of selections.
 *
 * This follows the same conventions as GhosttyBuffer: ptr may be NULL with
 * cap 0 to query the required capacity. APIs that fill this type set len to
 * the number of entries written on GHOSTTY_SUCCESS, or to the required entry
 * capacity on GHOSTTY_OUT_OF_SPACE.
 *
 * @ingroup selection
 */
typedef struct {
  /** Destination buffer for selections. May be NULL when cap is 0 to query
   * the required capacity. */
  GhosttySelection* ptr;

  /** Capacity of ptr in entries. */
  size_t cap;

  /** Entries written on success, or required entry capacity on
   * GHOSTTY_OUT_OF_SPACE. */
  size_t len;
} GhosttySelectionBuffer;

/**
 * Options for deriving a word selection from a terminal grid reference.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED(), then set
 * the fields you need. See @ref sized-structs.
 *
 * If boundary_codepoints is NULL and boundary_codepoints_len is 0, Ghostty's
 * default word-boundary codepoints are used. If boundary_codepoints_len is
 * non-zero, boundary_codepoints must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyTerminalSelectWordOptions). */
  size_t size;

  /** Grid reference under which to derive the word selection. */
  GhosttyGridRef ref;

  /** Optional word-boundary codepoints as uint32_t scalar values. */
  const uint32_t* boundary_codepoints;

  /** Number of entries in boundary_codepoints. */
  size_t boundary_codepoints_len;
} GhosttyTerminalSelectWordOptions;

/**
 * Options for deriving the nearest word selection between two grid references.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED(), then set
 * the fields you need. See @ref sized-structs.
 *
 * If boundary_codepoints is NULL and boundary_codepoints_len is 0, Ghostty's
 * default word-boundary codepoints are used. If boundary_codepoints_len is
 * non-zero, boundary_codepoints must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyTerminalSelectWordBetweenOptions). */
  size_t size;

  /** Starting grid reference for the inclusive search range. */
  GhosttyGridRef start;

  /** Ending grid reference for the inclusive search range. */
  GhosttyGridRef end;

  /** Optional word-boundary codepoints as uint32_t scalar values. */
  const uint32_t* boundary_codepoints;

  /** Number of entries in boundary_codepoints. */
  size_t boundary_codepoints_len;
} GhosttyTerminalSelectWordBetweenOptions;

/**
 * Options for deriving a line selection from a terminal grid reference.
 *
 * This is a sized struct. Initialize it with GHOSTTY_INIT_SIZED(), then set
 * the fields you need. See @ref sized-structs.
 *
 * If whitespace is NULL and whitespace_len is 0, Ghostty's default line-trim
 * whitespace codepoints are used. If whitespace_len is non-zero, whitespace
 * must not be NULL.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyTerminalSelectLineOptions). */
  size_t size;

  /** Grid reference under which to derive the line selection. */
  GhosttyGridRef ref;

  /** Optional codepoints to trim from the start and end of the line. */
  const uint32_t* whitespace;

  /** Number of entries in whitespace. */
  size_t whitespace_len;

  /** Whether semantic prompt state changes should bound the line selection. */
  bool semantic_prompt_boundary;
} GhosttyTerminalSelectLineOptions;

/**
 * Ordering of a selection's endpoints in terminal coordinates.
 *
 * Mirrored orders are only produced by rectangular selections whose start
 * and end endpoints are on opposite diagonal corners that are not simple
 * top-left-to-bottom-right or bottom-right-to-top-left orderings.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Start is before end in top-left to bottom-right order. */
  GHOSTTY_SELECTION_ORDER_FORWARD = 0,

  /** End is before start in top-left to bottom-right order. */
  GHOSTTY_SELECTION_ORDER_REVERSE = 1,

  /** Rectangular selection from top-right to bottom-left. */
  GHOSTTY_SELECTION_ORDER_MIRRORED_FORWARD = 2,

  /** Rectangular selection from bottom-left to top-right. */
  GHOSTTY_SELECTION_ORDER_MIRRORED_REVERSE = 3,

  GHOSTTY_SELECTION_ORDER_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionOrder;

/**
 * Operation used to adjust a selection endpoint.
 *
 * Adjustment mutates the selection's logical end endpoint, not whichever
 * endpoint is visually bottom/right. This preserves keyboard and drag
 * behavior for both forward and reversed selections.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Move left to the previous non-empty cell, wrapping upward. */
  GHOSTTY_SELECTION_ADJUST_LEFT = 0,

  /** Move right to the next non-empty cell, wrapping downward. */
  GHOSTTY_SELECTION_ADJUST_RIGHT = 1,

  /**
   * Move up one row at the current column, or to the beginning of the
   * line if already at the top.
   */
  GHOSTTY_SELECTION_ADJUST_UP = 2,

  /**
   * Move down to the next non-blank row at the current column, or to the
   * end of the line if none exists.
   */
  GHOSTTY_SELECTION_ADJUST_DOWN = 3,

  /** Move to the top-left cell of the screen. */
  GHOSTTY_SELECTION_ADJUST_HOME = 4,

  /** Move to the right edge of the last non-blank row on the screen. */
  GHOSTTY_SELECTION_ADJUST_END = 5,

  /**
   * Move up by one terminal page height, or to home if that would move
   * past the top.
   */
  GHOSTTY_SELECTION_ADJUST_PAGE_UP = 6,

  /**
   * Move down by one terminal page height, or to end if that would move
   * past the bottom.
   */
  GHOSTTY_SELECTION_ADJUST_PAGE_DOWN = 7,

  /** Move to the left edge of the current line. */
  GHOSTTY_SELECTION_ADJUST_BEGINNING_OF_LINE = 8,

  /** Move to the right edge of the current line. */
  GHOSTTY_SELECTION_ADJUST_END_OF_LINE = 9,

  GHOSTTY_SELECTION_ADJUST_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionAdjust;

/**
 * Selection behavior chosen for a gesture's click sequence.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Cell-granular drag selection. */
  GHOSTTY_SELECTION_GESTURE_BEHAVIOR_CELL = 0,

  /** Word selection on press and word-granular drag selection. */
  GHOSTTY_SELECTION_GESTURE_BEHAVIOR_WORD = 1,

  /** Line selection on press and line-granular drag selection. */
  GHOSTTY_SELECTION_GESTURE_BEHAVIOR_LINE = 2,

  /** Semantic command output selection on press and drag. */
  GHOSTTY_SELECTION_GESTURE_BEHAVIOR_OUTPUT = 3,

  GHOSTTY_SELECTION_GESTURE_BEHAVIOR_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionGestureBehavior;

/**
 * Selection behaviors for single-, double-, and triple-click gestures.
 *
 * @ingroup selection
 */
typedef struct {
  /** Behavior for single-click selection gestures. */
  GhosttySelectionGestureBehavior single_click;

  /** Behavior for double-click selection gestures. */
  GhosttySelectionGestureBehavior double_click;

  /** Behavior for triple-click selection gestures. */
  GhosttySelectionGestureBehavior triple_click;
} GhosttySelectionGestureBehaviors;

/**
 * Display geometry used to interpret selection gesture drag events.
 *
 * @ingroup selection
 */
typedef struct {
  /** Number of columns in the rendered terminal grid. Must be non-zero. */
  uint32_t columns;

  /** Width of one terminal cell in surface pixels. Must be non-zero. */
  uint32_t cell_width;

  /** Left padding before the terminal grid begins in surface pixels. */
  uint32_t padding_left;

  /** Height of the rendered terminal surface in surface pixels. Must be non-zero. */
  uint32_t screen_height;
} GhosttySelectionGestureGeometry;

/**
 * Current autoscroll direction for an active selection drag gesture.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** No selection autoscroll is requested. */
  GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE = 0,

  /** Selection dragging should autoscroll the viewport upward. */
  GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP = 1,

  /** Selection dragging should autoscroll the viewport downward. */
  GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN = 2,

  GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionGestureAutoscroll;

/**
 * Data fields readable from a selection gesture with
 * ghostty_selection_gesture_get().
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real data type. ghostty_selection_gesture_get() returns
   * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real data type.
   */
  GHOSTTY_SELECTION_GESTURE_DATA_INVALID = 0,

  /** Current click count: uint8_t*. 0 means inactive. */
  GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT = 1,

  /** Whether the current/last left-click gesture has dragged: bool*. */
  GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED = 2,

  /** Current autoscroll request: GhosttySelectionGestureAutoscroll*. */
  GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL = 3,

  /** Current gesture behavior: GhosttySelectionGestureBehavior*. */
  GHOSTTY_SELECTION_GESTURE_DATA_BEHAVIOR = 4,

  /**
   * Current left-click anchor: GhosttyGridRef*.
   *
   * Returns GHOSTTY_NO_VALUE if there is no valid active anchor. On success,
   * writes an untracked GhosttyGridRef snapshot with normal GhosttyGridRef
   * lifetime rules.
   */
  GHOSTTY_SELECTION_GESTURE_DATA_ANCHOR = 5,

  GHOSTTY_SELECTION_GESTURE_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionGestureData;

/**
 * Selection gesture event type.
 *
 * The event type is fixed when the event is created. Each event type documents
 * which options are valid and which options are required by gesture operations.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Press event for ghostty_selection_gesture_event(). */
  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS = 0,

  /** Release event for ghostty_selection_gesture_event(). */
  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE = 1,

  /** Drag event for ghostty_selection_gesture_event(). */
  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG = 2,

  /** Autoscroll tick event for ghostty_selection_gesture_event(). */
  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK = 3,

  /** Deep press event for ghostty_selection_gesture_event(). */
  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS = 4,

  GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionGestureEventType;

/**
 * Options stored on a reusable selection gesture event.
 *
 * Passing NULL as the value to ghostty_selection_gesture_event_set() clears the
 * corresponding option.
 *
 * @ingroup selection
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Not a real option. ghostty_selection_gesture_event_set() returns
   * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
   * uninitialized variable is never mistaken for a real option.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_INVALID = 0,

  /**
   * Grid reference under the pointer: GhosttyGridRef*.
   *
   * Required for PRESS and DRAG events. Optional for RELEASE events; when unset
   * or cleared, release records that the pointer did not map to a valid cell.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF = 1,

  /**
   * Surface-space pointer position: GhosttySurfacePosition*.
   *
   * Valid for PRESS, DRAG, and AUTOSCROLL_TICK.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION = 2,

  /** Maximum repeat-click distance in pixels: double*. */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE = 3,

  /**
   * Optional monotonic event time in nanoseconds: uint64_t*.
   *
   * If unset, press treats the event as untimed and only single-click behavior
   * is available.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS = 4,

  /** Maximum interval between repeat clicks in nanoseconds: uint64_t*. */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS = 5,

  /**
   * Word-boundary codepoints: GhosttyCodepoints*.
   *
   * The codepoints are copied into event-owned storage when set. If unset,
   * operations that need word boundaries use Ghostty's defaults.
   *
   * Valid for PRESS, DRAG, AUTOSCROLL_TICK, and DEEP_PRESS.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS = 6,

  /**
   * Selection behavior table: GhosttySelectionGestureBehaviors*.
   *
   * If unset, press uses the default behavior table: cell, word, line.
   */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_BEHAVIORS = 7,

  /** Whether a drag or autoscroll tick should produce a rectangular selection: bool*. */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE = 8,

  /** Drag display geometry: GhosttySelectionGestureGeometry*. Required for DRAG and AUTOSCROLL_TICK. */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY = 9,

  /** Viewport coordinate for an autoscroll tick: GhosttyPointCoordinate*. Required for AUTOSCROLL_TICK. */
  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT = 10,

  GHOSTTY_SELECTION_GESTURE_EVENT_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySelectionGestureEventOption;

/** @name Gesture Events
 * @{
 */

/**
 * Create a reusable selection gesture event object.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_event Receives the created event handle
 * @param type Event type. This is fixed for the lifetime of the event.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if out_event is
 *         NULL or type is invalid, or GHOSTTY_OUT_OF_MEMORY if allocation fails
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_event_new(
                                    const GhosttyAllocator* allocator,
                                    GhosttySelectionGestureEvent* out_event,
                                    GhosttySelectionGestureEventType type);

/**
 * Free a selection gesture event object.
 *
 * Passing NULL is allowed and is a no-op.
 *
 * @param event Selection gesture event handle to free
 *
 * @ingroup selection
 */
GHOSTTY_API void ghostty_selection_gesture_event_free(
                                    GhosttySelectionGestureEvent event);

/**
 * Set or clear an option on a selection gesture event.
 *
 * The value type depends on option and is documented by
 * GhosttySelectionGestureEventOption. Passing NULL for value clears the option.
 *
 * @param event Selection gesture event handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option Event option to set or clear
 * @param value Pointer to the input value for option, or NULL to clear
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY if copying
 *         event-owned data fails, GHOSTTY_INVALID_VALUE if `event` or `value`
 *         is invalid, or GHOSTTY_UNSUPPORTED if `option` is not known to this
 *         version of the library
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_event_set(
                                    GhosttySelectionGestureEvent event,
                                    GhosttySelectionGestureEventOption option,
                                    const void* value);

/**
 * Apply a selection gesture event and return the resulting selection snapshot.
 *
 * This dispatches to the gesture operation matching the event's fixed type.
 * For GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS, the event must have
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF set before calling this function.
 * All other press options use their initialized defaults when unset or cleared.
 *
 * For GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE, only
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF is valid. It is optional; if unset or
 * cleared, release records that the pointer did not map to a valid cell. Release
 * events update gesture state but do not produce a selection, so this function
 * returns GHOSTTY_NO_VALUE after applying them.
 *
 * For GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG,
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF and
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY are required. Position,
 * rectangle, and word-boundary codepoints are optional and use initialized
 * defaults when unset or cleared.
 *
 * For GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT and
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY are required. Position,
 * rectangle, and word-boundary codepoints are optional and use initialized
 * defaults when unset or cleared.
 *
 * An autoscroll tick scrolls the viewport exactly one row in the direction
 * GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL reports, then continues the drag at
 * the viewport coordinate. The gesture has no timer of its own. While that
 * direction is up or down, send ticks from a timer you run. The interval is up
 * to you, and ticking faster scrolls faster. A tick returns GHOSTTY_NO_VALUE
 * and scrolls nothing if there's no direction to scroll in. If the cell of the
 * original press is no longer on the active screen, it also resets the gesture
 * and leaves any existing terminal selection alone, so stop your timer.
 *
 * For GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DEEP_PRESS, only
 * GHOSTTY_SELECTION_GESTURE_EVENT_OPT_WORD_BOUNDARY_CODEPOINTS is valid. It is
 * optional and uses initialized defaults when unset or cleared.
 *
 * The returned selection is not installed as the terminal's current selection.
 * It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param gesture Selection gesture handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal Terminal used to interpret and update gesture state
 * @param event Selection gesture event handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_selection On success, receives the resulting selection. May
 *             be NULL to apply the event and discard the selection result.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the event does not
 *         currently produce a selection, GHOSTTY_OUT_OF_MEMORY if tracking
 *         gesture state fails, or GHOSTTY_INVALID_VALUE if gesture, terminal,
 *         event, or required event data is invalid
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_event(
                                    GhosttySelectionGesture gesture,
                                    GhosttyTerminal terminal,
                                    GhosttySelectionGestureEvent event,
                                    GhosttySelection* out_selection);

/** @} */

/** @name Gestures
 * @{
 */

/**
 * Create a selection gesture object.
 *
 * The gesture stores mutable state for terminal text selection gestures. The
 * gesture is not bound to a terminal at creation time; terminal-dependent APIs
 * take the terminal explicitly.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_gesture Receives the created gesture handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if out_gesture is
 *         NULL, or GHOSTTY_OUT_OF_MEMORY if allocation fails
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_new(
                                    const GhosttyAllocator* allocator,
                                    GhosttySelectionGesture* out_gesture);

/**
 * Free a selection gesture object.
 *
 * This releases any tracked terminal references owned by the gesture using the
 * provided terminal, then frees the gesture object. Passing NULL for gesture is
 * allowed and is a no-op.
 *
 * If the terminal is still alive, pass the terminal most recently used with the
 * gesture so any tracked terminal references can be released correctly. If the
 * terminal has already been freed, pass NULL for terminal; the terminal's page
 * storage has already released the underlying tracked references, so the
 * gesture wrapper can be safely discarded without touching the stale terminal
 * state.
 *
 * @param gesture Selection gesture handle to free
 * @param terminal Terminal used to release tracked gesture state, or NULL if
 *                 the terminal has already been freed
 *
 * @ingroup selection
 */
GHOSTTY_API void ghostty_selection_gesture_free(
                                    GhosttySelectionGesture gesture,
                                    GhosttyTerminal terminal);

/**
 * Reset any active selection gesture state.
 *
 * This cancels the active click sequence and releases any tracked terminal
 * references owned by the gesture without freeing the gesture object.
 * Passing NULL is allowed and is a no-op.
 *
 * @param gesture Selection gesture handle to reset
 * @param terminal Terminal used to release tracked gesture state
 *
 * @ingroup selection
 */
GHOSTTY_API void ghostty_selection_gesture_reset(
                                    GhosttySelectionGesture gesture,
                                    GhosttyTerminal terminal);

/**
 * Read data from a selection gesture.
 *
 * The type of value depends on data and is documented by
 * GhosttySelectionGestureData. For GHOSTTY_SELECTION_GESTURE_DATA_ANCHOR,
 * the returned GhosttyGridRef is an untracked snapshot with normal grid-ref
 * lifetime rules.
 *
 * @param gesture Selection gesture handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal Terminal used to validate terminal-backed gesture state
 * @param data Data field to read
 * @param value Output pointer whose type depends on data
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the requested data
 *         has no value, GHOSTTY_INVALID_VALUE if `gesture`, `terminal`, or
 *         `out` is invalid, or GHOSTTY_UNSUPPORTED if `data` is not known to
 *         this version of the library
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_get(
                                    GhosttySelectionGesture gesture,
                                    GhosttyTerminal terminal,
                                    GhosttySelectionGestureData data,
                                    void* value);

/**
 * Read multiple data fields from a selection gesture in a single call.
 *
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_selection_gesture_get() once per key, so
 * use whichever reads better.
 *
 * Each entry in values must point to storage of the type documented by
 * the corresponding GhosttySelectionGestureData key.
 *
 * If any individual read fails, the function returns that error and writes the
 * index of the failing key to out_written when out_written is non-NULL. On
 * success, out_written receives count when non-NULL.
 *
 * @param gesture Selection gesture handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal Terminal used to validate terminal-backed gesture state
 * @param count Number of data fields to read
 * @param keys Data fields to read (must not be NULL)
 * @param values Output pointers corresponding to keys (must not be NULL)
 * @param out_written Optional number of fields read, or failing index on error
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_selection_gesture_get_multi(
                                    GhosttySelectionGesture gesture,
                                    GhosttyTerminal terminal,
                                    size_t count,
                                    const GhosttySelectionGestureData* keys,
                                    void** values,
                                    size_t* out_written);

/** @} */

/** @name Selecting
 * @{
 */

/**
 * Derive a word selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param options Word-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the valid ref has
 *         no selectable word content, or GHOSTTY_INVALID_VALUE if the
 *         terminal, options, ref, codepoint pointer, or output pointer are
 *         invalid.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_word(
                                    GhosttyTerminal terminal,
                                    const GhosttyTerminalSelectWordOptions* options,
                                    GhosttySelection* out_selection);

/**
 * Derive the nearest word selection snapshot between two terminal grid refs.
 *
 * Starting at options->start, this searches toward options->end (inclusive)
 * and returns the first selectable word found using Ghostty's word-selection
 * rules.
 *
 * This is useful for implementing double-click-and-drag selection in a UI. If
 * a user double-clicks one word and drags across spaces or punctuation toward
 * another word, selecting only the word directly under the current pointer can
 * flicker or collapse when the pointer is between words. Instead, ask for the
 * nearest word between the original click and the drag point, ask again in the
 * reverse direction, and combine the two word bounds into the drag selection.
 *
 * @snippet c-vt-selection/src/main.c selection-word-between
 *
 * Full program: @ref c-vt-selection/src/main.c
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param options Word-between-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if there is no
 *         selectable word content between the valid refs, or
 *         GHOSTTY_INVALID_VALUE if the terminal, options, refs, codepoint
 *         pointer, or output pointer are invalid.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_word_between(
                                    GhosttyTerminal terminal,
                                    const GhosttyTerminalSelectWordBetweenOptions* options,
                                    GhosttySelection* out_selection);

/**
 * Derive a line selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param options Line-selection options
 * @param[out] out_selection On success, receives the derived selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the valid ref has
 *         no selectable line content, or GHOSTTY_INVALID_VALUE if the
 *         terminal, options, ref, codepoint pointer, or output pointer are
 *         invalid.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_line(
                                    GhosttyTerminal terminal,
                                    const GhosttyTerminalSelectLineOptions* options,
                                    GhosttySelection* out_selection);

/**
 * Derive a selection snapshot covering all selectable terminal content.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_selection On success, receives the derived selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if there is no
 *         selectable content, or GHOSTTY_INVALID_VALUE if the terminal or
 *         output pointer is invalid.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_all(
                                    GhosttyTerminal terminal,
                                    GhosttySelection* out_selection);

/**
 * Derive a command-output selection snapshot from a terminal grid reference.
 *
 * The returned selection is not installed as the terminal's current
 * selection. It is a snapshot with the same lifetime rules as GhosttySelection.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param ref Grid reference within command output to select
 * @param[out] out_selection On success, receives the derived selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the valid ref is
 *         not selectable command output, or GHOSTTY_INVALID_VALUE if the
 *         terminal, ref, or output pointer is invalid.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_select_output(
                                    GhosttyTerminal terminal,
                                    GhosttyGridRef ref,
                                    GhosttySelection* out_selection);

/** @} */

/** @name Working with Selections
 * @{
 */

/**
 * Adjust a selection snapshot using terminal selection semantics.
 *
 * This mutates your GhosttySelection in place. The logical end
 * endpoint is always moved, regardless of whether the selection is forward or
 * reversed visually. The input selection remains a snapshot: after adjustment,
 * call ghostty_terminal_set() with GHOSTTY_TERMINAL_OPT_SELECTION to install it
 * as the terminal-owned selection if desired.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to adjust in place
 * @param adjustment The adjustment operation to apply
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, or adjustment are invalid. Selection reference validity
 *         is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_adjust(
                                    GhosttyTerminal terminal,
                                    GhosttySelection* selection,
                                    GhosttySelectionAdjust adjustment);

/**
 * Get the current endpoint ordering of a selection snapshot.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param[out] out_order On success, receives the selection order
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_order(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttySelectionOrder* out_order);

/**
 * Return a selection snapshot with endpoints ordered as requested.
 *
 * Use GHOSTTY_SELECTION_ORDER_FORWARD to get top-left to bottom-right bounds,
 * and GHOSTTY_SELECTION_ORDER_REVERSE to get bottom-right to top-left bounds.
 * Mirrored desired orders are accepted but normalized the same as forward.
 * The output selection is a fresh untracked snapshot and is not installed as
 * the terminal's current selection.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to order
 * @param desired Desired endpoint order
 * @param[out] out_selection On success, receives the ordered selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, desired order, or output pointer are invalid. Selection
 *         reference validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_ordered(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttySelectionOrder desired,
                                    GhosttySelection* out_selection);

/**
 * Test whether a terminal point is inside a selection snapshot.
 *
 * This uses the same selection semantics as the terminal, including
 * rectangular/block selections and linear selections spanning multiple rows.
 *
 * The selection's start and end grid refs must both be valid untracked
 * snapshots for the given terminal's currently active screen. In practice,
 * they must come from that terminal and screen, and no mutating terminal call
 * may have occurred since the refs were produced or reconstructed from
 * tracked refs. Passing refs from another terminal, another screen, or stale
 * refs violates this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param selection Selection snapshot to inspect
 * @param point Point to test for containment
 * @param[out] out_contains On success, receives whether point is inside selection
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selection, point, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_contains(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* selection,
                                    GhosttyPoint point,
                                    bool* out_contains);

/**
 * Test whether two selection snapshots are equal.
 *
 * Equality uses the terminal's internal selection semantics: both endpoint
 * pins must match and both selections must have the same rectangular/block
 * state. This avoids requiring callers to compare raw GhosttyGridRef internals.
 *
 * Both selections' start and end grid refs must be valid untracked snapshots
 * for the given terminal's currently active screen. In practice, they must
 * come from that terminal and screen, and no mutating terminal call may have
 * occurred since the refs were produced or reconstructed from tracked refs.
 * Passing refs from another terminal, another screen, or stale refs violates
 * this precondition.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param a First selection snapshot to compare
 * @param b Second selection snapshot to compare
 * @param[out] out_equal On success, receives whether the selections are equal
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal,
 *         selections, or output pointer are invalid. Selection reference
 *         validity is a precondition and is not checked.
 *
 * @ingroup selection
 */
GHOSTTY_API GhosttyResult ghostty_terminal_selection_equal(
                                    GhosttyTerminal terminal,
                                    const GhosttySelection* a,
                                    const GhosttySelection* b,
                                    bool* out_equal);

/** @} */

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SELECTION_H */
