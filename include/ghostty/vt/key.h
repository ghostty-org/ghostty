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
 * or the Kitty Keyboard Protocol. An encoder has to follow the terminal's
 * modes, which the @ref guide-input "Input guide" explains.
 *
 * ## Example
 *
 * @snippet c-vt-encode-key/src/main.c key-encode
 *
 * @{
 */

#include <ghostty/vt/key/event.h>
#include <ghostty/vt/key/encoder.h>

/** @} */

#endif /* GHOSTTY_VT_KEY_H */
