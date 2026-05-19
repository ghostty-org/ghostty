#include "InspectorWindow.h"

#include <QCloseEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QPainter>
#include <QSurfaceFormat>
#include <QTimer>
#include <QWheelEvent>

namespace {

ghostty_input_mods_e translateMods(Qt::KeyboardModifiers m) {
  int r = GHOSTTY_MODS_NONE;
  if (m & Qt::ShiftModifier) r |= GHOSTTY_MODS_SHIFT;
  if (m & Qt::ControlModifier) r |= GHOSTTY_MODS_CTRL;
  if (m & Qt::AltModifier) r |= GHOSTTY_MODS_ALT;
  if (m & Qt::MetaModifier) r |= GHOSTTY_MODS_SUPER;
  return static_cast<ghostty_input_mods_e>(r);
}

// The editing/navigation keys an ImGui text field needs; other keys
// arrive as text via ghostty_inspector_text.
ghostty_input_key_e translateKey(int key) {
  switch (key) {
    case Qt::Key_Backspace: return GHOSTTY_KEY_BACKSPACE;
    case Qt::Key_Delete: return GHOSTTY_KEY_DELETE;
    case Qt::Key_Return:
    case Qt::Key_Enter: return GHOSTTY_KEY_ENTER;
    case Qt::Key_Tab: return GHOSTTY_KEY_TAB;
    case Qt::Key_Escape: return GHOSTTY_KEY_ESCAPE;
    case Qt::Key_Home: return GHOSTTY_KEY_HOME;
    case Qt::Key_End: return GHOSTTY_KEY_END;
    case Qt::Key_Left: return GHOSTTY_KEY_ARROW_LEFT;
    case Qt::Key_Right: return GHOSTTY_KEY_ARROW_RIGHT;
    case Qt::Key_Up: return GHOSTTY_KEY_ARROW_UP;
    case Qt::Key_Down: return GHOSTTY_KEY_ARROW_DOWN;
    default: return GHOSTTY_KEY_UNIDENTIFIED;
  }
}

}  // namespace

InspectorWindow::InspectorWindow(ghostty_surface_t surface)
    : m_surface(surface) {
  setWindowTitle(QStringLiteral("Ghostty Inspector"));
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);
  resize(800, 600);

  m_inspector = ghostty_surface_inspector(m_surface);

  // ~30fps: ImGui is immediate-mode, so it must re-render to reflect
  // hover and animation, not just on explicit RENDER_INSPECTOR actions.
  m_timer = new QTimer(this);
  connect(m_timer, &QTimer::timeout, this, &InspectorWindow::renderFrame);
  m_timer->start(33);
}

InspectorWindow::~InspectorWindow() {
  if (m_inspector && makeCurrent()) {
    ghostty_inspector_opengl_shutdown(m_inspector);
    delete m_fbo;
    m_context->doneCurrent();
  }
  if (m_surface) ghostty_inspector_free(m_surface);
  delete m_offscreen;
}

bool InspectorWindow::makeCurrent() {
  if (!m_context) {
    m_context = new QOpenGLContext(this);
    m_context->setFormat(QSurfaceFormat::defaultFormat());
    if (!m_context->create()) return false;
    m_offscreen = new QOffscreenSurface;
    m_offscreen->setFormat(m_context->format());
    m_offscreen->create();
  }
  return m_context->makeCurrent(m_offscreen);
}

void InspectorWindow::syncSize() {
  if (!m_inspector) return;
  const qreal dpr = devicePixelRatioF();
  ghostty_inspector_set_content_scale(m_inspector, dpr, dpr);
  ghostty_inspector_set_size(m_inspector,
                             static_cast<uint32_t>(width() * dpr),
                             static_cast<uint32_t>(height() * dpr));
}

