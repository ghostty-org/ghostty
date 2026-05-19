#include "MainWindow.h"

#include <algorithm>
#include <climits>
#include <cstdio>

#include <QApplication>
#include <QAudioOutput>
#include <QByteArray>
#include <QClipboard>
#include <QCloseEvent>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QList>
#include <QMap>
#include <QMediaPlayer>
#include <QMessageBox>
#include <QPoint>
#include <QRect>
#include <QShowEvent>
#include <QSplitter>
#include <QStringList>
#include <QUrl>
#include <QString>
#include <QStyleHints>
#include <QTabBar>
#include <QTabWidget>
#include <QTimer>
#include <QVariant>
#include <QVBoxLayout>

#include "CommandPalette.h"
#include "GhosttySurface.h"
#include "WindowBlur.h"

// Prefix marking a tab with an unacknowledged bell (bell-features title).
static const QString kBellMark = QStringLiteral("● ");

// Process-shared libghostty state — see MainWindow.h.
ghostty_app_t MainWindow::s_app = nullptr;
ghostty_config_t MainWindow::s_config = nullptr;
bool MainWindow::s_needsPremultiply = false;
QList<MainWindow *> MainWindow::s_windows;
QTimer *MainWindow::s_quitTimer = nullptr;
int MainWindow::s_quitDelayMs = 0;
std::atomic<bool> MainWindow::s_tickPending{false};

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
  s_windows.removeOne(this);

  // Destroy this window's surfaces (freeing their ghostty_surface_t)
  // before any app teardown; Qt's own child cleanup runs after this body.
  qDeleteAll(m_surfaces);
  m_surfaces.clear();

  // The shared app and config outlive every window but the last.
  if (s_windows.isEmpty()) {
    if (s_quitTimer) {
      delete s_quitTimer;
      s_quitTimer = nullptr;
    }
    if (s_app) {
      ghostty_app_free(s_app);
      s_app = nullptr;
    }
    if (s_config) {
      ghostty_config_free(s_config);
      s_config = nullptr;
    }
  }
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

// Scan the primary Ghostty config file for `key = value`, returning the
// last matching value (empty if absent). For keys not cleanly exposed by
// ghostty_config_get.
static QString configValue(const QString &key) {
  QString dir = qEnvironmentVariable("XDG_CONFIG_HOME");
  if (dir.isEmpty()) dir = QDir::homePath() + QStringLiteral("/.config");

  QFile f(dir + QStringLiteral("/ghostty/config"));
  if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return {};

  const QByteArray wanted = key.toUtf8();
  QString value;
  while (!f.atEnd()) {
    const QByteArray line = f.readLine().trimmed();
    const int eq = line.indexOf('=');
    if (eq < 0 || line.left(eq).trimmed() != wanted) continue;
    value = QString::fromUtf8(line.mid(eq + 1).trimmed());
  }
  return value;
}

// Post a desktop notification via the freedesktop D-Bus service.
static void postNotification(const QString &title, const QString &body) {
  QDBusMessage msg = QDBusMessage::createMethodCall(
      QStringLiteral("org.freedesktop.Notifications"),
      QStringLiteral("/org/freedesktop/Notifications"),
      QStringLiteral("org.freedesktop.Notifications"),
      QStringLiteral("Notify"));
  msg.setArguments({
      QStringLiteral("Ghostty"),             // app_name
      uint(0),                               // replaces_id
      QStringLiteral("utilities-terminal"),  // app_icon
      title,                                 // summary
      body,                                  // body
      QStringList(),                         // actions
      QVariantMap(),                         // hints
      -1,                                    // expire_timeout (default)
  });
  QDBusConnection::sessionBus().send(msg);  // fire-and-forget
}

// Drive the taskbar progress bar via the Unity LauncherEntry D-Bus API
// (honored by the KDE task manager), keyed to ghostty.desktop.
static void postProgress(bool visible, double fraction) {
  QDBusMessage msg = QDBusMessage::createSignal(
      QStringLiteral("/com/canonical/unity/launcherentry/ghostty"),
      QStringLiteral("com.canonical.Unity.LauncherEntry"),
      QStringLiteral("Update"));
  QVariantMap props;
  props[QStringLiteral("progress")] = fraction;
  props[QStringLiteral("progress-visible")] = visible;
  msg.setArguments(
      {QStringLiteral("application://ghostty.desktop"), QVariant(props)});
  QDBusConnection::sessionBus().send(msg);
}

