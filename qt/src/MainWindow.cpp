#include "MainWindow.h"

#include <algorithm>
#include <climits>
#include <cstdio>
#include <functional>

#include <QApplication>
#include <QClipboard>
#include <QCursor>
#include <QCloseEvent>
#include <QCoreApplication>
#include <QDesktopServices>
#include <QEvent>
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QIcon>
#include <QList>
#include <QMap>
#include <QPainter>
#include <QPalette>
#include <QPixmap>
#include <QMenu>
#include <QMessageBox>
#include <QPoint>
#include <QPointer>
#include <QProcess>
#include <QPushButton>
#include <QStandardPaths>
#include <QRect>
#include <QShowEvent>
#include <QSplitter>
#include <QStringList>
#include <QString>
#include <QStyleHints>
#include <QTabBar>
#include <QTabWidget>
#include <QTimer>
#include <QVariant>
#include <QVBoxLayout>

#include "app/GhosttyApp.h"
#include "bell/BellPlayer.h"
#include "config/Config.h"
#include "CommandPalette.h"
#include "GhosttySurface.h"
#include "quickterm/QuickTerminal.h"
#include "TabWidget.h"
#include "undo/UndoStack.h"
#include "Util.h"
#include "WindowBlur.h"

// Small accent-coloured dot icon shown in a tab while the tab has an
// unacknowledged bell (bell-features title). Replaces the prior
// inline "● " text prefix — that prefix shifted the title text and
// fought our title-elide cap.  macOS uses a yellow tab dot;
// GTK uses Adw.TabPage.needs-attention which renders as an accent
// dot in the tab strip. Built lazily from an in-memory pixmap so we
// don't ship an SVG asset for one glyph.
static QIcon bellAttentionIcon() {
  static QIcon cached;
  if (cached.isNull()) {
    QPixmap pm(16, 16);
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing);
    p.setPen(Qt::NoPen);
    // System highlight colour; falls back to a warm accent if a
    // theme returns black.
    QColor accent = QGuiApplication::palette().color(QPalette::Highlight);
    if (accent.lightness() < 40) accent = QColor(0xff, 0x9f, 0x1c);
    p.setBrush(accent);
    p.drawEllipse(QRectF(3.0, 3.0, 10.0, 10.0));
    cached = QIcon(pm);
  }
  return cached;
}

// All process-shared libghostty state lives on GhosttyApp::instance().
// MainWindow's config() and needsPremultiply() forward there so
// external consumers (GhosttySurface, InspectorWindow) don't have to
// take a dependency on app/GhosttyApp.h.
ghostty_config_t MainWindow::config() const {
  return GhosttyApp::instance().config();
}

bool MainWindow::needsPremultiply() const {
  return GhosttyApp::instance().needsPremultiply();
}

MainWindow::MainWindow() {
  setWindowTitle(QStringLiteral("Ghastty"));
  // Let a translucent terminal background show through to the desktop.
  setAttribute(Qt::WA_TranslucentBackground);

  m_tabs = new TabWidget(this);
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
  connect(m_tabs, &TabWidget::tabTornOff, this, &MainWindow::detachTab);
  connect(m_tabs, &TabWidget::tabContextMenuRequested, this,
          &MainWindow::showTabContextMenu);
  // Cross-window tab adoption: a TabBar dropEvent emits this when a
  // tear-off from a different window's bar lands on ours. Resolve
  // the source window via TabBar::parentWidget()->parent() and
  // call adoptTab.
  connect(m_tabs, &TabWidget::tabAdoptRequested, this,
          [this](TabBar *origin) {
            if (!origin) return;
            // The TabBar's grandparent is the source MainWindow
            // (TabBar -> TabWidget -> MainWindow).
            auto *srcTabs = qobject_cast<TabWidget *>(origin->parentWidget());
            if (!srcTabs) return;
            auto *srcWin = qobject_cast<MainWindow *>(srcTabs->parentWidget());
            if (!srcWin || srcWin == this) return;
            // Adopt the source's currently-dragged tab. The current
            // index is the tab being dragged at the time the drop
            // landed on our bar (startTearOff settled in-bar
            // reorder before exec, so currentIndex is stable).
            const int idx = srcTabs->currentIndex();
            if (idx < 0) return;
            QWidget *page = srcTabs->widget(idx);
            if (page) adoptTab(srcWin, page);
          });
}

MainWindow::~MainWindow() {
  // unregisterWindow also clears GhosttyApp's quick-terminal pointer
  // if this was it.
  GhosttyApp::instance().unregisterWindow(this);

  // Destroy this window's surfaces (freeing their ghostty_surface_t)
  // before any app teardown; Qt's own child cleanup runs after this body.
  qDeleteAll(m_surfaces);
  m_surfaces.clear();

  // If this was the last window and a quit delay is configured, arm
  // the natural-close quit timer instead of tearing down immediately.
  // Qt's setQuitOnLastWindowClosed is off (we did that in initialize
  // so the delay can run), so without this the process would stay
  // alive forever after closing the final window via the WM.
  // Mirrors GTK's application.zig:820-862 startQuitTimer wiring.
  const bool wasLast = GhosttyApp::instance().windows().isEmpty();
  if (wasLast && GhosttyApp::instance().quitDelayMs() > 0) {
    GhosttyApp::instance().handleQuitTimer(true);
    return;  // keep the app + config alive until the timer fires
  }

  // The shared app and config outlive every window but the last.
  if (wasLast) {
    // GhosttyApp::teardown stops + frees the frame and quit timers,
    // drains qApp-targeted MetaCalls (so worker callbacks can't touch
    // a freed app), and ghostty_app_frees + ghostty_config_frees the
    // live handles.
    GhosttyApp::instance().teardown();
  }
}

