#pragma once

#include <QString>
#include <Qt>

#include "ghostty.h"

// Shared helpers used across the Qt frontend. Kept header-only where
// possible so trivial wrappers stay inlined.

// bell-features is a packed struct returned by ghostty_config_get as a
// bitfield. Layout is fixed by the libghostty C ABI; do not reorder.
enum BellFeature : unsigned int {
  BellSystem = 1u << 0,
  BellAudio = 1u << 1,
  BellAttention = 1u << 2,
  BellTitle = 1u << 3,
  BellBorder = 1u << 4,
};

// Translate Qt keyboard modifiers into libghostty's modifier bitfield.
inline ghostty_input_mods_e translateMods(Qt::KeyboardModifiers m) {
  int r = GHOSTTY_MODS_NONE;
  if (m & Qt::ShiftModifier) r |= GHOSTTY_MODS_SHIFT;
  if (m & Qt::ControlModifier) r |= GHOSTTY_MODS_CTRL;
  if (m & Qt::AltModifier) r |= GHOSTTY_MODS_ALT;
  if (m & Qt::MetaModifier) r |= GHOSTTY_MODS_SUPER;
  return static_cast<ghostty_input_mods_e>(r);
}

// Render the printable letter/digit/named key portion of a libghostty
// trigger. Returns an empty string if the key is not displayable
// (CATCH_ALL, an unmapped physical key, etc.).
QString triggerKeyName(const ghostty_input_trigger_s &t);

// Format a libghostty trigger as a human-readable chord (e.g. "Ctrl+B").
// Used for context-menu shortcut hints and the key-sequence overlay.
// Unmapped physical keys render as "•"; trigger.tag CATCH_ALL renders
// as "…".
QString formatTrigger(const ghostty_input_trigger_s &t);

// Wrapper around ghostty_config_get that infers the value's length
// from a string literal, so call sites stop repeating qstrlen().
template <typename T, size_t N>
inline bool configGet(ghostty_config_t cfg, T *out, const char (&key)[N]) {
  return cfg && ghostty_config_get(cfg, out, key, N - 1);
}
