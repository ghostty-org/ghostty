// Wayland subsurface presenter for `GhosttySurface`.
//
// Scaffolding for the GPU-direct present path (issue: Phase 2 of the
// dmabuf-as-importable-surface rework). This class owns one
// `wl_subsurface` parented to the `GhosttySurface`'s native
// `wl_surface`. Its eventual job is to receive dmabuf fds from
// libghostty's renderer, wrap each one in a `wl_buffer` via
// `zwp_linux_dmabuf_v1`, and attach it to the subsurface so the
// compositor scans it out directly — bypassing the current mmap +
// memcpy + QImage + QPainter pipeline.
//
// In Phase 2 (this commit) the presenter only creates and tears down
// the subsurface. No buffer is ever attached; the existing
// `presentVulkanDmabuf` path keeps running unchanged. The proof this
// scaffolding works is that `ghastty-vulkan` still launches and
// renders identically with no Wayland protocol errors.
//
// Wayland-only by project decision (the Qt frontend is Wayland-only;
// see `feedback-qt-no-x11` memory). If the host isn't on a Wayland
// QPA platform or the compositor lacks `wl_subcompositor`,
// `tryCreate` returns nullptr — Phase 2 silently ignores that
// because nothing consumes the presenter yet; Phase 3 will treat it
// as fatal.

#pragma once

#include <memory>

struct wl_display;
struct wl_subsurface;
struct wl_surface;
class QWindow;

namespace wayland {

class SubsurfacePresenter {
public:
  // Build a subsurface parented to `parent`'s native `wl_surface`.
  // Returns nullptr if any prerequisite is missing (non-Wayland QPA,
  // null `wl_display`, `wl_subcompositor` unbindable, etc.).
  //
  // Forces `Qt::WA_NativeWindow` on the caller is the *caller's*
  // responsibility — `tryCreate` only reads `parent->surfaceHandle`.
  static std::unique_ptr<SubsurfacePresenter> tryCreate(QWindow *parent);

  ~SubsurfacePresenter();

  // Phase-3 accessors: when the present path moves to dmabuf-attach,
  // the caller will need the child `wl_surface` to attach buffers to
  // and the `wl_display` to flush. Exposed now so the API surface
  // doesn't churn between phases.
  wl_surface *childSurface() const { return m_childSurface; }
  wl_display *display() const { return m_display; }

  SubsurfacePresenter(const SubsurfacePresenter &) = delete;
  SubsurfacePresenter &operator=(const SubsurfacePresenter &) = delete;

private:
  SubsurfacePresenter(wl_display *display, wl_surface *child,
                      wl_subsurface *sub);

  wl_display *m_display;
  wl_surface *m_childSurface;
  wl_subsurface *m_subsurface;
};

} // namespace wayland
