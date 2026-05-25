#include "EglDmabufTarget.h"

#include <cstdio>
#include <cstring>
#include <unistd.h>

#include <QOpenGLContext>
#include <QOpenGLFunctions>

#include <EGL/egl.h>
#include <EGL/eglext.h>

namespace wayland {

namespace {

// EGL_MESA_image_dma_buf_export entry points (loaded once per
// process). Resolved via `eglGetProcAddress`, which returns null if
// the extension isn't present.
using PFNeglExportDMABUFImageQueryMESA =
    EGLBoolean (*)(EGLDisplay dpy, EGLImageKHR image, int *fourcc,
                   int *num_planes, EGLuint64KHR *modifiers);
using PFNeglExportDMABUFImageMESA =
    EGLBoolean (*)(EGLDisplay dpy, EGLImageKHR image, int *fds,
                   EGLint *strides, EGLint *offsets);

struct EglFns {
  PFNEGLCREATEIMAGEKHRPROC createImage = nullptr;
  PFNEGLDESTROYIMAGEKHRPROC destroyImage = nullptr;
  PFNeglExportDMABUFImageQueryMESA queryExport = nullptr;
  PFNeglExportDMABUFImageMESA exportImage = nullptr;
  bool resolved = false;
  bool available = false;
};

EglFns &eglFns() {
  static EglFns f;
  return f;
}

bool ensureEglFns(EGLDisplay display) {
  EglFns &f = eglFns();
  if (f.resolved) return f.available;
  f.resolved = true;

  const char *exts = eglQueryString(display, EGL_EXTENSIONS);
  if (!exts) return false;
  auto hasExt = [exts](const char *name) {
    const std::size_t n = std::strlen(name);
    const char *p = exts;
    while ((p = std::strstr(p, name)) != nullptr) {
      if ((p == exts || p[-1] == ' ') && (p[n] == '\0' || p[n] == ' '))
        return true;
      p += n;
    }
    return false;
  };
  if (!hasExt("EGL_KHR_image_base") ||
      !hasExt("EGL_MESA_image_dma_buf_export")) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: EGL display lacks "
                 "EGL_KHR_image_base or EGL_MESA_image_dma_buf_export\n");
    return false;
  }

  f.createImage = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
      eglGetProcAddress("eglCreateImageKHR"));
  f.destroyImage = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
      eglGetProcAddress("eglDestroyImageKHR"));
  f.queryExport = reinterpret_cast<PFNeglExportDMABUFImageQueryMESA>(
      eglGetProcAddress("eglExportDMABUFImageQueryMESA"));
  f.exportImage = reinterpret_cast<PFNeglExportDMABUFImageMESA>(
      eglGetProcAddress("eglExportDMABUFImageMESA"));
  if (!f.createImage || !f.destroyImage || !f.queryExport ||
      !f.exportImage) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: eglGetProcAddress returned "
                 "null for required entry points\n");
    return false;
  }
  f.available = true;
  return true;
}

EGLDisplay currentEglDisplay() {
  return eglGetCurrentDisplay();
}

// GL constants come from <QOpenGLFunctions> indirectly via the Qt
// GL headers — GL_TEXTURE_2D / GL_RGBA8 / GL_FRAMEBUFFER etc. are
// in scope without further includes.

} // namespace

bool EglDmabufTarget::available(QOpenGLContext *ctx) {
  if (!ctx) return false;
  if (!ctx->isValid()) return false;
  EGLDisplay dpy = currentEglDisplay();
  if (dpy == EGL_NO_DISPLAY) {
    std::fprintf(
        stderr,
        "[ghastty] EglDmabufTarget: no current EGL display (call after "
        "QOpenGLContext::makeCurrent on a Wayland QPA)\n");
    return false;
  }
  return ensureEglFns(dpy);
}

