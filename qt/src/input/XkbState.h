#pragma once

#include <cstdint>

#include <xkbcommon/xkbcommon.h>

#include "ghostty.h"

// Wraps a libxkbcommon keymap + state derived from the live keymap
// XkbTracker syncs via wl_keyboard (with a fallback to the system
// XKB defaults until the compositor's keymap arrives). We need this
// for two things:
//
//   1. The unshifted codepoint a key would produce with no modifiers —
//      libghostty's kitty encoder uses it to find a key entry for
//      printable keys (without it, punctuation falls into a fallback
//      that mis-encodes release events).
//
//   2. Which modifiers the layout "consumed" to produce the event's
//      text — e.g. Shift+; → ":" consumes Shift. The encoder uses
//      this to decide between plain text and a modifier-bearing CSI;
//      without it Shift+punctuation gets emitted as a kitty CSI the
//      shell can't decode (Shift+letter happens to work because A-Z
//      survive that path).
//
// THREAD SAFETY: this is a process singleton accessed only from the
// Qt GUI thread (Qt key events are dispatched there, and so is
// libghostty's inputMethodEvent forwarding). consumedMods mutates
// internal state; do not call from worker threads.
class XkbState {
public:
  static XkbState &instance();

  // Level-0 (unshifted) Unicode codepoint for `keycode`, or 0 if the
  // key has no associated UTF-32 (function keys, modifiers, etc.).
  // Honors the active layout group from the live tracker so a us+ru
  // user gets the correct codepoint per active group, not always us.
  uint32_t unshiftedCodepoint(uint32_t keycode) const;

  // Side bits for the libghostty mods bitfield, derived from a
  // keycode — pressing Right-Shift sets BOTH the unsided
  // GHOSTTY_MODS_SHIFT and GHOSTTY_MODS_SHIFT_RIGHT bit (a left-side
  // keycode sets only the unsided bit). macOS and GTK populate sided
  // bits this way; Qt was leaving them empty so bindings that
  // distinguish left-vs-right modifier keys couldn't fire.
  ghostty_input_mods_e sideBitsForKeycode(uint32_t keycode) const;

  // Caps Lock / Num Lock state from the live wl_keyboard tracker.
  ghostty_input_mods_e lockMods() const;

  // Modifiers consumed by the layout to produce `keycode`'s text
  // given `mods` are depressed. Returns the consumed subset
  // expressed as ghostty mod bits.
  ghostty_input_mods_e consumedMods(uint32_t keycode,
                                    ghostty_input_mods_e mods) const;

  XkbState(const XkbState &) = delete;
  XkbState &operator=(const XkbState &) = delete;

private:
  XkbState() = default;
  ~XkbState();

  // Build / rebuild the derived states from the live keymap. Cheap
  // when the keymap pointer is unchanged (one comparison + return).
  void syncFromTracker() const;

  // The keymap our derived states were built from. A ref taken in
  // syncFromTracker (released on rebuild and in dtor) keeps the xkb
  // allocator from freeing + reusing the address while we still
  // cache it as our identity.
  mutable struct xkb_keymap *m_keymap = nullptr;
  // Throwaway keymap from XKB defaults, built when the live keymap
  // hasn't arrived yet. Owned. Released in dtor; never replaced.
  mutable struct xkb_keymap *m_fallbackKeymap = nullptr;
  mutable struct xkb_state *m_unshifted = nullptr;  // no-mods state
  // Reused across consumedMods calls (mutated then reset).
  mutable struct xkb_state *m_query = nullptr;
  mutable xkb_mod_index_t m_idxShift = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxCtrl = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxAlt = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxSuper = XKB_MOD_INVALID;
};
