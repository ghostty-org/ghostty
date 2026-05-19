#include "MainWindow.h"

#include <algorithm>
#include <climits>
#include <cstdio>

#include <QApplication>
#include <QByteArray>
#include <QClipboard>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QList>
#include <QPoint>
#include <QRect>
#include <QShowEvent>
#include <QSplitter>
#include <QUrl>
#include <QString>
#include <QTabWidget>
#include <QTimer>
#include <QVBoxLayout>

#include "GhosttySurface.h"

MainWindow::MainWindow() {
  setWindowTitle(QStringLiteral("Ghostty (Qt)"));
  // Let a translucent terminal background show through to the desktop.
  setAttribute(Qt::WA_TranslucentBackground);

  m_tabs = new QTabWidget(this);
  m_tabs->setTabsClosable(true);
  m_tabs->setMovable(true);
  m_tabs->setDocumentMode(true);
  // Hide the tab bar with a single tab so the terminal gets the full
  // window height (matching the GTK frontend).
  m_tabs->setTabBarAutoHide(true);
  m_tabs->setContentsMargins(0, 0, 0, 0);
  // Paint an opaque background behind the tab widget so the tab bar
  // renders as a solid, styled bar. A plain QTabWidget fills nothing, so
  // the translucent top-level window would otherwise show through the
  // document-mode tabs; autoFillBackground fills it with the palette
  // window colour. Only the top-level window and the GL surfaces are
  // translucent: each GhosttySurface paints with CompositionMode_Source,
  // overwriting this opaque background so the terminal's per-pixel alpha
  // still reaches the window backing store.
  m_tabs->setAutoFillBackground(true);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->addWidget(m_tabs);

  connect(m_tabs, &QTabWidget::tabCloseRequested, this,
          &MainWindow::onTabCloseRequested);
  connect(m_tabs, &QTabWidget::currentChanged, this,
          &MainWindow::onCurrentChanged);
}

MainWindow::~MainWindow() {
  // Destroy the surfaces (freeing their ghostty_surface_t) before the
  // shared app; Qt's own child cleanup runs after this body.
  qDeleteAll(m_surfaces);
  m_surfaces.clear();
  if (m_app) ghostty_app_free(m_app);
  if (m_config) ghostty_config_free(m_config);
}

// Whether the Ghostty config enables a custom shader. libghostty does
// not expose this through ghostty_config_get (`custom-shader` is a
// repeatable path), so scan the primary config file directly.
static bool configHasCustomShader() {
  QString dir = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/.config");

  QFile f(dir + QStringLiteral("/ghostty/config"));
  if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return false;

  while (!f.atEnd()) {
    const QByteArray line = f.readLine().trimmed();
    if (!line.startsWith("custom-shader")) continue;
    // Require a non-empty value: `custom-shader =` alone clears it.
    const int eq = line.indexOf('=');
    if (eq >= 0 && !line.mid(eq + 1).trimmed().isEmpty()) return true;
  }
  return false;
}

bool MainWindow::initialize() {
  // Load configuration in the same order as the reference apprt.
  m_config = ghostty_config_new();
  ghostty_config_load_default_files(m_config);
  ghostty_config_load_cli_args(m_config);
  ghostty_config_load_recursive_files(m_config);
  ghostty_config_finalize(m_config);

  m_needsPremultiply = configHasCustomShader();

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
    std::fprintf(stderr, "[ghostty] ghostty_app_new failed\n");
    return false;
  }

  // Periodic tick as a backstop; onWakeup drives responsive ticking.
  auto *timer = new QTimer(this);
  connect(timer, &QTimer::timeout, this, &MainWindow::tick);
  timer->start(16);

  // The first tab is created in showEvent, not here: see below.
  return true;
}

void MainWindow::showEvent(QShowEvent *event) {
  QWidget::showEvent(event);

  // Create the first terminal only once the window is on-screen. A
  // surface created earlier (from initialize(), before show()) spawns
  // its shell while the device pixel ratio is still unsettled, so a
  // shell greeting such as fastfetch queries a wrong cell size and sizes
  // Kitty graphics images for it. Deferring to here — past show(), via a
  // queued call so the window is fully mapped — makes the first tab
  // behave exactly like every later one.
  if (m_firstTabPending) {
    m_firstTabPending = false;
    QTimer::singleShot(0, this, [this] { newTab(nullptr); });
  }
}