bool MainWindow::initialize() {
  s_windows.append(this);

  // The first window builds the shared libghostty app and config; every
  // later window reuses them.
  if (!s_app) {
    // Load configuration in the same order as the reference apprt.
    s_config = ghostty_config_new();
    ghostty_config_load_default_files(s_config);
    ghostty_config_load_cli_args(s_config);
    ghostty_config_load_recursive_files(s_config);
    ghostty_config_finalize(s_config);
    s_needsPremultiply = configHasCustomShader();

    ghostty_runtime_config_s rt = {};
    // No app userdata: actions are routed to a window via their target
    // surface, and app-level actions via the s_windows registry.
    rt.userdata = nullptr;
    rt.supports_selection_clipboard = true;
    rt.wakeup_cb = onWakeup;
    rt.action_cb = onAction;
    rt.read_clipboard_cb = onReadClipboard;
    rt.confirm_read_clipboard_cb = onConfirmReadClipboard;
    rt.write_clipboard_cb = onWriteClipboard;
    rt.close_surface_cb = onCloseSurface;

    s_app = ghostty_app_new(&rt, s_config);
    if (!s_app) {
      std::fprintf(stderr, "[ghostty] ghostty_app_new failed\n");
      return false;
    }

    // quit-after-last-window-closed: Qt's native "quit on last window"
    // covers the common (no-delay) case; a configured delay is honored
    // through the libghostty quit_timer action (see handleQuitTimer).
    const bool quitAfter = configBool("quit-after-last-window-closed", true);
    unsigned long long delayNs = 0;
    ghostty_config_get(s_config, &delayNs,
                       "quit-after-last-window-closed-delay",
                       qstrlen("quit-after-last-window-closed-delay"));
    s_quitDelayMs = quitAfter ? static_cast<int>(delayNs / 1000000ULL) : 0;
    QApplication::setQuitOnLastWindowClosed(quitAfter && s_quitDelayMs == 0);
  }

  // Per-window startup window state, applied before show().
  // window-decoration `none` drops the native frame; `auto`/`server`/
  // `client` keep a decorated window (the compositor picks the side on
  // Wayland).
  if (configString("window-decoration") == QLatin1String("none"))
    setWindowFlag(Qt::FramelessWindowHint, true);
  // fullscreen wins over maximize; its enum is `false` when unset.
  const QString fullscreen = configString("fullscreen");
  if (!fullscreen.isEmpty() && fullscreen != QLatin1String("false"))
    setWindowState(windowState() | Qt::WindowFullScreen);
  else if (configBool("maximize", false))
    setWindowState(windowState() | Qt::WindowMaximized);

  // Tab-bar policy and colour scheme.
  applyWindowConfig();

  // 60fps frame timer: a backstop tick plus rendering. onWakeup drives
  // extra ticks between frames for input responsiveness.
  auto *timer = new QTimer(this);
  connect(timer, &QTimer::timeout, this, &MainWindow::frame);
  timer->start(16);

  // The first tab is created in showEvent, not here: see below.
  return true;
}

MainWindow *MainWindow::newWindow(ghostty_surface_t parent) {
  auto *w = new MainWindow;
  w->setAttribute(Qt::WA_DeleteOnClose);  // self-destruct when closed
  w->m_firstTabParent = parent;           // first tab inherits from `parent`
  if (!w->initialize()) {
    delete w;
    return nullptr;
  }
  w->resize(800, 600);
  w->show();
  return w;
}

void MainWindow::showEvent(QShowEvent *event) {
  QWidget::showEvent(event);

  // Defer the first terminal until the device pixel ratio has settled.
  // On Wayland the fractional scale arrives asynchronously after the
  // window appears; a surface created before then spawns its shell at a
  // stale scale, so a shell greeting (fastfetch) queries a wrong cell
  // size and mis-sizes Kitty images. event() creates the tab as soon as
  // a DevicePixelRatioChange lands; this timer is the fallback for when
  // the ratio was already correct at show.
  if (m_firstTabPending)
    QTimer::singleShot(250, this, [this] { createFirstTab(); });

  // Apply background blur once the native (Wayland/X11) surface exists;
  // a zero-delay timer defers past the platform-window creation.
  QTimer::singleShot(0, this, [this] { applyBlur(); });
}

bool MainWindow::event(QEvent *e) {
  // The fractional scale settling after the window appears arrives as a
  // DevicePixelRatioChange — the earliest point the first surface can be
  // created with a correct, stable scale.
  if (e->type() == QEvent::DevicePixelRatioChange) createFirstTab();
  return QWidget::event(e);
}

