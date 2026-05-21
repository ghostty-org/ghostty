#include "GhosttySurface.h"

#include "InspectorWindow.h"
#include "MainWindow.h"
#include "OverlayScrollbar.h"
#include "SearchBar.h"
#include "TabWidget.h"
#include "Util.h"
#include "XkbTracker.h"

#include <algorithm>
#include <cmath>
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
#include <QSplitter>
#include <QString>
#include <QStringList>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>

#include <xkbcommon/xkbcommon.h>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner,
                               ghostty_surface_t parent_surface)
    : m_app(app), m_owner(owner), m_parentSurface(parent_surface) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);  // deliver motion events for hover/link detection
  setAttribute(Qt::WA_InputMethodEnabled, true);  // IME composition
  setAcceptDrops(true);                           // file / text drops

  // Scrollback scrollbar: a floating overlay driven by SCROLLBAR
  // actions. Dragging it runs libghostty's scroll_to_row.
  m_scrollbar = new OverlayScrollbar(this);
  connect(m_scrollbar, &OverlayScrollbar::scrollToRow, this,
          [this](int row) {
            if (!m_surface) return;
            const QByteArray a =
                "scroll_to_row:" + QByteArray::number(row);
            ghostty_surface_binding_action(m_surface, a.constData(),
                                           a.size());
          });
  // The widget paints a per-pixel-alpha QImage of the terminal; a
  // translucent background lets that alpha reach the desktop.
  setAttribute(Qt::WA_TranslucentBackground);

  // A private OpenGL context for libghostty's renderer. It is never made
  // current on a window — rendering goes to an offscreen framebuffer —
  // so an unparented QOffscreenSurface is enough to satisfy makeCurrent.
  m_context = new QOpenGLContext(this);
  m_context->setFormat(QSurfaceFormat::defaultFormat());
  if (!m_context->create()) {
    std::fprintf(stderr, "[ghastty] GL context creation failed\n");
    return;
  }
  m_offscreen = new QOffscreenSurface(nullptr, this);
  m_offscreen->setFormat(m_context->format());
  m_offscreen->create();

  if (!makeCurrent()) {
    std::fprintf(stderr, "[ghastty] makeCurrent failed\n");
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
    std::fprintf(stderr, "[ghastty] ghostty_surface_new failed\n");
    return;
  }

  if (m_owner->needsPremultiply()) initPremultiply();
}