GhosttySurface *MainWindow::newTab(ghostty_surface_t parent) {
  auto *surface = new GhosttySurface(m_app, this, parent);
  m_surfaces.append(surface);

  // The tab page hosts the tab's split tree (initially one surface).
  // It stays opaque chrome; the GhosttySurface paints over it.
  auto *page = new QWidget(m_tabs);
  auto *pageLayout = new QVBoxLayout(page);
  pageLayout->setContentsMargins(0, 0, 0, 0);
  pageLayout->addWidget(surface);

  const int index = m_tabs->addTab(page, QStringLiteral("Ghostty"));
  m_tabs->setCurrentIndex(index);
  surface->setFocus();
  return surface;
}

GhosttySurface *MainWindow::splitSurface(
    GhosttySurface *target, ghostty_action_split_direction_e dir) {
  if (!m_surfaces.contains(target)) return nullptr;

  const bool horizontal = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT ||
                          dir == GHOSTTY_SPLIT_DIRECTION_LEFT;
  const bool newAfter = dir == GHOSTTY_SPLIT_DIRECTION_RIGHT ||
                        dir == GHOSTTY_SPLIT_DIRECTION_DOWN;

  auto *surface = new GhosttySurface(m_app, this, target->surface());
  auto *splitter =
      new QSplitter(horizontal ? Qt::Horizontal : Qt::Vertical);
  splitter->setChildrenCollapsible(false);

  // Insert `splitter` where `target` currently sits in the tree.
  QWidget *parent = target->parentWidget();
  if (auto *parentSplitter = qobject_cast<QSplitter *>(parent)) {
    parentSplitter->replaceWidget(parentSplitter->indexOf(target), splitter);
  } else if (parent && parent->layout()) {
    delete parent->layout()->replaceWidget(target, splitter);
  } else {
    delete splitter;
    delete surface;
    return nullptr;
  }

  if (newAfter) {
    splitter->addWidget(target);
    splitter->addWidget(surface);
  } else {
    splitter->addWidget(surface);
    splitter->addWidget(target);
  }
  splitter->setSizes({1 << 20, 1 << 20});  // start the panes roughly equal

  m_surfaces.append(surface);
  surface->setFocus();
  return surface;
}

void MainWindow::removeSurface(GhosttySurface *surface) {
  if (!m_surfaces.removeOne(surface)) return;

  // Drop stale split-zoom state if the zoomed surface is going away.
  if (surface == m_zoomed) {
    m_zoomed = nullptr;
    m_zoomRoot = nullptr;
    m_zoomSplitter = nullptr;
  }

  QWidget *parent = surface->parentWidget();
  if (auto *splitter = qobject_cast<QSplitter *>(parent)) {
    // One pane of a split: collapse the splitter into its sibling.
    QWidget *sibling = nullptr;
    for (int i = 0; i < splitter->count(); ++i)
      if (splitter->widget(i) != surface) sibling = splitter->widget(i);

    QWidget *splitterParent = splitter->parentWidget();
    if (auto *grand = qobject_cast<QSplitter *>(splitterParent)) {
      grand->replaceWidget(grand->indexOf(splitter), sibling);
    } else if (splitterParent && splitterParent->layout()) {
      delete splitterParent->layout()->replaceWidget(splitter, sibling);
    }
    // Deleting the orphaned splitter also deletes `surface`.
    splitter->deleteLater();
    return;
  }

  // Otherwise this surface is the whole tab.
  const int index = m_tabs->indexOf(parent);
  if (index >= 0) m_tabs->removeTab(index);
  if (parent) parent->deleteLater();  // page; destroys the surface too
  if (m_tabs->count() == 0) close();
}

void MainWindow::closeTab(int index) {
  QWidget *page = m_tabs->widget(index);
  if (!page) return;
  const auto inTab = page->findChildren<GhosttySurface *>();
  for (GhosttySurface *s : inTab) m_surfaces.removeOne(s);
  m_tabs->removeTab(index);
  page->deleteLater();  // destroys every surface in the tab
  if (m_tabs->count() == 0) close();
}

void MainWindow::setSurfaceTitle(GhosttySurface *surface,
                                 const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  m_tabs->setTabText(index, title);
  if (index == m_tabs->currentIndex())
    setWindowTitle(title + QStringLiteral(" — Ghostty"));
}