void MainWindow::createFirstTab() {
  if (!m_firstTabPending) return;
  m_firstTabPending = false;
  newTab(m_firstTabParent);
  m_firstTabParent = nullptr;
}

GhosttySurface *MainWindow::newTab(ghostty_surface_t parent) {
  auto *surface = new GhosttySurface(s_app, this, parent);
  m_surfaces.append(surface);

  // The tab page hosts the tab's split tree (initially one surface).
  // It stays opaque chrome; the GhosttySurface paints over it.
  auto *page = new QWidget(m_tabs);
  auto *pageLayout = new QVBoxLayout(page);
  pageLayout->setContentsMargins(0, 0, 0, 0);
  pageLayout->addWidget(surface);

  // window-new-tab-position: place the tab right after the current one,
  // or append it at the end (the default).
  int index;
  if (configString("window-new-tab-position") == QLatin1String("current") &&
      m_tabs->count() > 0)
    index = m_tabs->insertTab(m_tabs->currentIndex() + 1, page,
                              QStringLiteral("Ghostty"));
  else
    index = m_tabs->addTab(page, QStringLiteral("Ghostty"));
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

  auto *surface = new GhosttySurface(s_app, this, target->surface());
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
  // The surface close was already confirmed; don't re-prompt on the
  // window close it may trigger.
  if (m_tabs->count() == 0) {
    m_skipCloseConfirm = true;
    close();
  }
}

void MainWindow::closeTab(int index) {
  QWidget *page = m_tabs->widget(index);
  if (!page) return;
  const auto inTab = page->findChildren<GhosttySurface *>();
  for (GhosttySurface *s : inTab) m_surfaces.removeOne(s);
  m_tabs->removeTab(index);
  page->deleteLater();  // destroys every surface in the tab
  if (m_tabs->count() == 0) {
    m_skipCloseConfirm = true;
    close();
  }
}

void MainWindow::setSurfaceTitle(GhosttySurface *surface,
                                 const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  // Store the terminal title as the tab's base; updateTabText decides
  // whether it or a manual override is shown.
  QStringList data = m_tabs->tabBar()->tabData(index).toStringList();
  while (data.size() < 2) data.append(QString());
  data[0] = title;
  m_tabs->tabBar()->setTabData(index, data);
  updateTabText(index);
}

void MainWindow::setTabTitleOverride(GhosttySurface *surface,
                                     const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  QStringList data = m_tabs->tabBar()->tabData(index).toStringList();
  while (data.size() < 2) data.append(QString());
  data[1] = title;  // empty clears the override
  m_tabs->tabBar()->setTabData(index, data);
  updateTabText(index);
}

void MainWindow::copyTitleToClipboard() {
  const int tab = m_tabs->currentIndex();
  if (tab < 0) return;
  const QStringList data = m_tabs->tabBar()->tabData(tab).toStringList();
  const QString title =
      !data.value(1).isEmpty() ? data.value(1) : data.value(0);
  if (!title.isEmpty()) QGuiApplication::clipboard()->setText(title);
}

void MainWindow::frame() {
  if (!s_app) return;
  ghostty_app_tick(s_app);
  // Rendering happens only here, so a flood of RENDER actions cannot
  // saturate the GUI thread — each surface renders at most once a frame.
  for (GhosttySurface *s : m_surfaces) s->renderIfDirty();
}

void MainWindow::onTabCloseRequested(int index) {
  if (!confirmCloseSurfaces(surfacesInTab(index))) return;
  closeTab(index);
}

void MainWindow::closeEvent(QCloseEvent *e) {
  // confirm-close-surface: prompt once for the whole window unless this
  // close was already confirmed (e.g. the last tab/surface closing).
  if (!m_skipCloseConfirm && !confirmCloseSurfaces(m_surfaces)) {
    e->ignore();
    return;
  }
  e->accept();
}

bool MainWindow::confirmCloseSurfaces(
    const QList<GhosttySurface *> &surfaces) {
  bool needsConfirm = false;
  for (GhosttySurface *s : surfaces)
    if (s->surface() && ghostty_surface_needs_confirm_quit(s->surface()))
      needsConfirm = true;
  if (!needsConfirm) return true;

  const auto choice = QMessageBox::question(
      this, QStringLiteral("Close"),
      QStringLiteral("There are still running processes. Close anyway?"),
      QMessageBox::Yes | QMessageBox::No, QMessageBox::No);
  return choice == QMessageBox::Yes;
}

