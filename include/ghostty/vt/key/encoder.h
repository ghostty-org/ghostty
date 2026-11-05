/**
 * @file encoder.h
 *
 * Key event encoding to terminal escape sequences.
 */

#ifndef GHOSTTY_VT_KEY_ENCODER_H
#define GHOSTTY_VT_KEY_ENCODER_H

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/key/event.h>

/**
 * Opaque handle to a key encoder instance.
 *
 * This handle represents a key encoder that converts key events into terminal
 * escape sequences.
 *
 * @ingroup key
 */
typedef struct GhosttyKeyEncoderImpl *GhosttyKeyEncoder;

/**
 * Kitty keyboard protocol flags.
 *
 * Bitflags representing the various modes of the Kitty keyboard protocol.
 * These can be combined using bitwise OR operations. Valid values all
 * start with `GHOSTTY_KITTY_KEY_`.
 *
 * @ingroup key
 */
typedef uint8_t GhosttyKittyKeyFlags;

/** Kitty keyboard protocol disabled (all flags off) */
#define GHOSTTY_KITTY_KEY_DISABLED 0

/** Disambiguate escape codes */
#define GHOSTTY_KITTY_KEY_DISAMBIGUATE (1 << 0)

/** Report key press and release events */
#define GHOSTTY_KITTY_KEY_REPORT_EVENTS (1 << 1)

/** Report alternate key codes */
#define GHOSTTY_KITTY_KEY_REPORT_ALTERNATES (1 << 2)

/** Report all key events including those normally handled by the terminal */
#define GHOSTTY_KITTY_KEY_REPORT_ALL (1 << 3)

/** Report associated text with key events */
#define GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED (1 << 4)

/** All Kitty keyboard protocol flags enabled */
#define GHOSTTY_KITTY_KEY_ALL (GHOSTTY_KITTY_KEY_DISAMBIGUATE | GHOSTTY_KITTY_KEY_REPORT_EVENTS | GHOSTTY_KITTY_KEY_REPORT_ALTERNATES | GHOSTTY_KITTY_KEY_REPORT_ALL | GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED)

/**
 * macOS option key behavior.
 *
 * Determines whether the "option" key on macOS is treated as "alt" or not.
 * See the Ghostty `macos-option-as-alt` configuration option for more details.
 *
 * @ingroup key
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /** Option key is not treated as alt */
    GHOSTTY_OPTION_AS_ALT_FALSE = 0,
    /** Option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_TRUE = 1,
    /** Only left option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_LEFT = 2,
    /** Only right option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_RIGHT = 3,
    GHOSTTY_OPTION_AS_ALT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyOptionAsAlt;

/**
 * Key encoder option identifiers.
 *
 * These values are used with ghostty_key_encoder_set() to configure
 * the behavior of the key encoder.
 *
 * @ingroup key
 */