GhosttySurface::~GhosttySurface() {
  // The inspector window holds m_surface; destroy it before m_surface.
  // QPointer auto-nulls on a destroyed QObject, so .data() is safe.
  delete m_inspectorWindow.data();

  // GL teardown must happen with the context current. If makeCurrent
  // fails (e.g. the ctor failed before m_context could be created), we
  // still free m_surface — it carries no GL state of its own — and we
  // still delete the FBO and premult helpers. Deleting QOpenGL* objects
  // without a current context leaks the GL-side resource but is safe
  // CPU-side; that's the best we can do when the context is gone.
  const bool current = makeCurrent();
  if (m_surface) ghostty_surface_free(m_surface);
  delete m_fbo;
  delete m_premultProg;
  delete m_premultVao;
  if (current) m_context->doneCurrent();
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
  // The terminal fills the full width; the scrollbar is a thin overlay
  // floating on top, so it does not subtract from the grid. Round-to-
  // nearest rather than truncate so a fractional DPR (e.g. 1.5) doesn't
  // shave a pixel off the framebuffer relative to the QImage blit.
  const int w = std::max(1, static_cast<int>(std::lround(width() * dpr)));
  const int h = std::max(1, static_cast<int>(std::lround(height() * dpr)));
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
  layoutScrollbar();
  syncSurfaceSize();
  if (m_exitOverlay) m_exitOverlay->setGeometry(rect());
  if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
    m_keySeqOverlay->move(8, height() - m_keySeqOverlay->height() - 8);
  layoutSearchBar();
  showResizeOverlay();
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

void GhosttySurface::renderIfDirty() {
  if (m_dirty.exchange(false)) renderTerminal();
}

void GhosttySurface::layoutScrollbar() {
  if (!m_scrollbar) return;
  // Always positioned (even while faded out) so it is placed correctly
  // the moment it is revealed.
  m_scrollbar->setGeometry(width() - OverlayScrollbar::kWidth, 0,
                           OverlayScrollbar::kWidth, height());
}

// `scrollbar = never` in the config hides the scrollbar unconditionally;
// `system` (the default) shows it whenever there is scrollback.
bool GhosttySurface::scrollbarAllowed() const {
  if (!m_owner || !m_owner->config()) return true;
  const char *value = nullptr;
  if (configGet(m_owner->config(), &value, "scrollbar") && value)
    return qstrcmp(value, "never") != 0;
  return true;  // unknown — default to showing
}

void GhosttySurface::updateScrollbar(uint64_t total, uint64_t offset,
                                     uint64_t len) {
  if (!m_scrollbar) return;
  if (!scrollbarAllowed() || total <= len) {
    m_scrollbar->setMetrics(0, 0, 0);
    m_scrollbar->hide();
    return;
  }
  m_scrollbar->setMetrics(total, offset, len);

  // Overlay behaviour: reveal the scrollbar on scroll activity, but not
  // for output that merely follows the bottom of the buffer.
  const bool atBottom = offset + len >= total;
  if (!atBottom || !m_scrollAtBottom) flashScrollbar();
  m_scrollAtBottom = atBottom;
}

// Reveal the overlay scrollbar (it fades itself back out when idle).
void GhosttySurface::flashScrollbar() {
  if (!m_scrollbar || !scrollbarAllowed()) return;
  // Handle colour: light on a dark terminal, dark on a light one.
  ghostty_config_color_s bg{};
  if (m_owner && configGet(m_owner->config(), &bg, "background")) {
    const double luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
    m_scrollbar->setHandleColor(luma < 128.0 ? QColor(235, 235, 235)
                                             : QColor(45, 45, 45));
  }
  layoutScrollbar();
  m_scrollbar->reveal();
}

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

  // Unfocused-split dimming: a translucent fill over an inactive pane.
  // Only split panes (a QSplitter parent) are dimmed, matching GTK.
  if (!hasFocus() && qobject_cast<QSplitter *>(parentWidget())) {
    ghostty_config_t cfg = m_owner ? m_owner->config() : nullptr;
    double opacity = 0.7;
    configGet(cfg, &opacity, "unfocused-split-opacity");
    if (opacity < 1.0) {
      QColor fill(0, 0, 0);  // default: dim toward black
      ghostty_config_color_s c{};
      if (configGet(cfg, &c, "unfocused-split-fill"))
        fill = QColor(c.r, c.g, c.b);
      fill.setAlphaF(1.0 - opacity);
      painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
      painter.fillRect(rect(), fill);
    }
  }

  // Bell `border` feature: a brief attention flash over the terminal.
  if (m_bellFlash) {
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.setPen(QPen(QColor(255, 96, 96, 230), 3));
    painter.setBrush(Qt::NoBrush);
    painter.drawRect(QRectF(rect()).adjusted(1.5, 1.5, -1.5, -1.5));
  }
}

void GhosttySurface::flashBorder() {
  m_bellFlash = true;
  update();
  QTimer::singleShot(160, this, [this]() {
    m_bellFlash = false;
    update();
  });
}

void GhosttySurface::setShape(Qt::CursorShape shape) {
  m_cursorShape = shape;
  if (m_mouseVisible) setCursor(shape);
}

void GhosttySurface::setMouseVisible(bool visible) {
  if (m_mouseVisible == visible) return;
  m_mouseVisible = visible;
  setCursor(visible ? m_cursorShape : Qt::BlankCursor);
}

// A small translucent overlay label (key-sequence / resize display).
static QLabel *makeOverlayLabel(QWidget *parent) {
  auto *label = new QLabel(parent);
  label->setAttribute(Qt::WA_TransparentForMouseEvents);
  label->setStyleSheet(QStringLiteral(
      "background: rgba(0,0,0,0.75); color: #f0f0f0; font-size: 13px;"
      "padding: 4px 10px; border-radius: 4px;"));
  label->hide();
  return label;
}

// Read a string/enum config value (enums arrive as their tag name).
static QString cfgString(ghostty_config_t cfg, const char *key) {
  const char *v = nullptr;
  if (cfg && ghostty_config_get(cfg, &v, key, qstrlen(key)) && v)
    return QString::fromUtf8(v);
  return {};
}

void GhosttySurface::promptTitle(bool tabScope) {
  bool ok = false;
  const QString title = QInputDialog::getText(
      this,
      tabScope ? QStringLiteral("Change Tab Title")
               : QStringLiteral("Change Title"),
      QStringLiteral("Title:"), QLineEdit::Normal, QString(), &ok);
  if (!ok || !m_surface) return;
  // The keybind action round-trips through libghostty, which emits
  // SET_TAB_TITLE / SET_TITLE back to apply it (an empty title resets).
  const QByteArray act =
      (tabScope ? QByteArrayLiteral("set_tab_title:")
                : QByteArrayLiteral("set_surface_title:")) +
      title.toUtf8();
  ghostty_surface_binding_action(m_surface, act.constData(), act.size());
}

