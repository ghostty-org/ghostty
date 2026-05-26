#pragma once

#include <cstdint>

struct xkb_context;
struct xkb_keymap;
struct xkb_state;

// Tracks the user's live XKB state on Wayland: the active keymap, the
// effective layout group, and the locked modifier mask (Caps Lock,
// Num Lock).
//
// Qt does not expose any of this directly. We bind to the
// process-wide wl_seat via the platform native interface, install a
// wl_keyboard listener, rebuild our xkb_keymap from the compositor's
// keymap FD on every keymap event, and keep an xkb_state synced via
// the modifiers event.
//
// Read access (modsLocked / activeGroup / xkbState) is from the GUI
// thread only — same as Qt's input event delivery — and these
// methods do not mutate state.
//
// Wayland-only: this file's symbols are referenced from
// GhosttySurface, which already runs only on Wayland.
class XkbTracker {
 public:
  // Process-wide singleton; returns nullptr if Wayland binding
  // failed (e.g. running under XWayland with no wl_seat available
  // through Qt).
  static XkbTracker *instance();

  // The live xkb_state. Owned by the tracker; do not unref. May be
  // null if the compositor hasn't sent a keymap yet.
  xkb_state *state() const { return m_state; }

  // The live xkb_keymap from the compositor. Owned by the tracker;
  // do not unref. Replaced on every keymap event from the
  // compositor; consumers that cache derived state should compare
  // pointer identity to detect rebuilds.
  xkb_keymap *keymap() const { return m_keymap; }
  // The shared xkb_context. Lives as long as the tracker (process
  // lifetime).
  xkb_context *ctx() const { return m_ctx; }

  // True if Caps Lock is on right now.
  bool capsLockOn() const;
  // True if Num Lock is on right now.
  bool numLockOn() const;

  // The active layout group (0-based). 0 when the compositor hasn't
  // sent a modifiers event yet.
  uint32_t activeGroup() const { return m_group; }

  // Listener entry points are public because they're addressed by C
  // function pointer in the wl_keyboard_listener / wl_seat_listener
  // / wl_registry_listener structs. They are not part of the public
  // API; treat as internal.
  static void onKeymap(void *data, struct wl_keyboard *kb, uint32_t format,
                       int32_t fd, uint32_t size);
  static void onEnter(void *data, struct wl_keyboard *kb, uint32_t serial,
                      struct wl_surface *surface, struct wl_array *keys);
  static void onLeave(void *data, struct wl_keyboard *kb, uint32_t serial,
                      struct wl_surface *surface);
  static void onKey(void *data, struct wl_keyboard *kb, uint32_t serial,
                    uint32_t time, uint32_t key, uint32_t state);
  static void onModifiers(void *data, struct wl_keyboard *kb, uint32_t serial,
                          uint32_t mods_depressed, uint32_t mods_latched,
                          uint32_t mods_locked, uint32_t group);
  static void onRepeatInfo(void *data, struct wl_keyboard *kb, int32_t rate,
                           int32_t delay);
  // Registry callbacks (used to find wl_seat).
  static void onRegistryGlobal(void *data, struct wl_registry *registry,
                               uint32_t name, const char *interface,
                               uint32_t version);
  static void onRegistryGlobalRemove(void *data, struct wl_registry *registry,
                                     uint32_t name);
  // wl_seat capability-changed callback.
  static void onSeatCapabilities(void *data, struct wl_seat *seat,
                                 uint32_t capabilities);
  static void onSeatName(void *data, struct wl_seat *seat, const char *name);

 private:
  XkbTracker();
  ~XkbTracker();
  XkbTracker(const XkbTracker &) = delete;
  XkbTracker &operator=(const XkbTracker &) = delete;

  xkb_context *m_ctx = nullptr;
  xkb_keymap *m_keymap = nullptr;
  xkb_state *m_state = nullptr;
  uint32_t m_modsLocked = 0;
  uint32_t m_group = 0;
  // Indices into the keymap for the lock mods. XKB_MOD_INVALID until
  // a keymap is loaded.
  uint32_t m_idxCapsLock = ~0u;
  uint32_t m_idxNumLock = ~0u;
  // wl_seat handle, owned by us via wl_registry_bind. Kept alive for
  // the singleton's lifetime so capability changes (keyboard
  // hot-plug, layout switch) keep flowing to onSeatCapabilities, and
  // so the proxy isn't dangling on the private registry queue we
  // destroy at the end of the ctor.
  struct wl_seat *m_seat = nullptr;
  // wl_keyboard handle, owned by us via wl_seat_get_keyboard.
  struct wl_keyboard *m_keyboard = nullptr;
};
