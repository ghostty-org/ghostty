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

#include "fractional-scale-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "viewporter-client-protocol.h"

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
  wp_viewporter *viewporter = nullptr;
  wp_fractional_scale_manager_v1 *fractionalScale = nullptr;
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
  } else if (std::strcmp(interface, wp_viewporter_interface.name) == 0) {
    g->viewporter = static_cast<wp_viewporter *>(
        wl_registry_bind(registry, name, &wp_viewporter_interface, 1));
  } else if (std::strcmp(
                 interface, wp_fractional_scale_manager_v1_interface.name) == 0) {
    g->fractionalScale = static_cast<wp_fractional_scale_manager_v1 *>(
        wl_registry_bind(registry, name,
                         &wp_fractional_scale_manager_v1_interface, 1));
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
  if (globals.viewporter)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.viewporter),
                       nullptr);
  if (globals.fractionalScale)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.fractionalScale),
                       nullptr);
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
  if (!g->compositor || !g->subcompositor || !g->dmabuf || !g->viewporter) {
    std::fprintf(
        stderr,
        "[ghastty] SubsurfacePresenter: compositor missing required globals "
        "(compositor=%p subcompositor=%p dmabuf=%p viewporter=%p)\n",
        static_cast<void *>(g->compositor),
        static_cast<void *>(g->subcompositor), static_cast<void *>(g->dmabuf),
        static_cast<void *>(g->viewporter));
    return nullptr;
  }
  // wp_fractional_scale_manager_v1 is optional — if missing we
  // assume integer scale 1.0 and let wp_viewport.set_destination
  // still do its job. Most modern compositors support it.

  wl_surface *child = wl_compositor_create_surface(g->compositor);
  if (!child) return nullptr;

  wl_subsurface *sub =
      wl_subcompositor_get_subsurface(g->subcompositor, child, parentSurface);
  if (!sub) {
    wl_surface_destroy(child);
    return nullptr;
  }

  // Sync mode (the wl_subsurface default): wl_surface.commit on
  // the child caches state until the parent commits, at which point
  // both apply atomically. This is what guarantees lockstep resize
  // behavior — parent grows to the new size and our matching
  // new-size buffer apply in the same compositor frame, no gap.
  //
  // Sync mode requires the parent to commit for our state to
  // apply. Qt's backing-store flush doesn't fire for our
  // translucent QWidget (paintEvent produces no damage), so
  // GhosttySurface forces the parent commit explicitly via
  // QtWaylandClient::QWaylandWindow::commit() (Qt6::WaylandClient-
  // Private) after every child commit + viewport update. See
  // `forceParentCommit` in GhosttySurface.cpp.
  //
  // The earlier desync-mode attempt avoided the Qt-private
  // dependency but couldn't deliver lockstep resize because the
  // two surfaces commit independently in that mode.

  // Subsurface covers the parent at the origin. Phase 4 will keep
  // this in sync on splits/tabs/etc.; for now the GhosttySurface
  // forces WA_NativeWindow so its QWindow IS the terminal's native
  // wayland surface and (0,0) is correct.
  wl_subsurface_set_position(sub, 0, 0);

  // Stack the subsurface BELOW the parent so Qt's child widgets
  // (SearchBar, overlays, scrollbar, exit/health/link/resize hints)
  // remain visible — they're painted into the parent's backing
  // store, and Wayland's default subsurface stacking is *above*
  // parent which would hide all of them. With place_below the
  // parent QWidget renders on top; WA_TranslucentBackground means
  // the terminal area of the parent is transparent so the
  // subsurface shows through, while the chrome painted by
  // paintEvent stays visible on top.
  wl_subsurface_place_below(sub, parentSurface);

  // Set an empty input region so pointer/touch events fall through
  // to the parent surface (Qt's QWindow). The default input region
  // is the whole attached buffer, which would mean our subsurface
  // captures every click in the terminal area — Qt's QWidget would
  // never see contextMenuEvent (right-click menu), mouse press/
  // release, or any other pointer event in the terminal. wl_region
  // with no add_rectangle calls = empty = "no input." The region
  // can be destroyed immediately after set_input_region; the
  // compositor copies its state into the surface's pending state.
  wl_region *empty = wl_compositor_create_region(g->compositor);
  if (empty) {
    wl_surface_set_input_region(child, empty);
    wl_region_destroy(empty);
  }

  // wp_viewport: per-surface object that lets us tell the compositor
  // the destination size in surface-local coords, independent of
  // the buffer's pixel dimensions. With fractional scaling we
  // render at, say, 960x720 device pixels into an 800x600 surface
  // area, and the viewport handles the mapping.
  wp_viewport *viewport =
      wp_viewporter_get_viewport(g->viewporter, child);
  if (!viewport) {
    wl_subsurface_destroy(sub);
    wl_surface_destroy(child);
    return nullptr;
  }

  // wp_fractional_scale_v1: subscribe to the compositor's
  // per-surface preferred scale. Optional — if the global is
  // missing we stick with default 120 (= 1.0×).
  wp_fractional_scale_v1 *frac_scale = nullptr;
  if (g->fractionalScale) {
    frac_scale = wp_fractional_scale_manager_v1_get_fractional_scale(
        g->fractionalScale, child);
  }

  wl_display_flush(display);
  if (int err = wl_display_get_error(display); err != 0) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: wl_display error %d after "
                 "subsurface creation\n",
                 err);
    if (frac_scale) wp_fractional_scale_v1_destroy(frac_scale);
    wp_viewport_destroy(viewport);
    wl_subsurface_destroy(sub);
    wl_surface_destroy(child);
    return nullptr;
  }

  std::fprintf(stderr,
               "[ghastty] SubsurfacePresenter: ready (parent=%p child=%p "
               "sub=%p dmabuf=%p viewport=%p frac_scale=%p)\n",
               static_cast<void *>(parentSurface), static_cast<void *>(child),
               static_cast<void *>(sub), static_cast<void *>(g->dmabuf),
               static_cast<void *>(viewport),
               static_cast<void *>(frac_scale));

  return std::unique_ptr<SubsurfacePresenter>(new SubsurfacePresenter(
      display, child, sub, g->dmabuf, viewport, frac_scale));
}

