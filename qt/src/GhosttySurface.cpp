#include "GhosttySurface.h"

#include "config/Config.h"
#include "input/XkbState.h"
#include "InspectorWindow.h"
#include "MainWindow.h"
#include "OverlayScrollbar.h"
#include "SearchBar.h"
#include "TabWidget.h"
#include "Util.h"
#include "vulkan/Host.h"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

#include <sys/mman.h>

#include <QByteArray>
#include <QClipboard>
#include <QThread>
#include <QContextMenuEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFocusEvent>
#include <QFont>
#include <QFontMetrics>
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

  // Pick the renderer up-front so the rest of the surface setup
  // (GL context vs. Vulkan host) only touches the path we'll
  // actually use. Mixing the two on the same process can confuse
  // some drivers (NVIDIA's GL+VK coexistence on a single Wayland
  // surface is reportedly fragile); keep them disjoint.
  vulkan::Host *vk_host = nullptr;
  if (const char *r = std::getenv("GHASTTY_RENDERER");
      r != nullptr && std::strcmp(r, "vulkan") == 0) {
    vk_host = vulkan::Host::instance();
  }

  if (vk_host == nullptr) {
    // OpenGL path: stand up the private context + offscreen FBO
    // libghostty's GL renderer draws into.
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
  }

  ghostty_surface_config_s sc =
      m_parentSurface
          ? ghostty_surface_inherited_config(m_parentSurface,
                                             GHOSTTY_SURFACE_CONTEXT_TAB)
          : ghostty_surface_config_new();

  if (vk_host != nullptr) {
    m_useVulkan = true;
    sc.platform_tag = GHOSTTY_PLATFORM_VULKAN;
    sc.platform.vulkan = vk_host->asPlatform(this);

    // Polling timer on the GUI thread: every 16ms, check if the
    // renderer thread parked a new frame in `m_pending` and swap
    // it into `m_image` for paintEvent to pick up.
    m_vulkanPollTimer = new QTimer(this);
    m_vulkanPollTimer->setInterval(16);  // ≈60 Hz
    connect(m_vulkanPollTimer, &QTimer::timeout, this, [this]() {
      QImage frame;
      {
        QMutexLocker lock(&m_pendingMutex);
        if (m_pending.isNull()) return;
        frame = std::move(m_pending);
      }
      m_image = std::move(frame);
      update();
    });
    m_vulkanPollTimer->start();
  } else {
    sc.platform_tag = GHOSTTY_PLATFORM_OPENGL;
    sc.platform.opengl.userdata = this;
    sc.platform.opengl.get_proc_address = glGetProcAddress;
    sc.platform.opengl.make_current = glMakeCurrent;
    sc.platform.opengl.release_current = glReleaseCurrent;
    sc.platform.opengl.present = glPresent;
  }
  sc.userdata = this;
  sc.scale_factor = devicePixelRatioF();

  m_surface = ghostty_surface_new(m_app, &sc);
  if (!m_surface) {
    std::fprintf(stderr, "[ghastty] ghostty_surface_new failed\n");
    return;
  }

  // initPremultiply creates a `QOpenGLVertexArrayObject` against the
  // private GL context. That context doesn't exist on the Vulkan
  // path, so skip the setup. The Vulkan renderer handles alpha
  // pre-multiplication itself (or doesn't need to — the dmabuf
  // contents are already in the host's expected order).
  if (!m_useVulkan && m_owner->needsPremultiply()) initPremultiply();
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

  // Vulkan path: libghostty manages the target image itself (it
  // allocates the dmabuf-exportable VkImage). We just need to tell
  // it the new pixel size + DPR — the renderer thread picks up
  // the new size and produces frames on its own clock; the
  // GUI-thread polling timer (`m_vulkanPollTimer`) picks them up.
  // We deliberately do NOT call `renderTerminal()` here: doing so
  // synchronously from inside `resizeEvent` was deadlocking with
  // Qt's first-show event delivery during bring-up.
  if (m_useVulkan) {
    ghostty_surface_set_content_scale(m_surface, dpr, dpr);
    ghostty_surface_set_size(m_surface, static_cast<uint32_t>(w),
                             static_cast<uint32_t>(h));
    return;
  }

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
  if (m_linkOverlay && m_linkOverlay->isVisible()) {
    int y = height() - m_linkOverlay->height() - 8;
    if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
      y -= m_keySeqOverlay->height() + 4;
    m_linkOverlay->move(8, y);
  }
  if (m_healthOverlay && m_healthOverlay->isVisible())
    m_healthOverlay->move(width() - m_healthOverlay->width() - 8, 8);
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
  // Visibility transitions: tell libghostty so its renderer thread
  // can bail out of updateFrame while the surface is hidden (a
  // non-current tab, a minimised window, the quick terminal faded
  // out). On visibility regain libghostty rebuilds + draws to catch
  // up. Mirrors the GTK frontend's glareaMap / glareaUnmap →
  // updateOcclusion path (ghostty-org/ghostty#12760) — keeps idle
  // background tabs at ~0% CPU instead of churning the renderer.
  //
  // Qt fires QEvent::Show / QEvent::Hide when the widget itself
  // becomes effectively visible to the user, including transitively
  // via parent hide / tab switch on QTabWidget. The GLArea-style
  // map/unmap signals are the same semantic.
  if (m_surface) {
    if (e->type() == QEvent::Show)
      ghostty_surface_set_occlusion(m_surface, true);
    else if (e->type() == QEvent::Hide)
      ghostty_surface_set_occlusion(m_surface, false);
  }
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
  // config::get is null-safe (returns false when handle() is null),
  // so we only need the "could not read" → default-to-showing path.
  const char *value = nullptr;
  if (config::get(&value, "scrollbar") && value)
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
  if (config::get(&bg, "background")) {
    const double luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
    m_scrollbar->setHandleColor(luma < 128.0 ? QColor(235, 235, 235)
                                             : QColor(45, 45, 45));
  }
  layoutScrollbar();
  m_scrollbar->reveal();
}

