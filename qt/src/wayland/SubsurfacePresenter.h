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
  // `buffer_scale` is the Wayland buffer scale factor (1 for stock
  // DPI, 2 for HiDPI, etc.) — set on the child surface so the
  // compositor scales the buffer correctly relative to the parent's
  // surface-local coordinates.
  void presentDmabuf(int fd, uint32_t drm_format, uint64_t drm_modifier,
                     uint32_t width, uint32_t height, uint32_t stride,
                     int buffer_scale);

  SubsurfacePresenter(const SubsurfacePresenter &) = delete;
  SubsurfacePresenter &operator=(const SubsurfacePresenter &) = delete;

private:
  SubsurfacePresenter(wl_display *display, wl_surface *child,
                      wl_subsurface *sub, zwp_linux_dmabuf_v1 *dmabuf);

  wl_display *m_display;
  wl_surface *m_childSurface;
  wl_subsurface *m_subsurface;
  zwp_linux_dmabuf_v1 *m_dmabuf;
  int m_lastBufferScale = 0;
};

} // namespace wayland