bool MainWindow::initialize() {
  // First-call: build libghostty app + config via the singleton.
  if (!GhosttyApp::instance().ensureInitialized()) return false;

  GhosttyApp::instance().registerWindow(this);

  // First window also caches the quit-after-last-window-closed state.
  // Subsequent windows skip it (the singleton already holds the live
  // value via its config; only the QApplication quit strategy is set
  // once here).
  if (GhosttyApp::instance().windows().size() == 1) {
    // quit-after-last-window-closed: Qt's native "quit on last window"
    // covers the common (no-delay) case; a configured delay is honored
    // through the libghostty quit_timer action (see handleQuitTimer).
    const bool quitAfter = config::boolean("quit-after-last-window-closed", true);
    // quit-after-last-window-closed-delay is a `?Duration` and Duration
    // is neither extern nor packed, so libghostty's ghostty_config_get
    // returns false for it. Read from disk and parse.
    const uint64_t delayNs =
        config::durationNs("quit-after-last-window-closed-delay", 0);
    const uint64_t delayMs = delayNs / 1000000ULL;
    const int delayMsInt = quitAfter
        ? static_cast<int>(std::min(delayMs, uint64_t(INT_MAX)))
        : 0;
    GhosttyApp::instance().setQuitDelayMs(delayMsInt);
    QApplication::setQuitOnLastWindowClosed(quitAfter && delayMsInt == 0);
  }

  // Per-window startup window state, applied before show(). None of it
  // applies to the quick terminal — that is a layer-shell surface.
  if (!m_quickTerminal) {
    // window-decoration `none` drops the native frame; `auto`/`server`/
    // `client` keep a decorated window (the compositor picks the side
    // on Wayland).
    if (config::string("window-decoration") == QLatin1String("none"))
      setWindowFlag(Qt::FramelessWindowHint, true);
    // fullscreen wins over maximize; its enum is `false` when unset.
    const QString fullscreen = config::string("fullscreen");
    if (!fullscreen.isEmpty() && fullscreen != QLatin1String("false"))
      setWindowState(windowState() | Qt::WindowFullScreen);
    else if (config::boolean("maximize", false))
      setWindowState(windowState() | Qt::WindowMaximized);
  }

  // Tab-bar policy and colour scheme.
  applyWindowConfig();

  // Process-wide 60fps frame timer + libghostty wakeup coalescing
  // both live on GhosttyApp now.
  GhosttyApp::instance().ensureFrameTimer();

  // The first tab is created in showEvent, not here: see below.
  return true;
}

MainWindow *MainWindow::newWindow(ghostty_surface_t parent) {
  // If the natural-close quit timer is running (because the last
  // window was closed and we're inside the configured delay), cancel
  // it now: the process is no longer headless. macOS/GTK do the
  // same. handleQuitTimer is a no-op when no delay is configured, so
  // calling it unconditionally is safe.
  GhosttyApp::instance().handleQuitTimer(false);

  auto *w = new MainWindow;
  w->setAttribute(Qt::WA_DeleteOnClose);  // self-destruct when closed
  w->m_firstTabParent = parent;           // first tab inherits from `parent`
  if (!w->initialize()) {
    delete w;
    return nullptr;
  }

  // Default initial size. window-width / window-height (in cells) is
  // honored by libghostty: surface init fires INITIAL_SIZE with the
  // correct pixel rect, which our action handler picks up. So we don't
  // re-read those here; this 800x600 only applies until INITIAL_SIZE
  // arrives (typically a single frame).
  w->resize(800, 600);

  // Window position: window-position-x/y are optional (?i16 in
  // Config.zig). config::get writes the value and returns true when
  // the optional is present. Both must be set to take effect (matching
  // the Config.zig doc comment). If unset, fall back to a cascade
  // offset from the previous window so Cmd+N spam doesn't pile every
  // window at the same origin — macOS does this via
  // NSWindow.cascadeTopLeft. Wayland compositors typically ignore
  // window placement requests; this is a hint at most.
  int16_t posX = 0, posY = 0;
  const bool haveX = config::get(&posX, "window-position-x");
  const bool haveY = config::get(&posY, "window-position-y");
  if (haveX && haveY) {
    w->move(posX, posY);
  } else {
    const QList<MainWindow *> &all = GhosttyApp::instance().windows();
    if (all.size() > 1) {
      if (MainWindow *prev = all.value(all.size() - 2))
        w->move(prev->pos() + QPoint(30, 30));
    }
  }

  // initial-window: when false the very first window is bootstrap
  // only — built so libghostty's app + config exists, then closed
  // immediately without ever being mapped. Skipping show() here
  // (instead of show-then-close) keeps the daemon-mode startup
  // flicker-free. After the bootstrap, `initial-window` is no
  // longer load-bearing — every subsequent newWindow() shows.
  static bool s_initialWindowConsumed = false;
  bool wantsShow = true;
  if (!s_initialWindowConsumed) {
    s_initialWindowConsumed = true;
    bool initialWindow = true;
    // Default-on; the success bit isn't load-bearing.
    (void)config::get(&initialWindow, "initial-window");
    wantsShow = initialWindow;
  }
  if (wantsShow) w->show();
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

  // Apply background blur once the native Wayland surface exists; a
  // zero-delay timer defers past the platform-window creation.
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
  auto *surface = new GhosttySurface(GhosttyApp::instance().app(), this, parent);
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
  if (config::string("window-new-tab-position") == QLatin1String("current") &&
      m_tabs->count() > 0)
    index = m_tabs->insertTab(m_tabs->currentIndex() + 1, page,
                              QStringLiteral("Ghastty"));
  else
    index = m_tabs->addTab(page, QStringLiteral("Ghastty"));
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

  auto *surface = new GhosttySurface(GhosttyApp::instance().app(), this, target->surface());
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
    // Drop split-zoom stash if any of its widgets is about to die.
    // m_zoomSplitter (the splitter the zoomed surface came from) and
    // m_zoomRoot (the page's tree root) can both be reached by
    // collapsing siblings, leaving the stash dangling for the next
    // toggleSplitZoom.
    if (m_zoomed && (splitter == m_zoomSplitter || splitter == m_zoomRoot)) {
      m_zoomed = nullptr;
      m_zoomRoot = nullptr;
      m_zoomSplitter = nullptr;
    }
    // Deleting the orphaned splitter also deletes `surface`.
    splitter->deleteLater();
    return;
  }

  // Otherwise this surface is the whole tab.
  const int index = m_tabs->indexOf(parent);
  // Push to undo so a shell-exited tab close is symmetric with a
  // user-initiated tab close (closeTab pushes too). Skip the last
  // tab — its closeEvent runs undo::pushWindow and we don't want to
  // double-stack. Also skip the quick terminal (which doesn't push
  // to either stack by design).
  if (index >= 0 && m_tabs->count() > 1 && !m_quickTerminal)
    undo::pushTab(m_tabs->tabText(index));
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
  // Snapshot the tab's title for undo before we lose the reference.
  // undo::pushTab is no-op for the last tab in a window — that close
  // ends up triggering undo::pushWindow via closeEvent instead.
  if (m_tabs->count() > 1 && !m_quickTerminal)
    undo::pushTab(m_tabs->tabText(index));
  const auto inTab = page->findChildren<GhosttySurface *>();
  for (GhosttySurface *s : inTab) m_surfaces.removeOne(s);
  // If the zoomed surface was in this tab, clear the stash so a later
  // toggleSplitZoom doesn't dereference a deleted page tree.
  if (m_zoomed && inTab.contains(m_zoomed)) {
    m_zoomed = nullptr;
    m_zoomRoot = nullptr;
    m_zoomSplitter = nullptr;
  }
  m_tabs->removeTab(index);
  page->deleteLater();  // destroys every surface in the tab
  if (m_tabs->count() == 0) {
    m_skipCloseConfirm = true;
    close();
  }
}

