#include "SubsurfacePresenter.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <vector>

#include <QGuiApplication>
#include <QLatin1String>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>

#include "linux-dmabuf-v1-client-protocol.h"

namespace wayland {

namespace {

// Process-wide bindings for the Wayland globals the presenter needs,
// plus the (format → modifiers) table the compositor advertises via
// zwp_linux_dmabuf_v1's format/modifier events. Populated once by
// `discoverGlobals` on the GUI thread; subsequent reads from the
// renderer thread are safe because the table is never mutated after
// the initial discovery completes.
struct PresenterGlobals {
  wl_compositor *compositor = nullptr;
  wl_subcompositor *subcompositor = nullptr;
  zwp_linux_dmabuf_v1 *dmabuf = nullptr;
  std::unordered_map<uint32_t, std::vector<uint64_t>> modifiers;
  bool searched = false;
};

PresenterGlobals &globalState() {
  static PresenterGlobals g;
  return g;
}

// Pre-v4 dmabuf format event. We ignore it: v3 also fires `modifier`
// events for every (format, modifier) tuple including LINEAR — the
// `format` event is legacy from v1/v2 when modifiers didn't exist.
void dmabufFormat(void *, zwp_linux_dmabuf_v1 *, uint32_t /*format*/) {}

// `modifier` event: compositor advertises one (format, modifier) it
// can scan out. Fires once per pair during the bind roundtrip; we
// stash them all in the per-format vector. Duplicate-keyed inserts
// are theoretically possible across compositor restarts but won't
// happen within a single bind round, so we don't dedupe.
void dmabufModifier(void *data, zwp_linux_dmabuf_v1 *, uint32_t format,
                    uint32_t modifier_hi, uint32_t modifier_lo) {
  auto *g = static_cast<PresenterGlobals *>(data);
  const uint64_t modifier =
      (static_cast<uint64_t>(modifier_hi) << 32) | modifier_lo;
  g->modifiers[format].push_back(modifier);
}

const zwp_linux_dmabuf_v1_listener kDmabufListener = {
    dmabufFormat,
    dmabufModifier,
};

void registryGlobal(void *data, wl_registry *registry, uint32_t name,
                    const char *interface, uint32_t version) {
  auto *g = static_cast<PresenterGlobals *>(data);
  if (std::strcmp(interface, wl_compositor_interface.name) == 0) {
    // Bind wl_compositor at version 3+ so child wl_surfaces we
    // create support `set_buffer_scale` (added in v3, used by the
    // presenter on HiDPI displays). Cap at v6 (the highest we've
    // tested against); if the compositor advertises less, take
    // what we get and `presentDmabuf` will skip the buffer_scale
    // call on those compositors.
    const uint32_t v = std::min<uint32_t>(version, 6u);
    g->compositor = static_cast<wl_compositor *>(
        wl_registry_bind(registry, name, &wl_compositor_interface, v));
  } else if (std::strcmp(interface, wl_subcompositor_interface.name) == 0) {
    g->subcompositor = static_cast<wl_subcompositor *>(
        wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  } else if (std::strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {
    // v3 has `create_immed`, which we want (synchronous wl_buffer
    // creation — the v2 async `create` + `created`/`failed` event
    // dance would add a layer of callback machinery for no real win
    // in our renderer's strict-fd-validity scenario). v4 adds the
    // dynamic format/modifier feedback dance; we don't need it yet.
    g->dmabuf = static_cast<zwp_linux_dmabuf_v1 *>(wl_registry_bind(
        registry, name, &zwp_linux_dmabuf_v1_interface, 3));
    // Add the listener immediately so the modifier events queued by
    // the bind get delivered when the dispatch loop continues.
    zwp_linux_dmabuf_v1_add_listener(g->dmabuf, &kDmabufListener, g);
  }
}
void registryGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener kRegistryListener = {
    registryGlobal,
    registryGlobalRemove,
};

PresenterGlobals *discoverGlobals(wl_display *display) {
  PresenterGlobals &globals = globalState();
  if (globals.searched) return &globals;
  globals.searched = true;

  wl_event_queue *queue = wl_display_create_queue(display);
  wl_registry *registry = wl_display_get_registry(display);
  wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
  wl_registry_add_listener(registry, &kRegistryListener, &globals);
  // Roundtrip 1: bind compositor/subcompositor/dmabuf. Inside the
  // registry callback we attach the dmabuf listener immediately, so
  // any format/modifier events that arrive in the same dispatch
  // pass fire on it.
  wl_display_roundtrip_queue(display, queue);
  wl_registry_destroy(registry);
  // Roundtrip 2: belt-and-suspenders for any compositor that defers
  // the modifier events past the bind reply (most don't, but some
  // batch them). After this returns the modifier table is fully
  // populated and frozen for the process lifetime.
  if (globals.dmabuf) wl_display_roundtrip_queue(display, queue);

  std::size_t total_mods = 0;
  for (const auto &kv : globals.modifiers) total_mods += kv.second.size();
  std::fprintf(stderr,
               "[ghastty] wayland: discovered %zu dmabuf (format,modifier) "
               "pairs across %zu formats\n",
               total_mods, globals.modifiers.size());

  // Move the bound proxies back to the default queue so Qt's main
  // dispatch drives subsequent events on them, then drop the private
  // queue. (Same lifecycle dance as `blurManager`.)
  if (globals.compositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.compositor),
                       nullptr);
  if (globals.subcompositor)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.subcompositor),
                       nullptr);
  if (globals.dmabuf)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.dmabuf), nullptr);
  wl_event_queue_destroy(queue);

  return &globals;
}

