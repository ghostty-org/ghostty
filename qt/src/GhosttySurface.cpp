#include "GhosttySurface.h"

#include <cstdio>

#include <QByteArray>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QString>
#include <QWheelEvent>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner,
                               ghostty_surface_t parent_surface)
    : m_app(app), m_owner(owner), m_parentSurface(parent_surface) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);  // deliver motion events for hover/link detection
}

GhosttySurface::~GhosttySurface() {
  if (m_surface) {
    // The renderer releases GL objects during teardown, so do it with
    // our context current.
    makeCurrent();
    ghostty_surface_free(m_surface);
    doneCurrent();
  }
}

// --- QOpenGLWidget --------------------------------------------------

void GhosttySurface::initializeGL() {
  // The context is current. Create the libghostty surface now so the
  // renderer's GL objects are created in this widget's context.
  ghostty_surface_config_s sc =
      m_parentSurface
          ? ghostty_surface_inherited_config(m_parentSurface,
                                             GHOSTTY_SURFACE_CONTEXT_TAB)
          : ghostty_surface_config_new();
  sc.platform_tag = GHOSTTY_PLATFORM_OPENGL;
  sc.platform.opengl.userdata = this;
  sc.platform.opengl.get_proc_address = glGetProcAddress;
  sc.platform.opengl.make_current = glMakeCurrent;
  sc.platform.opengl.release_current = glReleaseCurrent;
  sc.platform.opengl.present = glPresent;
  sc.userdata = this;
  sc.scale_factor = devicePixelRatioF();

  m_surface = ghostty_surface_new(m_app, &sc);
  if (!m_surface) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_surface_new failed\n");
    return;
  }
  ghostty_surface_set_focus(m_surface, hasFocus());
}

void GhosttySurface::paintGL() {
  // libghostty renders into the framebuffer QOpenGLWidget has bound.
  if (!m_surface) return;
  syncSize();
  ghostty_surface_draw(m_surface);
}

void GhosttySurface::resizeGL(int, int) {
  // The framebuffer was resized; request a repaint. paintGL reads the
  // GL viewport, which is the authoritative framebuffer size.
  update();
}

void GhosttySurface::syncSize() {
  if (!m_surface) return;

  // QOpenGLWidget sets the GL viewport to its framebuffer's true size
  // before paintGL. That is the size libghostty must render into — it
  // is NOT width() * devicePixelRatio(): on a fractional-scale Wayland
  // output the framebuffer uses the fractional scale, while
  // devicePixelRatio() reports a rounded-up integer.
  int vp[4] = {0, 0, 0, 0};
  QOpenGLContext::currentContext()->functions()->glGetIntegerv(0x0BA2, vp);
  const int fbw = vp[2], fbh = vp[3];
  if (fbw <= 0 || fbh <= 0) return;
  if (fbw == m_lastW && fbh == m_lastH) return;
  m_lastW = fbw;
  m_lastH = fbh;

  // Content scale is the framebuffer-to-logical ratio (the real
  // display scale), so libghostty sizes the font correctly.
  const double sx = width() > 0 ? static_cast<double>(fbw) / width() : 1.0;
  const double sy = height() > 0 ? static_cast<double>(fbh) / height() : 1.0;
  ghostty_surface_set_content_scale(m_surface, sx, sy);
  ghostty_surface_set_size(m_surface, static_cast<uint32_t>(fbw),
                           static_cast<uint32_t>(fbh));
}

// --- input ----------------------------------------------------------

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
  // On xcb nativeScanCode() is the X11/XKB keycode; the Wayland plugin
  // likewise reports the XKB keycode, which is libghostty's Linux native.
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
  setFocus();
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttySurface::mouseReleaseEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

void GhosttySurface::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_surface) return;
  const double dpr = devicePixelRatioF();
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

// --- libghostty GL platform callbacks --------------------------------

void *GhosttySurface::glGetProcAddress(void *, const char *name) {
  QOpenGLContext *ctx = QOpenGLContext::currentContext();
  return ctx ? reinterpret_cast<void *>(ctx->getProcAddress(name)) : nullptr;
}

void GhosttySurface::glMakeCurrent(void *ud) {
  static_cast<GhosttySurface *>(ud)->makeCurrent();
}

void GhosttySurface::glReleaseCurrent(void *) {
  // No-op: QOpenGLWidget manages context currency around paintGL.
}

void GhosttySurface::glPresent(void *) {
  // No-op: Qt composites the widget's framebuffer and swaps the window.
}