void GhosttySurface::pushKeySequence(const QString &chord) {
  m_keySeq.append(chord);
  if (!m_keySeqOverlay) m_keySeqOverlay = makeOverlayLabel(this);
  m_keySeqOverlay->setText(m_keySeq.join(QStringLiteral("  ")));
  m_keySeqOverlay->adjustSize();
  m_keySeqOverlay->move(8, height() - m_keySeqOverlay->height() - 8);
  m_keySeqOverlay->show();
  m_keySeqOverlay->raise();
}

void GhosttySurface::endKeySequence() {
  m_keySeq.clear();
  if (m_keySeqOverlay) m_keySeqOverlay->hide();
}

void GhosttySurface::toggleInspector(ghostty_action_inspector_e mode) {
  const bool visible = m_inspectorWindow && m_inspectorWindow->isVisible();
  bool show;
  switch (mode) {
    case GHOSTTY_INSPECTOR_SHOW: show = true; break;
    case GHOSTTY_INSPECTOR_HIDE: show = false; break;
    default: show = !visible; break;  // GHOSTTY_INSPECTOR_TOGGLE
  }
  if (show) {
    if (!m_inspectorWindow)
      m_inspectorWindow = new InspectorWindow(m_surface);
    m_inspectorWindow->show();
    m_inspectorWindow->raise();
    m_inspectorWindow->activateWindow();
  } else if (m_inspectorWindow) {
    m_inspectorWindow->hide();
  }
}

void GhosttySurface::refreshInspector() {
  if (m_inspectorWindow) m_inspectorWindow->update();
}

void GhosttySurface::openSearch(const QString &prefill) {
  if (!m_searchBar) m_searchBar = new SearchBar(this);
  m_searchBar->open(prefill);
  layoutSearchBar();
}

void GhosttySurface::closeSearch() {
  if (m_searchBar) m_searchBar->hide();
}

void GhosttySurface::setSearchTotal(int total) {
  if (m_searchBar) m_searchBar->setTotal(total);
}

void GhosttySurface::setSearchSelected(int selected) {
  if (m_searchBar) m_searchBar->setSelected(selected);
}

void GhosttySurface::layoutSearchBar() {
  if (!m_searchBar || !m_searchBar->isVisible()) return;
  m_searchBar->adjustSize();
  // Top-right, kept clear of the overlay scrollbar's strip.
  m_searchBar->move(
      width() - m_searchBar->width() - OverlayScrollbar::kWidth - 8, 8);
}