// Honor libghostty's close_tab_mode (THIS / OTHER / RIGHT) for the
// CLOSE_TAB action. macOS supports all three; GTK supports all three
// via adw.TabView.closeOtherPages / closePagesAfter.
void MainWindow::closeTabsByMode(GhosttySurface *src,
                                 ghostty_action_close_tab_mode_e mode) {
  const int srcTab = tabIndexForSurface(src);
  if (srcTab < 0) return;

  // Build the list of tab indices to close, in DESCENDING order so
  // removeTab doesn't shift later indices out from under us.
  QList<int> indices;
  switch (mode) {
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS:
      indices = {srcTab};
      break;
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER:
      for (int i = m_tabs->count() - 1; i >= 0; --i)
        if (i != srcTab) indices.append(i);
      break;
    case GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT:
      for (int i = m_tabs->count() - 1; i > srcTab; --i) indices.append(i);
      break;
  }
  if (indices.isEmpty()) return;

  // Single confirm prompt covering every surface affected.
  QList<GhosttySurface *> affected;
  for (int i : indices)
    for (GhosttySurface *s : surfacesInTab(i)) affected.append(s);
  if (!confirmCloseSurfaces(affected)) return;

  for (int i : indices) closeTab(i);
}

// Right-click on a tab brings up Close / Close Others / Close Right /
// Rename — matching macOS's NSTabViewController menu and GTK's
// adw.TabView setup-menu (window.zig:1588).
void MainWindow::showTabContextMenu(int index, const QPoint &globalPos) {
  if (index < 0 || index >= m_tabs->count()) return;
  GhosttySurface *src = surfaceAt(index);
  if (!src) return;

  QMenu menu(this);
  QAction *aClose = menu.addAction(QStringLiteral("Close Tab"));
  QAction *aOther = menu.addAction(QStringLiteral("Close Other Tabs"));
  QAction *aRight = menu.addAction(QStringLiteral("Close Tabs to the Right"));
  // "Other" / "Right" are no-ops with only one tab or the rightmost
  // tab respectively.
  aOther->setEnabled(m_tabs->count() > 1);
  aRight->setEnabled(index < m_tabs->count() - 1);
  menu.addSeparator();
  QAction *aRename = menu.addAction(QStringLiteral("Rename Tab…"));

  QAction *chosen = menu.exec(globalPos);
  if (!chosen || !GhosttyApp::instance().surfaceAlive(src)) return;
  if (chosen == aClose)
    closeTabsByMode(src, GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS);
  else if (chosen == aOther)
    closeTabsByMode(src, GHOSTTY_ACTION_CLOSE_TAB_MODE_OTHER);
  else if (chosen == aRight)
    closeTabsByMode(src, GHOSTTY_ACTION_CLOSE_TAB_MODE_RIGHT);
  else if (chosen == aRename)
    src->promptTitle(/*tabScope=*/true);
}

void MainWindow::adoptTab(MainWindow *src, QWidget *page) {
  const int srcIndex = src->m_tabs->indexOf(page);
  if (srcIndex < 0 || src == this) return;

  // Re-home every surface in the tab — the libghostty surfaces are
  // unaffected (the app is shared), only the owning window changes.
  const auto adopted = page->findChildren<GhosttySurface *>();
  // If the source's zoomed surface lived in this tab, clear src's
  // zoom stash before transferring — the stashed root/splitter
  // pointers belong to widgets we're about to reparent away.
  if (src->m_zoomed && adopted.contains(src->m_zoomed)) {
    src->m_zoomed = nullptr;
    src->m_zoomRoot = nullptr;
    src->m_zoomSplitter = nullptr;
  }
  for (GhosttySurface *s : adopted) {
    src->m_surfaces.removeOne(s);
    if (!m_surfaces.contains(s)) m_surfaces.append(s);
    s->setOwner(this);
  }

  const QString text = src->m_tabs->tabText(srcIndex);
  // QVariant carrying the typed TabData; copies cleanly across windows.
  const QVariant data = src->m_tabs->tabBar()->tabData(srcIndex);
  src->m_tabs->removeTab(srcIndex);          // page is now parentless
  const int index = m_tabs->addTab(page, text);  // reparents page here
  m_tabs->tabBar()->setTabData(index, data);
  m_tabs->setCurrentIndex(index);

  if (src->m_tabs->count() == 0) {
    src->m_skipCloseConfirm = true;
    src->close();
  }
}

