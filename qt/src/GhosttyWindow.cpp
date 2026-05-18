#include "GhosttyWindow.h"

#include <atomic>
#include <cstdio>

#include <QByteArray>
#include <QExposeEvent>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QResizeEvent>
#include <QString>
#include <QSurfaceFormat>
#include <QTimer>

// Count of presented frames, bumped from the renderer thread. A rising
// value confirms the OpenGL embedded render path is producing frames.
static std::atomic<unsigned> s_frameCount{0};

GhosttyWindow::GhosttyWindow() {
  setSurfaceType(QWindow::OpenGLSurface);
  setTitle(QStringLiteral("Ghostty (Qt)"));

  // Guide the platform's visual selection toward a GL-capable config so
  // the EGL window surface can be created against this window.
  QSurfaceFormat fmt;
  fmt.setRenderableType(QSurfaceFormat::OpenGL);
  fmt.setProfile(QSurfaceFormat::CoreProfile);
  fmt.setVersion(4, 3);
  fmt.setRedBufferSize(8);
  fmt.setGreenBufferSize(8);
  fmt.setBlueBufferSize(8);
  fmt.setAlphaBufferSize(8);
  setFormat(fmt);
}

GhosttyWindow::~GhosttyWindow() {
  // Freeing the surface stops libghostty's renderer thread, which calls
  // threadExit -> glReleaseCurrent before this returns.
  if (m_surface) ghostty_surface_free(m_surface);
  if (m_app) ghostty_app_free(m_app);
  if (m_config) ghostty_config_free(m_config);

  if (m_eglDisplay != EGL_NO_DISPLAY) {
    if (m_eglSurface != EGL_NO_SURFACE)
      eglDestroySurface(m_eglDisplay, m_eglSurface);
    if (m_eglContext != EGL_NO_CONTEXT)
      eglDestroyContext(m_eglDisplay, m_eglContext);
    eglTerminate(m_eglDisplay);
  }
}

bool GhosttyWindow::initialize() {
  // Force native window creation so winId() is valid for EGL.
  create();

  if (!setupEgl()) {
    std::fprintf(stderr, "[ghostty-qt] EGL setup failed\n");
    return false;
  }

  m_config = ghostty_config_new();
  ghostty_config_finalize(m_config);

  // App-level runtime config.
  ghostty_runtime_config_s rt = {};
  rt.userdata = this;
  rt.supports_selection_clipboard = true;
  rt.wakeup_cb = onWakeup;
  rt.action_cb = onAction;
  rt.read_clipboard_cb = onReadClipboard;
  rt.confirm_read_clipboard_cb = onConfirmReadClipboard;
  rt.write_clipboard_cb = onWriteClipboard;
  rt.close_surface_cb = onCloseSurface;

  m_app = ghostty_app_new(&rt, m_config);
  if (!m_app) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_app_new failed\n");
    return false;
  }

  // Surface config: hand libghostty our EGL context via callbacks.
  ghostty_surface_config_s sc = ghostty_surface_config_new();
  sc.platform_tag = GHOSTTY_PLATFORM_OPENGL;
  sc.platform.opengl.userdata = this;
  sc.platform.opengl.get_proc_address = glGetProcAddress;
  sc.platform.opengl.make_current = glMakeCurrent;
  sc.platform.opengl.release_current = glReleaseCurrent;
  sc.platform.opengl.present = glPresent;
  sc.userdata = this;
  sc.scale_factor = devicePixelRatio();

  // ghostty_surface_new runs the renderer's init synchronously on this
  // (the GUI) thread: it makes our EGL context current, builds GL
  // objects, then releases it again before spawning the renderer thread.
  m_surface = ghostty_surface_new(m_app, &sc);
  if (!m_surface) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_surface_new failed\n");
    return false;
  }

  updateSize();
  ghostty_surface_set_focus(m_surface, true);

  // Periodic tick as a backstop; onWakeup drives responsive ticking.
  auto *timer = new QTimer(this);
  connect(timer, &QTimer::timeout, this, &GhosttyWindow::tick);
  timer->start(16);

  return true;
}

bool GhosttyWindow::setupEgl() {
  m_eglDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (m_eglDisplay == EGL_NO_DISPLAY) return false;
  if (!eglInitialize(m_eglDisplay, nullptr, nullptr)) return false;

  // Ghostty's renderer uses desktop OpenGL, not GLES.
  if (!eglBindAPI(EGL_OPENGL_API)) return false;

  const EGLint configAttribs[] = {
      EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
      EGL_RED_SIZE,        8,
      EGL_GREEN_SIZE,      8,
      EGL_BLUE_SIZE,       8,
      EGL_ALPHA_SIZE,      8,
      EGL_NONE,
  };
  EGLConfig config = nullptr;
  EGLint numConfigs = 0;
  if (!eglChooseConfig(m_eglDisplay, configAttribs, &config, 1, &numConfigs) ||
      numConfigs < 1)
    return false;

  // Ghostty's OpenGL renderer requires at least OpenGL 4.3 core.
  const EGLint contextAttribs[] = {
      EGL_CONTEXT_MAJOR_VERSION,        4,
      EGL_CONTEXT_MINOR_VERSION,        3,
      EGL_CONTEXT_OPENGL_PROFILE_MASK,  EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
      EGL_NONE,
  };
  m_eglContext =
      eglCreateContext(m_eglDisplay, config, EGL_NO_CONTEXT, contextAttribs);
  if (m_eglContext == EGL_NO_CONTEXT) return false;

  m_eglSurface = eglCreateWindowSurface(
      m_eglDisplay, config,
      static_cast<EGLNativeWindowType>(winId()), nullptr);
  if (m_eglSurface == EGL_NO_SURFACE) return false;

  return true;
}