void MainWindow::tick() {
  if (!m_app) return;
  ghostty_app_tick(m_app);
  // Process exit is handled by libghostty: a normal exit closes the
  // surface via close_surface_cb; an abnormal one fires SHOW_CHILD_EXITED.
}

void MainWindow::onTabCloseRequested(int index) { closeTab(index); }

void MainWindow::onCurrentChanged(int index) {
  GhosttySurface *s = surfaceAt(index);
  if (!s) return;
  s->setFocus();
  setWindowTitle(m_tabs->tabText(index) + QStringLiteral(" — Ghostty"));
}

GhosttySurface *MainWindow::surfaceAt(int index) const {
  QWidget *page = m_tabs->widget(index);
  if (!page) return nullptr;
  const auto surfaces = page->findChildren<GhosttySurface *>();
  return surfaces.isEmpty() ? nullptr : surfaces.first();
}

int MainWindow::tabIndexForSurface(GhosttySurface *surface) const {
  for (int i = 0; i < m_tabs->count(); ++i)
    if (m_tabs->widget(i)->isAncestorOf(surface)) return i;
  return -1;
}

QList<GhosttySurface *> MainWindow::surfacesInTab(int index) const {
  QWidget *page = m_tabs->widget(index);
  if (!page) return {};
  return page->findChildren<GhosttySurface *>();
}

void MainWindow::gotoTab(ghostty_action_goto_tab_e tab) {
  const int n = m_tabs->count();
  if (n == 0) return;
  int index;
  switch (tab) {
    case GHOSTTY_GOTO_TAB_PREVIOUS:
      index = (m_tabs->currentIndex() - 1 + n) % n;
      break;
    case GHOSTTY_GOTO_TAB_NEXT:
      index = (m_tabs->currentIndex() + 1) % n;
      break;
    case GHOSTTY_GOTO_TAB_LAST:
      index = n - 1;
      break;
    default:
      // A positive value is a 1-based tab number.
      index = static_cast<int>(tab) - 1;
      break;
  }
  if (index >= 0 && index < n) m_tabs->setCurrentIndex(index);
}

void MainWindow::gotoSplit(GhosttySurface *from,
                           ghostty_action_goto_split_e dir) {
  const int tab = tabIndexForSurface(from);
  if (tab < 0) return;
  QList<GhosttySurface *> panes = surfacesInTab(tab);
  if (panes.size() < 2) return;

  const auto centerOf = [](GhosttySurface *s) {
    return QRect(s->mapToGlobal(QPoint(0, 0)), s->size()).center();
  };

  GhosttySurface *target = nullptr;
  if (dir == GHOSTTY_GOTO_SPLIT_PREVIOUS ||
      dir == GHOSTTY_GOTO_SPLIT_NEXT) {
    // Cycle through panes in reading order.
    std::sort(panes.begin(), panes.end(),
              [&](GhosttySurface *a, GhosttySurface *b) {
                const QPoint pa = centerOf(a), pb = centerOf(b);
                return pa.y() != pb.y() ? pa.y() < pb.y() : pa.x() < pb.x();
              });
    const int i = panes.indexOf(from);
    const int step = dir == GHOSTTY_GOTO_SPLIT_NEXT ? 1 : -1;
    target = panes[(i + step + panes.size()) % panes.size()];
  } else {
    // Directional: the nearest pane whose center lies that way.
    const QPoint fc = centerOf(from);
    int best = INT_MAX;
    for (GhosttySurface *p : panes) {
      if (p == from) continue;
      const QPoint c = centerOf(p);
      const int dx = c.x() - fc.x(), dy = c.y() - fc.y();
      bool ok = false;
      switch (dir) {
        case GHOSTTY_GOTO_SPLIT_LEFT: ok = dx < 0; break;
        case GHOSTTY_GOTO_SPLIT_RIGHT: ok = dx > 0; break;
        case GHOSTTY_GOTO_SPLIT_UP: ok = dy < 0; break;
        case GHOSTTY_GOTO_SPLIT_DOWN: ok = dy > 0; break;
        default: break;
      }
      if (!ok) continue;
      const int dist = dx * dx + dy * dy;
      if (dist < best) {
        best = dist;
        target = p;
      }
    }
  }

  if (target) target->setFocus();
}