wl_display *acquireWaylandDisplay() {
  if (!QGuiApplication::platformName().startsWith(QLatin1String("wayland")))
    return nullptr;
  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return nullptr;
  return static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
}

// wl_buffer::release listener: the compositor is done sampling the
// buffer for any committed surface state, so we can destroy our
// client-side handle. The underlying dmabuf memory is owned by
// libghostty; we never close that fd here (the SCM_RIGHTS transfer
// in zwp_linux_buffer_params.add gave the compositor its own
// reference, which lives independently of our wl_buffer).
void bufferRelease(void *, wl_buffer *buffer) {
  wl_buffer_destroy(buffer);
}
const wl_buffer_listener kBufferListener = {
    bufferRelease,
};

} // namespace

void primeDmabufModifierRegistry() {
  if (wl_display *display = acquireWaylandDisplay()) {
    (void)discoverGlobals(display);
  }
}

std::size_t supportedDmabufModifiers(std::uint32_t drm_format,
                                     std::uint64_t *out,
                                     std::size_t capacity) {
  const PresenterGlobals &g = globalState();
  if (!g.searched) return 0;
  auto it = g.modifiers.find(drm_format);
  if (it == g.modifiers.end()) return 0;
  const std::size_t available = it->second.size();
  if (out == nullptr || capacity == 0) return available;
  const std::size_t copied = std::min(available, capacity);
  std::memcpy(out, it->second.data(), copied * sizeof(std::uint64_t));
  return copied;
}

std::unique_ptr<SubsurfacePresenter>
SubsurfacePresenter::tryCreate(QWindow *parent) {
  if (!parent) return nullptr;

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
  if (!g->compositor || !g->subcompositor || !g->dmabuf) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: compositor missing required "
                 "globals (compositor=%p subcompositor=%p dmabuf=%p)\n",
                 static_cast<void *>(g->compositor),
                 static_cast<void *>(g->subcompositor),
                 static_cast<void *>(g->dmabuf));
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

  // Subsurface covers the parent at the origin. Phase 4 will keep
  // this in sync on splits/tabs/etc.; for now the GhosttySurface
  // forces WA_NativeWindow so its QWindow IS the terminal's native
  // wayland surface and (0,0) is correct.
  wl_subsurface_set_position(sub, 0, 0);

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
               "[ghastty] SubsurfacePresenter: ready (parent=%p child=%p "
               "sub=%p dmabuf=%p)\n",
               static_cast<void *>(parentSurface), static_cast<void *>(child),
               static_cast<void *>(sub), static_cast<void *>(g->dmabuf));

  return std::unique_ptr<SubsurfacePresenter>(
      new SubsurfacePresenter(display, child, sub, g->dmabuf));
}

