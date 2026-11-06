/**
 * @file event.h
 *
 * Key event representation and manipulation.
 */

#ifndef GHOSTTY_VT_KEY_EVENT_H
#define GHOSTTY_VT_KEY_EVENT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>

/**
 * Opaque handle to a key event.
 * 
 * This handle represents a keyboard input event containing information about
 * the physical key pressed, modifiers, and generated text.
 *
 * @ingroup key
 */
typedef struct GhosttyKeyEventImpl *GhosttyKeyEvent;

/**
 * Keyboard input event types.
 *
 * @ingroup key
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /** Key was released */
    GHOSTTY_KEY_ACTION_RELEASE = 0,
    /** Key was pressed */
    GHOSTTY_KEY_ACTION_PRESS = 1,
    /** Key is being repeated (held down) */
    GHOSTTY_KEY_ACTION_REPEAT = 2,
    GHOSTTY_KEY_ACTION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKeyAction;

/**
 * Keyboard modifier keys bitmask.
 *
 * A bitmask representing all keyboard modifiers. This tracks which modifier keys 
 * are pressed and, where supported by the platform, which side (left or right) 
 * of each modifier is active.
 *
 * Use the GHOSTTY_MODS_* constants to test and set individual modifiers.
 *
 * Modifier side bits are only meaningful when the corresponding modifier bit is set.
 * Not all platforms support distinguishing between left and right modifier 
 * keys and Ghostty is built to expect that some platforms may not provide this
 * information.
 *
 * @ingroup key
 */
typedef uint16_t GhosttyMods;

/** Shift key is pressed. @ingroup key */
#define GHOSTTY_MODS_SHIFT (1 << 0)
/** Control key is pressed. @ingroup key */
#define GHOSTTY_MODS_CTRL (1 << 1)
/** Alt/Option key is pressed. @ingroup key */
#define GHOSTTY_MODS_ALT (1 << 2)
/** Super/Command/Windows key is pressed. @ingroup key */
#define GHOSTTY_MODS_SUPER (1 << 3)
/** Caps Lock is active. @ingroup key */
#define GHOSTTY_MODS_CAPS_LOCK (1 << 4)
/** Num Lock is active. @ingroup key */
#define GHOSTTY_MODS_NUM_LOCK (1 << 5)

/**
 * Right shift is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_SHIFT is set.
 *
 * @ingroup key
 */
#define GHOSTTY_MODS_SHIFT_SIDE (1 << 6)
/**
 * Right ctrl is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_CTRL is set.
 *
 * @ingroup key
 */
#define GHOSTTY_MODS_CTRL_SIDE (1 << 7)
/**
 * Right alt is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_ALT is set.
 *
 * @ingroup key
 */
#define GHOSTTY_MODS_ALT_SIDE (1 << 8)
/**
 * Right super is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_SUPER is set.
 *
 * @ingroup key
 */
#define GHOSTTY_MODS_SUPER_SIDE (1 << 9)

/**
 * Physical key codes.
 *
 * The set of key codes that Ghostty is aware of. These represent physical keys 
 * on the keyboard and are layout-independent. For example, the "a" key on a US 
 * keyboard is the same as the "ф" key on a Russian keyboard, but both will 
 * report the same key_a value.
 *
 * Layout-dependent strings are provided separately as UTF-8 text and are produced 
 * by the platform. These values are based on the W3C UI Events KeyboardEvent code 
 * standard. See: https://www.w3.org/TR/uievents-code
 *
 * @ingroup key
 */
