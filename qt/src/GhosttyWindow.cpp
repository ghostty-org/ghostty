#include "GhosttyWindow.h"

#include <cstdio>

#include <QByteArray>
#include <QExposeEvent>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QResizeEvent>
#include <QString>
#include <QSurfaceFormat>
#include <QTimer>
#include <QWheelEvent>

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
  // No alpha: the window should be opaque, not composited against the
  // desktop. (Background transparency would be a deliberate later opt-in.)
  fmt.setAlphaBufferSize(0);
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
      EGL_NONE,
  };
  EGLConfig configs[64];
  EGLint numConfigs = 0;
  if (!eglChooseConfig(m_eglDisplay, configAttribs, configs, 64, &numConfigs) ||
      numConfigs < 1)
    return false;

  // EGL color-size attributes are minimums, so eglChooseConfig may still
  // return alpha-bearing configs. Pick one with no alpha channel so the
  // window surface is opaque.
  EGLConfig config = configs[0];
  for (EGLint i = 0; i < numConfigs; ++i) {
    EGLint alpha = 0;
    eglGetConfigAttrib(m_eglDisplay, configs[i], EGL_ALPHA_SIZE, &alpha);
    if (alpha == 0) {
      config = configs[i];
      break;
    }
  }

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

// Translate Qt keyboard modifiers into libghostty's modifier bitfield.
static ghostty_input_mods_e translateMods(Qt::KeyboardModifiers m) {
  int r = GHOSTTY_MODS_NONE;
  if (m & Qt::ShiftModifier) r |= GHOSTTY_MODS_SHIFT;
  if (m & Qt::ControlModifier) r |= GHOSTTY_MODS_CTRL;
  if (m & Qt::AltModifier) r |= GHOSTTY_MODS_ALT;
  if (m & Qt::MetaModifier) r |= GHOSTTY_MODS_SUPER;
  return static_cast<ghostty_input_mods_e>(r);
}

void GhosttyWindow::sendKey(QKeyEvent *ev, ghostty_input_action_e action) {
  if (!m_surface) return;

  // Forward committed text only for printable input; control characters
  // and special keys (Enter, Tab, arrows, Ctrl+letter, ...) are encoded
  // by libghostty from the physical keycode + modifiers.
  const QByteArray text = ev->text().toUtf8();
  const bool printable =
      !text.isEmpty() &&
      static_cast<unsigned char>(text.front()) >= 0x20 &&
      static_cast<unsigned char>(text.front()) != 0x7f;

  // Unshifted codepoint, used for keybind matching (letters and digits).
  uint32_t unshifted = 0;
  const int key = ev->key();
  if (key >= Qt::Key_A && key <= Qt::Key_Z)
    unshifted = static_cast<uint32_t>('a' + (key - Qt::Key_A));
  else if (key >= Qt::Key_0 && key <= Qt::Key_9)
    unshifted = static_cast<uint32_t>('0' + (key - Qt::Key_0));

  ghostty_input_key_s k = {};
  k.action = action;
  k.mods = translateMods(ev->modifiers());
  k.consumed_mods = GHOSTTY_MODS_NONE;
  // On the xcb platform nativeScanCode() is the X11/XKB keycode, which
  // is exactly what libghostty expects as the native keycode on Linux.
  k.keycode = ev->nativeScanCode();
  k.text = printable ? text.constData() : nullptr;
  k.unshifted_codepoint = unshifted;
  k.composing = false;

  ghostty_surface_key(m_surface, k);
}

void GhosttyWindow::sendMouseButton(QMouseEvent *ev,
                                    ghostty_input_mouse_state_e state) {
  if (!m_surface) return;
  ghostty_input_mouse_button_e button;
  switch (ev->button()) {
    case Qt::LeftButton: button = GHOSTTY_MOUSE_LEFT; break;
    case Qt::RightButton: button = GHOSTTY_MOUSE_RIGHT; break;
    case Qt::MiddleButton: button = GHOSTTY_MOUSE_MIDDLE; break;
    default: button = GHOSTTY_MOUSE_UNKNOWN; break;
  }
  ghostty_surface_mouse_button(m_surface, state, button,
                               translateMods(ev->modifiers()));
}

void GhosttyWindow::tick() {
  if (m_app) ghostty_app_tick(m_app);
  if (m_surface && ghostty_surface_process_exited(m_surface)) close();
}

// --- QWindow events --------------------------------------------------

void GhosttyWindow::exposeEvent(QExposeEvent *) {
  if (!m_surface || !isExposed()) return;
  // devicePixelRatio() is only reliable once the window is on a screen,
  // so (re)sync the surface size here as well as in resizeEvent.
  updateSize();
  ghostty_surface_refresh(m_surface);
}

void GhosttyWindow::resizeEvent(QResizeEvent *) { updateSize(); }

void GhosttyWindow::keyPressEvent(QKeyEvent *ev) {
  sendKey(ev, ev->isAutoRepeat() ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS);
}

void GhosttyWindow::keyReleaseEvent(QKeyEvent *ev) {
  // Qt synthesizes a release before each auto-repeat press; drop those.
  if (ev->isAutoRepeat()) return;
  sendKey(ev, GHOSTTY_ACTION_RELEASE);
}

void GhosttyWindow::mousePressEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttyWindow::mouseReleaseEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

void GhosttyWindow::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_surface) return;
  const double dpr = devicePixelRatio();
  ghostty_surface_mouse_pos(m_surface, ev->position().x() * dpr,
                            ev->position().y() * dpr,
                            translateMods(ev->modifiers()));
}

void GhosttyWindow::wheelEvent(QWheelEvent *ev) {
  if (!m_surface) return;
  // angleDelta is in eighths of a degree; 120 units == one wheel notch.
  const QPoint d = ev->angleDelta();
  ghostty_surface_mouse_scroll(m_surface, d.x() / 120.0, d.y() / 120.0, 0);
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