void MainWindow::detachTab(int index) {
  QWidget *page = m_tabs->widget(index);
  if (!page || m_tabs->count() <= 1) return;  // never tear off a lone tab

  auto *w = new MainWindow;
  w->setAttribute(Qt::WA_DeleteOnClose);
  w->m_firstTabPending = false;  // it is handed the torn-off tab instead
  if (!w->initialize()) {
    delete w;
    return;
  }
  w->adoptTab(this, page);
  w->resize(size());
  w->show();
  w->move(QCursor::pos());  // a hint; Wayland leaves placement to KWin
}

void MainWindow::setSurfaceTitle(GhosttySurface *surface,
                                 const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  // Store the terminal title as the tab's base; updateTabText decides
  // whether it or a manual override is shown.
  TabData data = m_tabs->tabBar()->tabData(index).value<TabData>();
  data.base = title;
  m_tabs->tabBar()->setTabData(index, QVariant::fromValue(data));
  updateTabText(index);
}

void MainWindow::setTabTitleOverride(GhosttySurface *surface,
                                     const QString &title) {
  const int index = tabIndexForSurface(surface);
  if (index < 0) return;
  TabData data = m_tabs->tabBar()->tabData(index).value<TabData>();
  data.override_ = title;  // empty clears the override
  m_tabs->tabBar()->setTabData(index, QVariant::fromValue(data));
  updateTabText(index);
}

void MainWindow::copyTitleToClipboard(GhosttySurface *src) {
  // Per-surface: copy the title of the tab containing `src`, not
  // whatever tab is currently visible. macOS does the same; otherwise
  // a binding triggered from a non-current tab copies the wrong title.
  // Falls back to the current tab if the source is unknown.
  int tab = src ? tabIndexForSurface(src) : -1;
  if (tab < 0) tab = m_tabs->currentIndex();
  if (tab < 0) return;
  const TabData data = m_tabs->tabBar()->tabData(tab).value<TabData>();
  const QString title =
      !data.override_.isEmpty() ? data.override_ : data.base;
  if (!title.isEmpty()) QGuiApplication::clipboard()->setText(title);
}

void MainWindow::onTabCloseRequested(int index) {
  if (!confirmCloseSurfaces(surfacesInTab(index))) return;
  closeTab(index);
}

void MainWindow::closeEvent(QCloseEvent *e) {
  // confirm-close-surface: prompt once for the whole window unless this
  // close was already confirmed (e.g. the last tab/surface closing).
  // The skip flag is consumed for THIS close attempt only — if the
  // close goes on to be ignored (it shouldn't here, but a future
  // closeEvent override could), the next attempt re-prompts. macOS
  // resets per-action, mirroring this.
  const bool skip = m_skipCloseConfirm;
  m_skipCloseConfirm = false;
  if (!skip && !confirmCloseSurfaces(m_surfaces)) {
    e->ignore();
    return;
  }
  // Snapshot for undo. We push the window's full tab list so undo
  // restores all of them; closeTab paths skip the per-tab push when
  // they reach the last tab so we don't double-stack the same close.
  QStringList titles;
  titles.reserve(m_tabs->count());
  for (int i = 0; i < m_tabs->count(); ++i)
    titles << m_tabs->tabText(i);
  undo::pushWindow(titles, geometry(), m_quickTerminal);
  e->accept();
}

bool MainWindow::confirmCloseSurfaces(
    const QList<GhosttySurface *> &surfaces) {
  // Honor the `confirm-close-surface` config:
  //   false  -> never prompt
  //   true   -> prompt only when libghostty says a process is running
  //   always -> always prompt, even for surfaces with no live process
  // (libghostty Config.zig: ConfirmCloseSurface enum.)
  const QString mode = config::string("confirm-close-surface");
  if (mode == QLatin1String("false")) return true;

  bool needsConfirm = (mode == QLatin1String("always"));
  if (!needsConfirm) {
    for (GhosttySurface *s : surfaces)
      if (s->surface() && ghostty_surface_needs_confirm_quit(s->surface())) {
        needsConfirm = true;
        break;
      }
  }
  if (!needsConfirm) return true;

  // Destructive-styled dialog with Cancel/Close, matching macOS
  // NSAlert and GTK Adw.MessageDialog (`close-response: cancel`,
  // destructive class on the close button).
  QMessageBox box(this);
  box.setIcon(QMessageBox::Warning);
  box.setWindowTitle(QStringLiteral("Close"));
  box.setText(QStringLiteral("There are still running processes."));
  box.setInformativeText(
      QStringLiteral("Closing will terminate the running processes."));
  QPushButton *close = box.addButton(QStringLiteral("Close"),
                                     QMessageBox::DestructiveRole);
  QPushButton *cancel = box.addButton(QStringLiteral("Cancel"),
                                      QMessageBox::RejectRole);
  box.setDefaultButton(cancel);
  box.exec();
  return box.clickedButton() == close;
}

void MainWindow::closeAllWindows(bool thenQuit) {
  // One process-level prompt covers every window. Destructive button
  // + Cancel default — same style as confirmCloseSurfaces. Title /
  // verb track whether this is a Quit (process ends) or a
  // Close All Windows (process may stay alive).
  ghostty_app_t app = GhosttyApp::instance().app();
  if (app && ghostty_app_needs_confirm_quit(app)) {
    const QString title = thenQuit ? QStringLiteral("Quit")
                                   : QStringLiteral("Close All Windows");
    const QString verb = thenQuit ? QStringLiteral("Quit")
                                  : QStringLiteral("Close All");
    const QList<MainWindow *> &live = GhosttyApp::instance().windows();
    QMessageBox box(live.isEmpty() ? nullptr : live.first());
    box.setIcon(QMessageBox::Warning);
    box.setWindowTitle(title);
    box.setText(QStringLiteral("There are still running processes."));
    box.setInformativeText(QStringLiteral(
        "%1 will terminate the running processes.").arg(title));
    QPushButton *go = box.addButton(verb, QMessageBox::DestructiveRole);
    QPushButton *cancel = box.addButton(QStringLiteral("Cancel"),
                                        QMessageBox::RejectRole);
    box.setDefaultButton(cancel);
    box.exec();
    if (box.clickedButton() != go) return;
  }
  // Copy: each close() may delete the window and mutate the live list.
  const QList<MainWindow *> windows = GhosttyApp::instance().windows();
  for (MainWindow *w : windows) {
    w->m_skipCloseConfirm = true;
    w->close();
  }
  if (thenQuit) {
    // QUIT explicitly ends the process even when
    // quit-after-last-window-closed left quitOnLastWindowClosed off.
    qApp->quit();
  } else {
    // CLOSE_ALL_WINDOWS leaves the process alive when
    // quit-after-last-window-closed=false. When true with a delay,
    // libghostty's QUIT_TIMER action drives the eventual termination
    // (matching the natural-close path). When true without a delay,
    // Qt's quitOnLastWindowClosed terminates as the last window's
    // close event runs. We read both decisions off the *cached*
    // QApplication state so they stay consistent: refreshChrome
    // sets quitOnLastWindowClosed and the singleton's delay together.
    if (QApplication::quitOnLastWindowClosed() &&
        GhosttyApp::instance().quitDelayMs() == 0) {
      qApp->quit();
    }
    // Else: the close loop above already triggered the natural-close
    // teardown path; either Qt will terminate as quitOnLastWindowClosed
    // arms, or the QUIT_TIMER fires, or we stay alive headless.
  }
}