void GhosttySurface::showResizeOverlay() {
  if (!m_surface || !m_owner) return;
  const ghostty_surface_size_s sz = ghostty_surface_size(m_surface);
  // Only a grid-size change is a "resize" worth announcing.
  if (sz.columns == m_lastCols && sz.rows == m_lastRows) return;
  m_lastCols = sz.columns;
  m_lastRows = sz.rows;

  ghostty_config_t cfg = m_owner->config();
  const QString mode = cfgString(cfg, "resize-overlay");
  const bool first = !m_firstGridSeen;
  m_firstGridSeen = true;
  if (mode == QLatin1String("never")) return;
  if (mode == QLatin1String("after-first") && first) return;

  if (!m_resizeOverlay) m_resizeOverlay = makeOverlayLabel(this);
  m_resizeOverlay->setText(
      QStringLiteral("%1 × %2").arg(sz.columns).arg(sz.rows));
  m_resizeOverlay->adjustSize();

  // resize-overlay-position: center / {top,bottom}-{left,center,right}.
  const QString pos = cfgString(cfg, "resize-overlay-position");
  const int m = 8;
  int x = (width() - m_resizeOverlay->width()) / 2;
  int y = (height() - m_resizeOverlay->height()) / 2;
  if (pos.contains(QLatin1String("left"))) x = m;
  else if (pos.contains(QLatin1String("right")))
    x = width() - m_resizeOverlay->width() - m;
  if (pos.contains(QLatin1String("top"))) y = m;
  else if (pos.contains(QLatin1String("bottom")))
    y = height() - m_resizeOverlay->height() - m;
  m_resizeOverlay->move(x, y);
  m_resizeOverlay->show();
  m_resizeOverlay->raise();

  unsigned long long durNs = 0;
  configGet(cfg, &durNs, "resize-overlay-duration");
  const int durMs = durNs ? static_cast<int>(durNs / 1000000ULL) : 750;
  if (!m_resizeHideTimer) {
    m_resizeHideTimer = new QTimer(this);
    m_resizeHideTimer->setSingleShot(true);
    connect(m_resizeHideTimer, &QTimer::timeout, this, [this]() {
      if (m_resizeOverlay) m_resizeOverlay->hide();
    });
  }
  m_resizeHideTimer->start(durMs);
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

// Wraps a libxkbcommon keymap + state derived from the system's XKB
// defaults (XKB_DEFAULT_LAYOUT etc.). We need this for two things:
//
//   1. The unshifted codepoint a key would produce with no modifiers —
//      libghostty's kitty encoder uses it to find a key entry for
//      printable keys (without it, punctuation falls into a fallback
//      that mis-encodes release events).
//
//   2. Which modifiers the layout "consumed" to produce the event's
//      text — e.g. Shift+; → ":" consumes Shift. The encoder uses this
//      to decide between plain text and a modifier-bearing CSI; without
//      it Shift+punctuation gets emitted as a kitty CSI the shell can't
//      decode (Shift+letter happens to work because A-Z survive that
//      path).
//
// THREAD SAFETY: this is a process singleton accessed only from the Qt
// GUI thread (Qt key events are dispatched there, and so is libghostty's
// inputMethodEvent forwarding). consumedMods mutates m_query, so a
// second thread would race; do not call from worker threads.
class XkbState {
public:
  static XkbState &instance() {
    static XkbState self;
    return self;
  }

  // Level-0 (unshifted) Unicode codepoint for `keycode`, or 0 if the
  // key has no associated UTF-32 (function keys, modifiers, etc.).
  //
  // Uses the live keymap from XkbTracker (synced via wl_keyboard) so
  // the active layout group is honored. A us+ru user gets the
  // correct codepoint per active group, instead of always us.
  uint32_t unshiftedCodepoint(uint32_t keycode) const {
    syncFromTracker();
    if (!m_unshifted) return 0;
    const xkb_keysym_t sym =
        xkb_state_key_get_one_sym(m_unshifted, keycode);
    if (sym == XKB_KEY_NoSymbol) return 0;
    return xkb_keysym_to_utf32(sym);
  }

  // Side bits for the libghostty mods bitfield, derived from a
  // keycode — used so that pressing Right-Shift sets BOTH the
  // unsided GHOSTTY_MODS_SHIFT and the GHOSTTY_MODS_SHIFT_RIGHT bit
  // (a left-side keycode sets only the unsided bit). macOS and GTK
  // populate sided bits this way; Qt was leaving them empty so
  // bindings that distinguish left-vs-right modifier keys couldn't
  // fire.
  ghostty_input_mods_e sideBitsForKeycode(uint32_t keycode) const {
    syncFromTracker();
    if (!m_unshifted) return GHOSTTY_MODS_NONE;
    const xkb_keysym_t sym =
        xkb_state_key_get_one_sym(m_unshifted, keycode);
    int r = GHOSTTY_MODS_NONE;
    switch (sym) {
      case XKB_KEY_Shift_R: r |= GHOSTTY_MODS_SHIFT_RIGHT; break;
      case XKB_KEY_Control_R: r |= GHOSTTY_MODS_CTRL_RIGHT; break;
      // Both Alt_R and ISO_Level3_Shift (AltGr) are right-Alt physically.
      case XKB_KEY_Alt_R:
      case XKB_KEY_ISO_Level3_Shift: r |= GHOSTTY_MODS_ALT_RIGHT; break;
      case XKB_KEY_Super_R:
      case XKB_KEY_Hyper_R:
      case XKB_KEY_Meta_R: r |= GHOSTTY_MODS_SUPER_RIGHT; break;
      default: break;
    }
    return static_cast<ghostty_input_mods_e>(r);
  }

  // Caps Lock / Num Lock state from the live wl_keyboard tracker.
  ghostty_input_mods_e lockMods() const {
    int r = GHOSTTY_MODS_NONE;
    if (XkbTracker *t = XkbTracker::instance()) {
      if (t->capsLockOn()) r |= GHOSTTY_MODS_CAPS;
      if (t->numLockOn()) r |= GHOSTTY_MODS_NUM;
    }
    return static_cast<ghostty_input_mods_e>(r);
  }

  // Modifiers consumed by the layout to produce `keycode`'s text given
  // `mods` are depressed. Returns the consumed subset, expressed as
  // ghostty mod bits. Mutates m_query (mutable) — see thread-safety
  // note on the class.
  ghostty_input_mods_e consumedMods(uint32_t keycode,
                                    ghostty_input_mods_e mods) const {
    syncFromTracker();
    if (!m_query) return GHOSTTY_MODS_NONE;
    xkb_mod_mask_t depressed = 0;
    if ((mods & GHOSTTY_MODS_SHIFT) && m_idxShift != XKB_MOD_INVALID)
      depressed |= (1u << m_idxShift);
    if ((mods & GHOSTTY_MODS_CTRL) && m_idxCtrl != XKB_MOD_INVALID)
      depressed |= (1u << m_idxCtrl);
    if ((mods & GHOSTTY_MODS_ALT) && m_idxAlt != XKB_MOD_INVALID)
      depressed |= (1u << m_idxAlt);
    if ((mods & GHOSTTY_MODS_SUPER) && m_idxSuper != XKB_MOD_INVALID)
      depressed |= (1u << m_idxSuper);
    // Use the live group from the tracker so a layout switch (e.g.
    // us↔ru) takes effect immediately.
    const uint32_t group =
        XkbTracker::instance() ? XkbTracker::instance()->activeGroup() : 0;
    xkb_state_update_mask(m_query, depressed, 0, 0, 0, 0, group);
    const xkb_mod_mask_t consumed = xkb_state_key_get_consumed_mods2(
        m_query, keycode, XKB_CONSUMED_MODE_XKB);
    // Reset so the next query starts from no-mods.
    xkb_state_update_mask(m_query, 0, 0, 0, 0, 0, group);
    int r = GHOSTTY_MODS_NONE;
    if (m_idxShift != XKB_MOD_INVALID && (consumed & (1u << m_idxShift)))
      r |= GHOSTTY_MODS_SHIFT;
    if (m_idxCtrl != XKB_MOD_INVALID && (consumed & (1u << m_idxCtrl)))
      r |= GHOSTTY_MODS_CTRL;
    if (m_idxAlt != XKB_MOD_INVALID && (consumed & (1u << m_idxAlt)))
      r |= GHOSTTY_MODS_ALT;
    if (m_idxSuper != XKB_MOD_INVALID && (consumed & (1u << m_idxSuper)))
      r |= GHOSTTY_MODS_SUPER;
    return static_cast<ghostty_input_mods_e>(r);
  }

private:
  // Lazy: build/rebuild m_unshifted + m_query from the live keymap.
  // Called from every public method; cheap when the keymap pointer
  // hasn't changed (a single comparison + early-return).
  void syncFromTracker() const {
    XkbTracker *t = XkbTracker::instance();
    xkb_keymap *liveKm = t ? t->keymap() : nullptr;
    xkb_keymap *km = liveKm ? liveKm : m_fallbackKeymap;

    if (!km && t && t->ctx()) {
      // Compositor hasn't sent a keymap yet (early startup). Build a
      // throwaway from XKB defaults so the first key event isn't
      // dropped; it will be replaced on the next syncFromTracker
      // call once the tracker has the live keymap.
      m_fallbackKeymap = xkb_keymap_new_from_names(
          t->ctx(), nullptr, XKB_KEYMAP_COMPILE_NO_FLAGS);
      km = m_fallbackKeymap;
    }
    if (!km || km == m_keymap) {
      // Already synced (or no keymap available at all).
      // Update the live group on m_unshifted so the level-0 lookup
      // honors the active layout, even when the keymap pointer
      // hasn't changed.
      if (m_unshifted && t) {
        xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
      }
      return;
    }

    // The live keymap was rebuilt by the tracker (or we're picking
    // up the first one). Drop our derived states and rebuild.
    if (m_unshifted) xkb_state_unref(m_unshifted);
    if (m_query) xkb_state_unref(m_query);
    m_unshifted = xkb_state_new(km);
    m_query = xkb_state_new(km);
    m_idxShift = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_SHIFT);
    m_idxCtrl = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_CTRL);
    m_idxAlt = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_ALT);
    m_idxSuper = xkb_keymap_mod_get_index(km, XKB_MOD_NAME_LOGO);
    m_keymap = km;  // pointer-identity comparison only; no ref taken
    if (t)
      xkb_state_update_mask(m_unshifted, 0, 0, 0, 0, 0, t->activeGroup());
  }

  XkbState() = default;

  ~XkbState() {
    // Run on process exit when the static is destroyed. The OS would
    // reclaim regardless, but explicit teardown silences leak checkers
    // and documents the ownership chain.
    if (m_query) xkb_state_unref(m_query);
    if (m_unshifted) xkb_state_unref(m_unshifted);
    if (m_fallbackKeymap) xkb_keymap_unref(m_fallbackKeymap);
  }

  XkbState(const XkbState &) = delete;
  XkbState &operator=(const XkbState &) = delete;

  // Pointer-identity reference to the keymap our derived states were
  // built from. NOT owned (the tracker or m_fallbackKeymap owns).
  mutable struct xkb_keymap *m_keymap = nullptr;
  // Throwaway keymap from XKB defaults, built when the live keymap
  // hasn't arrived yet. Owned. Released in dtor; never replaced.
  mutable struct xkb_keymap *m_fallbackKeymap = nullptr;
  mutable struct xkb_state *m_unshifted = nullptr;  // no-mods state
  // Reused across consumedMods calls (mutated then reset).
  mutable struct xkb_state *m_query = nullptr;
  mutable xkb_mod_index_t m_idxShift = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxCtrl = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxAlt = XKB_MOD_INVALID;
  mutable xkb_mod_index_t m_idxSuper = XKB_MOD_INVALID;
};