void MainWindow::resizeSplit(GhosttySurface *from,
                             ghostty_action_resize_split_s rs) {
  auto *splitter = qobject_cast<QSplitter *>(from->parentWidget());
  if (!splitter) return;

  const bool horizontal = splitter->orientation() == Qt::Horizontal;
  const bool axisMatches =
      horizontal ? (rs.direction == GHOSTTY_RESIZE_SPLIT_LEFT ||
                    rs.direction == GHOSTTY_RESIZE_SPLIT_RIGHT)
                 : (rs.direction == GHOSTTY_RESIZE_SPLIT_UP ||
                    rs.direction == GHOSTTY_RESIZE_SPLIT_DOWN);
  if (!axisMatches) return;

  QList<int> sizes = splitter->sizes();
  const int idx = splitter->indexOf(from);
  if (idx < 0 || sizes.size() < 2) return;

  const bool grow = rs.direction == GHOSTTY_RESIZE_SPLIT_RIGHT ||
                    rs.direction == GHOSTTY_RESIZE_SPLIT_DOWN;
  const int delta = grow ? rs.amount : -static_cast<int>(rs.amount);
  const int other = idx == 0 ? 1 : idx - 1;
  sizes[idx] = std::max(0, sizes[idx] + delta);
  sizes[other] = std::max(0, sizes[other] - delta);
  splitter->setSizes(sizes);
}

void MainWindow::equalizeSplits(GhosttySurface *from) {
  const int tab = tabIndexForSurface(from);
  if (tab < 0) return;
  QWidget *page = m_tabs->widget(tab);
  const auto splitters = page->findChildren<QSplitter *>();
  for (QSplitter *splitter : splitters) {
    QList<int> sizes;
    for (int i = 0; i < splitter->count(); ++i) sizes.append(1 << 20);
    splitter->setSizes(sizes);
  }
}

// Push `config` to the app and every surface, and adopt it as the live
// config. Takes ownership of `config` (frees the previous one).
void MainWindow::applyConfig(ghostty_config_t config) {
  if (!config) return;
  ghostty_app_update_config(m_app, config);
  for (GhosttySurface *s : m_surfaces)
    if (s->surface()) ghostty_surface_update_config(s->surface(), config);

  if (m_config && m_config != config) ghostty_config_free(m_config);
  m_config = config;
  m_needsPremultiply = configHasCustomShader();
}

void MainWindow::reloadConfig() {
  // Re-read the config from disk in the same order as initialize().
  ghostty_config_t config = ghostty_config_new();
  ghostty_config_load_default_files(config);
  ghostty_config_load_cli_args(config);
  ghostty_config_load_recursive_files(config);
  ghostty_config_finalize(config);
  applyConfig(config);
}

void MainWindow::toggleSplitZoom(GhosttySurface *surface) {
  // Already zoomed: restore the surface into its splitter and the
  // stashed tree back into the tab page.
  if (m_zoomed) {
    GhosttySurface *was = m_zoomed;
    QWidget *page = m_zoomRoot->parentWidget();
    page->layout()->removeWidget(was);
    m_zoomSplitter->insertWidget(m_zoomIndex, was);
    page->layout()->addWidget(m_zoomRoot);
    m_zoomRoot->show();
    m_zoomed = nullptr;
    m_zoomRoot = nullptr;
    m_zoomSplitter = nullptr;
    was->setFocus();
    if (was == surface) return;  // plain toggle-off
    // Zoom requested on a different pane: fall through and zoom it.
  }

  // A surface with no splitter parent is the whole tab — nothing to zoom.
  auto *splitter = qobject_cast<QSplitter *>(surface->parentWidget());
  if (!splitter) return;
  const int tab = tabIndexForSurface(surface);
  if (tab < 0) return;
  QLayout *pageLayout = m_tabs->widget(tab)->layout();
  if (!pageLayout || pageLayout->count() == 0) return;
  QWidget *root = pageLayout->itemAt(0)->widget();
  if (!root) return;

  m_zoomed = surface;
  m_zoomSplitter = splitter;
  m_zoomIndex = splitter->indexOf(surface);
  m_zoomRoot = root;

  // Stash the tree (hidden, still a child of the page) and let the
  // zoomed surface fill the page.
  pageLayout->removeWidget(root);
  root->hide();
  pageLayout->addWidget(surface);
  surface->show();
  surface->setFocus();
}

// --- libghostty runtime callbacks ------------------------------------

