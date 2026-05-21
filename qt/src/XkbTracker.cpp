#include "XkbTracker.h"

#include <sys/mman.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>

#include <QGuiApplication>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

namespace {

// Listener structs assembled from the static thunks below.
const wl_keyboard_listener kKeyboardListener = {
    &XkbTracker::onKeymap,    &XkbTracker::onEnter,    &XkbTracker::onLeave,
    &XkbTracker::onKey,       &XkbTracker::onModifiers,
    &XkbTracker::onRepeatInfo,
};
const wl_seat_listener kSeatListener = {
    &XkbTracker::onSeatCapabilities, &XkbTracker::onSeatName,
};
const wl_registry_listener kRegistryListener = {
    &XkbTracker::onRegistryGlobal, &XkbTracker::onRegistryGlobalRemove,
};

}  // namespace

XkbTracker *XkbTracker::instance() {
  // Singleton initialised on first call. If Wayland binding fails
  // (e.g. running under XWayland with no exposed wl_seat) we return
  // a non-null tracker that simply has no state — callers handle a
  // null xkb_state gracefully.
  static XkbTracker self;
  return &self;
}

XkbTracker::XkbTracker() {
  m_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  if (!m_ctx) return;

  QPlatformNativeInterface *native =
      QGuiApplication::platformNativeInterface();
  if (!native) return;
  auto *display = static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
  if (!display) return;

  // Enumerate the registry on a private event queue so we don't
  // disturb Qt's own queue. After we find wl_seat and get the
  // wl_keyboard, the keyboard proxy is moved back to the default
  // queue so Qt's event loop drives our listener callbacks.
  wl_event_queue *queue = wl_display_create_queue(display);
  wl_registry *registry = wl_display_get_registry(display);
  wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
  wl_registry_add_listener(registry, &kRegistryListener, this);
  wl_display_roundtrip_queue(display, queue);
  wl_registry_destroy(registry);

  // Roundtrip again to receive seat capabilities and pick up the
  // wl_keyboard; the registry pass only binds the seat.
  if (m_keyboard == nullptr)
    wl_display_roundtrip_queue(display, queue);

  // The keyboard proxy is hot — move it onto the default queue so
  // Qt's event loop dispatches our listeners alongside Qt's own
  // input events.
  if (m_keyboard) {
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(m_keyboard), nullptr);
  }
  wl_event_queue_destroy(queue);
}

XkbTracker::~XkbTracker() {
  // Process-wide singleton; OS reclaims at exit. Explicit teardown
  // keeps leak checkers quiet and documents ownership.
  if (m_keyboard) wl_keyboard_destroy(m_keyboard);
  if (m_state) xkb_state_unref(m_state);
  if (m_keymap) xkb_keymap_unref(m_keymap);
  if (m_ctx) xkb_context_unref(m_ctx);
}

bool XkbTracker::capsLockOn() const {
  if (m_idxCapsLock == ~0u) return false;
  return (m_modsLocked & (1u << m_idxCapsLock)) != 0;
}

bool XkbTracker::numLockOn() const {
  if (m_idxNumLock == ~0u) return false;
  return (m_modsLocked & (1u << m_idxNumLock)) != 0;
}

// --- Registry / seat binding ----------------------------------------

void XkbTracker::onRegistryGlobal(void *data, wl_registry *registry,
                                  uint32_t name, const char *interface,
                                  uint32_t /*version*/) {
  auto *self = static_cast<XkbTracker *>(data);
  if (std::strcmp(interface, wl_seat_interface.name) != 0) return;

  // Bind the seat at version 5 (which exposes seat name + the
  // listener callbacks we need). If the compositor advertises an
  // older version, the bind silently downgrades; we only need
  // capabilities in either case.
  auto *seat = static_cast<wl_seat *>(
      wl_registry_bind(registry, name, &wl_seat_interface, 5));
  if (!seat) return;
  // Subscribe to capability changes; we'll grab the keyboard from
  // the capability callback once the seat tells us it has one.
  wl_seat_add_listener(seat, &kSeatListener, self);
}

