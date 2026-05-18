#include "GhosttySurface.h"

#include "MainWindow.h"

#include <algorithm>
#include <cstdio>

#include <QByteArray>
#include <QFocusEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLVertexArrayObject>
#include <QPainter>
#include <QResizeEvent>
#include <QString>
#include <QSurfaceFormat>
#include <QWheelEvent>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner,
                               ghostty_surface_t parent_surface)
    : m_app(app), m_owner(owner), m_parentSurface(parent_surface) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);  // deliver motion events for hover/link detection
  // The widget paints a per-pixel-alpha QImage of the terminal; a
  // translucent background lets that alpha reach the desktop.
  setAttribute(Qt::WA_TranslucentBackground);

  // A private OpenGL context for libghostty's renderer. It is never made
  // current on a window — rendering goes to an offscreen framebuffer —
  // so an unparented QOffscreenSurface is enough to satisfy makeCurrent.
  m_context = new QOpenGLContext(this);
  m_context->setFormat(QSurfaceFormat::defaultFormat());
  if (!m_context->create()) {
    std::fprintf(stderr, "[ghostty-qt] GL context creation failed\n");
    return;
  }
  m_offscreen = new QOffscreenSurface(nullptr, this);
  m_offscreen->setFormat(m_context->format());
  m_offscreen->create();

  if (!makeCurrent()) {
    std::fprintf(stderr, "[ghostty-qt] makeCurrent failed\n");
    return;
  }

  // A placeholder framebuffer; resizeEvent installs the real size.
  QOpenGLFramebufferObjectFormat fmt;
  fmt.setInternalTextureFormat(GL_RGBA8);
  m_fbw = m_fbh = 16;
  m_fbo = new QOpenGLFramebufferObject(QSize(m_fbw, m_fbh), fmt);

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

  if (m_owner->needsPremultiply()) initPremultiply();
}

GhosttySurface::~GhosttySurface() {
  // Release GL-owning objects with the context current.
  if (makeCurrent()) {
    if (m_surface) ghostty_surface_free(m_surface);
    delete m_fbo;
    delete m_premultProg;
    delete m_premultVao;
    m_context->doneCurrent();
  }
}

bool GhosttySurface::makeCurrent() {
  return m_context && m_offscreen && m_offscreen->isValid() &&
         m_context->makeCurrent(m_offscreen);
}

// --- rendering ------------------------------------------------------

void GhosttySurface::resizeEvent(QResizeEvent *) {
  if (!m_surface) return;

  // Render at the display's device-pixel resolution. devicePixelRatioF()
  // is the true (possibly fractional) scale because main() selects the
  // PassThrough rounding policy.
  const double dpr = devicePixelRatioF();
  const int w = std::max(1, static_cast<int>(width() * dpr));
  const int h = std::max(1, static_cast<int>(height() * dpr));
  if (w == m_fbw && h == m_fbh) return;
  m_fbw = w;
  m_fbh = h;

  if (!makeCurrent()) return;
  delete m_fbo;
  QOpenGLFramebufferObjectFormat fmt;
  fmt.setInternalTextureFormat(GL_RGBA8);
  m_fbo = new QOpenGLFramebufferObject(QSize(w, h), fmt);

  ghostty_surface_set_content_scale(m_surface, dpr, dpr);
  ghostty_surface_set_size(m_surface, static_cast<uint32_t>(w),
                           static_cast<uint32_t>(h));
  renderTerminal();
}

void GhosttySurface::requestRender() { renderTerminal(); }

void GhosttySurface::renderTerminal() {
  if (!m_surface || !m_fbo || !makeCurrent()) return;

  // libghostty renders into its own target and blits the result to the
  // currently bound framebuffer — bind ours so we get the final image.
  m_fbo->bind();
  m_context->functions()->glViewport(0, 0, m_fbw, m_fbh);
  ghostty_surface_draw(m_surface);
  premultiplyFramebuffer();

  // Read the frame back as a premultiplied, top-down QImage. paintEvent
  // scales it to the widget, so its device pixel ratio is irrelevant.
  m_image = m_fbo->toImage();
  m_fbo->release();

  update();
}

void GhosttySurface::paintEvent(QPaintEvent *) {
  if (m_image.isNull()) return;
  QPainter painter(this);
  // Scale the framebuffer image to fill the widget. The QRect overload
  // is required: drawImage(0, 0, img) would select the int-coordinate
  // overload, which blits at raw pixel size and ignores both the
  // widget's logical size and the device pixel ratio (a 2x zoom on a
  // HiDPI display).
  painter.setRenderHint(QPainter::SmoothPixmapTransform);
  // Replace the (transparent) widget pixels with the terminal image,
  // alpha included, so the background's translucency is preserved.
  painter.setCompositionMode(QPainter::CompositionMode_Source);
  painter.drawImage(rect(), m_image);
}

// libghostty's renderer outputs premultiplied alpha — except a custom
// shader runs as a final Shadertoy-style pass and those conventionally
// emit *straight* alpha (RGB not scaled by alpha). QPainter and the
// compositor expect premultiplied, so a straight framebuffer renders the
// terminal color at full strength and reads as opaque. Fix it by
// premultiplying the framebuffer in place before reading it back.
//
// This runs only when a custom shader is configured: without one the
// renderer's output is already premultiplied and a second pass would
// wrongly darken the background.
void GhosttySurface::initPremultiply() {
  m_premultVao = new QOpenGLVertexArrayObject(this);
  m_premultVao->create();

  m_premultProg = new QOpenGLShaderProgram(this);
  // A single oversized triangle covering the viewport; positions are
  // derived from gl_VertexID so no vertex buffer is needed.
  m_premultProg->addShaderFromSourceCode(QOpenGLShader::Vertex,
                                         R"(#version 330 core
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})");
  // The fragment color is irrelevant: the blend below uses a source
  // factor of zero, so only the destination framebuffer and its alpha
  // matter.
  m_premultProg->addShaderFromSourceCode(QOpenGLShader::Fragment,
                                         R"(#version 330 core
out vec4 fragColor;
void main() { fragColor = vec4(1.0); }
)");
  m_premultProg->link();
}

void GhosttySurface::premultiplyFramebuffer() {
  if (!m_premultProg || !m_premultProg->isLinked()) return;
  auto *f = m_context->functions();

  // result.rgb = src.rgb*0 + dst.rgb*dst.a ; alpha left untouched by the
  // color mask. This multiplies every pixel's RGB by its own alpha.
  f->glViewport(0, 0, m_fbw, m_fbh);
  f->glDisable(GL_SCISSOR_TEST);
  f->glDisable(GL_DEPTH_TEST);
  f->glEnable(GL_BLEND);
  f->glBlendFuncSeparate(GL_ZERO, GL_DST_ALPHA, GL_ZERO, GL_ONE);
  f->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE);

  m_premultVao->bind();
  m_premultProg->bind();
  f->glDrawArrays(GL_TRIANGLES, 0, 3);
  m_premultProg->release();
  m_premultVao->release();

  f->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  f->glDisable(GL_BLEND);
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
  // No-op: renderTerminal makes the context current around each frame.
}

void GhosttySurface::glPresent(void *) {
  // No-op: the frame is read back from the framebuffer, not swapped.
}
