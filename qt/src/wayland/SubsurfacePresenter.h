// Wayland subsurface presenter for `GhosttySurface`.
//
// Owns one `wl_subsurface` parented to the `GhosttySurface`'s native
// `wl_surface`, plus the `zwp_linux_dmabuf_v1` machinery for wrapping
// libghostty's dmabuf fds in `wl_buffer`s and attaching them to that
// subsurface. The compositor scans the buffers out directly — no
// mmap, no memcpy, no QImage, no QPainter blit on the present path.
//
// Also exposes the process-wide compositor modifier registry
// (`primeDmabufModifierRegistry` / `supportedDmabufModifiers`)
// learned from zwp_linux_dmabuf_v1's format/modifier events.
// libghostty's Vulkan renderer queries this via the
// `get_supported_modifiers` platform callback to pick a modifier
// the compositor will actually accept — without that intersection,
// drivers that don't expose COLOR_ATTACHMENT for LINEAR (NVIDIA)
// can't get into Target's direct-export mode at all.
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

struct wl_display;
struct wl_subsurface;
struct wl_surface;
struct zwp_linux_dmabuf_v1;
struct wp_viewport;
struct wp_fractional_scale_v1;
class QWindow;

namespace wayland {

// Eagerly discover the compositor's globals (incl. the
// zwp_linux_dmabuf_v1 format/modifier list) on the calling thread.
// MUST be called from the GUI thread before any
// `supportedDmabufModifiers` reader runs (the renderer thread). Safe
// to call multiple times — discovery happens exactly once.
//
// Idempotent no-op if the QPA isn't Wayland or the
// QPlatformNativeInterface lookup fails.
void primeDmabufModifierRegistry();

// Read the cached compositor-supported DRM modifiers for the given
// DRM_FORMAT_* fourcc. Returns the number of modifiers actually
// written to `out` (capped at `capacity`). Pass `out=nullptr,
// capacity=0` to query the total count.
//
// Thread-safe for readers once `primeDmabufModifierRegistry` has
// returned. Returns 0 if the registry hasn't been primed yet or the
// format isn't advertised.
std::size_t supportedDmabufModifiers(std::uint32_t drm_format,
                                     std::uint64_t *out,
                                     std::size_t capacity);

class SubsurfacePresenter {
public:
  // Build a subsurface parented to `parent`'s native `wl_surface`,
  // and bind the linux-dmabuf-v1 global on the same display.
  // Returns nullptr if any prerequisite is missing (non-Wayland QPA,
  // null `wl_display`, `wl_subcompositor` unbindable,
  // `zwp_linux_dmabuf_v1` unbindable, etc.).
  //
  // Forcing `Qt::WA_NativeWindow` on the caller is the *caller's*
  // responsibility — `tryCreate` only reads `parent->surfaceHandle`.
  static std::unique_ptr<SubsurfacePresenter> tryCreate(QWindow *parent);

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
  void presentDmabuf(int fd, uint32_t drm_format, uint64_t drm_modifier,
                     uint32_t width, uint32_t height, uint32_t stride,
                     int dest_width, int dest_height);

  // Compositor-preferred fractional scale for this surface, in
  // units of 1/120 (e.g. 144 = 1.2, 180 = 1.5, 240 = 2.0). Returns
  // 120 (= 1.0) until the compositor sends its first
  // wp_fractional_scale_v1.preferred_scale event for our surface.
  // Renderer / GhosttySurface size their buffers at
  // `logical * preferredScale120() / 120` device pixels.
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
};

} // namespace wayland