MainWindow *MainWindow::makeQuickTerminal() {
  auto *w = new MainWindow;
  w->m_quickTerminal = true;
  w->setAttribute(Qt::WA_DeleteOnClose);
  if (!w->initialize()) {
    delete w;
    return nullptr;
  }
  quickterm::setupLayerShell(w);
  quickterm::animateIn(w);
  return w;
}

void MainWindow::animateQuickTerminalIn() { quickterm::animateIn(this); }
void MainWindow::animateQuickTerminalOut() { quickterm::animateOut(this); }

void MainWindow::changeEvent(QEvent *e) {
  // quick-terminal-autohide: fade out the dropdown when it loses
  // focus (use the configured animation duration so this matches
  // an explicit toggle).
  if (e->type() == QEvent::ActivationChange && m_quickTerminal &&
      isVisible() && !isActiveWindow() &&
      config::boolean("quick-terminal-autohide", true))
    animateQuickTerminalOut();
  QWidget::changeEvent(e);
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
  if (!surface) return -1;
  for (int i = 0; i < m_tabs->count(); ++i) {
    QWidget *page = m_tabs->widget(i);
    if (page && page->isAncestorOf(surface)) return i;
  }
  return -1;
}

int MainWindow::tabCount() const { return m_tabs->count(); }