void MainWindow::closeAllWindows() {
  // One process-level prompt covers every window.
  if (s_app && ghostty_app_needs_confirm_quit(s_app)) {
    const auto choice = QMessageBox::question(
        s_windows.isEmpty() ? nullptr : s_windows.first(),
        QStringLiteral("Quit"),
        QStringLiteral("There are still running processes. Quit anyway?"),
        QMessageBox::Yes | QMessageBox::No, QMessageBox::No);
    if (choice != QMessageBox::Yes) return;
  }
  // Copy: each close() may delete the window and mutate s_windows.
  const QList<MainWindow *> windows = s_windows;
  for (MainWindow *w : windows) {
    w->m_skipCloseConfirm = true;
    w->close();
  }
  // An explicit quit/close-all should end the process even when
  // quit-after-last-window-closed left quitOnLastWindowClosed off.
  qApp->quit();
}

void MainWindow::toggleVisibility() {
  // If anything is showing, hide everything; otherwise reveal it all.
  bool anyVisible = false;
  for (MainWindow *w : s_windows)
    if (w->isVisible()) {
      anyVisible = true;
      break;
    }
  for (MainWindow *w : s_windows) {
    if (anyVisible) {
      w->hide();
    } else {
      w->show();
      w->raise();
      w->activateWindow();
    }
  }
}

void MainWindow::handleQuitTimer(bool start) {
  // Only meaningful when a delay is configured; otherwise Qt's
  // quitOnLastWindowClosed already handles the quit.
  if (s_quitDelayMs <= 0) return;
  if (start) {
    if (!s_quitTimer) {
      s_quitTimer = new QTimer;
      s_quitTimer->setSingleShot(true);
      QObject::connect(s_quitTimer, &QTimer::timeout, qApp,
                       &QApplication::quit);
    }
    s_quitTimer->start(s_quitDelayMs);
  } else if (s_quitTimer) {
    s_quitTimer->stop();
  }
}

