#include "GhosttySurface.h"

#include "MainWindow.h"

#include <algorithm>
#include <cstdio>

#include <QByteArray>
#include <QClipboard>
#include <QContextMenuEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFocusEvent>
#include <QGuiApplication>
#include <QIcon>
#include <QInputDialog>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMimeData>
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
#include <QStringList>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner,
                               ghostty_surface_t parent_surface)
    : m_app(app), m_owner(owner), m_parentSurface(parent_surface) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);  // deliver motion events for hover/link detection
  setAttribute(Qt::WA_InputMethodEnabled, true);  // IME composition
  setAcceptDrops(true);                           // file / text drops
  // The widget paints a per-pixel-alpha QImage of the terminal; a
  // translucent background lets that alpha reach the desktop.
  setAttribute(Qt::WA_TranslucentBackground);

  // A private OpenGL context for libghostty's renderer. It is never made
  // current on a window — rendering goes to an offscreen framebuffer —
  // so an unparented QOffscreenSurface is enough to satisfy makeCurrent.
  m_context = new QOpenGLContext(this);
  m_context->setFormat(QSurfaceFormat::defaultFormat());
  if (!m_context->create()) {
    std::fprintf(stderr, "[ghostty] GL context creation failed\n");
    return;
  }
  m_offscreen = new QOffscreenSurface(nullptr, this);
  m_offscreen->setFormat(m_context->format());
  m_offscreen->create();

  if (!makeCurrent()) {
    std::fprintf(stderr, "[ghostty] makeCurrent failed\n");
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
    std::fprintf(stderr, "[ghostty] ghostty_surface_new failed\n");
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

// Re-sync the framebuffer and libghostty surface to the widget's current
// size and device pixel ratio. Driven by resizeEvent and by
// DevicePixelRatioChange: on Wayland the fractional scale settles
// asynchronously, after the window has already first appeared.
void GhosttySurface::syncSurfaceSize() {
  if (!m_surface) return;

  // Render at the display's device-pixel resolution. devicePixelRatioF()
  // is the true (possibly fractional) scale because main() selects the
  // PassThrough rounding policy.
  const double dpr = devicePixelRatioF();
  const int w = std::max(1, static_cast<int>(width() * dpr));
  const int h = std::max(1, static_cast<int>(height() * dpr));
  if (w == m_fbw && h == m_fbh && dpr == m_fbDpr) return;
  m_fbw = w;
  m_fbh = h;
  m_fbDpr = dpr;

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

void GhosttySurface::resizeEvent(QResizeEvent *) {
  syncSurfaceSize();
  if (m_exitOverlay) m_exitOverlay->setGeometry(rect());
}

bool GhosttySurface::event(QEvent *e) {
  // The device pixel ratio can change without a resize — the Wayland
  // fractional scale settling after startup, or a move between monitors.
  // Re-sync so the framebuffer matches and the readback is tagged with
  // that same ratio; otherwise paintEvent blits the frame at the wrong
  // size (the FBO was sized at one DPR, the image tagged with another).
  if (e->type() == QEvent::DevicePixelRatioChange) syncSurfaceSize();
  return QWidget::event(e);
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

  // Read the frame back as a premultiplied, top-down QImage, tagged with
  // the ratio the framebuffer was sized at so paintEvent can blit it 1:1
  // at its true logical size. Using the live devicePixelRatioF() here
  // would mis-size the blit if the DPR changed since syncSurfaceSize ran.
  // (Scaling it to the widget instead made the whole frame — images
  // included — rubber-band while a resize was in flight.)
  m_image = m_fbo->toImage();
  m_image.setDevicePixelRatio(m_fbDpr);
  m_fbo->release();

  update();
}

void GhosttySurface::paintEvent(QPaintEvent *) {
  if (m_image.isNull()) return;
  QPainter painter(this);
  // Blit the framebuffer 1:1. m_image carries the device pixel ratio, so
  // the QPointF overload draws it at its true logical size: when in sync
  // that exactly fills the widget, and mid-resize the content keeps its
  // real size instead of stretching to the (already-resized) widget.
  // CompositionMode_Source replaces the transparent widget pixels with
  // the terminal image, alpha included, so its translucency is kept.
  painter.setCompositionMode(QPainter::CompositionMode_Source);
  painter.drawImage(QPointF(0, 0), m_image);
}

void GhosttySurface::showChildExited(int exitCode) {
  if (m_exitOverlay) return;  // already shown

  // Defer the banner briefly. A normal `exit` closes the surface within
  // a frame or two (libghostty calls close() right after this action),
  // and we don't want the banner to flash in that case. The QObject-
  // context singleShot is cancelled if the surface is destroyed first,
  // so the banner only appears for surfaces that actually persist (an
  // abnormal exit, or `wait-after-command`).
  QTimer::singleShot(120, this, [this, exitCode]() { buildExitOverlay(exitCode); });
}

void GhosttySurface::buildExitOverlay(int exitCode) {
  if (m_exitOverlay) return;

  // A translucent banner over the terminal. It is transparent to mouse
  // events so a click lands on this widget and dismisses it (see
  // mousePressEvent / keyPressEvent).
  m_exitOverlay = new QLabel(this);
  m_exitOverlay->setAlignment(Qt::AlignCenter);
  m_exitOverlay->setWordWrap(true);
  m_exitOverlay->setAttribute(Qt::WA_TransparentForMouseEvents);
  m_exitOverlay->setStyleSheet(QStringLiteral(
      "background: rgba(0,0,0,0.65); color: #e0e0e0; font-size: 14px;"));
  const QString code = exitCode >= 0
                           ? QStringLiteral(" (code %1)").arg(exitCode)
                           : QString();
  m_exitOverlay->setText(QStringLiteral(
      "Process exited%1\nPress any key or click to close").arg(code));
  m_exitOverlay->setGeometry(rect());
  m_exitOverlay->show();
  m_exitOverlay->raise();
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
  // While the child-exited overlay is up, any key dismisses it (closes
  // the pane) instead of reaching the dead terminal.
  if (m_exitOverlay) {
    m_owner->removeSurface(this);
    return;
  }
  sendKey(ev,
          ev->isAutoRepeat() ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS);
}

void GhosttySurface::keyReleaseEvent(QKeyEvent *ev) {
  // Qt synthesizes a release before each auto-repeat press; drop those.
  if (ev->isAutoRepeat()) return;
  sendKey(ev, GHOSTTY_ACTION_RELEASE);
}

// A right-click opens the context menu (contextMenuEvent) unless the
// running program is capturing the mouse, in which case it gets the
// click. Returns true if the click was for the menu and should not be
// forwarded to the terminal.
bool GhosttySurface::rightClickOpensMenu(QMouseEvent *ev) const {
  return ev->button() == Qt::RightButton && m_surface &&
         !ghostty_surface_mouse_captured(m_surface);
}

void GhosttySurface::mousePressEvent(QMouseEvent *ev) {
  if (m_exitOverlay) {
    m_owner->removeSurface(this);
    return;
  }
  setFocus();
  if (rightClickOpensMenu(ev)) return;
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttySurface::mouseReleaseEvent(QMouseEvent *ev) {
  if (rightClickOpensMenu(ev)) return;
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

// The keybind bound to `action` in the live config, as a QKeySequence
// for a context-menu hint. Empty if unbound or not displayable.
QKeySequence GhosttySurface::shortcutFor(const char *action) const {
  if (!m_owner || !m_owner->config()) return {};
  const ghostty_input_trigger_s t =
      ghostty_config_trigger(m_owner->config(), action, qstrlen(action));

  QString key;
  switch (t.tag) {
    case GHOSTTY_TRIGGER_UNICODE:
      if (t.key.unicode) key = QString(QChar(t.key.unicode)).toUpper();
      break;
    case GHOSTTY_TRIGGER_PHYSICAL: {
      const ghostty_input_key_e k = t.key.physical;
      if (k >= GHOSTTY_KEY_A && k <= GHOSTTY_KEY_Z)
        key = QChar('A' + (k - GHOSTTY_KEY_A));
      else if (k >= GHOSTTY_KEY_DIGIT_0 && k <= GHOSTTY_KEY_DIGIT_9)
        key = QChar('0' + (k - GHOSTTY_KEY_DIGIT_0));
      else if (k == GHOSTTY_KEY_ENTER)
        key = QStringLiteral("Return");
      else if (k == GHOSTTY_KEY_SPACE)
        key = QStringLiteral("Space");
      else if (k == GHOSTTY_KEY_TAB)
        key = QStringLiteral("Tab");
      break;
    }
    default:
      break;  // CATCH_ALL etc. — nothing displayable
  }
  if (key.isEmpty()) return {};

  QString seq;
  if (t.mods & GHOSTTY_MODS_CTRL) seq += QStringLiteral("Ctrl+");
  if (t.mods & GHOSTTY_MODS_ALT) seq += QStringLiteral("Alt+");
  if (t.mods & GHOSTTY_MODS_SHIFT) seq += QStringLiteral("Shift+");
  if (t.mods & GHOSTTY_MODS_SUPER) seq += QStringLiteral("Meta+");
  return QKeySequence(seq + key);
}

void GhosttySurface::contextMenuEvent(QContextMenuEvent *ev) {
  // Let a mouse-capturing program have the right-click; also suppress
  // the menu while the child-exited overlay is up.
  if (!m_surface || m_exitOverlay ||
      ghostty_surface_mouse_captured(m_surface))
    return;

  QMenu menu(this);
  // Each item carries its libghostty keybind-action string in data();
  // exec() returns the chosen action and we run it once, below. Icons
  // come from the system theme; the shortcut hint from the live config.
  const auto add = [this](QMenu *into, const char *label, const char *icon,
                          const char *action, bool enabled) {
    QAction *a = into->addAction(QString::fromUtf8(label));
    a->setData(QString::fromUtf8(action));
    a->setEnabled(enabled);
    if (QIcon themed = QIcon::fromTheme(QString::fromUtf8(icon));
        !themed.isNull())
      a->setIcon(themed);
    if (QKeySequence sc = shortcutFor(action); !sc.isEmpty())
      a->setShortcut(sc);
  };

  add(&menu, "Copy", "edit-copy", "copy_to_clipboard",
      ghostty_surface_has_selection(m_surface));
  add(&menu, "Paste", "edit-paste", "paste_from_clipboard",
      !QGuiApplication::clipboard()->text().isEmpty());
  add(&menu, "Select All", "edit-select-all", "select_all", true);
  add(&menu, "Notify on Next Command Finish",
      "preferences-desktop-notification", "@notify-command", true);
  menu.addSeparator();
  add(&menu, "Clear", "edit-clear-all", "clear_screen", true);
  add(&menu, "Reset", "view-refresh", "reset", true);
  menu.addSeparator();

  QMenu *split = menu.addMenu(
      QIcon::fromTheme(QStringLiteral("view-split-left-right")),
      QStringLiteral("Split"));
  add(split, "Change Title…", "document-edit", "prompt_surface_title", true);
  add(split, "Split Right", "view-split-left-right", "new_split:right", true);
  add(split, "Split Down", "view-split-top-bottom", "new_split:down", true);
  add(split, "Split Left", "view-split-left-right", "new_split:left", true);
  add(split, "Split Up", "view-split-top-bottom", "new_split:up", true);

  QMenu *tab = menu.addMenu(QIcon::fromTheme(QStringLiteral("tab-new")),
                            QStringLiteral("Tab"));
  add(tab, "Change Tab Title…", "document-edit", "prompt_tab_title", true);
  add(tab, "New Tab", "tab-new", "new_tab", true);
  add(tab, "Close Tab", "tab-close", "close_tab", true);

  QMenu *window = menu.addMenu(QIcon::fromTheme(QStringLiteral("window-new")),
                               QStringLiteral("Window"));
  add(window, "New Window", "window-new", "new_window", true);
  add(window, "Close Window", "window-close", "close_window", true);

  menu.addSeparator();
  QMenu *config = menu.addMenu(QIcon::fromTheme(QStringLiteral("configure")),
                               QStringLiteral("Config"));
  add(config, "Open Config", "document-open", "open_config", true);
  add(config, "Reload Config", "view-refresh", "reload_config", true);

  QAction *chosen = menu.exec(ev->globalPos());
  if (!chosen || !m_surface) return;
  const QString data = chosen->data().toString();

  // Arm the one-shot "command finished" notification (no keybind action).
  if (data == QLatin1String("@notify-command")) {
    armCommandNotify();
    return;
  }

  // The title items have no apprt-side prompt in libghostty: collect the
  // text here and apply it with the set_*_title keybind action (an empty
  // title resets it).
  if (data == QLatin1String("prompt_surface_title") ||
      data == QLatin1String("prompt_tab_title")) {
    const bool surfaceTitle = data == QLatin1String("prompt_surface_title");
    bool ok = false;
    const QString title = QInputDialog::getText(
        this,
        surfaceTitle ? QStringLiteral("Change Title")
                     : QStringLiteral("Change Tab Title"),
        QStringLiteral("Title:"), QLineEdit::Normal, QString(), &ok);
    if (!ok) return;
    const QByteArray act =
        (surfaceTitle ? QByteArrayLiteral("set_surface_title:")
                      : QByteArrayLiteral("set_tab_title:")) +
        title.toUtf8();
    ghostty_surface_binding_action(m_surface, act.constData(), act.size());
    return;
  }

  const QByteArray action = data.toUtf8();
  ghostty_surface_binding_action(m_surface, action.constData(),
                                 action.size());
}

void GhosttySurface::dragEnterEvent(QDragEnterEvent *ev) {
  if (ev->mimeData()->hasUrls() || ev->mimeData()->hasText())
    ev->acceptProposedAction();
}

void GhosttySurface::dropEvent(QDropEvent *ev) {
  const QMimeData *mime = ev->mimeData();
  QString text;
  if (mime->hasUrls()) {
    // Dropped files are inserted as shell-quoted, space-separated paths.
    QStringList paths;
    for (const QUrl &url : mime->urls()) {
      QString p = url.isLocalFile() ? url.toLocalFile() : url.toString();
      p.replace(QLatin1String("'"), QLatin1String("'\\''"));
      paths << QLatin1Char('\'') + p + QLatin1Char('\'');
    }
    text = paths.join(QLatin1Char(' '));
  } else if (mime->hasText()) {
    text = mime->text();
  }
  if (text.isEmpty()) return;
  commitText(text);
  ev->acceptProposedAction();
}

void GhosttySurface::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_surface) return;
  // ghostty_surface_mouse_pos wants unscaled (logical) coordinates — it
  // applies the content scale itself. Passing device pixels double-scales
  // the position and drifts the selection on HiDPI displays.
  ghostty_surface_mouse_pos(m_surface, ev->position().x(),
                            ev->position().y(),
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

// Insert a string of committed text (an IME commit) as terminal input.
void GhosttySurface::commitText(const QString &text) {
  if (!m_surface || text.isEmpty()) return;
  const QByteArray utf8 = text.toUtf8();
  ghostty_input_key_s k = {};
  k.action = GHOSTTY_ACTION_PRESS;
  k.mods = GHOSTTY_MODS_NONE;
  k.consumed_mods = GHOSTTY_MODS_NONE;
  k.keycode = 0;
  k.text = utf8.constData();
  k.unshifted_codepoint = 0;
  k.composing = false;
  ghostty_surface_key(m_surface, k);
}

void GhosttySurface::inputMethodEvent(QInputMethodEvent *ev) {
  if (m_surface) {
    // Forward the in-progress composition for inline display, then any
    // finalized text. A well-behaved IME sends an empty preedit string
    // alongside the commit, so this order matches GTK: clear, then commit.
    const QByteArray preedit = ev->preeditString().toUtf8();
    ghostty_surface_preedit(
        m_surface, preedit.isEmpty() ? nullptr : preedit.constData(),
        static_cast<uintptr_t>(preedit.size()));
    if (!ev->commitString().isEmpty()) commitText(ev->commitString());
  }
  ev->accept();
}

QVariant GhosttySurface::inputMethodQuery(Qt::InputMethodQuery query) const {
  switch (query) {
    case Qt::ImEnabled:
      return true;
    case Qt::ImCursorRectangle:
      // Approximate anchor for the candidate window; tracking the real
      // terminal cursor cell is a follow-up.
      return QRect(4, height() - 4, 1, 1);
    default:
      return QWidget::inputMethodQuery(query);
  }
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