GhosttySurface *MainWindow::currentSurface() const {
  return surfaceAt(m_tabs->currentIndex());
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
      // A positive value is a 1-based tab number; clamp out-of-range
      // values to the last tab so `goto-tab:99` lands on the rightmost
      // tab instead of being silently dropped. macOS clamps the same
      // way; GTK clamps via `@min`.
      index = static_cast<int>(tab) - 1;
      if (index >= n) index = n - 1;
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

  // split-preserve-zoom.navigation: if the source pane is currently
  // zoomed and the config asks to preserve zoom across navigation,
  // we'll re-zoom the destination once the focus moves. Otherwise
  // the existing semantics of dropping zoom on navigation apply.
  //
  // SplitPreserveZoom = packed struct { navigation: bool } so bit 0
  // is `navigation`. config::bitfield handles the c_uint sizing
  // dance documented there.
  const unsigned int pzBits = config::bitfield("split-preserve-zoom", 0);
  const bool preserveZoom = (pzBits & 0x1) != 0 && m_zoomed == from;

  const auto centerOf = [](GhosttySurface *s) {
    return QRect(s->mapToGlobal(QPoint(0, 0)), s->size()).center();
  };

  GhosttySurface *target = nullptr;
  if (dir == GHOSTTY_GOTO_SPLIT_PREVIOUS ||
      dir == GHOSTTY_GOTO_SPLIT_NEXT) {
    // Cycle in split-tree order, not screen-position order. macOS
    // and GTK both walk the surface tree depth-first; sorting by
    // widget center put nested unbalanced trees in a different
    // order than the user's mental model of "the next pane in the
    // tree." A flat sort got 3/4 right by accident — fixing it for
    // the asymmetric case.
    QList<GhosttySurface *> order;
    std::function<void(QWidget *)> walk = [&](QWidget *w) {
      if (auto *s = qobject_cast<GhosttySurface *>(w)) {
        order.append(s);
      } else if (auto *sp = qobject_cast<QSplitter *>(w)) {
        for (int i = 0; i < sp->count(); ++i) walk(sp->widget(i));
      } else if (w) {
        // The tab page itself: descend into its child layout.
        for (QObject *c : w->children())
          if (auto *cw = qobject_cast<QWidget *>(c)) walk(cw);
      }
    };
    walk(m_tabs->widget(tab));
    if (order.isEmpty()) return;
    const int i = order.indexOf(from);
    if (i < 0) return;
    const int step = dir == GHOSTTY_GOTO_SPLIT_NEXT ? 1 : -1;
    target = order[(i + step + order.size()) % order.size()];
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

  if (target) {
    // If a zoom was active on `from` and split-preserve-zoom.navigation
    // is on, unzoom-then-rezoom on the destination so the new pane is
    // the one filling the tab. toggleSplitZoom on a different pane
    // while one is zoomed first restores then zooms — exactly what we
    // want.
    if (preserveZoom) toggleSplitZoom(target);
    target->setFocus();
  }
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
  // Clamp the delta against both panes' minimum size (0) before
  // applying so total area is conserved. Without this, a clamp on
  // sizes[idx] would still subtract the unclamped delta from `other`,
  // shrinking the total area QSplitter sees and forcing it to
  // renormalise inconsistently.
  int appliedDelta = delta;
  if (sizes[idx] + appliedDelta < 0) appliedDelta = -sizes[idx];
  if (sizes[other] - appliedDelta < 0) appliedDelta = sizes[other];
  sizes[idx] += appliedDelta;
  sizes[other] -= appliedDelta;
  splitter->setSizes(sizes);
}

// Count the number of GhosttySurface leaves under `widget`, recursively.
// Used by equalizeSplits to weight splitter children by leaf count so a
// 3-pane sibling gets 3x the size of a 1-pane sibling — matching macOS's
// surfaceTree.equalized() and GTK's split_tree weight model.
static int countLeaves(QWidget *widget) {
  if (!widget) return 0;
  if (qobject_cast<GhosttySurface *>(widget)) return 1;
  if (auto *splitter = qobject_cast<QSplitter *>(widget)) {
    int n = 0;
    for (int i = 0; i < splitter->count(); ++i)
      n += countLeaves(splitter->widget(i));
    return std::max(1, n);
  }
  // For containers like the tab page, recurse into direct children.
  int n = 0;
  for (QObject *c : widget->children())
    if (auto *w = qobject_cast<QWidget *>(c)) n += countLeaves(w);
  return n;
}

void MainWindow::equalizeSplits(GhosttySurface *from) {
  const int tab = tabIndexForSurface(from);
  if (tab < 0) return;
  QWidget *page = m_tabs->widget(tab);
  // Weight each splitter child by its leaf count so equalize means
  // "every pane gets the same area," not "every direct child of each
  // splitter gets the same area." A 3-pane vertical split next to a
  // 1-pane sibling now ends up 3:1 at the top level (and 1:1:1
  // within the 3-pane child), giving every pane the same final size.
  const auto splitters = page->findChildren<QSplitter *>();
  for (QSplitter *splitter : splitters) {
    QList<int> sizes;
    for (int i = 0; i < splitter->count(); ++i)
      sizes.append(countLeaves(splitter->widget(i)) * (1 << 16));
    splitter->setSizes(sizes);
  }
}

void MainWindow::moveTab(int amount) {
  // Out-of-range moves clamp to the first/last tab. Qt clamps; macOS
  // clamps; GTK wraps around. The audit (I3) flagged the GTK
  // mismatch — we deliberately match macOS here: a wrap means
  // `move-tab:99` on a 3-tab window silently lands on tab 1, which
  // is rarely what a user means.
  const int n = m_tabs->count();
  if (n < 2 || amount == 0) return;
  const int from = m_tabs->currentIndex();
  const int to = std::clamp(from + amount, 0, n - 1);
  if (to != from)
    if (QTabBar *bar = m_tabs->findChild<QTabBar *>()) bar->moveTab(from, to);
}

void MainWindow::ringBell(GhosttySurface *surface) {
  // bell-features is a packed struct returned by ghostty_config_get as
  // a bitfield (see BellFeature in Util.h). If the config-get call
  // itself fails (e.g. an ABI drift between Qt frontend and libghostty
  // dropping the field), use BellAttention as a sane minimum fallback.
  // If config-get succeeds with features=0, the user explicitly opted
  // out of every bell feature and we honor that.
  const unsigned int features =
      config::bitfield("bell-features", BellAttention);
  if (features & BellAttention) QApplication::alert(this);
  if (features & BellSystem) QApplication::beep();
  if (features & BellAudio && m_bellPlayer) m_bellPlayer->play();

  if (!surface) return;
  if (features & BellBorder) surface->flashBorder();
  if (features & BellTitle) {
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
  const TabData data = m_tabs->tabBar()->tabData(tab).value<TabData>();
  QString text = !data.override_.isEmpty() ? data.override_
                 : !data.base.isEmpty()    ? data.base
                                           : QStringLiteral("Ghastty");
  m_tabs->setTabText(tab, text);
  // Show an accent dot icon while the tab has an unacknowledged bell.
  // macOS uses a yellow tab dot; GTK uses adw.TabPage.needs-attention.
  // The earlier "● " text prefix shifted the title and fought our
  // tab-elide cap.
  m_tabs->setTabIcon(tab, tabBellMarked(tab) ? bellAttentionIcon() : QIcon());
  if (tab == m_tabs->currentIndex())
    setWindowTitle(text + QStringLiteral(" — Ghastty"));
}

// Refresh every window's chrome from the current GhosttyApp config: tab-bar
// policy, colour scheme, blur — plus window-level state that
// previously only applied at startup (window-decoration, fullscreen,
// maximize) and the quit-after-last-window-closed delay.
void MainWindow::refreshChrome() {
  // Refresh app-scoped state. quit-after-last-window-closed[-delay]
  // can change the delay or the quitOnLastWindowClosed strategy at
  // runtime; mirrors the calculation in initialize().
  if (GhosttyApp::instance().config()) {
    bool quitAfter = true;
    // Default-on; the success bit isn't load-bearing.
    (void)config::get(&quitAfter, "quit-after-last-window-closed");
    // Same Duration-decode workaround as initialize().
    const uint64_t delayNs =
        config::durationNs("quit-after-last-window-closed-delay", 0);
    const uint64_t delayMs = delayNs / 1000000ULL;
    const int delayMsInt = quitAfter
        ? static_cast<int>(std::min(delayMs, uint64_t(INT_MAX)))
        : 0;
    GhosttyApp::instance().setQuitDelayMs(delayMsInt);
    QApplication::setQuitOnLastWindowClosed(quitAfter && delayMsInt == 0);
  }

  for (MainWindow *w : GhosttyApp::instance().windows()) {
    w->applyWindowConfig();
    w->applyBlur();

    // Quick terminal is layer-shell-anchored and window flags don't
    // apply; the rest of the per-window state is config-driven and
    // only the static initialize() ever touched it before. This
    // brings reload-time changes through to live windows.
    if (w->m_quickTerminal) continue;

    // window-decoration: `none` → frameless, anything else → decorated.
    // Toggling Qt::FramelessWindowHint hides+reshows the window, so
    // gate on a real change.
    const bool wantFrameless =
        config::string("window-decoration") == QLatin1String("none");
    const bool isFrameless =
        w->windowFlags().testFlag(Qt::FramelessWindowHint);
    if (wantFrameless != isFrameless) {
      const bool wasVisible = w->isVisible();
      w->setWindowFlag(Qt::FramelessWindowHint, wantFrameless);
      if (wasVisible) {
        w->show();
        w->activateWindow();
      }
    }

    // fullscreen / maximize: `fullscreen=true` wins over `maximize`.
    // Setting back to a non-fullscreen window goes through showNormal
    // first so the WM lets us out of fullscreen cleanly.
    const QString fs = config::string("fullscreen");
    const bool wantFullscreen = !fs.isEmpty() && fs != QLatin1String("false");
    const bool wantMax = config::boolean("maximize", false);
    if (wantFullscreen) {
      if (!w->isFullScreen()) w->showFullScreen();
    } else if (w->isFullScreen()) {
      w->showNormal();
    }
    if (!wantFullscreen) {
      if (wantMax && !w->isMaximized()) w->showMaximized();
      // No "un-maximize on reload" path: a user who removed `maximize`
      // from their config probably doesn't want their existing
      // maximized window snapped back to its non-maximized geometry.
    }
  }
}

void MainWindow::reloadConfig() { reloadConfigGlobal(); }

void MainWindow::reloadConfigGlobal() {
  if (!GhosttyApp::instance().app()) return;
  // Re-read the config from disk in the same order as initialize().
  ghostty_config_t config = ghostty_config_new();
  ghostty_config_load_default_files(config);
  ghostty_config_load_cli_args(config);
  ghostty_config_load_recursive_files(config);
  ghostty_config_finalize(config);

  // Push to libghostty. App.updateConfig propagates the config to every
  // surface and fires CONFIG_CHANGE back at us — which only refreshes
  // chrome, never re-pushes, so this does not loop.
  ghostty_app_update_config(GhosttyApp::instance().app(), config);

  // Hand the new config to the singleton, which frees the previous one
  // (in the right order — libghostty borrows the previous until update
  // completes) and recomputes needsPremultiply.
  GhosttyApp::instance().replaceConfig(config);

  refreshChrome();

  // app-notifications.config-reload: post a desktop notification so
  // the user has a visible cue that the reload landed.
  //
  // AppNotifications = packed struct { clipboard-copy: bool = true,
  // config-reload: bool = true }. libghostty serializes packed
  // structs as c_uint (see c_get.zig). Bit 0 = clipboard-copy,
  // bit 1 = config-reload. The clipboard-copy bit is read for
  // forward compatibility — Qt doesn't currently post a copy
  // toast, but a future one will pick up the same gate.
  // config::bitfield failure → defaults (both bits set) so the
  // feature still works as documented.
  const unsigned int notifBits = config::bitfield("app-notifications", 0x3);
  const bool wantConfigReload = (notifBits & 0x2) != 0;
  if (wantConfigReload)
    postNotification(QStringLiteral("Ghostty"),
                     QStringLiteral("Configuration reloaded."));
}

bool MainWindow::focusFollowsMouse() const {
  return config::boolean("focus-follows-mouse", false);
}

// Bring this window forward and focus the surface inside it. Mirrors
// macOS PRESENT_TERMINAL (NSApp.activate / makeKeyAndOrderFront) and
// GTK presentTerminal (window.present()).
void MainWindow::presentTerminal(GhosttySurface *surface) {
  show();
  raise();
  activateWindow();
  if (surface) surface->setFocus();
}

// Cycle through the live window list. The libghostty target picks a
// starting window (the one whose surface fired the action);
// GOTO_WINDOW_NEXT goes forward, PREVIOUS goes backward, wrapping at
// the ends.
void MainWindow::gotoWindow(MainWindow *from,
                            ghostty_action_goto_window_e dir) {
  const QList<MainWindow *> &live = GhosttyApp::instance().windows();
  const int n = live.size();
  if (n <= 1) return;
  const int idx = from ? live.indexOf(from) : 0;
  if (idx < 0) return;
  const int step = (dir == GHOSTTY_GOTO_WINDOW_NEXT) ? 1 : -1;
  const int next = (idx + step + n) % n;
  if (MainWindow *w = live.value(next)) w->presentTerminal(nullptr);
}

// FLOAT_WINDOW: keep this window above other windows (Qt::
// WindowStaysOnTopHint). Resetting flags hides+reshows the window;
// preserve its prior visibility/maximized/fullscreen state. macOS uses
// NSWindow.level = .floating; GTK toggles GtkWindow:keep-above.
void MainWindow::setFloating(ghostty_action_float_window_e mode) {
  bool target = false;
  switch (mode) {
    case GHOSTTY_FLOAT_WINDOW_ON: target = true; break;
    case GHOSTTY_FLOAT_WINDOW_OFF: target = false; break;
    case GHOSTTY_FLOAT_WINDOW_TOGGLE: target = !m_floating; break;
  }
  if (target == m_floating) return;
  m_floating = target;
  // setWindowFlag preserves visibility but hides+reshows; re-activate
  // so we don't drop focus.
  setWindowFlag(Qt::WindowStaysOnTopHint, target);
  if (isVisible()) {
    show();
    activateWindow();
  }
}

// TOGGLE_WINDOW_DECORATIONS: flip the frameless flag at runtime. Same
// hide+reshow caveat as setFloating. The compositor decides how to
// render the resulting window on Wayland.
void MainWindow::toggleWindowDecorations() {
  m_decorationsHidden = !m_decorationsHidden;
  setWindowFlag(Qt::FramelessWindowHint, m_decorationsHidden);
  if (isVisible()) {
    show();
    activateWindow();
  }
}

// TOGGLE_BACKGROUND_OPACITY: flip between honoring the configured
// background-opacity (translucent window) and forcing the window
// opaque. Implemented via WA_TranslucentBackground because libghostty
// owns the per-pixel alpha; this just controls whether Qt composites
// the window onto the desktop translucently.
void MainWindow::toggleBackgroundOpacity() {
  m_opacityForcedOpaque = !m_opacityForcedOpaque;
  setAttribute(Qt::WA_TranslucentBackground, !m_opacityForcedOpaque);
  update();
}

// SIZE_LIMIT: clamp the window's resizable range. libghostty derives
// these from the surface's cell-grid limits; honoring them prevents a
// user from shrinking a window below one cell or expanding past the
// terminal's max grid size. A zero max means "no upper bound".
void MainWindow::setSizeLimits(uint32_t minW, uint32_t minH, uint32_t maxW,
                               uint32_t maxH) {
  if (minW || minH) setMinimumSize(QSize(minW, minH));
  // Treat 0 as "no constraint" — Qt's QWIDGETSIZE_MAX is the upper bound.
  setMaximumSize(QSize(maxW ? int(maxW) : QWIDGETSIZE_MAX,
                       maxH ? int(maxH) : QWIDGETSIZE_MAX));
}

// CELL_SIZE: store the value and apply window-step-resize. The
// `window-step-resize` config asks Qt to resize in cell increments
// via QWidget::setSizeIncrement, but Wayland has no equivalent of
// WM_NORMAL_HINTS step so compositors typically ignore it. Config
// docs explicitly say "currently only supported on macOS / has no
// effect on Linux," so this is strictly a bonus.
void MainWindow::setCellSize(uint32_t w, uint32_t h) {
  m_cellSize = QSize(int(w), int(h));
  if (config::boolean("window-step-resize", false))
    setSizeIncrement(int(w), int(h));
  else
    setSizeIncrement(0, 0);  // back to pixel-precise
}

void MainWindow::undoLastClose() { undo::undoLast(); }
void MainWindow::redoLastClose() { undo::redoLast(); }

// Close the active tab without prompting. Called from
// undo::redoLast for a Tab redo: the user already accepted the
// original close, so re-closing carries the same prior consent.
void MainWindow::closeCurrentTabForRedo() {
  const int idx = m_tabs->currentIndex();
  if (idx >= 0) closeTab(idx);
}

// Close the entire window without re-prompting. Called from
// undo::redoLast for a Window redo.
void MainWindow::closeForRedo() {
  m_skipCloseConfirm = true;
  close();
}

void MainWindow::applyWindowConfig() {
  // window-show-tab-bar: always shown / auto-hidden with a lone tab /
  // never shown.
  const QString tabBar = config::string("window-show-tab-bar");
  if (tabBar == QLatin1String("never")) {
    m_tabs->setTabBarAutoHide(false);
    m_tabs->tabBar()->hide();
  } else if (tabBar == QLatin1String("always")) {
    m_tabs->setTabBarAutoHide(false);
    m_tabs->tabBar()->show();
  } else {  // auto (the default): hidden while there is a lone tab
    m_tabs->setTabBarAutoHide(true);
    // setTabBarAutoHide does not retroactively correct an explicitly
    // shown/hidden bar, so set the right state for the current count.
    m_tabs->tabBar()->setVisible(m_tabs->count() > 1);
  }

  // bell-audio: BellPlayer caches the path/volume so the bell hot
  // path doesn't re-scan the on-disk config on every ring.
  if (!m_bellPlayer) m_bellPlayer = new BellPlayer(this);
  m_bellPlayer->refreshFromConfig();

  // window-title-font-family: apply to the tab bar (and the WM
  // title via Qt's window-title system font is harder to override
  // portably; the tab bar is what users actually look at). Empty /
  // unset reverts to the application font.
  const QString titleFamily = config::diskValue("window-title-font-family");
  if (m_tabs && m_tabs->tabBar()) {
    QFont tf = QApplication::font();
    if (!titleFamily.isEmpty()) tf.setFamily(titleFamily);
    m_tabs->tabBar()->setFont(tf);
  }

  // split-divider-color: style the QSplitter handles. Stored as a
  // CSS-form string in the user's config (e.g. "#ff00ff"). Empty
  // leaves Qt's default. Applied via setStyleSheet on this window's
  // QSplitter children since splitters can be added/removed at any
  // time, walk them on each apply.
  const QString divider = config::diskValue("split-divider-color");
  const QString splitterCss = divider.isEmpty()
      ? QString()
      : QStringLiteral("QSplitter::handle { background-color: %1; }")
            .arg(divider);
  for (QSplitter *s : findChildren<QSplitter *>())
    s->setStyleSheet(splitterCss);

  // window-theme: force a light/dark scheme, or follow the OS.
  //
  //   `auto` / `system` — follow the OS (Qt 6.8+ honours the platform
  //   colour scheme automatically).
  //   `dark` / `light` — force the explicit scheme.
  //   `ghostty` — derive from the configured background colour's
  //   luminance (Rec.601 weighting).
  //
  // We require Qt 6.8+ (Debian trixie ships 6.8.2; the project's
  // CMake doesn't compile against older Qt). The setColorScheme
  // hint propagates to chrome (tab bar, dialogs); the terminal
  // itself honours its own theme via libghostty.
  const QString theme = config::string("window-theme");
  Qt::ColorScheme scheme = Qt::ColorScheme::Unknown;
  if (theme == QLatin1String("dark")) {
    scheme = Qt::ColorScheme::Dark;
  } else if (theme == QLatin1String("light")) {
    scheme = Qt::ColorScheme::Light;
  } else if (theme == QLatin1String("ghostty")) {
    ghostty_config_color_s bg{};
    if (config::get(&bg, "background")) {
      const double luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
      scheme = luma < 128.0 ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light;
    }
  }
  QGuiApplication::styleHints()->setColorScheme(scheme);
}

void MainWindow::toggleCommandPalette(GhosttySurface *surface) {
  if (!m_commandPalette) m_commandPalette = new CommandPalette(this);
  m_commandPalette->toggleFor(surface);
}

void MainWindow::applyBlur() {
  // background-blur is a union whose C value is an i16: 0 (and the
  // macOS-only negatives) means off, a positive radius means on. KWin
  // uses its own configured radius, so only on/off matters here. On
  // read failure blur stays 0 (off).
  short blur = 0;
  (void)config::get(&blur, "background-blur");
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

// All libghostty runtime callbacks live outside MainWindow:
// onAction → actions::dispatch in qt/src/actions/ActionDispatcher.cpp
// onWakeup, onReadClipboard, onConfirmReadClipboard, onWriteClipboard,
// onCloseSurface → GhosttyApp.
