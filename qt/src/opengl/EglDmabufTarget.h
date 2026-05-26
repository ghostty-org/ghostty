// Dmabuf-exporting GL render target for the OpenGL present path.
//
// libghostty's GL renderer draws into a host-owned framebuffer (see
// GhosttySurface's `m_fbo`). Today that framebuffer's pixels get
// pulled back through `glReadPixels` (via `QOpenGLFramebufferObject::toImage`)
// into a QImage, then re-uploaded to the QWidget backing store by
// QPainter. After this class is wired in, the host instead allocates
// a GL texture, wraps it as an `EGLImage` via `eglCreateImage`,
// exports its memory as a dmabuf via `eglExportDMABUFImageMESA`,
// and attaches that texture to a GL framebuffer for libghostty to
// draw into. The cached dmabuf fd / fourcc / modifier / stride are
// then handed straight to the `wayland::SubsurfacePresenter` — same
// zero-copy path the Vulkan renderer's Target uses, just sourced
// from EGL instead of Vulkan.
//
// Requires `EGL_MESA_image_dma_buf_export` (checked by the static
// `available()` predicate). Wayland-only by project decision.

#pragma once

#include <cstdint>
#include <memory>

class QOpenGLContext;

namespace opengl {

class EglDmabufTarget {
public:
  // Detect at runtime whether the current EGL display advertises
  // `EGL_MESA_image_dma_buf_export`. Caller MUST have a Wayland QPA
  // and `ctx` must be a usable, makeCurrent-able QOpenGLContext.
  // Cached after first call.
  static bool available(QOpenGLContext *ctx);

  // Build a target of the given device-pixel size. Returns nullptr
  // on any EGL / GL failure (caller falls back to the legacy
  // QOpenGLFramebufferObject + toImage path). `ctx` must be current
  // on the calling thread when called.
  static std::unique_ptr<EglDmabufTarget> create(QOpenGLContext *ctx,
                                                  int width_px,
                                                  int height_px);

  ~EglDmabufTarget();

  // Bind the framebuffer for draw operations. Caller is responsible
  // for `glViewport` / `glClear` etc. Mirrors `QOpenGLFramebufferObject::bind`.
  void bind() const;
  void release() const;

  // Pixel + dmabuf metadata. Stable for the lifetime of this target;
  // resize allocates a new target. `stride` is the value returned by
  // `eglExportDMABUFImageMESA` for plane 0.
  int width() const { return m_width; }
  int height() const { return m_height; }
  int fd() const { return m_fd; }
  std::uint32_t drmFormat() const { return m_drmFormat; }
  std::uint64_t drmModifier() const { return m_drmModifier; }
  std::uint32_t stride() const { return m_stride; }
  // Raw GL framebuffer object id for glBlitFramebuffer callers that
  // need to write into the dmabuf-backed FBO from a different
  // attached target (e.g. blitting from m_fbo with an inverted dst
  // rect to flip Y, since the linux-dmabuf-v1 Y_INVERT flag is not
  // universally supported).
  unsigned int framebuffer() const { return m_framebuffer; }

  EglDmabufTarget(const EglDmabufTarget &) = delete;
  EglDmabufTarget &operator=(const EglDmabufTarget &) = delete;

private:
  EglDmabufTarget();

  // Opaque to callers (and avoids leaking EGL/GL handle types into
  // the header). The .cpp owns the EGLDisplay/EGLImage casts.
  void *m_eglDisplay = nullptr;
  void *m_eglImage = nullptr;
  unsigned int m_texture = 0;
  unsigned int m_framebuffer = 0;
  int m_width = 0;
  int m_height = 0;
  int m_fd = -1;
  std::uint32_t m_drmFormat = 0;
  std::uint64_t m_drmModifier = 0;
  std::uint32_t m_stride = 0;
};

} // namespace opengl
