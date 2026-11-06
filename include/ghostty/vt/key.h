/**
 * @file key.h
 *
 * Key encoding module - encode key events into terminal escape sequences.
 */

#ifndef GHOSTTY_VT_KEY_H
#define GHOSTTY_VT_KEY_H

/** @addtogroup key
 *
 * Encode key events into terminal escape sequences, with the legacy encoding
 * or the Kitty Keyboard Protocol.
 *
 * An encoder has to follow the terminal's modes. If you have a terminal, call
 * ghostty_key_encoder_set_from_terminal() before you encode. You don't need a
 * terminal to use this, but then you set the options yourself.
 *
 * ## Example
 *
 * @snippet c-vt-encode-key/src/main.c key-encode
 *
 * Full program: @ref c-vt-encode-key/src/main.c
 *
 * The @ref guide-input "Input guide" explains which modes matter and when to
 * sync them.
 *
 * @{
 */

#include <ghostty/vt/key/event.h>
#include <ghostty/vt/key/encoder.h>

/** @} */

#endif /* GHOSTTY_VT_KEY_H */