SubsurfacePresenter::SubsurfacePresenter(wl_display *display, wl_surface *child,
                                         wl_subsurface *sub,
                                         zwp_linux_dmabuf_v1 *dmabuf)
    : m_display(display),
      m_childSurface(child),
      m_subsurface(sub),
      m_dmabuf(dmabuf) {}

SubsurfacePresenter::~SubsurfacePresenter() {
  if (m_subsurface) wl_subsurface_destroy(m_subsurface);
  if (m_childSurface) wl_surface_destroy(m_childSurface);
  if (m_display) wl_display_flush(m_display);
}

void SubsurfacePresenter::presentDmabuf(int fd, uint32_t drm_format,
                                        uint64_t drm_modifier, uint32_t width,
                                        uint32_t height, uint32_t stride,
                                        int buffer_scale) {
  if (fd < 0 || !m_dmabuf || !m_childSurface) return;
  if (buffer_scale < 1) buffer_scale = 1;

  // Wrap libghostty's borrowed fd in a wl_buffer.
  zwp_linux_buffer_params_v1 *params =
      zwp_linux_dmabuf_v1_create_params(m_dmabuf);
  if (!params) return;
  zwp_linux_buffer_params_v1_add(params, fd, /*plane_idx*/ 0,
                                 /*offset*/ 0, stride,
                                 static_cast<uint32_t>(drm_modifier >> 32),
                                 static_cast<uint32_t>(drm_modifier & 0xFFFFFFFFu));
  wl_buffer *buffer = zwp_linux_buffer_params_v1_create_immed(
      params, static_cast<int32_t>(width), static_cast<int32_t>(height),
      drm_format, /*flags*/ 0);
  zwp_linux_buffer_params_v1_destroy(params);
  if (!buffer) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: create_immed returned null "
                 "(fd=%d %ux%u fmt=0x%x mod=0x%llx)\n",
                 fd, width, height, drm_format,
                 static_cast<unsigned long long>(drm_modifier));
    return;
  }
  wl_buffer_add_listener(buffer, &kBufferListener, this);

  // Set buffer scale only when it changes — calling on every present
  // is harmless but the compositor's bookkeeping is cheaper if we
  // skip the redundant request.
  if (buffer_scale != m_lastBufferScale) {
    // set_buffer_scale was added in wl_surface v3; guard against
    // older compositors that bind us at v1/v2 (rare but possible).
    if (wl_proxy_get_version(reinterpret_cast<wl_proxy *>(m_childSurface)) >= 3) {
      wl_surface_set_buffer_scale(m_childSurface, buffer_scale);
    }
    m_lastBufferScale = buffer_scale;
  }

  wl_surface_attach(m_childSurface, buffer, 0, 0);
  // Damage the full buffer extent — terminals tend to update large
  // dirty rects anyway (cursor blink, scroll, repaint) so a precise
  // damage region wouldn't save much, and `damage_buffer` (vs
  // `damage`) uses buffer coordinates so it's resolution-correct
  // regardless of buffer_scale.
  wl_surface_damage_buffer(m_childSurface, 0, 0, static_cast<int32_t>(width),
                           static_cast<int32_t>(height));
  wl_surface_commit(m_childSurface);

  wl_display_flush(m_display);
  if (int err = wl_display_get_error(m_display); err != 0) {
    std::fprintf(
        stderr,
        "[ghastty] SubsurfacePresenter: wl_display error %d after present\n",
        err);
  }
}

} // namespace wayland
