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
[[nodiscard]] ghostty_config_t handle();

// Read a string-valued config key (or an enum, which libghostty
// returns as its tag-name string). Empty if absent or the call
// fails.
[[nodiscard]] QString string(const char *key);

// Read a bool-valued config key. Returns `fallback` when the key is
// absent or the call fails. Note: libghostty's bool config keys are
// strict bools, NOT packed bitfields — see bitfield<>() for those.
[[nodiscard]] bool boolean(const char *key, bool fallback);

// Parse a duration config key as nanoseconds via the on-disk
// fallback. Use this for `?Duration` (optional) keys: c_get.zig
// returns false for a null optional, so the disk text is the only
// way to recover the configured value. Non-optional `Duration` keys
// surface through ghostty_config_get directly (it returns the value
// in *milliseconds*, per Duration.cval()) and should use config::get
// with `unsigned long long` and a manual ms→ns multiplication, NOT
// this wrapper, to avoid a redundant disk re-scan on every read.
// Returns `fallbackNs` on parse failure or absent key.
[[nodiscard]] uint64_t durationNs(const char *key, uint64_t fallbackNs);

// Scan the user's primary on-disk config file for `key = value`
// directly. Used for keys ghostty_config_get can't decode (Duration,
// repeating paths). Returns the last matching value, or empty.
[[nodiscard]] QString diskValue(const char *key);

// True if the live config has any custom-shader entry. Drives
// GhosttySurface's premultiply pass — `custom-shader` is a
// repeatable path that ghostty_config_get can't expose, so we scan
// the on-disk config text directly.
[[nodiscard]] bool hasCustomShader();

// Read a packed-bitfield config key. libghostty serializes packed
// structs as a c_uint via c_get.zig (`ptr.* = @intCast(@as(Backing,
// @bitCast(value)))`), so the returned bits are flag-indexed by the
// struct field order. Reading into a smaller buffer (e.g. a `bool`
// for a one-field packed struct) under-sizes the write and corrupts
// adjacent stack — always go through this. Returns `fallbackBits`
// when ghostty_config_get fails.
[[nodiscard]] unsigned int bitfield(const char *key, unsigned int fallbackBits);

// Read a path-valued disk config and expand a leading `~/` to the
// user's home directory. Returns empty when the key is absent.
// Path-valued keys are read off-disk (libghostty doesn't surface
// them through ghostty_config_get) so this is just diskValue() with
// a tilde-expansion pass.
[[nodiscard]] QString expandedPath(const char *key);

// Wrapper around ghostty_config_get that infers the value's length
// from a string literal so call sites stop repeating qstrlen(). The
// template only binds to char-array references (string literals);
// passing a `const char*` is intentionally a compile error —
// runtime-length keys must call ghostty_config_get directly.
//
// `out` must point to the type ghostty.h documents for the key
// (bool* for bool keys, ghostty_config_color_s* for colors, etc.).
// Returns false when the key is absent or the underlying call
// fails. The success bit MUST be checked — `out` is left untouched
// on failure, so dropping the return masks an unread / unwritten
// access.
template <typename T, size_t N>
[[nodiscard]] inline bool get(T *out, const char (&key)[N]) {
  static_assert(N > 1, "config::get requires a non-empty key literal");
  ghostty_config_t cfg = handle();
  return cfg && ghostty_config_get(cfg, out, key, N - 1);
}

}  // namespace config
