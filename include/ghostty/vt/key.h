/**
 * @file key.h
 *
 * Key encoding module - encode key events into terminal escape sequences.
 */

#ifndef GHOSTTY_VT_KEY_H
#define GHOSTTY_VT_KEY_H

/** @defgroup key Key Encoding
 *
 * Utilities for encoding key events into terminal escape sequences,
 * supporting both legacy encoding as well as Kitty Keyboard Protocol.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with ghostty_key_encoder_new()
 * 2. Configure encoder options with ghostty_key_encoder_setopt()
 *    or ghostty_key_encoder_setopt_from_terminal() if you have a 
 *    GhosttyTerminal.
 * 3. For each key event:
 *    - Create a key event with ghostty_key_event_new()
 *    - Set event properties (action, key, modifiers, etc.)
 *    - Encode with ghostty_key_encoder_encode()
 *    - Free the event with ghostty_key_event_free()
 *    - Note: You can also reuse the same key event multiple times by
 *      changing its properties.
 * 4. Free the encoder with ghostty_key_encoder_free() when done
 *
 * For a complete working example, see example/c-vt-encode-key in the
 * repository.
 *
 * ## Example
 *
 * @snippet c-vt-encode-key/src/main.c key-encode
 *
 * ## Example: Encoding with Terminal State
 *
 * When you have a GhosttyTerminal, you can sync its modes (cursor key
 * application, Kitty flags, etc.) into the encoder automatically:
 *
 * @code{.c}
 * // Create a terminal and feed it some VT data that changes modes
 * GhosttyTerminal terminal;
 * ghostty_terminal_new(NULL, &terminal,
 *     (GhosttyTerminalOptions){.cols = 80, .rows = 24, .max_scrollback = 0});
 *
 * // Application might write data that enables Kitty keyboard protocol, etc.
 * ghostty_terminal_vt_write(terminal, vt_data, vt_len);
 *
 * // Create an encoder and sync its options from the terminal
 * GhosttyKeyEncoder encoder;
 * ghostty_key_encoder_new(NULL, &encoder);
 * ghostty_key_encoder_setopt_from_terminal(encoder, terminal);
 *
 * // Encode a key event using the terminal-derived options
 * char buf[128];
 * size_t written = 0;
 * ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *
 * ghostty_key_encoder_free(encoder);
 * ghostty_terminal_free(terminal);
 * @endcode
 *
 * @{
 */

#include <ghostty/vt/key/event.h>
#include <ghostty/vt/key/encoder.h>

/** @} */

#endif /* GHOSTTY_VT_KEY_H */
