/**
 * @file event.h
 *
 * Mouse event representation and manipulation.
 */

#ifndef GHOSTTY_VT_MOUSE_EVENT_H
#define GHOSTTY_VT_MOUSE_EVENT_H

#include <stdbool.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/key/event.h>
#include <ghostty/vt/types.h>

/**
 * Opaque handle to a mouse event.
 *
 * This handle represents a normalized mouse input event containing
 * action, button, modifiers, and surface-space position.
 *
 * @ingroup mouse
 */
typedef struct GhosttyMouseEventImpl *GhosttyMouseEvent;

/**
 * Mouse event action type.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Mouse button was pressed. */
  GHOSTTY_MOUSE_ACTION_PRESS = 0,

  /** Mouse button was released. */
  GHOSTTY_MOUSE_ACTION_RELEASE = 1,

  /** Mouse moved. */
  GHOSTTY_MOUSE_ACTION_MOTION = 2,
  GHOSTTY_MOUSE_ACTION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseAction;

/**
 * Mouse button identity.
 *
 * @ingroup mouse
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_MOUSE_BUTTON_UNKNOWN = 0,
  GHOSTTY_MOUSE_BUTTON_LEFT = 1,
  GHOSTTY_MOUSE_BUTTON_RIGHT = 2,
  GHOSTTY_MOUSE_BUTTON_MIDDLE = 3,
  GHOSTTY_MOUSE_BUTTON_FOUR = 4,
  GHOSTTY_MOUSE_BUTTON_FIVE = 5,
  GHOSTTY_MOUSE_BUTTON_SIX = 6,
  GHOSTTY_MOUSE_BUTTON_SEVEN = 7,
  GHOSTTY_MOUSE_BUTTON_EIGHT = 8,
  GHOSTTY_MOUSE_BUTTON_NINE = 9,
  GHOSTTY_MOUSE_BUTTON_TEN = 10,
  GHOSTTY_MOUSE_BUTTON_ELEVEN = 11,
  GHOSTTY_MOUSE_BUTTON_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyMouseButton;

/**
 * Mouse position in surface-space pixels.
 *
 * @ingroup mouse
 */
typedef struct {
  float x;
  float y;
} GhosttyMousePosition;

/**
 * Create a new mouse event instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param event Pointer to store the created event handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_new(const GhosttyAllocator *allocator,
                                      GhosttyMouseEvent *event);

/**
 * Free a mouse event instance.
 *
 * @param event The mouse event handle to free (may be NULL)
 *
 * @ingroup mouse
 */
GHOSTTY_API void ghostty_mouse_event_free(GhosttyMouseEvent event);

/**
 * Set the event action.
 *
 * @param event The event handle
 * @param action The action to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event` is
 *         NULL or `action` is not a GhosttyMouseAction value this version of the
 *         library knows. On error the event is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_set_action(GhosttyMouseEvent event,
                                    GhosttyMouseAction action);

/**
 * Get the event action.
 *
 * @param event The event handle
 * @return The event action, or GHOSTTY_MOUSE_ACTION_PRESS if `event` is NULL
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyMouseAction ghostty_mouse_event_get_action(GhosttyMouseEvent event);

/**
 * Set the event button.
 *
 * This sets a concrete button identity for the event.
 * To represent "no button" (for motion events), use
 * ghostty_mouse_event_clear_button().
 *
 * @param event The event handle
 * @param button The button to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event` is
 *         NULL or `button` is not a GhosttyMouseButton value this version of the
 *         library knows. On error the event is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_set_button(GhosttyMouseEvent event,
                                    GhosttyMouseButton button);

/**
 * Clear the event button.
 *
 * This sets the event button to "none".
 *
 * @param event The event handle
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_clear_button(GhosttyMouseEvent event);

/**
 * Get the event button.
 *
 * A new event has no button, and ghostty_mouse_event_clear_button() removes
 * the button from an event. Having no button is normal, for example when
 * the mouse moves with no button held. It is not an error, so check for
 * GHOSTTY_NO_VALUE separately:
 *
 * @code{.c}
 * GhosttyMouseButton button;
 * switch (ghostty_mouse_event_get_button(event, &button)) {
 * case GHOSTTY_SUCCESS:
 *     // `button` holds the event's button.
 *     break;
 * case GHOSTTY_NO_VALUE:
 *     // The event has no button. `button` was not written.
 *     break;
 * default:
 *     // `event` or the output pointer was NULL.
 *     break;
 * }
 * @endcode
 *
 * @param event The event handle
 * @param out_button Where to write the button. Must not be NULL.
 * @return GHOSTTY_SUCCESS if the event has a button, GHOSTTY_NO_VALUE if it
 *         has none, or GHOSTTY_INVALID_VALUE if `event` or `out_button` is
 *         NULL. `out_button` is written only on GHOSTTY_SUCCESS.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_get_button(GhosttyMouseEvent event,
                                    GhosttyMouseButton *out_button);

/**
 * Set keyboard modifiers held during the event.
 *
 * @param event The event handle
 * @param mods Modifier bitmask
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_set_mods(GhosttyMouseEvent event,
                                  GhosttyMods mods);

/**
 * Get keyboard modifiers held during the event.
 *
 * @param event The event handle
 * @return Modifier bitmask, or 0 (no modifiers) if `event` is NULL
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyMods ghostty_mouse_event_get_mods(GhosttyMouseEvent event);

/**
 * Set the event position in surface-space pixels.
 *
 * @param event The event handle
 * @param position The position to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyResult ghostty_mouse_event_set_position(GhosttyMouseEvent event,
                                      GhosttyMousePosition position);

/**
 * Get the event position in surface-space pixels.
 *
 * @param event The event handle
 * @return The current event position, or (0, 0) if `event` is NULL
 *
 * @ingroup mouse
 */
GHOSTTY_API GhosttyMousePosition ghostty_mouse_event_get_position(GhosttyMouseEvent event);

#endif /* GHOSTTY_VT_MOUSE_EVENT_H */