void GhosttySurface::sendKey(QKeyEvent *ev, ghostty_input_action_e action) {
  if (!m_surface) return;

  // Forward committed text only for printable input; control characters
  // and special keys (Enter, Tab, arrows, Ctrl+letter, ...) are encoded
  // by libghostty from the physical keycode + modifiers.
  // The QByteArray below is stack-local; ghostty_surface_key is
  // synchronous and copies any text it needs internally, so the buffer
  // only has to live across this call.
  const QByteArray text = ev->text().toUtf8();
  const bool printable =
      !text.isEmpty() &&
      static_cast<unsigned char>(text.front()) >= 0x20 &&
      static_cast<unsigned char>(text.front()) != 0x7f;

  // On xcb nativeScanCode() is the X11/XKB keycode; the Wayland plugin
  // likewise reports the XKB keycode, which is libghostty's Linux native.
  const uint32_t keycode = ev->nativeScanCode();

  ghostty_input_key_s k = {};
  k.action = action;
  k.mods = translateMods(ev->modifiers());
  // OR in any right-side bit for this keycode (e.g. Right-Shift sets
  // SHIFT_RIGHT alongside SHIFT) and the live Caps/Num lock state
  // from XkbTracker. macOS + GTK populate all of these; without
  // them, keybinds like `right_shift+x` can't distinguish from
  // `left_shift+x` and the kitty CSI-u encoding loses the lock bits.
  k.mods = static_cast<ghostty_input_mods_e>(
      k.mods | XkbState::instance().sideBitsForKeycode(keycode) |
      XkbState::instance().lockMods());
  k.keycode = keycode;
  k.text = printable ? text.constData() : nullptr;
  // XKB lookups: unshifted codepoint (what this physical key would
  // produce with no mods, e.g. ';' for the Shift+; → ':' event) and the
  // modifiers the layout consumed to produce the event's text. Without
  // consumed_mods, Shift+punctuation is emitted as a kitty CSI sequence
  // the shell can't decode; with it set, libghostty's encoder falls
  // back to plain text correctly.
  k.unshifted_codepoint = XkbState::instance().unshiftedCodepoint(keycode);
  // consumed_mods is computed for every event, not just printable ones.
  // Function/keypad/Backspace/arrows can also have layout-consumed
  // modifiers (e.g. Caps Lock affecting case for letter keys, Mode_Switch
  // for layout shifts on Backspace) that the kitty encoder needs to
  // strip. macOS + GTK both compute it unconditionally; gating on
  // printable lost that info on non-text keys.
  k.consumed_mods = XkbState::instance().consumedMods(keycode, k.mods);
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
    // Side / extra buttons (back, forward, etc.). macOS handles
    // NSEvent buttonNumber 3-10 and GTK handles GDK button 4-11;
    // Qt's ExtraButton1..ExtraButton8 cover the same hardware. The
    // libghostty C ABI defines FOUR..ELEVEN, so map by index.
    case Qt::ExtraButton1: button = GHOSTTY_MOUSE_FOUR; break;
    case Qt::ExtraButton2: button = GHOSTTY_MOUSE_FIVE; break;
    case Qt::ExtraButton3: button = GHOSTTY_MOUSE_SIX; break;
    case Qt::ExtraButton4: button = GHOSTTY_MOUSE_SEVEN; break;
    case Qt::ExtraButton5: button = GHOSTTY_MOUSE_EIGHT; break;
    case Qt::ExtraButton6: button = GHOSTTY_MOUSE_NINE; break;
    case Qt::ExtraButton7: button = GHOSTTY_MOUSE_TEN; break;
    case Qt::ExtraButton8: button = GHOSTTY_MOUSE_ELEVEN; break;
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
  // Click-to-focus: if the surface didn't have focus, this click is
  // grabbing focus rather than a real interaction with the running
  // program. macOS + GTK suppress the matching mouse-up so vim, less,
  // etc. don't see a stray button-up event. We mirror that by setting
  // a one-shot flag the matching release consults.
  const bool wasFocused = hasFocus();
  setFocus();
  if (!wasFocused && ev->button() == Qt::LeftButton)
    m_suppressNextLeftRelease = true;

  // Right-click: send the press to libghostty BEFORE deciding to
  // open the context menu. macOS + GTK both do this so the core can
  // word-select on right-press and then we open the menu over the
  // selection. If the running program is mouse-captured, the press
  // is forwarded as a real button event.
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttySurface::mouseReleaseEvent(QMouseEvent *ev) {
  // Suppress the release of a focus-grabbing click — see press above.
  if (ev->button() == Qt::LeftButton && m_suppressNextLeftRelease) {
    m_suppressNextLeftRelease = false;
    return;
  }
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

// The keybind bound to `action` in the live config, as a QKeySequence
// for a context-menu hint. Empty if unbound or not displayable
// (CATCH_ALL, an unmapped physical key, etc.).
QKeySequence GhosttySurface::shortcutFor(const char *action) const {
  if (!m_owner || !m_owner->config()) return {};
  const ghostty_input_trigger_s t =
      ghostty_config_trigger(m_owner->config(), action, qstrlen(action));

  const QString key = triggerKeyName(t);
  if (key.isEmpty()) return {};

  QString seq;
  if (t.mods & GHOSTTY_MODS_CTRL) seq += QStringLiteral("Ctrl+");
  if (t.mods & GHOSTTY_MODS_ALT) seq += QStringLiteral("Alt+");
  if (t.mods & GHOSTTY_MODS_SHIFT) seq += QStringLiteral("Shift+");
  // QKeySequence parses Meta+ as the Super/Logo key on Linux.
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
  add(&menu, "Find…", "edit-find", "start_search", true);
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
  // text here and apply it via promptTitle (the set_*_title keybind).
  if (data == QLatin1String("prompt_surface_title") ||
      data == QLatin1String("prompt_tab_title")) {
    promptTitle(data == QLatin1String("prompt_tab_title"));
    return;
  }

  const QByteArray action = data.toUtf8();
  ghostty_surface_binding_action(m_surface, action.constData(),
                                 action.size());
}

void GhosttySurface::dragEnterEvent(QDragEnterEvent *ev) {
  // Accept a tab tear-off drag too — not to handle it, but so Qt does
  // not paint a "forbidden" cursor while a torn-off tab hovers the
  // terminal. The tear-off still completes as a new window (only a tab
  // bar's drop cancels it).
  if (ev->mimeData()->hasUrls() || ev->mimeData()->hasText() ||
      ev->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime)))
    ev->acceptProposedAction();
}