void GhosttySurface::renderTerminal() {
  if (!m_surface) return;

  // Vulkan path: libghostty owns its target VkImage; it renders into
  // it directly and presents via the apprt dmabuf callback. No GL
  // context, no FBO, no readback — just kick the draw and let the
  // platform-side `present` machinery wire the result back to us.
  if (m_useVulkan) {
    ghostty_surface_draw(m_surface);
    return;
  }

  if (!m_fbo || !makeCurrent()) return;

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
  // No frame yet — leave the widget background untouched. With
  // `WA_TranslucentBackground` set the area is transparent until
  // the first frame imports, matching the OpenGL path. New surfaces
  // (splits, tabs) hit paintEvent before libghostty's renderer
  // thread has emitted its first frame; the gap is short enough
  // that flashing a debug placeholder is more jarring than the
  // brief see-through.
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
    double opacity = 0.7;  // default: 70% opaque
    // On read failure opacity keeps the default; the success bit
    // isn't load-bearing.
    (void)config::get(&opacity, "unfocused-split-opacity");
    if (opacity < 1.0) {
      QColor fill(0, 0, 0);  // default: dim toward black
      ghostty_config_color_s c{};
      if (config::get(&c, "unfocused-split-fill"))
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

  // Transient "cols × rows" overlay, on top of everything else.
  paintResizeOverlay(painter);
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

void GhosttySurface::setLinkOverlay(const QString &url) {
  if (url.isEmpty()) {
    if (m_linkOverlay) m_linkOverlay->hide();
    return;
  }
  if (!m_linkOverlay) m_linkOverlay = makeOverlayLabel(this);
  // Cap very long URLs so the overlay doesn't span the whole pane.
  // 80 chars is enough to recognise hostnames + the path prefix; an
  // ellipsis in the middle preserves both halves so a query string
  // reveal still includes the host.
  QString display = url;
  constexpr int kCap = 80;
  if (display.size() > kCap) {
    const int half = (kCap - 1) / 2;
    display = display.left(half) + QStringLiteral("…") +
              display.right(kCap - 1 - half);
  }
  m_linkOverlay->setText(display);
  m_linkOverlay->adjustSize();
  // Bottom-left, but offset upward when the keybind-chord overlay is
  // visible so they don't stack on top of each other.
  int yBase = height() - m_linkOverlay->height() - 8;
  if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
    yBase -= m_keySeqOverlay->height() + 4;
  m_linkOverlay->move(8, yBase);
  m_linkOverlay->show();
  m_linkOverlay->raise();
}

void GhosttySurface::setRendererHealth(bool unhealthy) {
  if (!unhealthy) {
    if (m_healthOverlay) m_healthOverlay->hide();
    return;
  }
  if (!m_healthOverlay) {
    // Reuses the standard overlay style but with a destructive accent;
    // top-right rather than the bottom-left that key-chord/link share so
    // it doesn't fight them when both are visible at once.
    m_healthOverlay = new QLabel(this);
    m_healthOverlay->setAttribute(Qt::WA_TransparentForMouseEvents);
    m_healthOverlay->setStyleSheet(QStringLiteral(
        "background: rgba(180,30,30,0.85); color: #ffffff;"
        "font-size: 12px; padding: 4px 10px; border-radius: 4px;"));
  }
  m_healthOverlay->setText(QStringLiteral("renderer unhealthy"));
  m_healthOverlay->adjustSize();
  m_healthOverlay->move(width() - m_healthOverlay->width() - 8, 8);
  m_healthOverlay->show();
  m_healthOverlay->raise();
}

void GhosttySurface::setPwd(const QString &pwd) {
  if (m_pwd == pwd) return;
  m_pwd = pwd;
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

// Called from resizeEvent for every size change. The overlay is drawn
// in paintEvent (see m_resizeOverlayVisible there) rather than as a
// child QLabel: a child widget composited over this surface gets
// covered / flickers while the surface repaints rapidly during a
// resize. Here we just refresh the text and (re)arm the hide timer on
// EVERY resize event, so the overlay stays up for the whole drag and
// only fades once resizing actually stops.
void GhosttySurface::showResizeOverlay() {
  if (!m_surface || !m_owner) return;
  const ghostty_surface_size_s sz = ghostty_surface_size(m_surface);

  const QString mode = config::string("resize-overlay");
  if (mode == QLatin1String("never")) return;

  if (sz.columns != m_lastCols || sz.rows != m_lastRows) {
    const bool first = !m_firstGridSeen;
    m_lastCols = sz.columns;
    m_lastRows = sz.rows;
    m_firstGridSeen = true;
    // `after-first`: stay silent for the surface's very first grid.
    if (mode == QLatin1String("after-first") && first) return;
    m_resizeOverlayText =
        QStringLiteral("%1 × %2").arg(sz.columns).arg(sz.rows);
  }
  // Nothing to announce yet (a pixel-only resize before the first grid,
  // or `after-first` still waiting on the surface's initial grid).
  if (m_resizeOverlayText.isEmpty()) return;

  m_resizeOverlayVisible = true;

  // ghostty_config_get returns a Duration through Duration.cval(),
  // which is MILLISECONDS — use it as-is. Dividing by 1e6 here (the
  // value was misnamed "durNs") turned the 750ms default into 0, so
  // the hide timer fired on the next event-loop tick and the overlay
  // vanished the instant it appeared.
  unsigned long long durCfgMs = 0;
  const bool durOk = config::get(&durCfgMs, "resize-overlay-duration");
  // Clamp before narrowing: a Duration's millisecond value can exceed
  // INT_MAX, and a wrapped negative int would make QTimer::start()
  // reject the interval, leaving the overlay stuck on screen.
  const int durMs =
      (durOk && durCfgMs > 0)
          ? static_cast<int>(std::min<unsigned long long>(
                durCfgMs, std::numeric_limits<int>::max()))
          : 750;
  if (!m_resizeHideTimer) {
    m_resizeHideTimer = new QTimer(this);
    m_resizeHideTimer->setSingleShot(true);
    connect(m_resizeHideTimer, &QTimer::timeout, this, [this]() {
      m_resizeOverlayVisible = false;
      update();
    });
  }
  m_resizeHideTimer->start(durMs);
  update();
}

// Draw the transient "cols × rows" overlay onto the current frame.
// Called from paintEvent so the overlay is composited in the same pass
// as the terminal image — it cannot be covered or flicker.
void GhosttySurface::paintResizeOverlay(QPainter &painter) {
  if (!m_resizeOverlayVisible || m_resizeOverlayText.isEmpty()) return;

  QFont f = font();
  f.setPixelSize(13);
  const QFontMetrics fm(f);
  const int padX = 10, padY = 4;
  const QSize ts = fm.size(Qt::TextSingleLine, m_resizeOverlayText);
  const qreal boxW = ts.width() + 2 * padX;
  const qreal boxH = ts.height() + 2 * padY;

  // resize-overlay-position: center / {top,bottom}-{left,center,right}.
  const QString pos = config::string("resize-overlay-position");
  const qreal m = 8;
  qreal x = (width() - boxW) / 2;
  qreal y = (height() - boxH) / 2;
  if (pos.contains(QLatin1String("left"))) x = m;
  else if (pos.contains(QLatin1String("right"))) x = width() - boxW - m;
  if (pos.contains(QLatin1String("top"))) y = m;
  else if (pos.contains(QLatin1String("bottom"))) y = height() - boxH - m;

  const QRectF box(x, y, boxW, boxH);
  painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setPen(Qt::NoPen);
  painter.setBrush(QColor(0, 0, 0, 191));  // rgba(0,0,0,0.75)
  painter.drawRoundedRect(box, 4, 4);
  painter.setFont(f);
  painter.setPen(QColor(0xf0, 0xf0, 0xf0));
  painter.drawText(box, Qt::AlignCenter, m_resizeOverlayText);
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

  // The Wayland plugin reports the XKB keycode via nativeScanCode(),
  // which is libghostty's Linux-native input format.
  const uint32_t keycode = ev->nativeScanCode();

  // OR in any right-side bit for this keycode (e.g. Right-Shift sets
  // SHIFT_RIGHT alongside SHIFT) and the live Caps/Num lock state
  // from XkbTracker. macOS + GTK populate all of these; without
  // them, keybinds like `right_shift+x` can't distinguish from
  // `left_shift+x` and the kitty CSI-u encoding loses the lock bits.
  const ghostty_input_mods_e mods = static_cast<ghostty_input_mods_e>(
      translateMods(ev->modifiers()) |
      XkbState::instance().sideBitsForKeycode(keycode) |
      XkbState::instance().lockMods());

  // XKB lookups:
  //   unshifted_codepoint — what this physical key would produce with
  //   no mods (e.g. ';' for the Shift+; → ':' event). Without it
  //   libghostty's kitty encoder mis-handles punctuation release
  //   events.
  //   consumed_mods — modifiers the layout consumed to produce the
  //   event's text. Computed for every event, not just printable
  //   ones: function / keypad / Backspace / arrows can have layout-
  //   consumed mods (Caps Lock for letter case, Mode_Switch for
  //   layout shifts on Backspace) the encoder needs to strip. macOS
  //   + GTK both compute it unconditionally.
  const ghostty_input_key_s k{
      .action = action,
      .mods = mods,
      .consumed_mods = XkbState::instance().consumedMods(keycode, mods),
      .keycode = keycode,
      .text = printable ? text.constData() : nullptr,
      .unshifted_codepoint = XkbState::instance().unshiftedCodepoint(keycode),
      .composing = false,
  };
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
  // "Notify on Next Command Finish" is a togglable arm. We render the
  // checked state with a themed checkmark icon in the regular icon
  // column rather than QAction::setCheckable() — Breeze/KDE draws the
  // checkable indicator in its own column, misaligned with the rest
  // of the menu's icons. The bell icon previously used here was also
  // misleading (suggested a stateless trigger, not a one-shot flag).
  {
    QAction *notify = menu.addAction(
        QStringLiteral("Notify on Next Command Finish"));
    notify->setData(QStringLiteral("@notify-command"));
    if (commandNotifyArmed()) {
      QIcon ok = QIcon::fromTheme(QStringLiteral("emblem-ok"));
      if (ok.isNull())
        ok = QIcon::fromTheme(QStringLiteral("object-select"));
      if (ok.isNull()) ok = QIcon::fromTheme(QStringLiteral("dialog-ok"));
      if (!ok.isNull()) notify->setIcon(ok);
    }
    if (QKeySequence sc = shortcutFor("@notify-command"); !sc.isEmpty())
      notify->setShortcut(sc);
  }
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

  // Toggle the one-shot "command finished" notification (no keybind
  // action). Not a checkable QAction — see the icon-column comment in
  // the menu-build section above — so flip by reading the current
  // armed state.
  if (data == QLatin1String("@notify-command")) {
    if (commandNotifyArmed())
      clearCommandNotify();
    else
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
  const ghostty_input_key_s k{
      .action = GHOSTTY_ACTION_PRESS,
      .mods = GHOSTTY_MODS_NONE,
      .consumed_mods = GHOSTTY_MODS_NONE,
      .keycode = 0,
      .text = utf8.constData(),
      .unshifted_codepoint = 0,
      .composing = false,
  };
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

// --- libghostty Vulkan present path ----------------------------------

void GhosttySurface::presentVulkanDmabuf(
    int dmabuf_fd,
    quint32 drm_format,
    quint64 drm_modifier,
    quint32 width,
    quint32 height,
    quint32 stride) {
  // Called from the renderer thread. We mmap the dmabuf, copy the
  // bytes into a QImage, and hand the QImage to the GUI thread for
  // paint via `QMetaObject::invokeMethod`. The fd is a borrow (per
  // the `ghostty_platform_vulkan_s` contract); libghostty closes it
  // when the underlying memory is freed.
  (void)drm_modifier;  // LINEAR for v1; not used here.

  // One-shot breadcrumb so logs confirm the dmabuf hand-off is
  // wired. Subsequent frames are silent so we don't spam stderr.
  static bool logged_first = false;
  if (!logged_first) {
    logged_first = true;
    std::fprintf(stderr,
                 "[ghastty] first Vulkan dmabuf frame: fd=%d %ux%u stride=%u fourcc=0x%08x mod=0x%lx\n",
                 dmabuf_fd, width, height, stride, drm_format,
                 static_cast<unsigned long>(drm_modifier));
  }

  // sanity check the size before we allocate / mmap.
  if (dmabuf_fd < 0 || width == 0 || height == 0 || stride < width * 4)
    return;

  const size_t bytes = static_cast<size_t>(stride) * height;
  void *mapped = ::mmap(nullptr, bytes, PROT_READ, MAP_SHARED, dmabuf_fd, 0);
  if (mapped == MAP_FAILED) {
    std::fprintf(stderr, "[ghastty] mmap of dmabuf fd=%d failed: %s\n",
                 dmabuf_fd, std::strerror(errno));
    return;
  }
  // QImage holds the pixel data by copying when constructed with
  // `Format_ARGB32_Premultiplied` from a buffer with explicit stride.
  // We then detach (copy()) so the QImage survives the unmap.
  //
  // drm_format ARGB8888 (0x34325241 = "AR24") matches QImage's
  // ARGB32 byte order on little-endian (B,G,R,A in memory).
  //
  // We use the *premultiplied* variant because the renderer's
  // fragment shaders output premultiplied alpha and the render
  // target is `VK_FORMAT_B8G8R8A8_SRGB` (hardware gamma-encodes the
  // linear shader output at framebuffer-write time). The bytes
  // landing in this buffer are therefore sRGB-encoded premultiplied
  // ARGB — exactly what Format_ARGB32_Premultiplied expects.
  (void)drm_format;
  const QImage stamped(
      static_cast<const uchar *>(mapped),
      static_cast<int>(width),
      static_cast<int>(height),
      static_cast<int>(stride),
      QImage::Format_ARGB32_Premultiplied);
  QImage owned = stamped.copy();
  ::munmap(mapped, bytes);

  // Tell QPainter the image's pixels are device pixels at the same
  // DPR the framebuffer was sized at. Without this, `drawImage` would
  // treat the image as logical pixels and re-scale to framebuffer
  // pixels on a HiDPI display (DPR>1) — glyphs come out 2× too big.
  // `m_fbDpr` is the DPR `syncSurfaceSize` used when telling
  // libghostty the framebuffer size, so it matches what the renderer
  // actually drew.
  if (m_fbDpr > 0) owned.setDevicePixelRatio(m_fbDpr);

  // Stash for the GUI-thread polling timer to pick up.
  {
    QMutexLocker lock(&m_pendingMutex);
    m_pending = std::move(owned);
  }
}

// Trampoline so `Host.cpp` doesn't need to include the full
// `GhosttySurface.h`. The forward declaration lives in
// `vulkan/Host.cpp` (namespace scope, not anonymous, so the linker
// resolves this definition).
namespace vulkan {

void presentToGhosttySurface(
    void *surface,
    int dmabuf_fd,
    uint32_t drm_format,
    uint64_t drm_modifier,
    uint32_t width,
    uint32_t height,
    uint32_t stride) {
  if (surface == nullptr) return;
  static_cast<GhosttySurface *>(surface)->presentVulkanDmabuf(
      dmabuf_fd, drm_format, drm_modifier, width, height, stride);
}

} // namespace vulkan