const wp_fractional_scale_v1_listener kFractionalScaleListener = {
    SubsurfacePresenter::onPreferredScale,
};

void SubsurfacePresenter::onPreferredScale(void *data,
                                            wp_fractional_scale_v1 *,
                                            uint32_t scale) {
  auto *self = static_cast<SubsurfacePresenter *>(data);
  if (scale == 0) return; // guard against compositor bugs
  if (scale != self->m_preferredScale120) {
    std::fprintf(stderr,
                 "[ghastty] SubsurfacePresenter: preferred scale %u/120 = "
                 "%.3f\n",
                 scale, static_cast<double>(scale) / 120.0);
    self->m_preferredScale120 = scale;
  }
}

SubsurfacePresenter::SubsurfacePresenter(wl_display *display, wl_surface *child,
                                         wl_subsurface *sub,
                                         zwp_linux_dmabuf_v1 *dmabuf,
                                         wp_viewport *viewport,
                                         wp_fractional_scale_v1 *frac_scale)
    : m_display(display),
      m_childSurface(child),
      m_subsurface(sub),
      m_dmabuf(dmabuf),
      m_viewport(viewport),
      m_fractionalScale(frac_scale) {
  if (m_fractionalScale) {
    wp_fractional_scale_v1_add_listener(m_fractionalScale,
                                         &kFractionalScaleListener, this);
  }
}

SubsurfacePresenter::~SubsurfacePresenter() {
  if (m_fractionalScale) wp_fractional_scale_v1_destroy(m_fractionalScale);
  if (m_viewport) wp_viewport_destroy(m_viewport);
  if (m_subsurface) wl_subsurface_destroy(m_subsurface);
  if (m_childSurface) wl_surface_destroy(m_childSurface);
  if (m_display) wl_display_flush(m_display);
}

void SubsurfacePresenter::presentDmabuf(int fd, uint32_t drm_format,
                                        uint64_t drm_modifier, uint32_t width,
                                        uint32_t height, uint32_t stride,
                                        int dest_width, int dest_height) {
  if (fd < 0 || !m_dmabuf || !m_childSurface || !m_viewport) return;
  if (dest_width <= 0) dest_width = 1;
  if (dest_height <= 0) dest_height = 1;

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

  // Tell the compositor the destination size in surface-local
  // coordinates. With fractional scaling this is the logical pixel
  // size (e.g. 800x600) while the buffer is at device pixels (e.g.
  // 960x720 for 1.2× DPR). wp_viewport handles the mapping;
  // wl_surface.set_buffer_scale is intentionally NOT used here
  // because (a) it only supports integer scales, and (b) when
  // wp_fractional_scale_v1 is active the protocol forbids using
  // set_buffer_scale to anything other than 1.
  if (dest_width != m_lastDestWidth || dest_height != m_lastDestHeight) {
    wp_viewport_set_destination(m_viewport, dest_width, dest_height);
    m_lastDestWidth = dest_width;
    m_lastDestHeight = dest_height;
  }

  wl_surface_attach(m_childSurface, buffer, 0, 0);
  // Damage the full buffer extent — terminals tend to update large
  // dirty rects anyway (cursor blink, scroll, repaint) so a precise
  // damage region wouldn't save much, and `damage_buffer` (vs
  // `damage`) uses buffer coordinates so it's resolution-correct.
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

void SubsurfacePresenter::resizeDestination(int dest_width, int dest_height) {
  if (!m_viewport || !m_childSurface) return;
  if (dest_width <= 0 || dest_height <= 0) return;
  if (dest_width == m_lastDestWidth && dest_height == m_lastDestHeight) return;

  // Update destination + commit child WITHOUT attaching a new buffer.
  // In desync mode the commit applies immediately and the compositor
  // stretches the currently-attached buffer to the new dest extent.
  // The next presentDmabuf will overwrite this with a properly-sized
  // buffer, but until then the subsurface fills the new area instead
  // of leaving a transparent gap during the parent's resize commit.
  wp_viewport_set_destination(m_viewport, dest_width, dest_height);
  m_lastDestWidth = dest_width;
  m_lastDestHeight = dest_height;
  wl_surface_commit(m_childSurface);
  wl_display_flush(m_display);
}

} // namespace wayland
