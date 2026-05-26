#include "AlphaModifier.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>

#include <QGuiApplication>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>

#include "alpha-modifier-v1-client-protocol.h"

namespace wayland {

namespace {

// Process-wide binding. Lazily initialised on first supported()/
// setOpacity() call, then read lock-free via the atomic-by-fence
// guarantee of `std::call_once`. Once bound it lives for the
// process lifetime — there's no clean teardown path on Wayland
// global teardown that would matter for a manager-style global.
struct GlobalState {
  wl_display *display = nullptr;
  wp_alpha_modifier_v1 *manager = nullptr;  // null if compositor lacks it
  bool ready = false;                       // call_once fired (success or failure)
};

GlobalState &globalState() {
  static GlobalState g;
  return g;
}

// Listener: discover wp_alpha_modifier_v1 in the registry. The
// scoped wl_event_queue we use here is destroyed before the
// listener data goes out of scope, so the registry's child
// proxies (none survive past this binding pass) are safe.
void onRegistryGlobal(void *data, wl_registry *registry, uint32_t name,
                      const char *interface, uint32_t /*version*/) {
  auto *g = static_cast<GlobalState *>(data);
  if (std::strcmp(interface, wp_alpha_modifier_v1_interface.name) != 0)
    return;
  // Version 1 is the only version of this staging protocol so far.
  g->manager = static_cast<wp_alpha_modifier_v1 *>(
      wl_registry_bind(registry, name, &wp_alpha_modifier_v1_interface, 1));
}

void onRegistryGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener kRegistryListener = {
    &onRegistryGlobal,
    &onRegistryGlobalRemove,
};

// Bind the manager global lazily on first use. Idempotent under
// std::call_once. Mirrors the private-queue pattern in
// XkbTracker — and like that, we migrate the bound proxy onto
// the default queue before destroying the private queue, so
// future calls (set_multiplier, get_surface) dispatch on Qt's
// event loop instead of a dangling queue.
void initOnce() {
  static std::once_flag once;
  std::call_once(once, []() {
    auto &g = globalState();
    QPlatformNativeInterface *native =
        QGuiApplication::platformNativeInterface();
    if (!native) {
      g.ready = true;
      return;
    }
    g.display = static_cast<wl_display *>(
        native->nativeResourceForIntegration("wl_display"));
    if (!g.display) {
      g.ready = true;
      return;
    }

    wl_event_queue *queue = wl_display_create_queue(g.display);
    wl_registry *registry = wl_display_get_registry(g.display);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
    wl_registry_add_listener(registry, &kRegistryListener, &g);
    wl_display_roundtrip_queue(g.display, queue);
    wl_registry_destroy(registry);

    // Migrate the manager onto the default queue BEFORE destroying
    // the private one — otherwise compositor-side messages for the
    // manager (none expected for this protocol, but cleanliness
    // matters and Qt's event queue is the dispatch target we want
    // anyway) would target a destroyed queue, the same footgun that
    // produced the exit-time SIGSEGV in XkbTracker.
    if (g.manager) {
      wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(g.manager), nullptr);
    }
    wl_event_queue_destroy(queue);
    g.ready = true;
  });
}

// Per-wl_surface alpha modifier object cache. Cached so animation
// ticks don't re-roundtrip get_surface every frame.
//
// Keyed by wl_surface* — that's stable for the wl_surface's
// lifetime, and we explicitly drop on detach(). If a QWindow is
// destroyed without detach() being called the wl_surface gets
// destroyed by Qt; the cached wp_alpha_modifier_surface_v1 would
// then be invalid on next get_surface, so callers MUST detach()
// from the QWindow's destruction path. Map access is from the
// GUI thread only.
struct Cache {
  std::unordered_map<wl_surface *, wp_alpha_modifier_surface_v1 *> entries;
};

Cache &cache() {
  static Cache c;
  return c;
}

wl_surface *surfaceFor(QWindow *window) {
  if (!window) return nullptr;
  QPlatformNativeInterface *native =
      QGuiApplication::platformNativeInterface();
  if (!native) return nullptr;
  return static_cast<wl_surface *>(
      native->nativeResourceForWindow("surface", window));
}

wp_alpha_modifier_surface_v1 *getOrCreate(wl_surface *surface) {
  auto &c = cache();
  auto it = c.entries.find(surface);
  if (it != c.entries.end()) return it->second;
  auto *manager = globalState().manager;
  if (!manager) return nullptr;
  auto *obj = wp_alpha_modifier_v1_get_surface(manager, surface);
  if (!obj) return nullptr;
  c.entries.emplace(surface, obj);
  return obj;
}

}  // namespace

bool AlphaModifier::supported() {
  initOnce();
  return globalState().manager != nullptr;
}

bool AlphaModifier::setOpacity(QWindow *window, double opacity) {
  initOnce();
  auto &g = globalState();
  if (!g.manager) return false;
  wl_surface *surface = surfaceFor(window);
  if (!surface) return false;
  auto *mod = getOrCreate(surface);
  if (!mod) return false;

  // Convert [0.0, 1.0] → [0, UINT32_MAX]. Clamp first; lround
  // gives the closest integer, matching what users expect at the
  // endpoints (1.0 → fully opaque, 0.0 → fully transparent) without
  // off-by-one rounding drift at intermediate values.
  const double clamped = std::clamp(opacity, 0.0, 1.0);
  const uint32_t factor = static_cast<uint32_t>(
      std::lround(clamped * static_cast<double>(UINT32_MAX)));
  wp_alpha_modifier_surface_v1_set_multiplier(mod, factor);
  // Alpha multiplier is double-buffered on the wl_surface; the
  // change applies on the next wl_surface.commit. Commit here so
  // the caller doesn't need to know about Wayland's double-buffer
  // semantics. For Qt-managed top-level windows we don't have a
  // clean Qt API to force a parent commit, so we wl_surface.commit
  // the surface directly — same trick used elsewhere in this code
  // for subsurface state changes.
  wl_surface_commit(surface);
  // And flush so the commit reaches the compositor immediately
  // rather than sitting in libwayland-client's send buffer until
  // Qt's next event-loop iteration. Otherwise rapid animation
  // ticks would coalesce into one frame at the end of the tick
  // cycle, defeating the smooth fade.
  wl_display_flush(g.display);
  return true;
}

void AlphaModifier::detach(QWindow *window) {
  wl_surface *surface = surfaceFor(window);
  if (!surface) return;
  auto &c = cache();
  auto it = c.entries.find(surface);
  if (it == c.entries.end()) return;
  wp_alpha_modifier_surface_v1_destroy(it->second);
  c.entries.erase(it);
}

}  // namespace wayland