// Quote `s` for a POSIX shell using $'…' encoding. Mirrors
// macOS Ghostty.Shell.escape and GTK ShellEscapeWriter — handles
// embedded quotes, backslashes, newlines, and control chars; bash's
// `'\''` trick fails on dash/zsh + non-printable bytes.
static QString shellQuote(const QString &s) {
  QString out;
  out.reserve(s.size() + 4);
  out += QLatin1String("$'");
  for (QChar ch : s) {
    const ushort c = ch.unicode();
    if (c == '\\' || c == '\'')
      out += QLatin1Char('\\'), out += ch;
    else if (c == '\n')
      out += QLatin1String("\\n");
    else if (c == '\r')
      out += QLatin1String("\\r");
    else if (c == '\t')
      out += QLatin1String("\\t");
    else if (c < 0x20)
      out += QString::asprintf("\\x%02x", c);
    else
      out += ch;
  }
  out += QLatin1Char('\'');
  return out;
}

void GhosttySurface::dropEvent(QDropEvent *ev) {
  const QMimeData *mime = ev->mimeData();
  // A tab tear-off released on the terminal: accept it cleanly and let
  // the tear-off code turn it into a new window.
  if (mime->hasFormat(QString::fromLatin1(kGhosttyTabMime))) {
    ev->acceptProposedAction();
    return;
  }
  QString text;
  if (mime->hasUrls()) {
    // Distinguish file URLs from non-file URLs (http://, etc). File
    // URLs become shell-quoted paths joined with spaces; non-file URLs
    // paste as plain text. macOS + GTK both make this distinction
    // (otherwise dragging a link from a browser yields a quoted
    // command-line argument instead of pasting the URL).
    QStringList parts;
    for (const QUrl &url : mime->urls()) {
      if (url.isLocalFile())
        parts << shellQuote(url.toLocalFile());
      else
        parts << url.toString();
    }
    text = parts.join(QLatin1Char(' '));
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

  // Reveal the overlay scrollbar when the pointer reaches the right
  // edge. While it is visible the scrollbar widget grabs the strip
  // itself; this only fires once it has faded out and been hidden.
  if (ev->position().x() >= width() - OverlayScrollbar::kWidth)
    flashScrollbar();
}

void GhosttySurface::wheelEvent(QWheelEvent *ev) {
  if (!m_surface) return;
  // libghostty's ScrollMods is a packed u8: bit 0 = precision (high-res
  // / pixel-precise), bits 1-3 = momentum phase (none/began/changed/
  // ended/cancelled/may_begin) per src/input/mouse.zig.
  //
  // Trackpads and high-resolution mice fill in pixelDelta; classic
  // notched wheels only fill angleDelta (120 units per notch). When
  // pixelDelta is present we feed that, divide by an approximate cell
  // height (we don't have it from libghostty here, so use 16 logical
  // pixels — close enough for smooth-scroll feel) and flag the event
  // as precision so kitty's smooth-scroll engages. Otherwise we fall
  // back to the classic "120 units == one notch" path.
  double dx = 0.0, dy = 0.0;
  int mods = 0;
  const QPoint pd = ev->pixelDelta();
  if (!pd.isNull()) {
    constexpr double kCellPx = 16.0;
    dx = pd.x() / kCellPx;
    dy = pd.y() / kCellPx;
    mods |= 1;  // ScrollMods.precision
  } else {
    const QPoint a = ev->angleDelta();
    dx = a.x() / 120.0;
    dy = a.y() / 120.0;
  }

  // ScrollMods.momentum (3-bit field at bit 1). Qt only signals the
  // ScrollBegin/ScrollUpdate/ScrollEnd phases on trackpads.
  switch (ev->phase()) {
    case Qt::ScrollBegin:    mods |= (1 /*began*/) << 1; break;
    case Qt::ScrollUpdate:   mods |= (3 /*changed*/) << 1; break;
    case Qt::ScrollEnd:      mods |= (4 /*ended*/) << 1; break;
    case Qt::ScrollMomentum: mods |= (3 /*changed*/) << 1; break;
    default: break;  // NoScrollPhase: treat as a discrete notch
  }
  ghostty_surface_mouse_scroll(m_surface, dx, dy, mods);
  flashScrollbar();  // mouse-wheel scrolling reveals the overlay scrollbar
}

void GhosttySurface::enterEvent(QEnterEvent *ev) {
  // focus-follows-mouse: take focus when the pointer enters this pane.
  if (m_owner && m_owner->focusFollowsMouse() && !hasFocus()) setFocus();
  // Tell libghostty about the actual cursor position so hover state
  // and OSC-8 link arming reset from any stale (-1, -1) sentinel.
  // macOS does this in mouseEntered (SurfaceView_AppKit.swift:920);
  // GTK does it in ecMouseEnter (apprt/gtk/class/surface.zig).
  if (m_surface)
    ghostty_surface_mouse_pos(m_surface, ev->position().x(),
                              ev->position().y(),
                              translateMods(QGuiApplication::keyboardModifiers()));
}

void GhosttySurface::leaveEvent(QEvent *) {
  // libghostty's "no cursor here" sentinel: pass (-1, -1) so any
  // hover-armed state (URL underline, mouse-report sequences for an
  // OSC-8 link) clears once the pointer leaves the pane. macOS and
  // GTK both do this; without it the arm state would survive until
  // the next move event.
  if (m_surface)
    ghostty_surface_mouse_pos(m_surface, -1, -1,
                              translateMods(QGuiApplication::keyboardModifiers()));
}

void GhosttySurface::focusInEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, true);
  update();  // repaint without the unfocused-split dim
}

