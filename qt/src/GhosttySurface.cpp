#include "GhosttySurface.h"

#include <cstdio>

#include <QByteArray>
#include <QExposeEvent>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QResizeEvent>
#include <QString>
#include <QSurfaceFormat>
#include <QWheelEvent>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner)
    : m_app(app), m_owner(owner) {
  setSurfaceType(QWindow::OpenGLSurface);

  // Guide the platform's visual selection toward a GL-capable, opaque
  // config so the EGL window surface can be created against this window.
  QSurfaceFormat fmt;
  fmt.setRenderableType(QSurfaceFormat::OpenGL);
  fmt.setProfile(QSurfaceFormat::CoreProfile);
  fmt.setVersion(4, 3);
  fmt.setRedBufferSize(8);
  fmt.setGreenBufferSize(8);
  fmt.setBlueBufferSize(8);
  fmt.setAlphaBufferSize(0);
  setFormat(fmt);
}

GhosttySurface::~GhosttySurface() {
  // Freeing the surface stops libghostty's renderer thread, which calls
  // threadExit -> glReleaseCurrent before this returns.
  if (m_surface) ghostty_surface_free(m_surface);

  // Destroy this surface's own EGL objects, but NOT the EGLDisplay: it
  // is the process-wide default display shared by every surface, so
  // calling eglTerminate here would invalidate the other surfaces'
  // contexts. The display is released when the process exits.
  if (m_eglDisplay != EGL_NO_DISPLAY) {
    if (m_eglSurface != EGL_NO_SURFACE)
      eglDestroySurface(m_eglDisplay, m_eglSurface);
    if (m_eglContext != EGL_NO_CONTEXT)
      eglDestroyContext(m_eglDisplay, m_eglContext);
  }
}

bool GhosttySurface::initialize(ghostty_surface_t parent) {
  // Force native window creation so winId() is valid for EGL.
  create();

  if (!setupEgl()) {
    std::fprintf(stderr, "[ghostty-qt] EGL setup failed\n");
    return false;
  }

  // A new surface in a tab inherits the parent surface's working
  // directory etc.; the first surface uses a default config.
  ghostty_surface_config_s sc =
      parent ? ghostty_surface_inherited_config(parent,
                                                GHOSTTY_SURFACE_CONTEXT_TAB)
             : ghostty_surface_config_new();
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
  return true;
}

bool GhosttySurface::setupEgl() {
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
      EGL_CONTEXT_MAJOR_VERSION,       4,
      EGL_CONTEXT_MINOR_VERSION,       3,
      EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
      EGL_NONE,
  };
  m_eglContext =
      eglCreateContext(m_eglDisplay, config, EGL_NO_CONTEXT, contextAttribs);
  if (m_eglContext == EGL_NO_CONTEXT) return false;

  m_eglSurface = eglCreateWindowSurface(
      m_eglDisplay, config, static_cast<EGLNativeWindowType>(winId()),
      nullptr);
  if (m_eglSurface == EGL_NO_SURFACE) return false;

  return true;
}

void GhosttySurface::updateSize() {
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

void GhosttySurface::sendKey(QKeyEvent *ev, ghostty_input_action_e action) {
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

void GhosttySurface::sendMouseButton(QMouseEvent *ev,
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

// --- QWindow events --------------------------------------------------

void GhosttySurface::exposeEvent(QExposeEvent *) {
  if (!m_surface || !isExposed()) return;
  // devicePixelRatio() is only reliable once the window is on a screen,
  // so (re)sync the surface size here as well as in resizeEvent.
  updateSize();
  ghostty_surface_refresh(m_surface);
}

void GhosttySurface::resizeEvent(QResizeEvent *) { updateSize(); }

void GhosttySurface::keyPressEvent(QKeyEvent *ev) {
  sendKey(ev,
          ev->isAutoRepeat() ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS);
}

void GhosttySurface::keyReleaseEvent(QKeyEvent *ev) {
  // Qt synthesizes a release before each auto-repeat press; drop those.
  if (ev->isAutoRepeat()) return;
  sendKey(ev, GHOSTTY_ACTION_RELEASE);
}

void GhosttySurface::mousePressEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttySurface::mouseReleaseEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

void GhosttySurface::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_surface) return;
  const double dpr = devicePixelRatio();
  ghostty_surface_mouse_pos(m_surface, ev->position().x() * dpr,
                            ev->position().y() * dpr,
                            translateMods(ev->modifiers()));
}

void GhosttySurface::wheelEvent(QWheelEvent *ev) {
  if (!m_surface) return;
  // angleDelta is in eighths of a degree; 120 units == one wheel notch.
  const QPoint d = ev->angleDelta();
  ghostty_surface_mouse_scroll(m_surface, d.x() / 120.0, d.y() / 120.0, 0);
}

void GhosttySurface::focusInEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, true);
}

void GhosttySurface::focusOutEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, false);
}

// --- GL context callbacks (run on libghostty's renderer thread) ------

void *GhosttySurface::glGetProcAddress(void *, const char *name) {
  return reinterpret_cast<void *>(eglGetProcAddress(name));
}

void GhosttySurface::glMakeCurrent(void *ud) {
  auto *self = static_cast<GhosttySurface *>(ud);
  eglMakeCurrent(self->m_eglDisplay, self->m_eglSurface, self->m_eglSurface,
                 self->m_eglContext);
}

void GhosttySurface::glReleaseCurrent(void *ud) {
  auto *self = static_cast<GhosttySurface *>(ud);
  eglMakeCurrent(self->m_eglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE,
                 EGL_NO_CONTEXT);
}

void GhosttySurface::glPresent(void *ud) {
  auto *self = static_cast<GhosttySurface *>(ud);
  eglSwapBuffers(self->m_eglDisplay, self->m_eglSurface);
}