void GhosttyWindow::updateSize() {
  if (!m_surface) return;
  const double dpr = devicePixelRatio();
  const int w = static_cast<int>(width() * dpr);
  const int h = static_cast<int>(height() * dpr);
  ghostty_surface_set_content_scale(m_surface, dpr, dpr);
  if (w > 0 && h > 0)
    ghostty_surface_set_size(m_surface, static_cast<uint32_t>(w),
                             static_cast<uint32_t>(h));
}

void GhosttyWindow::pushText(const QString &text) {
  if (!m_surface || text.isEmpty()) return;
  const QByteArray utf8 = text.toUtf8();
  ghostty_surface_text(m_surface, utf8.constData(),
                       static_cast<uintptr_t>(utf8.size()));
}

void GhosttyWindow::tick() {
  if (m_app) ghostty_app_tick(m_app);
  if (m_surface && ghostty_surface_process_exited(m_surface)) {
    close();
    return;
  }
  // Scaffold heartbeat: report presented frames roughly once a second.
  if (++m_tickCount % 60 == 0)
    std::fprintf(stderr, "[ghostty-qt] frames presented: %u\n",
                 s_frameCount.load());
}

// --- QWindow events --------------------------------------------------

void GhosttyWindow::exposeEvent(QExposeEvent *) {
  if (m_surface && isExposed()) ghostty_surface_refresh(m_surface);
}

void GhosttyWindow::resizeEvent(QResizeEvent *) { updateSize(); }

void GhosttyWindow::keyPressEvent(QKeyEvent *ev) {
  // TODO(B3): full key translation via ghostty_surface_key -- control
  // sequences, arrows, function keys, modifiers. For the scaffold we
  // forward committed text only, which covers typing and Enter.
  pushText(ev->text());
}

void GhosttyWindow::focusInEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, true);
}

void GhosttyWindow::focusOutEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, false);
}

// --- GL context callbacks (run on libghostty's renderer thread) ------

void *GhosttyWindow::glGetProcAddress(void *, const char *name) {
  return reinterpret_cast<void *>(eglGetProcAddress(name));
}

void GhosttyWindow::glMakeCurrent(void *ud) {
  auto *self = static_cast<GhosttyWindow *>(ud);
  eglMakeCurrent(self->m_eglDisplay, self->m_eglSurface, self->m_eglSurface,
                 self->m_eglContext);
}

void GhosttyWindow::glReleaseCurrent(void *ud) {
  auto *self = static_cast<GhosttyWindow *>(ud);
  eglMakeCurrent(self->m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                 EGL_NO_CONTEXT);
}

void GhosttyWindow::glPresent(void *ud) {
  auto *self = static_cast<GhosttyWindow *>(ud);
  eglSwapBuffers(self->m_eglDisplay, self->m_eglSurface);
  s_frameCount.fetch_add(1);
}

// --- libghostty runtime callbacks ------------------------------------

void GhosttyWindow::onWakeup(void *ud) {
  // Called from a libghostty thread; hop to the GUI thread to tick.
  auto *self = static_cast<GhosttyWindow *>(ud);
  QMetaObject::invokeMethod(self, "tick", Qt::QueuedConnection);
}

bool GhosttyWindow::onAction(ghostty_app_t, ghostty_target_s,
                             ghostty_action_s) {
  // TODO(C): handle actions -- title changes, new tab/split/window,
  // fullscreen, clipboard confirmations, etc.
  return false;
}

bool GhosttyWindow::onReadClipboard(void *, ghostty_clipboard_e, void *) {
  // TODO(B4): wire QClipboard.
  return false;
}

void GhosttyWindow::onConfirmReadClipboard(void *, const char *, void *,
                                           ghostty_clipboard_request_e) {
  // TODO(B4): paste confirmation dialog.
}

void GhosttyWindow::onWriteClipboard(void *, ghostty_clipboard_e,
                                     const ghostty_clipboard_content_s *,
                                     size_t, bool) {
  // TODO(B4): wire QClipboard.
}

void GhosttyWindow::onCloseSurface(void *ud, bool) {
  auto *self = static_cast<GhosttyWindow *>(ud);
  QMetaObject::invokeMethod(self, "close", Qt::QueuedConnection);
}
