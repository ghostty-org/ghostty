#pragma once

#include <cstdint>

#include <QString>

#include "ghostty.h"

// Typed accessors over the live libghostty config held by
// GhosttyApp::instance().config(). Every call here resolves the
// singleton's config pointer at access time, so reads stay coherent
// after a config reload (replaceConfig swaps the pointer in place).
//
// Layout: this header is include-anywhere (depends only on QString
// and ghostty.h). The implementations live in Config.cpp; the
// templated string-literal `get()` stays inline so callers don't pay
// a function-call hop on each config read.
namespace config {

// The live ghostty_config_t. Returns nullptr before the singleton has
// finished ensureInitialized — callers that read config during early
// startup (before the first MainWindow::initialize) must check.
ghostty_config_t handle();

// Read a string-valued config key (or an enum, which libghostty
// returns as its tag-name string). Empty if absent or the call
// fails.
QString string(const char *key);

// Read a bool-valued config key. Returns `fallback` when the key is
// absent or the call fails. Note: libghostty's bool config keys are
// strict bools, NOT packed bitfields — see bitfield<>() for those.
bool boolean(const char *key, bool fallback);

// Parse a duration config key as nanoseconds. Always reads through
// the disk-fallback (configDiskValue) because libghostty's
// ghostty_config_get rejects Duration types (non-extern non-packed
// struct). Returns `fallbackNs` on parse failure or absent key.
uint64_t durationNs(const char *key, uint64_t fallbackNs);

// Scan the user's primary on-disk config file for `key = value`
// directly. Used for keys ghostty_config_get can't decode (Duration,
// repeating paths). Returns the last matching value, or empty.
QString diskValue(const char *key);

// True if the live config has any custom-shader entry. Drives
// GhosttySurface's premultiply pass — `custom-shader` is a
// repeatable path that ghostty_config_get can't expose, so we scan
// the on-disk config text directly.
bool hasCustomShader();

// Wrapper around ghostty_config_get that infers the value's length
// from a string literal so call sites stop repeating qstrlen(). The
// template only binds to char-array references (string literals);
// passing a `const char*` is intentionally a compile error —
// runtime-length keys must call ghostty_config_get directly.
//
// `out` must point to the type ghostty.h documents for the key
// (bool* for bool keys, ghostty_config_color_s* for colors, etc.).
// Returns false when the key is absent or the underlying call
// fails.
template <typename T, size_t N>
inline bool get(T *out, const char (&key)[N]) {
  ghostty_config_t cfg = handle();
  return cfg && ghostty_config_get(cfg, out, key, N - 1);
}

}  // namespace config
