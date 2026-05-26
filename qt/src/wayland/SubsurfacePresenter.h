// Wayland subsurface presenter for `GhosttySurface`.
//
// Owns one `wl_subsurface` parented to the `GhosttySurface`'s native
// `wl_surface`, plus the `zwp_linux_dmabuf_v1` machinery for wrapping
// libghostty's dmabuf fds in `wl_buffer`s and attaching them to that
// subsurface. The compositor scans the buffers out directly — no
// mmap, no memcpy, no QImage, no QPainter blit on the present path.
//
// The process-wide compositor modifier registry that used to share
// this header now lives in `DmabufRegistry.h`. The implementations
// share `globalState()` machinery in `SubsurfacePresenter.cpp` but
// the API surfaces are disjoint: presenter is per-widget, registry
// is process-wide and read-only.
//
// Wayland-only by project decision (the Qt frontend is Wayland-only;
// see `feedback-qt-no-x11` memory). If the host isn't on a Wayland
// QPA platform or the compositor lacks the required globals,
// `tryCreate` returns nullptr — the caller decides whether that's a
// fatal error.

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

struct wl_buffer;
struct wl_display;
struct wl_subsurface;
struct wl_surface;
struct zwp_linux_dmabuf_v1;
struct wp_viewport;
struct wp_fractional_scale_v1;
class QWindow;

namespace wayland {

class SubsurfacePresenter {
public:
  // Build a subsurface parented to `topLevel`'s native `wl_surface`,
  // and bind the linux-dmabuf-v1 global on the same display. Pass
  // the TOP-LEVEL QWindow (e.g. `widget->window()->windowHandle()`)
  // — NOT a per-widget native QWindow. We attach all panes/splits
  // as siblings under the top-level surface and position each with
  // `setPosition`, instead of giving each pane its own QWindow
  // (which Qt's QSplitter-embedded child widgets don't handle
  // cleanly: "QWidgetWindow must be a top level window" warning,
  // and the result renders black).
  //
  // Returns nullptr if any prerequisite is missing (non-Wayland QPA,
  // null `wl_display`, `wl_subcompositor` unbindable,
  // `zwp_linux_dmabuf_v1` unbindable, etc.).
  static std::unique_ptr<SubsurfacePresenter> tryCreate(QWindow *topLevel);

  ~SubsurfacePresenter();

  // Hand a dmabuf-backed frame to the compositor: wrap the fd in a
  // `wl_buffer` via `zwp_linux_buffer_params_v1.create_immed`, attach
  // to the subsurface, damage, commit. MUST be called on the Qt GUI
  // thread (the thread that owns the wl_display dispatch); the
  // renderer thread should marshal frames through a Qt-side queue.
  //
  // libghostty owns the fd; this method does not close it. The
  // wayland client library duplicates the fd kernel-side via
  // SCM_RIGHTS, so the compositor's reference survives even after
  // libghostty reuses or closes its handle.
  //
  // `dest_width` / `dest_height` are the size of the subsurface in
  // PARENT surface-local coordinates (i.e. logical pixels). For
  // integer scales they match the buffer dimensions divided by the
  // scale; for fractional scales they're independent (set via
  // wp_viewport.set_destination, which decouples buffer dimensions
  // from surface area).
  // `y_invert` requests the compositor flip the buffer vertically
  // when sampling. The OpenGL renderer's coordinate convention is
  // bottom-left origin (Y up), but Wayland/DRM samples top-down —
  // without the flag, GL frames render upside-down. Vulkan
  // rasterizes Y-down by default and passes false.
  void presentDmabuf(int fd, uint32_t drm_format, uint64_t drm_modifier,
                     uint32_t width, uint32_t height, uint32_t stride,
                     int dest_width, int dest_height,
                     bool y_invert = false);

  // Compositor-preferred fractional scale for this surface, in
  // units of 1/120 (e.g. 144 = 1.2, 180 = 1.5, 240 = 2.0). Returns
  // 120 (= 1.0) until the compositor sends its first
  // wp_fractional_scale_v1.preferred_scale event for our surface.
  //
  // Currently INFORMATIONAL only: GhosttySurface uses Qt's
  // devicePixelRatioF() for buffer sizing (which Qt derives from
  // the same protocol on Wayland), so the two values agree at
  // steady state. Exposed for diagnostics + a future direct-
  // protocol path that bypasses Qt's DPR cache lag during a
  // screen-change race.
  uint32_t preferredScale120() const { return m_preferredScale120; }