void MainWindow::onWakeup(void *ud) {
  // app userdata; hop to the GUI thread to tick.
  auto *self = static_cast<MainWindow *>(ud);
  QMetaObject::invokeMethod(self, "tick", Qt::QueuedConnection);
}

// Map a libghostty mouse shape to the nearest Qt cursor.
static Qt::CursorShape mouseShapeToCursor(ghostty_action_mouse_shape_e s) {
  switch (s) {
    case GHOSTTY_MOUSE_SHAPE_TEXT:
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return Qt::IBeamCursor;
    case GHOSTTY_MOUSE_SHAPE_POINTER:
    case GHOSTTY_MOUSE_SHAPE_ALIAS: return Qt::PointingHandCursor;
    case GHOSTTY_MOUSE_SHAPE_WAIT:
    case GHOSTTY_MOUSE_SHAPE_PROGRESS: return Qt::WaitCursor;
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
    case GHOSTTY_MOUSE_SHAPE_CELL: return Qt::CrossCursor;
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
    case GHOSTTY_MOUSE_SHAPE_NO_DROP: return Qt::ForbiddenCursor;
    case GHOSTTY_MOUSE_SHAPE_GRAB: return Qt::OpenHandCursor;
    case GHOSTTY_MOUSE_SHAPE_GRABBING: return Qt::ClosedHandCursor;
    case GHOSTTY_MOUSE_SHAPE_MOVE:
    case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return Qt::SizeAllCursor;
    case GHOSTTY_MOUSE_SHAPE_COPY: return Qt::DragCopyCursor;
    case GHOSTTY_MOUSE_SHAPE_HELP: return Qt::WhatsThisCursor;
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return Qt::SizeHorCursor;
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return Qt::SizeVerCursor;
    case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return Qt::SizeBDiagCursor;
    case GHOSTTY_MOUSE_SHAPE_NW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return Qt::SizeFDiagCursor;
    default: return Qt::ArrowCursor;  // DEFAULT, CONTEXT_MENU, zoom, ...
  }
}