void GhosttySurface::focusOutEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, false);
  update();  // repaint with the unfocused-split dim (if a split pane)
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
    const QString preeditStr = ev->preeditString();
    const QString commitStr = ev->commitString();

    // Forward the in-progress composition for inline display, then any
    // finalized text. A well-behaved IME sends an empty preedit string
    // alongside the commit, so this order matches GTK: clear, then commit.
    const QByteArray preedit = preeditStr.toUtf8();
    ghostty_surface_preedit(
        m_surface, preedit.isEmpty() ? nullptr : preedit.constData(),
        static_cast<uintptr_t>(preedit.size()));

    // Only commit when the text is the result of real IME composition —
    // either the preceding event left us in preedit, or this event has
    // active preedit alongside the commit. On Wayland's text-input-v3
    // (KDE Plasma 6 with no IME), the compositor sends a commit for
    // every plain ASCII character it also delivers as a key event;
    // forwarding both here would double every keystroke (the visible
    // symptom: ":" in nvim arriving as "::").
    if (!commitStr.isEmpty() && (m_hadPreedit || !preeditStr.isEmpty()))
      commitText(commitStr);
    m_hadPreedit = !preeditStr.isEmpty();
  }
  ev->accept();
}

QVariant GhosttySurface::inputMethodQuery(Qt::InputMethodQuery query) const {
  switch (query) {
    case Qt::ImEnabled:
      return true;
    case Qt::ImCursorRectangle: {
      // Anchor the IME candidate window at the terminal cursor.
      // libghostty reports the cursor in device pixels; the IME wants
      // logical widget coordinates, so divide by the surface's DPR.
      if (!m_surface) return QRect();
      const ghostty_surface_cursor_position_s c =
          ghostty_surface_cursor_position(m_surface);
      // m_fbDpr defaults to 1.0 and only ever takes positive values
      // from syncSurfaceSize, so dividing is always safe.
      return QRect(static_cast<int>(c.x / m_fbDpr),
                   static_cast<int>(c.y / m_fbDpr),
                   std::max(1, static_cast<int>(c.width / m_fbDpr)),
                   std::max(1, static_cast<int>(c.height / m_fbDpr)));
    }
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