  // Stretch the existing subsurface buffer to a new destination
  // size WITHOUT attaching a new buffer. Used at the *start* of a
  // resize, before the renderer has produced a new-size frame:
  // wp_viewport.set_destination is double-buffered on the child
  // surface, so committing the child here in desync mode applies
  // the new destination immediately and the compositor stretches
  // the old buffer to fill it. Result: the parent surface can grow
  // to its new size with the subsurface already covering the new
  // area (briefly stretched), instead of leaving a one-frame
  // transparent gap where the translucent parent shows through.
  //
  // The next presentDmabuf call (with the real new-size buffer)
  // replaces the stretched content, ending the brief blur.
  //
  // Same pattern mpv's vo_dmabuf_wayland uses for its video
  // subsurface during resize.
  void resizeDestination(int dest_width, int dest_height);

  // Update the subsurface position in parent-surface-local coords.
  // For panes inside splits / tabs, position is the GhosttySurface
  // widget's offset within the top-level (`mapTo(window(),
  // QPoint(0,0))`). wl_subsurface.set_position is double-buffered
  // on the *parent* surface — caller must trigger a parent commit
  // (Qt's QtWaylandClient::QWaylandWindow::commit()) for the new
  // position to apply. No-op if the position hasn't changed.
  void setPosition(int x, int y);

  // Detach the currently-attached buffer so the subsurface becomes
  // invisible. Called when the owning GhosttySurface hides (tab
  // switch) so the inactive pane's pixels don't ghost on top of
  // whatever the active tab is showing in the same on-screen
  // region. The next presentDmabuf call re-attaches a buffer and
  // the subsurface becomes visible again.
  void hide();

  // Re-attach + commit the most recently cached wl_buffer, if any.
  // Called from `QEvent::Show` so a tab-switch / re-show sees the
  // last frame immediately rather than a transparent area while
  // the renderer thread spins up its first new frame. Without this,
  // the parent surface paints through (WA_TranslucentBackground)
  // and the user sees a flash of whatever is behind the window.
  // No-op when the cache is empty (first show — there's nothing
  // to re-attach yet; caller is responsible for the new-tab flash
  // mitigation if needed).
  void reattachCached();

  // Called from the wp_fractional_scale_v1.preferred_scale event.
  // Public so the C-style listener struct at file scope in the .cpp
  // can name it; not part of the API for other call sites.
  static void onPreferredScale(void *data, wp_fractional_scale_v1 *,
                                uint32_t scale);

  SubsurfacePresenter(const SubsurfacePresenter &) = delete;
  SubsurfacePresenter &operator=(const SubsurfacePresenter &) = delete;

private:
  SubsurfacePresenter(wl_display *display, wl_surface *child,
                      wl_subsurface *sub, zwp_linux_dmabuf_v1 *dmabuf,
                      wp_viewport *viewport,
                      wp_fractional_scale_v1 *frac_scale);

  wl_display *m_display;
  wl_surface *m_childSurface;
  wl_subsurface *m_subsurface;
  zwp_linux_dmabuf_v1 *m_dmabuf;
  wp_viewport *m_viewport;
  wp_fractional_scale_v1 *m_fractionalScale;
  uint32_t m_preferredScale120 = 120; // default: 1.0×
  int m_lastDestWidth = 0;
  int m_lastDestHeight = 0;
  int m_lastX = 0;
  int m_lastY = 0;

  // wl_buffer cache. libghostty re-uses the same dmabuf fd across
  // frames until the next Target.deinit (i.e. until a resize), so
  // we can wrap the fd in a wl_buffer ONCE and re-attach it every
  // frame instead of round-tripping `create_immed` per present.
  // create_immed costs a Wayland round-trip + compositor-side
  // dmabuf import; at 125 FPS (animated post shader) with multiple
  // panes this was ~half of the GUI-thread CPU at idle. Invalidate
  // the cache when any of the dmabuf-shape inputs change.
  wl_buffer *m_cachedBuffer = nullptr;
  int m_cachedFd = -1;
  uint32_t m_cachedWidth = 0;
  uint32_t m_cachedHeight = 0;
  uint32_t m_cachedStride = 0;
  uint32_t m_cachedFormat = 0;
  uint64_t m_cachedModifier = 0;
  bool m_cachedYInvert = false;
};

} // namespace wayland