bool MainWindow::onAction(ghostty_app_t app, ghostty_target_s target,
                          ghostty_action_s action) {
  auto *self = static_cast<MainWindow *>(ghostty_app_userdata(app));
  if (!self) return false;

  // The surface this action targets, if any.
  GhosttySurface *src = nullptr;
  if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface)
    src = static_cast<GhosttySurface *>(
        ghostty_surface_userdata(target.target.surface));

  // Actions may be dispatched from non-GUI threads, so window-touching
  // work is marshalled onto the GUI thread.
  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      // libghostty wants a redraw; schedule one on the terminal window.
      if (src)
        QMetaObject::invokeMethod(src, "requestRender", Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_NEW_TAB:
    case GHOSTTY_ACTION_NEW_WINDOW: {
      ghostty_surface_t parent = src ? src->surface() : nullptr;
      QMetaObject::invokeMethod(
          self, [self, parent]() { self->newTab(parent); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      QMetaObject::invokeMethod(
          self, [self, src, dir]() { self->splitSurface(src, dir); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB:
      if (src)
        QMetaObject::invokeMethod(
            self, [self, src]() { self->removeSurface(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      QMetaObject::invokeMethod(
          self, [self, src, t]() { self->setSurfaceTitle(src, t); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_GOTO_TAB: {
      const ghostty_action_goto_tab_e tab = action.action.goto_tab;
      QMetaObject::invokeMethod(
          self, [self, tab]() { self->gotoTab(tab); }, Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_GOTO_SPLIT: {
      if (!src) return false;
      const ghostty_action_goto_split_e dir = action.action.goto_split;
      QMetaObject::invokeMethod(
          self, [self, src, dir]() { self->gotoSplit(src, dir); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_RESIZE_SPLIT: {
      if (!src) return false;
      const ghostty_action_resize_split_s rs = action.action.resize_split;
      QMetaObject::invokeMethod(
          self, [self, src, rs]() { self->resizeSplit(src, rs); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      if (src)
        QMetaObject::invokeMethod(
            self, [self, src]() { self->equalizeSplits(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      QMetaObject::invokeMethod(
          self,
          [self]() {
            if (self->isFullScreen())
              self->showNormal();
            else
              self->showFullScreen();
          },
          Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      QMetaObject::invokeMethod(
          self,
          [self]() {
            if (self->isMaximized())
              self->showNormal();
            else
              self->showMaximized();
          },
          Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      QMetaObject::invokeMethod(
          self, [self]() { self->close(); }, Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED: {
      if (!src) return false;
      const int code =
          static_cast<int>(action.action.child_exited.exit_code);
      QMetaObject::invokeMethod(
          src, [src, code]() { src->showChildExited(code); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      if (src)
        QMetaObject::invokeMethod(
            self, [self, src]() { self->toggleSplitZoom(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      QMetaObject::invokeMethod(
          self, [self]() { self->reloadConfig(); }, Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_CONFIG_CHANGE: {
      // Clone libghostty's config so it outlives this callback; applyConfig
      // adopts the clone as the live config.
      ghostty_config_t cfg =
          ghostty_config_clone(action.action.config_change.config);
      QMetaObject::invokeMethod(
          self, [self, cfg]() { self->applyConfig(cfg); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_INITIAL_SIZE: {
      const ghostty_action_initial_size_s sz = action.action.initial_size;
      QMetaObject::invokeMethod(
          self,
          [self, sz]() {
            // The action carries device pixels; resize() takes logical.
            const double dpr = self->devicePixelRatioF();
            self->resize(static_cast<int>(sz.width / dpr),
                         static_cast<int>(sz.height / dpr));
          },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      QMetaObject::invokeMethod(
          self, [self]() { self->close(); }, Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_RING_BELL:
      // Taskbar/window attention hint. Honoring `bell-features` config
      // (audio file, volume) is a future refinement.
      QMetaObject::invokeMethod(
          self, [self]() { QApplication::alert(self); },
          Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_MOUSE_SHAPE: {
      if (!src) return false;
      const Qt::CursorShape shape =
          mouseShapeToCursor(action.action.mouse_shape);
      QMetaObject::invokeMethod(
          src, [src, shape]() { src->setCursor(shape); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK: {
      if (!src) return true;
      const ghostty_action_mouse_over_link_s l = action.action.mouse_over_link;
      const QString url =
          l.url && l.len ? QString::fromUtf8(l.url, l.len) : QString();
      QMetaObject::invokeMethod(
          src, [src, url]() { src->setToolTip(url); }, Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_OPEN_URL: {
      const ghostty_action_open_url_s u = action.action.open_url;
      if (!u.url || !u.len) return true;
      const QString s = QString::fromUtf8(u.url, static_cast<int>(u.len));
      QMetaObject::invokeMethod(
          self,
          [s]() {
            QDesktopServices::openUrl(
                QUrl::fromUserInput(s, QString(), QUrl::AssumeLocalFile));
          },
          Qt::QueuedConnection);
      return true;
    }

    default:
      // Inspector, command palette, search, etc. are not handled yet.
      return false;
  }
}

bool MainWindow::onReadClipboard(void *ud, ghostty_clipboard_e loc,
                                 void *state) {
  // surface userdata. Called synchronously when libghostty needs
  // clipboard contents (paste).
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface || !surface->surface()) return false;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QByteArray text = QGuiApplication::clipboard()->text(mode).toUtf8();
  ghostty_surface_complete_clipboard_request(surface->surface(),
                                             text.constData(), state, true);
  return true;
}

void MainWindow::onConfirmReadClipboard(void *ud, const char *str, void *state,
                                        ghostty_clipboard_request_e) {
  // The scaffold trusts pastes rather than showing an unsafe-paste
  // confirmation dialog. TODO: a real confirmation prompt.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (surface && surface->surface())
    ghostty_surface_complete_clipboard_request(surface->surface(), str, state,
                                               true);
}

void MainWindow::onWriteClipboard(void *ud, ghostty_clipboard_e loc,
                                  const ghostty_clipboard_content_s *content,
                                  size_t n, bool) {
  if (n == 0 || !content[0].data) return;
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface) return;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QString text = QString::fromUtf8(content[0].data);
  QMetaObject::invokeMethod(
      surface->owner(),
      [text, mode]() { QGuiApplication::clipboard()->setText(text, mode); },
      Qt::QueuedConnection);
}

void MainWindow::onCloseSurface(void *ud, bool) {
  // surface userdata.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface) return;
  MainWindow *self = surface->owner();
  QMetaObject::invokeMethod(
      self, [self, surface]() { self->removeSurface(surface); },
      Qt::QueuedConnection);
}
