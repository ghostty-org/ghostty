#pragma once

#include <utility>

#include <QMetaObject>
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

// Parse a libghostty duration string ("750ms", "1s500us", "2h", ...)
// into nanoseconds. Returns `fallback` if parsing fails or the input
// is empty. libghostty exposes Duration via ghostty_config_get as a
// non-extern non-packed struct, which c_get silently rejects; we
// fall back to scanning the config file text.
uint64_t parseDurationNs(const QString &s, uint64_t fallback);

// Scan the primary Ghostty config file for `key = value`, returning
// the last matching value (empty if absent). For keys not cleanly
// exposed by ghostty_config_get (Duration, paths, ...).
QString configValue(const QString &key);

// Post a desktop notification via the freedesktop D-Bus service.
// Fire-and-forget; no return code (notifications are best-effort).
void postNotification(const QString &title, const QString &body);

// Format a libghostty trigger as a human-readable chord (e.g. "Ctrl+B").
// Used for context-menu shortcut hints and the key-sequence overlay.
// Unmapped physical keys render as "•"; trigger.tag CATCH_ALL renders
// as "…".
QString formatTrigger(const ghostty_input_trigger_s &t);

// Wrapper around ghostty_config_get that infers the value's length
// from a string literal, so call sites stop repeating qstrlen().
//
// The template only binds to char-array references (string literals);
// passing a `const char*` is intentionally a compile error — runtime-
// length keys must call ghostty_config_get directly with qstrlen.
template <typename T, size_t N>
inline bool configGet(ghostty_config_t cfg, T *out, const char (&key)[N]) {
  return cfg && ghostty_config_get(cfg, out, key, N - 1);
}

// Queue `f` on `target`'s thread, but only if `target` is still alive
// when the slot runs (Qt cancels queued slots whose receiver was
// deleted). Cross-captured pointers must be wrapped in QPointer
// separately — `target` only protects itself.
template <class Target, class F>
inline void post(Target *target, F &&f) {
  if (!target) return;
  QMetaObject::invokeMethod(target, std::forward<F>(f), Qt::QueuedConnection);
}