std::unique_ptr<EglDmabufTarget> EglDmabufTarget::create(QOpenGLContext *ctx,
                                                          int width_px,
                                                          int height_px) {
  if (!ctx || !ctx->isValid()) return nullptr;
  if (width_px <= 0 || height_px <= 0) return nullptr;
  EGLDisplay dpy = currentEglDisplay();
  if (dpy == EGL_NO_DISPLAY) return nullptr;
  if (!ensureEglFns(dpy)) return nullptr;
  const EglFns &fns = eglFns();
  auto *gl = ctx->functions();
  if (!gl) return nullptr;

  // We populate `target->m_*` AS we acquire each resource; on any
  // failure we just `return nullptr` and let the unique_ptr's
  // destructor unwind everything that's been stored so far. This is
  // the only cleanup path — no manual gl->glDeleteTextures /
  // ::close(fd) on early returns, which previously double-freed the
  // texture and made the cleanup logic asymmetric per branch.
  auto target = std::unique_ptr<EglDmabufTarget>(new EglDmabufTarget());
  target->m_eglDisplay = dpy;
  target->m_width = width_px;
  target->m_height = height_px;

  // 1. Allocate a GL texture sized to the desired framebuffer.
  unsigned int tex = 0;
  gl->glGenTextures(1, &tex);
  if (tex == 0) return nullptr;
  target->m_texture = tex;
  gl->glBindTexture(GL_TEXTURE_2D, tex);
  gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  gl->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  gl->glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width_px, height_px, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, nullptr);
  gl->glBindTexture(GL_TEXTURE_2D, 0);

  // 2. Wrap as an EGLImage targeting the GL texture.
  EGLImageKHR img = fns.createImage(
      dpy, ctx->nativeInterface<QNativeInterface::QEGLContext>()
               ? reinterpret_cast<EGLContext>(
                     ctx->nativeInterface<QNativeInterface::QEGLContext>()
                         ->nativeContext())
               : eglGetCurrentContext(),
      EGL_GL_TEXTURE_2D_KHR,
      reinterpret_cast<EGLClientBuffer>(static_cast<uintptr_t>(tex)), nullptr);
  if (img == EGL_NO_IMAGE_KHR) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: eglCreateImageKHR failed (0x%x)\n",
                 eglGetError());
    return nullptr;
  }
  target->m_eglImage = img;

  // 3. Query the export metadata (fourcc, plane count, modifier).
  int fourcc = 0;
  int num_planes = 0;
  EGLuint64KHR modifier = 0;
  if (!fns.queryExport(dpy, img, &fourcc, &num_planes, &modifier)) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: eglExportDMABUFImageQueryMESA "
                 "failed (0x%x)\n",
                 eglGetError());
    return nullptr;
  }
  if (num_planes != 1) {
    // Multi-plane modifiers need a wider present-callback ABI on the
    // subsurface side. NVIDIA / Mesa default tilings for RGBA are
    // single-plane in practice; refuse multi-plane cleanly and fall
    // back to the QImage path.
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: refusing multi-plane export "
                 "(num_planes=%d fourcc=0x%x mod=0x%llx)\n",
                 num_planes, fourcc,
                 static_cast<unsigned long long>(modifier));
    return nullptr;
  }
  target->m_drmFormat = static_cast<std::uint32_t>(fourcc);
  target->m_drmModifier = static_cast<std::uint64_t>(modifier);

  // 4. Export the dmabuf fd + per-plane stride/offset.
  int fd = -1;
  EGLint stride = 0;
  EGLint offset = 0;
  if (!fns.exportImage(dpy, img, &fd, &stride, &offset) || fd < 0) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: eglExportDMABUFImageMESA failed "
                 "(0x%x fd=%d)\n",
                 eglGetError(), fd);
    return nullptr;
  }
  target->m_fd = fd;
  target->m_stride = static_cast<std::uint32_t>(stride);

  // 5. Attach to a framebuffer so libghostty can render into it.
  unsigned int fbo = 0;
  gl->glGenFramebuffers(1, &fbo);
  if (fbo == 0) return nullptr;
  target->m_framebuffer = fbo;
  gl->glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  gl->glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                             GL_TEXTURE_2D, tex, 0);
  const unsigned int status = gl->glCheckFramebufferStatus(GL_FRAMEBUFFER);
  gl->glBindFramebuffer(GL_FRAMEBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    std::fprintf(stderr,
                 "[ghastty] EglDmabufTarget: framebuffer incomplete (0x%x)\n",
                 status);
    return nullptr;
  }

  std::fprintf(stderr,
               "[ghastty] EglDmabufTarget: %dx%d fd=%d fourcc=0x%x mod=0x%llx "
               "stride=%u\n",
               width_px, height_px, fd, target->m_drmFormat,
               static_cast<unsigned long long>(target->m_drmModifier),
               target->m_stride);
  return target;
}

EglDmabufTarget::EglDmabufTarget() = default;

EglDmabufTarget::~EglDmabufTarget() {
  // Caller must ensure the owning QOpenGLContext is current; on
  // GhosttySurface destruction we go through `makeCurrent` first.
  auto ctx = QOpenGLContext::currentContext();
  if (ctx) {
    auto *gl = ctx->functions();
    if (m_framebuffer) gl->glDeleteFramebuffers(1, &m_framebuffer);
    if (m_texture) gl->glDeleteTextures(1, &m_texture);
  }
  if (m_eglImage && m_eglDisplay) {
    eglFns().destroyImage(m_eglDisplay, m_eglImage);
  }
  if (m_fd >= 0) ::close(m_fd);
}

void EglDmabufTarget::bind() const {
  auto ctx = QOpenGLContext::currentContext();
  if (!ctx || !m_framebuffer) return;
  ctx->functions()->glBindFramebuffer(GL_FRAMEBUFFER, m_framebuffer);
}

void EglDmabufTarget::release() const {
  auto ctx = QOpenGLContext::currentContext();
  if (!ctx) return;
  ctx->functions()->glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

} // namespace wayland