typedef enum GHOSTTY_ENUM_TYPED {
    /**
     * Not a real option. ghostty_key_encoder_set() returns
     * GHOSTTY_INVALID_VALUE for it. Its value is 0, so a zeroed or
     * uninitialized variable is never mistaken for a real option.
     */
    GHOSTTY_KEY_ENCODER_OPT_INVALID = 0,

    /** Terminal DEC mode 1: cursor key application mode (value: bool,
     *  default: false) */
    GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION = 1,

    /** Terminal DEC mode 66: keypad key application mode (value: bool,
     *  default: false) */
    GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION = 2,

    /** Terminal DEC mode 1035: ignore keypad with numlock (value: bool,
     *  default: false) */
    GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK = 3,

    /** Terminal DEC mode 1036: alt sends escape prefix (value: bool,
     *  default: false) */
    GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX = 4,

    /** xterm modifyOtherKeys mode 2 (value: bool, default: false) */
    GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 = 5,

    /** Kitty keyboard protocol flags (value: GhosttyKittyKeyFlags bitmask,
     *  default: GHOSTTY_KITTY_KEY_DISABLED) */
    GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS = 6,

    /** macOS option-as-alt setting (value: GhosttyOptionAsAlt,
     *  default: GHOSTTY_OPTION_AS_ALT_FALSE) */
    GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT = 7,

    /** Backarrow key mode (value: bool)
     * See https://vt100.net/dec/ek-vt3xx-tp-002.pdf page 170
     * If `false` (the default), `backspace` emits 0x7f
     * If `true`, `backspace` emits 0x08
     */
    GHOSTTY_KEY_ENCODER_OPT_BACKARROW_KEY_MODE = 8,

    GHOSTTY_KEY_ENCODER_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKeyEncoderOption;

/**
 * Create a new key encoder instance.
 *
 * Creates a new key encoder with default options. The encoder can be configured
 * using ghostty_key_encoder_set() and must be freed using
 * ghostty_key_encoder_free() when no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param encoder Pointer to store the created encoder handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_new(const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder);

/**
 * Free a key encoder instance.
 *
 * Releases all resources associated with the key encoder. After this call,
 * the encoder handle becomes invalid and must not be used.
 *
 * @param encoder The encoder handle to free (may be NULL)
 *
 * @ingroup key
 */
GHOSTTY_API void ghostty_key_encoder_free(GhosttyKeyEncoder encoder);

/**
 * Set an option on the key encoder.
 *
 * Configures the behavior of the key encoder. Options control various aspects
 * of encoding such as terminal modes (cursor key application mode, keypad mode),
 * protocol selection (Kitty keyboard protocol flags), and platform-specific
 * behaviors (macOS option-as-alt).
 *
 * If you are using a terminal instance, you can set the key encoding
 * options based on the active terminal state (e.g. legacy vs Kitty mode
 * and associated flags) with ghostty_key_encoder_set_from_terminal().
 *
 * Passing NULL for `value` resets the option to its default, the same
 * value a new encoder starts with. Each option's default is listed on
 * GhosttyKeyEncoderOption.
 *
 * @code{.c}
 * bool enabled = true;
 * ghostty_key_encoder_set(
 *     encoder, GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, &enabled);
 *
 * // Later, put the option back to its default (false).
 * ghostty_key_encoder_set(
 *     encoder, GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION, NULL);
 * @endcode
 *
 * @param encoder The encoder handle, must not be NULL
 * @param option The option to set
 * @param value Pointer to the value to set (type depends on the option), or
 *              NULL to reset the option to its default
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `encoder` is
 *         NULL or the value is out of range (such as an unknown
 *         GhosttyOptionAsAlt), or GHOSTTY_UNSUPPORTED if `option` is not
 *         known to this version of the library
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_set(GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void *value);

/**
 * Set encoder options from a terminal's current state.
 *
 * Reads the terminal's current modes and flags and applies them to the
 * encoder's options. This sets cursor key application mode, keypad mode,
 * alt escape prefix, modifyOtherKeys state, and Kitty keyboard protocol
 * flags from the terminal state.
 *
 * Note that the `macos_option_as_alt` option cannot be determined from
 * terminal state and is reset to `GHOSTTY_OPTION_AS_ALT_FALSE` by this
 * call. Use ghostty_key_encoder_set() to set it afterward if needed.
 *
 * @param encoder The encoder handle
 * @param terminal The terminal handle
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if `encoder`
 *         or `terminal` is NULL. On error the encoder is not changed.
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_set_from_terminal(GhosttyKeyEncoder encoder, GhosttyTerminal terminal);

/**
 * Encode a key event into a terminal escape sequence.
 *
 * Converts a key event into the appropriate terminal escape sequence based on
 * the encoder's current options. The sequence is written to the provided buffer.
 *
 * Not all key events produce output. For example, unmodified modifier keys
 * typically don't generate escape sequences. For those events this returns
 * GHOSTTY_SUCCESS with @p out_written set to 0.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE and sets
 * @p out_written to the size needed. The buffer may then hold part of the
 * sequence, which you should discard. To get the size without encoding
 * anything, pass NULL for @p buf and 0 for @p buf_len. An event with no
 * output still returns GHOSTTY_SUCCESS in that case, because it needs no
 * space.
 *
 * @param encoder The encoder handle, must not be NULL
 * @param event The key event to encode, must not be NULL
 * @param buf Buffer to write the sequence into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE. Must not be NULL.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_SPACE if buffer too small, or other error code
 *
 * ## Example: Calculate required buffer size
 *
 * @code{.c}
 * // Query the required size with a NULL buffer
 * size_t required = 0;
 * GhosttyResult result = ghostty_key_encoder_encode(encoder, event, NULL, 0, &required);
 * if (result == GHOSTTY_SUCCESS) {
 *   // This event produces no output, so there is nothing to send
 *   return;
 * }
 * assert(result == GHOSTTY_OUT_OF_SPACE);
 *
 * // Allocate buffer of required size
 * uint8_t *buf = malloc(required);
 *
 * // Encode with properly sized buffer
 * size_t written = 0;
 * result = ghostty_key_encoder_encode(encoder, event, buf, required, &written);
 * assert(result == GHOSTTY_SUCCESS);
 *
 * // Use the encoded sequence...
 *
 * free(buf);
 * @endcode
 *
 * ## Example: Direct encoding with static buffer
 *
 * @code{.c}
 * // Most escape sequences are short, so a static buffer often suffices
 * uint8_t buf[128];
 * size_t written = 0;
 * GhosttyResult result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *
 * if (result == GHOSTTY_SUCCESS) {
 *   // Write the encoded sequence to the terminal
 *   write(pty_fd, buf, written);
 * } else if (result == GHOSTTY_OUT_OF_SPACE) {
 *   // Buffer too small, written contains required size
 *   uint8_t *dynamic_buf = malloc(written);
 *   result = ghostty_key_encoder_encode(encoder, event, dynamic_buf, written, &written);
 *   assert(result == GHOSTTY_SUCCESS);
 *   write(pty_fd, dynamic_buf, written);
 *   free(dynamic_buf);
 * }
 * @endcode
 *
 * @ingroup key
 */
GHOSTTY_API GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder encoder, GhosttyKeyEvent event, uint8_t *buf, size_t buf_len, size_t *out_written);

#endif /* GHOSTTY_VT_KEY_ENCODER_H */