typedef enum GHOSTTY_ENUM_TYPED {
    GHOSTTY_KEY_UNIDENTIFIED = 0,

    // Writing System Keys (W3C § 3.1.1)
    GHOSTTY_KEY_BACKQUOTE = 1,
    GHOSTTY_KEY_BACKSLASH = 2,
    GHOSTTY_KEY_BRACKET_LEFT = 3,
    GHOSTTY_KEY_BRACKET_RIGHT = 4,
    GHOSTTY_KEY_COMMA = 5,
    GHOSTTY_KEY_DIGIT_0 = 6,
    GHOSTTY_KEY_DIGIT_1 = 7,
    GHOSTTY_KEY_DIGIT_2 = 8,
    GHOSTTY_KEY_DIGIT_3 = 9,
    GHOSTTY_KEY_DIGIT_4 = 10,
    GHOSTTY_KEY_DIGIT_5 = 11,
    GHOSTTY_KEY_DIGIT_6 = 12,
    GHOSTTY_KEY_DIGIT_7 = 13,
    GHOSTTY_KEY_DIGIT_8 = 14,
    GHOSTTY_KEY_DIGIT_9 = 15,
    GHOSTTY_KEY_EQUAL = 16,
    GHOSTTY_KEY_INTL_BACKSLASH = 17,
    GHOSTTY_KEY_INTL_RO = 18,
    GHOSTTY_KEY_INTL_YEN = 19,
    GHOSTTY_KEY_A = 20,
    GHOSTTY_KEY_B = 21,
    GHOSTTY_KEY_C = 22,
    GHOSTTY_KEY_D = 23,
    GHOSTTY_KEY_E = 24,
    GHOSTTY_KEY_F = 25,
    GHOSTTY_KEY_G = 26,
    GHOSTTY_KEY_H = 27,
    GHOSTTY_KEY_I = 28,
    GHOSTTY_KEY_J = 29,
    GHOSTTY_KEY_K = 30,
    GHOSTTY_KEY_L = 31,
    GHOSTTY_KEY_M = 32,
    GHOSTTY_KEY_N = 33,
    GHOSTTY_KEY_O = 34,
    GHOSTTY_KEY_P = 35,
    GHOSTTY_KEY_Q = 36,
    GHOSTTY_KEY_R = 37,
    GHOSTTY_KEY_S = 38,
    GHOSTTY_KEY_T = 39,
    GHOSTTY_KEY_U = 40,
    GHOSTTY_KEY_V = 41,
    GHOSTTY_KEY_W = 42,
    GHOSTTY_KEY_X = 43,
    GHOSTTY_KEY_Y = 44,
    GHOSTTY_KEY_Z = 45,
    GHOSTTY_KEY_MINUS = 46,
    GHOSTTY_KEY_PERIOD = 47,
    GHOSTTY_KEY_QUOTE = 48,
    GHOSTTY_KEY_SEMICOLON = 49,
    GHOSTTY_KEY_SLASH = 50,

    // Functional Keys (W3C § 3.1.2)
    GHOSTTY_KEY_ALT_LEFT = 51,
    GHOSTTY_KEY_ALT_RIGHT = 52,
    GHOSTTY_KEY_BACKSPACE = 53,
    GHOSTTY_KEY_CAPS_LOCK = 54,
    GHOSTTY_KEY_CONTEXT_MENU = 55,
    GHOSTTY_KEY_CONTROL_LEFT = 56,
    GHOSTTY_KEY_CONTROL_RIGHT = 57,
    GHOSTTY_KEY_ENTER = 58,
    GHOSTTY_KEY_META_LEFT = 59,
    GHOSTTY_KEY_META_RIGHT = 60,
    GHOSTTY_KEY_SHIFT_LEFT = 61,
    GHOSTTY_KEY_SHIFT_RIGHT = 62,
    GHOSTTY_KEY_SPACE = 63,
    GHOSTTY_KEY_TAB = 64,
    GHOSTTY_KEY_CONVERT = 65,
    GHOSTTY_KEY_KANA_MODE = 66,
    GHOSTTY_KEY_NON_CONVERT = 67,

    // Control Pad Section (W3C § 3.2)
    GHOSTTY_KEY_DELETE = 68,
    GHOSTTY_KEY_END = 69,
    GHOSTTY_KEY_HELP = 70,
    GHOSTTY_KEY_HOME = 71,
    GHOSTTY_KEY_INSERT = 72,
    GHOSTTY_KEY_PAGE_DOWN = 73,
    GHOSTTY_KEY_PAGE_UP = 74,

    // Arrow Pad Section (W3C § 3.3)
    GHOSTTY_KEY_ARROW_DOWN = 75,
    GHOSTTY_KEY_ARROW_LEFT = 76,
    GHOSTTY_KEY_ARROW_RIGHT = 77,
    GHOSTTY_KEY_ARROW_UP = 78,

    // Numpad Section (W3C § 3.4)
    GHOSTTY_KEY_NUM_LOCK = 79,
    GHOSTTY_KEY_NUMPAD_0 = 80,
    GHOSTTY_KEY_NUMPAD_1 = 81,
    GHOSTTY_KEY_NUMPAD_2 = 82,
    GHOSTTY_KEY_NUMPAD_3 = 83,
    GHOSTTY_KEY_NUMPAD_4 = 84,
    GHOSTTY_KEY_NUMPAD_5 = 85,
    GHOSTTY_KEY_NUMPAD_6 = 86,
    GHOSTTY_KEY_NUMPAD_7 = 87,
    GHOSTTY_KEY_NUMPAD_8 = 88,
    GHOSTTY_KEY_NUMPAD_9 = 89,
    GHOSTTY_KEY_NUMPAD_ADD = 90,
    GHOSTTY_KEY_NUMPAD_BACKSPACE = 91,
    GHOSTTY_KEY_NUMPAD_CLEAR = 92,
    GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY = 93,
    GHOSTTY_KEY_NUMPAD_COMMA = 94,
    GHOSTTY_KEY_NUMPAD_DECIMAL = 95,
    GHOSTTY_KEY_NUMPAD_DIVIDE = 96,
    GHOSTTY_KEY_NUMPAD_ENTER = 97,
    GHOSTTY_KEY_NUMPAD_EQUAL = 98,
    GHOSTTY_KEY_NUMPAD_MEMORY_ADD = 99,
    GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR = 100,
    GHOSTTY_KEY_NUMPAD_MEMORY_RECALL = 101,
    GHOSTTY_KEY_NUMPAD_MEMORY_STORE = 102,
    GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT = 103,
    GHOSTTY_KEY_NUMPAD_MULTIPLY = 104,
    GHOSTTY_KEY_NUMPAD_PAREN_LEFT = 105,
    GHOSTTY_KEY_NUMPAD_PAREN_RIGHT = 106,
    GHOSTTY_KEY_NUMPAD_SUBTRACT = 107,
    GHOSTTY_KEY_NUMPAD_SEPARATOR = 108,
    GHOSTTY_KEY_NUMPAD_UP = 109,
    GHOSTTY_KEY_NUMPAD_DOWN = 110,
    GHOSTTY_KEY_NUMPAD_RIGHT = 111,
    GHOSTTY_KEY_NUMPAD_LEFT = 112,
    GHOSTTY_KEY_NUMPAD_BEGIN = 113,
    GHOSTTY_KEY_NUMPAD_HOME = 114,
    GHOSTTY_KEY_NUMPAD_END = 115,
    GHOSTTY_KEY_NUMPAD_INSERT = 116,
    GHOSTTY_KEY_NUMPAD_DELETE = 117,
    GHOSTTY_KEY_NUMPAD_PAGE_UP = 118,
    GHOSTTY_KEY_NUMPAD_PAGE_DOWN = 119,

    // Function Section (W3C § 3.5)
    GHOSTTY_KEY_ESCAPE = 120,
    GHOSTTY_KEY_F1 = 121,
    GHOSTTY_KEY_F2 = 122,
    GHOSTTY_KEY_F3 = 123,
    GHOSTTY_KEY_F4 = 124,
    GHOSTTY_KEY_F5 = 125,
    GHOSTTY_KEY_F6 = 126,
    GHOSTTY_KEY_F7 = 127,
    GHOSTTY_KEY_F8 = 128,
    GHOSTTY_KEY_F9 = 129,
    GHOSTTY_KEY_F10 = 130,
    GHOSTTY_KEY_F11 = 131,
    GHOSTTY_KEY_F12 = 132,
    GHOSTTY_KEY_F13 = 133,
    GHOSTTY_KEY_F14 = 134,
    GHOSTTY_KEY_F15 = 135,
    GHOSTTY_KEY_F16 = 136,
    GHOSTTY_KEY_F17 = 137,
    GHOSTTY_KEY_F18 = 138,
    GHOSTTY_KEY_F19 = 139,
    GHOSTTY_KEY_F20 = 140,
    GHOSTTY_KEY_F21 = 141,
    GHOSTTY_KEY_F22 = 142,
    GHOSTTY_KEY_F23 = 143,
    GHOSTTY_KEY_F24 = 144,
    GHOSTTY_KEY_F25 = 145,
    GHOSTTY_KEY_FN = 146,
    GHOSTTY_KEY_FN_LOCK = 147,
    GHOSTTY_KEY_PRINT_SCREEN = 148,
    GHOSTTY_KEY_SCROLL_LOCK = 149,
    GHOSTTY_KEY_PAUSE = 150,

    // Media Keys (W3C § 3.6)
    GHOSTTY_KEY_BROWSER_BACK = 151,
    GHOSTTY_KEY_BROWSER_FAVORITES = 152,
    GHOSTTY_KEY_BROWSER_FORWARD = 153,
    GHOSTTY_KEY_BROWSER_HOME = 154,
    GHOSTTY_KEY_BROWSER_REFRESH = 155,
    GHOSTTY_KEY_BROWSER_SEARCH = 156,
    GHOSTTY_KEY_BROWSER_STOP = 157,
    GHOSTTY_KEY_EJECT = 158,
    GHOSTTY_KEY_LAUNCH_APP_1 = 159,
    GHOSTTY_KEY_LAUNCH_APP_2 = 160,
    GHOSTTY_KEY_LAUNCH_MAIL = 161,
    GHOSTTY_KEY_MEDIA_PLAY_PAUSE = 162,
    GHOSTTY_KEY_MEDIA_SELECT = 163,
    GHOSTTY_KEY_MEDIA_STOP = 164,
    GHOSTTY_KEY_MEDIA_TRACK_NEXT = 165,
    GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS = 166,
    GHOSTTY_KEY_POWER = 167,
    GHOSTTY_KEY_SLEEP = 168,
    GHOSTTY_KEY_AUDIO_VOLUME_DOWN = 169,
    GHOSTTY_KEY_AUDIO_VOLUME_MUTE = 170,
    GHOSTTY_KEY_AUDIO_VOLUME_UP = 171,
    GHOSTTY_KEY_WAKE_UP = 172,

    // Legacy, Non-standard, and Special Keys (W3C § 3.7)
    GHOSTTY_KEY_COPY = 173,
    GHOSTTY_KEY_CUT = 174,
    GHOSTTY_KEY_PASTE = 175,
    GHOSTTY_KEY_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKey;

/**
 * Create a new key event instance.
 * 
 * Creates a new key event with default values. The event must be freed using
 * ghostty_key_event_free() when no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param event Pointer to store the created key event handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 * 
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_new(const GhosttyAllocator *allocator, GhosttyKeyEvent *event);

/**
 * Free a key event instance.
 * 
 * Releases all resources associated with the key event. After this call,
 * the event handle becomes invalid and must not be used.
 * 
 * @param event The key event handle to free (may be NULL)
 * 
 * @ingroup key
 */
GHOSTTY_API void ghostty_key_event_free(GhosttyKeyEvent event);

/**
 * Set the key action (press, release, repeat).
 *
 * @param event The key event handle
 * @param action The action to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event` is
 *         NULL or `action` is not a GhosttyKeyAction value this version of the
 *         library knows. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_action(GhosttyKeyEvent event, GhosttyKeyAction action);

/**
 * Get the key action (press, release, repeat).
 *
 * @param event The key event handle
 * @return The key action, or GHOSTTY_KEY_ACTION_RELEASE if `event` is NULL
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyKeyAction ghostty_key_event_get_action(GhosttyKeyEvent event);

/**
 * Set the physical key code.
 *
 * @param event The key event handle
 * @param key The physical key code to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event` is
 *         NULL or `key` is not a GhosttyKey value this version of the
 *         library knows. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_key(GhosttyKeyEvent event, GhosttyKey key);

/**
 * Get the physical key code.
 *
 * @param event The key event handle
 * @return The physical key code, or GHOSTTY_KEY_UNIDENTIFIED if `event` is
 *         NULL
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyKey ghostty_key_event_get_key(GhosttyKeyEvent event);

/**
 * Set the modifier keys bitmask.
 *
 * @param event The key event handle
 * @param mods The modifier keys bitmask to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_mods(GhosttyKeyEvent event, GhosttyMods mods);

/**
 * Get the modifier keys bitmask.
 *
 * @param event The key event handle
 * @return The modifier keys bitmask, or 0 (no modifiers) if `event` is NULL
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyMods ghostty_key_event_get_mods(GhosttyKeyEvent event);

/**
 * Set the consumed modifiers bitmask.
 *
 * @param event The key event handle
 * @param consumed_mods The consumed modifiers bitmask to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_consumed_mods(GhosttyKeyEvent event, GhosttyMods consumed_mods);

/**
 * Get the consumed modifiers bitmask.
 *
 * @param event The key event handle
 * @return The consumed modifiers bitmask, or 0 (no modifiers) if `event` is
 *         NULL
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyMods ghostty_key_event_get_consumed_mods(GhosttyKeyEvent event);

/**
 * Set whether the key event is part of a composition sequence.
 *
 * @param event The key event handle
 * @param composing Whether the key event is part of a composition sequence
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_composing(GhosttyKeyEvent event, bool composing);

/**
 * Get whether the key event is part of a composition sequence.
 *
 * @param event The key event handle
 * @return Whether the key event is part of a composition sequence, or false
 *         if `event` is NULL
 *
 * @ingroup key
 */
GHOSTTY_API bool ghostty_key_event_get_composing(GhosttyKeyEvent event);

/**
 * Set the UTF-8 text generated by the key for the current keyboard layout.
 *
 * Must contain the unmodified character before any Ctrl/Meta transformations.
 * The encoder derives modifier sequences from the logical key and mods
 * bitmask, not from this text. Do not pass C0 control characters
 * (U+0000-U+001F, U+007F) or platform function key codes (e.g. macOS PUA
 * U+F700-U+F8FF). For those keys, pass an empty string and the encoder will
 * use the logical key instead.
 *
 * A string with a length of zero clears the text. The library does not read
 * its pointer, so the pointer may be NULL.
 *
 * The key event does not copy the text. The bytes must stay valid until the
 * event is freed or its text is set again. String literals and buffers that
 * outlive the event are both fine.
 *
 * @code{.c}
 * // Set the text for a key that produced "a".
 * const char *text = "a";
 * GhosttyString utf8 = {
 *     .ptr = (const uint8_t *)text,
 *     .len = strlen(text),
 * };
 * GhosttyResult result = ghostty_key_event_set_utf8(event, utf8);
 *
 * // Clear the text, for example for a function key.
 * result = ghostty_key_event_set_utf8(event, (GhosttyString){0});
 * @endcode
 *
 * @param event The key event handle
 * @param utf8 The UTF-8 text to set. It does not need to be null-terminated.
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_utf8(GhosttyKeyEvent event, GhosttyString utf8);

/**
 * Get the UTF-8 text generated by the key event.
 *
 * The event does not copy its text, so the returned string points at the
 * same bytes that were passed to ghostty_key_event_set_utf8(). It stays
 * valid while those bytes do, until the event is freed or its text is set
 * again.
 *
 * The bytes are not null-terminated. Always use the length:
 *
 * @code{.c}
 * GhosttyString text = ghostty_key_event_get_utf8(event);
 * printf("%.*s\n", (int)text.len, (const char *)text.ptr);
 * @endcode
 *
 * @param event The key event handle
 * @return The UTF-8 text. If the event has no text or `event` is NULL, the
 *         string has a length of zero.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyString ghostty_key_event_get_utf8(GhosttyKeyEvent event);

/**
 * Set the unshifted Unicode codepoint.
 *
 * @param event The key event handle
 * @param codepoint The unshifted Unicode codepoint to set
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `event`
 *         is NULL. On error the event is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_event_set_unshifted_codepoint(GhosttyKeyEvent event, uint32_t codepoint);

/**
 * Get the unshifted Unicode codepoint.
 *
 * @param event The key event handle
 * @return The unshifted Unicode codepoint, or 0 if `event` is NULL
 *
 * @ingroup key
 */
GHOSTTY_API uint32_t ghostty_key_event_get_unshifted_codepoint(GhosttyKeyEvent event);

#endif /* GHOSTTY_VT_KEY_EVENT_H */