void MainWindow::onCurrentChanged(int index) {
  GhosttySurface *s = surfaceAt(index);
  if (!s) return;
  s->setFocus();
  // Acknowledge any bell `title` mark now that the tab is visible.
  for (GhosttySurface *surf : surfacesInTab(index)) surf->setBellTitle(false);
  updateTabText(index);
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

void MainWindow::moveTab(int amount) {
  const int n = m_tabs->count();
  if (n < 2 || amount == 0) return;
  const int from = m_tabs->currentIndex();
  const int to = std::clamp(from + amount, 0, n - 1);
  if (to != from)
    if (QTabBar *bar = m_tabs->findChild<QTabBar *>()) bar->moveTab(from, to);
}

void MainWindow::ringBell(GhosttySurface *surface) {
  // bell-features is a packed struct, returned by ghostty_config_get as
  // a bitfield: bit 0 system, 1 audio, 2 attention, 3 title, 4 border.
  unsigned int features = 1u << 2;  // fall back to `attention`
  ghostty_config_get(s_config, &features, "bell-features",
                     qstrlen("bell-features"));
  if (features & (1u << 2)) QApplication::alert(this);  // attention
  if (features & (1u << 0)) QApplication::beep();       // system
  if (features & (1u << 1)) playBellAudio();            // audio

  if (!surface) return;
  if (features & (1u << 4)) surface->flashBorder();     // border
  if (features & (1u << 3)) {                           // title
    const int tab = tabIndexForSurface(surface);
    // Marking the current tab is pointless — you are looking at it.
    if (tab >= 0 && tab != m_tabs->currentIndex()) {
      surface->setBellTitle(true);
      updateTabText(tab);
    }
  }
}

bool MainWindow::tabBellMarked(int tab) const {
  for (GhosttySurface *s : surfacesInTab(tab))
    if (s->bellTitle()) return true;
  return false;
}

void MainWindow::updateTabText(int tab) {
  if (tab < 0 || tab >= m_tabs->count()) return;
  const QStringList data = m_tabs->tabBar()->tabData(tab).toStringList();
  const QString base = data.value(0);
  const QString override = data.value(1);
  QString text = !override.isEmpty() ? override
                 : !base.isEmpty()   ? base
                                     : QStringLiteral("Ghostty");
  m_tabs->setTabText(tab, tabBellMarked(tab) ? kBellMark + text : text);
  if (tab == m_tabs->currentIndex())
    setWindowTitle(text + QStringLiteral(" — Ghostty"));
}

void MainWindow::playBellAudio() {
  QString path = configValue(QStringLiteral("bell-audio-path"));
  if (path.isEmpty()) return;
  if (path.startsWith(QLatin1String("~/")))
    path = QDir::homePath() + path.mid(1);

  bool ok = false;
  const double volume =
      configValue(QStringLiteral("bell-audio-volume")).toDouble(&ok);

  if (!m_bellPlayer) {
    m_bellAudio = new QAudioOutput(this);
    m_bellPlayer = new QMediaPlayer(this);
    m_bellPlayer->setAudioOutput(m_bellAudio);
  }
  m_bellAudio->setVolume(ok ? volume : 0.5);
  m_bellPlayer->setSource(QUrl::fromLocalFile(path));
  m_bellPlayer->play();
}

// Push `config` to the shared app and every surface of every window,
// and adopt it as the live config. Takes ownership of `config` (frees
// the previous one).
void MainWindow::applyConfig(ghostty_config_t config) {
  if (!config) return;
  ghostty_app_update_config(s_app, config);
  for (MainWindow *w : s_windows)
    for (GhosttySurface *s : w->m_surfaces)
      if (s->surface()) ghostty_surface_update_config(s->surface(), config);

  if (s_config && s_config != config) ghostty_config_free(s_config);
  s_config = config;
  s_needsPremultiply = configHasCustomShader();

  // Re-apply window settings that a reload may have changed.
  for (MainWindow *w : s_windows) {
    w->applyWindowConfig();
    w->applyBlur();
  }
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

QString MainWindow::configString(const char *key) const {
  const char *value = nullptr;
  if (!s_config ||
      !ghostty_config_get(s_config, &value, key, qstrlen(key)) || !value)
    return {};
  return QString::fromUtf8(value);
}

bool MainWindow::configBool(const char *key, bool fallback) const {
  bool value = fallback;  // ghostty_config_get leaves it untouched if absent
  if (s_config) ghostty_config_get(s_config, &value, key, qstrlen(key));
  return value;
}

bool MainWindow::focusFollowsMouse() const {
  return configBool("focus-follows-mouse", false);
}

void MainWindow::applyWindowConfig() {
  // window-show-tab-bar: always shown / auto-hidden with a lone tab /
  // never shown.
  const QString tabBar = configString("window-show-tab-bar");
  if (tabBar == QLatin1String("never")) {
    m_tabs->setTabBarAutoHide(false);
    m_tabs->tabBar()->hide();
  } else if (tabBar == QLatin1String("always")) {
    m_tabs->setTabBarAutoHide(false);
    m_tabs->tabBar()->show();
  } else {  // auto (the default)
    m_tabs->tabBar()->show();
    m_tabs->setTabBarAutoHide(true);
  }

  // window-theme: force a light/dark scheme, or follow the OS. `auto`
  // is rewritten to `system` on Linux by libghostty; `ghostty` follows
  // the configured background colour's luminance.
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
  const QString theme = configString("window-theme");
  Qt::ColorScheme scheme = Qt::ColorScheme::Unknown;  // Unknown = follow OS
  if (theme == QLatin1String("dark")) {
    scheme = Qt::ColorScheme::Dark;
  } else if (theme == QLatin1String("light")) {
    scheme = Qt::ColorScheme::Light;
  } else if (theme == QLatin1String("ghostty")) {
    ghostty_config_color_s bg{};
    if (ghostty_config_get(s_config, &bg, "background", qstrlen("background"))) {
      const double luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
      scheme = luma < 128.0 ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light;
    }
  }
  QGuiApplication::styleHints()->setColorScheme(scheme);
#endif
}

void MainWindow::toggleCommandPalette(GhosttySurface *surface) {
  if (!m_commandPalette) m_commandPalette = new CommandPalette(this);
  m_commandPalette->toggleFor(surface);
}

void MainWindow::applyBlur() {
  // background-blur is a union whose C value is an i16: 0 (and the
  // macOS-only negatives) means off, a positive radius means on. KWin
  // uses its own configured radius, so only on/off matters here.
  short blur = 0;
  if (s_config)
    ghostty_config_get(s_config, &blur, "background-blur",
                       qstrlen("background-blur"));
  applyWindowBlur(this, blur > 0);
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

void MainWindow::onWakeup(void *) {
  // Coalesce: queue a shared-app tick only when one is not already
  // pending, so a chatty surface cannot flood the event loop. May be
  // called off-thread, so it marshals onto qApp (always alive) rather
  // than any particular window.
  if (s_tickPending.exchange(true)) return;
  QMetaObject::invokeMethod(
      qApp,
      []() {
        s_tickPending.store(false);
        if (s_app) ghostty_app_tick(s_app);
      },
      Qt::QueuedConnection);
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

// Format a keybind trigger as a human-readable chord, e.g. "Ctrl+B".
static QString formatTrigger(const ghostty_input_trigger_s &t) {
  QString s;
  if (t.mods & GHOSTTY_MODS_CTRL) s += QStringLiteral("Ctrl+");
  if (t.mods & GHOSTTY_MODS_ALT) s += QStringLiteral("Alt+");
  if (t.mods & GHOSTTY_MODS_SHIFT) s += QStringLiteral("Shift+");
  if (t.mods & GHOSTTY_MODS_SUPER) s += QStringLiteral("Super+");
  switch (t.tag) {
    case GHOSTTY_TRIGGER_UNICODE:
      s += QString(QChar(t.key.unicode)).toUpper();
      break;
    case GHOSTTY_TRIGGER_PHYSICAL: {
      const ghostty_input_key_e k = t.key.physical;
      if (k >= GHOSTTY_KEY_DIGIT_0 && k <= GHOSTTY_KEY_DIGIT_9)
        s += QChar('0' + (k - GHOSTTY_KEY_DIGIT_0));
      else if (k >= GHOSTTY_KEY_A && k <= GHOSTTY_KEY_Z)
        s += QChar('A' + (k - GHOSTTY_KEY_A));
      else
        s += QStringLiteral("•");  // an unmapped physical key
      break;
    }
    default:
      s += QStringLiteral("…");  // catch-all
      break;
  }
  return s;
}

bool MainWindow::onAction(ghostty_app_t, ghostty_target_s target,
                          ghostty_action_s action) {
  // The surface this action targets, if any.
  GhosttySurface *src = nullptr;
  if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface)
    src = static_cast<GhosttySurface *>(
        ghostty_surface_userdata(target.target.surface));

  // The window the action applies to: the target surface's window, or
  // (for app-level actions) any live window. Surface/window work is
  // marshalled onto `win` so it is cancelled if that window goes away.
  MainWindow *win = src ? src->owner()
                        : (s_windows.isEmpty() ? nullptr : s_windows.first());

  // Actions may be dispatched from non-GUI threads, so window-touching
  // work is marshalled onto the GUI thread.
  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      // Mark the surface dirty; the frame timer renders it. No event is
      // queued here — a busy surface would otherwise flood the loop.
      if (src) src->markDirty();
      return true;

    case GHOSTTY_ACTION_NEW_TAB: {
      if (!win) return false;
      ghostty_surface_t parent = src ? src->surface() : nullptr;
      QMetaObject::invokeMethod(
          win, [win, parent]() { win->newTab(parent); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_NEW_WINDOW: {
      ghostty_surface_t parent = src ? src->surface() : nullptr;
      QMetaObject::invokeMethod(
          qApp, [parent]() { MainWindow::newWindow(parent); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      QMetaObject::invokeMethod(
          win, [win, src, dir]() { win->splitSurface(src, dir); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB:
      if (src)
        QMetaObject::invokeMethod(
            win,
            [win, src]() {
              if (win->confirmCloseSurfaces({src})) win->removeSurface(src);
            },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      QMetaObject::invokeMethod(
          win, [win, src, t]() { win->setSurfaceTitle(src, t); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_SET_TAB_TITLE: {
      // A manual tab-title override (an empty string clears it).
      if (!src) return true;
      const char *title = action.action.set_tab_title.title;
      const QString t = QString::fromUtf8(title ? title : "");
      QMetaObject::invokeMethod(
          win, [win, src, t]() { win->setTabTitleOverride(src, t); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_PROMPT_TITLE: {
      if (!src) return true;
      const bool tabScope =
          action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB;
      QMetaObject::invokeMethod(
          src, [src, tabScope]() { src->promptTitle(tabScope); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      if (win)
        QMetaObject::invokeMethod(
            win, [win]() { win->copyTitleToClipboard(); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      if (win)
        QMetaObject::invokeMethod(
            win,
            [win]() {
              win->resize(win->m_defaultWindowSize.isValid()
                              ? win->m_defaultWindowSize
                              : QSize(800, 600));
            },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_KEY_SEQUENCE: {
      if (!src) return true;
      const ghostty_action_key_sequence_s ks = action.action.key_sequence;
      if (!ks.active) {
        QMetaObject::invokeMethod(src, [src]() { src->endKeySequence(); },
                                  Qt::QueuedConnection);
        return true;
      }
      const QString chord = formatTrigger(ks.trigger);
      QMetaObject::invokeMethod(
          src, [src, chord]() { src->pushKeySequence(chord); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_GOTO_TAB: {
      if (!win) return false;
      const ghostty_action_goto_tab_e tab = action.action.goto_tab;
      QMetaObject::invokeMethod(
          win, [win, tab]() { win->gotoTab(tab); }, Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_GOTO_SPLIT: {
      if (!src) return false;
      const ghostty_action_goto_split_e dir = action.action.goto_split;
      QMetaObject::invokeMethod(
          win, [win, src, dir]() { win->gotoSplit(src, dir); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_RESIZE_SPLIT: {
      if (!src) return false;
      const ghostty_action_resize_split_s rs = action.action.resize_split;
      QMetaObject::invokeMethod(
          win, [win, src, rs]() { win->resizeSplit(src, rs); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      if (src)
        QMetaObject::invokeMethod(
            win, [win, src]() { win->equalizeSplits(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      if (!win) return false;
      QMetaObject::invokeMethod(
          win,
          [win]() {
            if (win->isFullScreen())
              win->showNormal();
            else
              win->showFullScreen();
          },
          Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      if (!win) return false;
      QMetaObject::invokeMethod(
          win,
          [win]() {
            if (win->isMaximized())
              win->showNormal();
            else
              win->showMaximized();
          },
          Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      QMetaObject::invokeMethod(qApp, []() { MainWindow::closeAllWindows(); },
                                Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_QUIT_TIMER: {
      const bool start =
          action.action.quit_timer == GHOSTTY_QUIT_TIMER_START;
      QMetaObject::invokeMethod(
          qApp, [start]() { MainWindow::handleQuitTimer(start); },
          Qt::QueuedConnection);
      return true;
    }

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
            win, [win, src]() { win->toggleSplitZoom(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_OPEN_CONFIG: {
      // libghostty opens the config file in the user's editor itself and
      // returns the path; we only need to free that string.
      ghostty_string_s path = ghostty_config_open_path();
      ghostty_string_free(path);
      return true;
    }

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      if (win)
        QMetaObject::invokeMethod(
            win, [win]() { win->reloadConfig(); }, Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_CONFIG_CHANGE: {
      // Clone libghostty's config so it outlives this callback; applyConfig
      // adopts the clone as the live config (and applies it to every
      // window). Free the clone ourselves if there is no window to adopt it.
      ghostty_config_t cfg =
          ghostty_config_clone(action.action.config_change.config);
      if (win)
        QMetaObject::invokeMethod(
            win, [win, cfg]() { win->applyConfig(cfg); },
            Qt::QueuedConnection);
      else
        ghostty_config_free(cfg);
      return true;
    }

    case GHOSTTY_ACTION_INITIAL_SIZE: {
      if (!win) return false;
      const ghostty_action_initial_size_s sz = action.action.initial_size;
      QMetaObject::invokeMethod(
          win,
          [win, sz]() {
            // The action carries device pixels; resize() takes logical.
            const double dpr = win->devicePixelRatioF();
            const QSize logical(static_cast<int>(sz.width / dpr),
                                static_cast<int>(sz.height / dpr));
            win->m_defaultWindowSize = logical;  // for RESET_WINDOW_SIZE
            win->resize(logical);
          },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      if (win)
        QMetaObject::invokeMethod(win, [win]() { win->close(); },
                                  Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_RING_BELL:
      if (win)
        QMetaObject::invokeMethod(win, [win, src]() { win->ringBell(src); },
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
          qApp,
          [s]() {
            QDesktopServices::openUrl(
                QUrl::fromUserInput(s, QString(), QUrl::AssumeLocalFile));
          },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION: {
      const ghostty_action_desktop_notification_s n =
          action.action.desktop_notification;
      const QString title = QString::fromUtf8(n.title ? n.title : "");
      const QString body = QString::fromUtf8(n.body ? n.body : "");
      QMetaObject::invokeMethod(
          qApp, [title, body]() { postNotification(title, body); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_COMMAND_FINISHED: {
      if (!src) return true;
      const int code = action.action.command_finished.exit_code;
      QMetaObject::invokeMethod(
          src,
          [src, code]() {
            if (!src->consumeCommandNotify()) return;
            postNotification(
                QStringLiteral("Command finished"),
                code >= 0 ? QStringLiteral("Exited with code %1").arg(code)
                          : QStringLiteral("The command completed."));
          },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_MOVE_TAB: {
      const int amount = static_cast<int>(action.action.move_tab.amount);
      if (win)
        QMetaObject::invokeMethod(
            win, [win, amount]() { win->moveTab(amount); },
            Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY: {
      if (!src) return false;
      const bool hidden =
          action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN;
      QMetaObject::invokeMethod(
          src,
          [src, hidden]() {
            src->setCursor(hidden ? Qt::BlankCursor : Qt::ArrowCursor);
          },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_RENDERER_HEALTH:
      if (action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY)
        std::fprintf(stderr, "[ghostty] renderer reported unhealthy\n");
      return true;

    case GHOSTTY_ACTION_SCROLLBAR: {
      if (!src) return false;
      const ghostty_action_scrollbar_s s = action.action.scrollbar;
      QMetaObject::invokeMethod(
          src,
          [src, s]() { src->updateScrollbar(s.total, s.offset, s.len); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_PROGRESS_REPORT: {
      const ghostty_action_progress_report_s p = action.action.progress_report;
      const bool visible = p.state != GHOSTTY_PROGRESS_STATE_REMOVE;
      const double fraction = p.progress >= 0 ? p.progress / 100.0 : 0.0;
      QMetaObject::invokeMethod(
          qApp, [visible, fraction]() { postProgress(visible, fraction); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      QMetaObject::invokeMethod(qApp,
                                []() { MainWindow::toggleVisibility(); },
                                Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      if (win)
        QMetaObject::invokeMethod(
            win, [win, src]() { win->toggleCommandPalette(src); },
            Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_START_SEARCH: {
      if (!src) return true;
      const char *needle = action.action.start_search.needle;
      const QString n = QString::fromUtf8(needle ? needle : "");
      QMetaObject::invokeMethod(src, [src, n]() { src->openSearch(n); },
                                Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_END_SEARCH:
      if (src)
        QMetaObject::invokeMethod(src, [src]() { src->closeSearch(); },
                                  Qt::QueuedConnection);
      return true;

    case GHOSTTY_ACTION_SEARCH_TOTAL: {
      if (!src) return true;
      const int total = static_cast<int>(action.action.search_total.total);
      QMetaObject::invokeMethod(
          src, [src, total]() { src->setSearchTotal(total); },
          Qt::QueuedConnection);
      return true;
    }

    case GHOSTTY_ACTION_SEARCH_SELECTED: {
      if (!src) return true;
      const int sel =
          static_cast<int>(action.action.search_selected.selected);
      QMetaObject::invokeMethod(
          src, [src, sel]() { src->setSearchSelected(sel); },
          Qt::QueuedConnection);
      return true;
    }

    default:
      // The terminal inspector is not handled yet.
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
  // libghostty asks for confirmation when a paste looks unsafe. The
  // dialog MUST be deferred: this callback runs inside libghostty, and a
  // modal dialog here spins a nested event loop that re-enters libghostty
  // through the render tick — a crash/freeze. `state` is a completion
  // token valid until used; `str` is not, so copy it.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface || !surface->surface()) return;

  const QByteArray content(str);
  QMetaObject::invokeMethod(
      surface->owner(),
      [surface, content, state]() {
        if (!surface->surface()) return;
        QString preview = QString::fromUtf8(content);
        if (preview.size() > 200)
          preview = preview.left(200) + QStringLiteral("…");
        const auto reply = QMessageBox::warning(
            surface->owner(), QStringLiteral("Confirm Paste"),
            QStringLiteral("The text being pasted may be unsafe:\n\n%1\n\n"
                           "Paste anyway?")
                .arg(preview),
            QMessageBox::Yes | QMessageBox::No, QMessageBox::No);
        ghostty_surface_complete_clipboard_request(
            surface->surface(), content.constData(), state,
            reply == QMessageBox::Yes);
      },
      Qt::QueuedConnection);
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
  // surface userdata. Deferred out of this callback so the confirm
  // dialog cannot spin a nested event loop back into libghostty.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surface) return;
  MainWindow *self = surface->owner();
  QMetaObject::invokeMethod(
      self,
      [self, surface]() {
        if (self->confirmCloseSurfaces({surface}))
          self->removeSurface(surface);
      },
      Qt::QueuedConnection);
}