void XkbTracker::onRegistryGlobalRemove(void *, wl_registry *, uint32_t) {}

void XkbTracker::onSeatCapabilities(void *data, wl_seat *seat,
                                    uint32_t capabilities) {
  auto *self = static_cast<XkbTracker *>(data);
  const bool hasKbd = (capabilities & WL_SEAT_CAPABILITY_KEYBOARD) != 0;
  if (hasKbd && !self->m_keyboard) {
    self->m_keyboard = wl_seat_get_keyboard(seat);
    if (self->m_keyboard)
      wl_keyboard_add_listener(self->m_keyboard, &kKeyboardListener, self);
  } else if (!hasKbd && self->m_keyboard) {
    wl_keyboard_destroy(self->m_keyboard);
    self->m_keyboard = nullptr;
  }
}

void XkbTracker::onSeatName(void *, wl_seat *, const char *) {}

// --- wl_keyboard listeners ------------------------------------------

void XkbTracker::onKeymap(void *data, wl_keyboard * /*kb*/, uint32_t format,
                          int32_t fd, uint32_t size) {
  auto *self = static_cast<XkbTracker *>(data);
  // We can only handle XKB v1 keymaps. Anything else is a Wayland
  // protocol extension we don't support; close the FD and bail.
  if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
    close(fd);
    return;
  }
  // mmap the keymap text and feed it to xkb. MAP_PRIVATE so writes
  // don't propagate; PROT_READ is enough.
  void *map = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
  if (map == MAP_FAILED) {
    std::fprintf(stderr, "[ghastty] xkb keymap mmap failed\n");
    close(fd);
    return;
  }

  xkb_keymap *km = xkb_keymap_new_from_string(
      self->m_ctx, static_cast<const char *>(map),
      XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
  munmap(map, size);
  close(fd);
  if (!km) {
    std::fprintf(stderr, "[ghastty] xkb keymap compile failed\n");
    return;
  }

  // Replace the previous keymap+state. Anything that captured the
  // old xkb_state* must use XkbTracker::state() each call rather
  // than caching the pointer — we document that at the call site.
  if (self->m_state) {
    xkb_state_unref(self->m_state);
    self->m_state = nullptr;
  }
  if (self->m_keymap) xkb_keymap_unref(self->m_keymap);
  self->m_keymap = km;
  self->m_state = xkb_state_new(km);
  self->m_idxCapsLock = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CAPS);
  self->m_idxNumLock = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_NUM);
  self->m_modsLocked = 0;
  self->m_group = 0;
}

void XkbTracker::onEnter(void *, wl_keyboard *, uint32_t, wl_surface *,
                         wl_array *) {}
void XkbTracker::onLeave(void *, wl_keyboard *, uint32_t, wl_surface *) {}
void XkbTracker::onKey(void *, wl_keyboard *, uint32_t, uint32_t, uint32_t,
                       uint32_t) {
  // Qt delivers key events; we don't want to double-process here.
}

void XkbTracker::onModifiers(void *data, wl_keyboard *, uint32_t,
                             uint32_t mods_depressed, uint32_t mods_latched,
                             uint32_t mods_locked, uint32_t group) {
  auto *self = static_cast<XkbTracker *>(data);
  if (!self->m_state) return;
  // Keep the live state in sync so xkb_state_key_get_one_sym (used
  // for unshifted_codepoint) and xkb_state_key_get_consumed_mods2
  // see the active layout group and locked-modifier mask.
  xkb_state_update_mask(self->m_state, mods_depressed, mods_latched,
                        mods_locked, 0, 0, group);
  self->m_modsLocked = mods_locked;
  self->m_group = group;
}

void XkbTracker::onRepeatInfo(void *, wl_keyboard *, int32_t, int32_t) {}
