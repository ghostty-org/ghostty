#include "SubsurfacePresenter.h"

#include <cstdio>
#include <cstring>

#include <QGuiApplication>
#include <QLatin1String>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>

namespace wayland {

namespace {

// Process-wide bindings for the Wayland globals the presenter needs.
// Lazily discovered on first `tryCreate`, mirrors the `blurManager`
// pattern in `qt/src/WindowBlur.cpp` — registry roundtrip happens on
// a private event queue so we never dispatch Qt's own Wayland events.
struct PresenterGlobals {
  wl_compositor *compositor = nullptr;
  wl_subcompositor *subcompositor = nullptr;
  bool searched = false;
};

void registryGlobal(void *data, wl_registry *registry, uint32_t name,
                    const char *interface, uint32_t /*version*/) {
  auto *g = static_cast<PresenterGlobals *>(data);
  if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
    g->compositor = static_cast<wl_compositor *>(
        wl_registry_bind(registry, name, &wl_compositor_interface, 1));
  } else if (std::strcmp(interface, wl_subcompositor_interface.name) == 0) {
    g->subcompositor = static_cast<wl_subcompositor *>(
        wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  }
}
void registryGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener kRegistryListener = {
    registryGlobal,
    registryGlobalRemove,
};

PresenterGlobals *discoverGlobals(wl_display *display) {
  static PresenterGlobals globals;
  if (globals.searched) return &globals;
  globals.searched = true;

  wl_event_queue *queue = wl_display_create_queue(display);
  wl_registry *registry = wl_display_get_registry(display);
  wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
  wl_registry_add_listener(registry, &kRegistryListener, &globals);
  wl_display_roundtrip_queue(display, queue);
  wl_registry_destroy(registry);

  // Move the bound proxies back to the default queue so Qt's main
  // dispatch drives subsequent events on them, then drop the private
  // queue. (Same lifecycle dance as `blurManager`.)
  if (globals.compositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.compositor),
                       nullptr);
  if (globals.subcompositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.subcompositor),
                       nullptr);
  wl_event_queue_destroy(queue);

  return &globals;
}

} // namespace

std::unique_ptr<SubsurfacePresenter>
SubsurfacePresenter::tryCreate(QWindow *parent) {
  if (!parent) return nullptr;

  // The Qt frontend is Wayland-only; if we're not on Wayland, the
  // native-interface lookups below would return null anyway, but
  // bail explicitly so the log message is useful.
  if (!QGuiApplication::platformName().startsWith(QLatin1String("wayland"))) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: not on Wayland QPA\n");
    return nullptr;
  }

  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return nullptr;

  auto *display = static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
  auto *parentSurface = static_cast<wl_surface *>(
      native->nativeResourceForWindow("surface", parent));
  if (!display || !parentSurface) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: missing wl_display or "
                 "parent wl_surface (display=%p surface=%p)\n",
                 static_cast<void *>(display),
                 static_cast<void *>(parentSurface));
    return nullptr;
  }

  PresenterGlobals *g = discoverGlobals(display);
  if (!g->compositor || !g->subcompositor) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: compositor lacks "
                 "wl_compositor or wl_subcompositor (compositor=%p "
                 "subcompositor=%p)\n",
                 static_cast<void *>(g->compositor),
                 static_cast<void *>(g->subcompositor));
    return nullptr;
  }

  wl_surface *child = wl_compositor_create_surface(g->compositor);
  if (!child) return nullptr;

  wl_subsurface *sub =
      wl_subcompositor_get_subsurface(g->subcompositor, child, parentSurface);
  if (!sub) {
    wl_surface_destroy(child);
    return nullptr;
  }

  // Independent frame pacing: the renderer's present cadence is
  // driven by libghostty's render thread, not the GUI thread's paint
  // cycle, so we don't want our wl_subsurface state changes to wait
  // for the parent's next commit. `set_desync` is what allows that.
  wl_subsurface_set_desync(sub);

  // Subsurface covers the parent at the origin. Phase 3 will keep
  // this in sync on resize; for Phase 2 it doesn't matter because
  // we never attach a buffer.
  wl_subsurface_set_position(sub, 0, 0);

  // Flush so the compositor sees the subsurface creation. We do NOT
  // commit the child surface — per protocol an uncommitted subsurface
  // with no attached buffer contributes nothing to the parent's
  // display, which is exactly the no-behavior-change state we want
  // for Phase 2.
  wl_display_flush(display);

  if (int err = wl_display_get_error(display); err != 0) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: wl_display error %d after "
                 "subsurface creation\n",
                 err);
    wl_subsurface_destroy(sub);
    wl_surface_destroy(child);
    return nullptr;
  }

  std::fprintf(stderr,
               "[ghastty] SubsurfacePresenter: subsurface ready (parent=%p "
               "child=%p sub=%p)\n",
               static_cast<void *>(parentSurface),
               static_cast<void *>(child), static_cast<void *>(sub));

  return std::unique_ptr<SubsurfacePresenter>(
      new SubsurfacePresenter(display, child, sub));
}

SubsurfacePresenter::SubsurfacePresenter(wl_display *display, wl_surface *child,
                                         wl_subsurface *sub)
    : m_display(display), m_childSurface(child), m_subsurface(sub) {}

SubsurfacePresenter::~SubsurfacePresenter() {
  if (m_subsurface) wl_subsurface_destroy(m_subsurface);
  if (m_childSurface) wl_surface_destroy(m_childSurface);
  if (m_display) wl_display_flush(m_display);
}

} // namespace wayland