void InspectorWindow::renderFrame() {
  if (!isVisible() || !m_inspector || !makeCurrent()) return;
  syncSize();

  const qreal dpr = devicePixelRatioF();
  const int w = qMax(1, static_cast<int>(width() * dpr));
  const int h = qMax(1, static_cast<int>(height() * dpr));
  if (!m_fbo || m_fbo->width() != w || m_fbo->height() != h) {
    delete m_fbo;
    m_fbo = new QOpenGLFramebufferObject(w, h);
  }

  m_fbo->bind();
  QOpenGLFunctions *gl = m_context->functions();
  gl->glViewport(0, 0, w, h);
  gl->glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  gl->glClear(GL_COLOR_BUFFER_BIT);

  if (!m_glReady) m_glReady = ghostty_inspector_opengl_init(m_inspector);
  if (m_glReady) ghostty_inspector_opengl_render(m_inspector);

  m_image = m_fbo->toImage();
  m_image.setDevicePixelRatio(dpr);
  m_fbo->release();
  m_context->doneCurrent();
  update();
}

void InspectorWindow::paintEvent(QPaintEvent *) {
  if (m_image.isNull()) return;
  QPainter painter(this);
  painter.drawImage(QPointF(0, 0), m_image);
}

void InspectorWindow::resizeEvent(QResizeEvent *) { syncSize(); }

void InspectorWindow::sendMouseButton(QMouseEvent *ev,
                                      ghostty_input_mouse_state_e state) {
  if (!m_inspector) return;
  ghostty_input_mouse_button_e button;
  switch (ev->button()) {
    case Qt::LeftButton: button = GHOSTTY_MOUSE_LEFT; break;
    case Qt::RightButton: button = GHOSTTY_MOUSE_RIGHT; break;
    case Qt::MiddleButton: button = GHOSTTY_MOUSE_MIDDLE; break;
    default: button = GHOSTTY_MOUSE_UNKNOWN; break;
  }
  ghostty_inspector_mouse_button(m_inspector, state, button,
                                 translateMods(ev->modifiers()));
}

void InspectorWindow::mouseMoveEvent(QMouseEvent *ev) {
  if (m_inspector)
    ghostty_inspector_mouse_pos(m_inspector, ev->position().x(),
                                ev->position().y());
}

void InspectorWindow::mousePressEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void InspectorWindow::mouseReleaseEvent(QMouseEvent *ev) {
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

void InspectorWindow::wheelEvent(QWheelEvent *ev) {
  if (!m_inspector) return;
  const QPoint d = ev->angleDelta();
  ghostty_inspector_mouse_scroll(m_inspector, d.x() / 120.0, d.y() / 120.0,
                                 0);
}

void InspectorWindow::keyPressEvent(QKeyEvent *ev) {
  if (!m_inspector) return;
  const ghostty_input_key_e key = translateKey(ev->key());
  if (key != GHOSTTY_KEY_UNIDENTIFIED)
    ghostty_inspector_key(m_inspector, GHOSTTY_ACTION_PRESS, key,
                          translateMods(ev->modifiers()));
  // Printable text drives ImGui's text input.
  const QByteArray text = ev->text().toUtf8();
  if (!text.isEmpty() && static_cast<unsigned char>(text.at(0)) >= 0x20)
    ghostty_inspector_text(m_inspector, text.constData());
}

void InspectorWindow::keyReleaseEvent(QKeyEvent *ev) {
  if (!m_inspector) return;
  const ghostty_input_key_e key = translateKey(ev->key());
  if (key != GHOSTTY_KEY_UNIDENTIFIED)
    ghostty_inspector_key(m_inspector, GHOSTTY_ACTION_RELEASE, key,
                          translateMods(ev->modifiers()));
}

void InspectorWindow::focusInEvent(QFocusEvent *) {
  if (m_inspector) ghostty_inspector_set_focus(m_inspector, true);
}

void InspectorWindow::focusOutEvent(QFocusEvent *) {
  if (m_inspector) ghostty_inspector_set_focus(m_inspector, false);
}
