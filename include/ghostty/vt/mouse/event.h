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
typedef struct GhosttyMouseEvent *GhosttyMouseEvent;

/**
 * Mouse event action type.
 *
 * @ingroup mouse
 */
typedef enum {
  /** Mouse button was pressed. */
  GHOSTTY_MOUSE_ACTION_PRESS = 0,

  /** Mouse button was released. */
  GHOSTTY_MOUSE_ACTION_RELEASE = 1,

  /** Mouse moved. */
  GHOSTTY_MOUSE_ACTION_MOTION = 2,
} GhosttyMouseAction;

/**
 * Mouse button identity.
 *
 * @ingroup mouse
 */
typedef enum {
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
GhosttyResult ghostty_mouse_event_new(const GhosttyAllocator *allocator,
                                      GhosttyMouseEvent *event);

/**
 * Free a mouse event instance.
 *
 * @param event The mouse event handle to free (may be NULL)
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_free(GhosttyMouseEvent event);

/**
 * Set the event action.
 *
 * @param event The event handle, must not be NULL
 * @param action The action to set
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_set_action(GhosttyMouseEvent event,
                                    GhosttyMouseAction action);

/**
 * Get the event action.
 *
 * @param event The event handle, must not be NULL
 * @return The event action
 *
 * @ingroup mouse
 */
GhosttyMouseAction ghostty_mouse_event_get_action(GhosttyMouseEvent event);

/**
 * Set the event button.
 *
 * This sets a concrete button identity for the event.
 * To represent "no button" (for motion events), use
 * ghostty_mouse_event_clear_button().
 *
 * @param event The event handle, must not be NULL
 * @param button The button to set
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_set_button(GhosttyMouseEvent event,
                                    GhosttyMouseButton button);

/**
 * Clear the event button.
 *
 * This sets the event button to "none".
 *
 * @param event The event handle, must not be NULL
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_clear_button(GhosttyMouseEvent event);

/**
 * Get the event button.
 *
 * @param event The event handle, must not be NULL
 * @param out_button Output pointer for the button value (may be NULL)
 * @return true if a button is set, false if no button is set
 *
 * @ingroup mouse
 */
bool ghostty_mouse_event_get_button(GhosttyMouseEvent event,
                                    GhosttyMouseButton *out_button);

/**
 * Set keyboard modifiers held during the event.
 *
 * @param event The event handle, must not be NULL
 * @param mods Modifier bitmask
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_set_mods(GhosttyMouseEvent event,
                                  GhosttyMods mods);

/**
 * Get keyboard modifiers held during the event.
 *
 * @param event The event handle, must not be NULL
 * @return Modifier bitmask
 *
 * @ingroup mouse
 */
GhosttyMods ghostty_mouse_event_get_mods(GhosttyMouseEvent event);

/**
 * Set the event position in surface-space pixels.
 *
 * @param event The event handle, must not be NULL
 * @param position The position to set
 *
 * @ingroup mouse
 */
void ghostty_mouse_event_set_position(GhosttyMouseEvent event,
                                      GhosttyMousePosition position);

/**
 * Get the event position in surface-space pixels.
 *
 * @param event The event handle, must not be NULL
 * @return The current event position
 *
 * @ingroup mouse
 */
GhosttyMousePosition ghostty_mouse_event_get_position(GhosttyMouseEvent event);

#endif /* GHOSTTY_VT_MOUSE_EVENT_H */
