#include "MainWindow.h"

#include <algorithm>
#include <climits>
#include <cstdio>
#include <functional>

#include <QApplication>
#include <QAudioOutput>
#include <QByteArray>
#include <QClipboard>
#include <QCursor>
#include <QCloseEvent>
#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDesktopServices>
#include <QEvent>
#include <QDir>
#include <QFile>
#include <QColor>
#include <QFont>
#include <QGuiApplication>
#include <QIcon>
#include <QList>
#include <QMap>
#include <QPainter>
#include <QPalette>
#include <QPixmap>
#include <QMediaPlayer>
#include <QMenu>
#include <QMessageBox>
#include <QEasingCurve>
#include <QPoint>
#include <QPointer>
#include <QProcess>
#include <QPropertyAnimation>
#include <QPushButton>
#include <QStandardPaths>
#include <QRect>
#include <QScreen>
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
#include <QWindow>

#include <LayerShellQt/window.h>

#include "app/GhosttyApp.h"
#include "CommandPalette.h"
#include "GhosttySurface.h"
#include "TabWidget.h"
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

// Process-shared libghostty state — see MainWindow.h.
//
// s_app / s_config / s_needsPremultiply mirror GhosttyApp::instance()
// so the rest of this file (and GhosttySurface) keep their existing
// access patterns. Phase 1.2+ will retire them as call sites move
// over to the singleton directly.
ghostty_app_t MainWindow::s_app = nullptr;
ghostty_config_t MainWindow::s_config = nullptr;
bool MainWindow::s_needsPremultiply = false;
int MainWindow::s_quitDelayMs = 0;

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
    // live handles. The local s_app / s_config mirrors are still in
    // use across this file; null them so they match the singleton.
    GhosttyApp::instance().teardown();
    s_app = nullptr;
    s_config = nullptr;
  }
}

// configHasCustomShader moved to GhosttyApp.cpp (custom-shader is an
// app-level fact: it drives needsPremultiply for every surface).

// Parse a libghostty duration string into nanoseconds. The format is
// concatenated `<n><unit>` segments per Config.zig's Duration.parseCLI:
//   y w d h m s ms µs us ns
// Each segment is added to the total. Returns the supplied default if
// parsing fails or the input is empty. libghostty exposes Duration via
// ghostty_config_get as a non-extern non-packed struct, which c_get
// silently rejects; we fall back to scanning the config file text.
static uint64_t parseDurationNs(const QString &s, uint64_t fallback) {
  if (s.isEmpty()) return fallback;
  // Order matters: longer units first so `ms` is matched before `s`,
  // `us` before `s`, etc. Mirrors Config.zig's units array.
  static constexpr struct { const char *name; uint64_t factor; } kUnits[] = {
      {"ns", 1ULL},
      {"us", 1000ULL},
      {"µs", 1000ULL},
      {"ms", 1000000ULL},
      {"s",  1000000000ULL},
      {"m",  60ULL * 1000000000ULL},
      {"h",  3600ULL * 1000000000ULL},
      {"d",  86400ULL * 1000000000ULL},
      {"w",  7ULL * 86400ULL * 1000000000ULL},
      {"y",  365ULL * 86400ULL * 1000000000ULL},
  };
  uint64_t total = 0;
  int i = 0;
  const int n = s.size();
  bool anyMatched = false;
  while (i < n) {
    while (i < n && s.at(i).isSpace()) ++i;
    if (i >= n) break;
    // Parse an integer.
    int start = i;
    while (i < n && s.at(i).isDigit()) ++i;
    if (i == start) return fallback;  // expected a number
    bool ok = false;
    const uint64_t value = s.mid(start, i - start).toULongLong(&ok);
    if (!ok) return fallback;
    while (i < n && s.at(i).isSpace()) ++i;
    // Match the longest unit prefix at i. unitLen is counted in
    // QChar (UTF-16 code unit) length, NOT byte length, because `i`
    // and `s.size()` are QChar-counted. `µs` is 3 UTF-8 bytes but
    // 2 QChars (µ + s); using qstrlen here over-advanced past the
    // input.
    const QString rest = s.mid(i);
    uint64_t factor = 0;
    int unitLen = 0;
    for (const auto &u : kUnits) {
      const QString unit = QString::fromUtf8(u.name);
      const int ulen = unit.size();  // QChar count, matches `i`
      if (rest.startsWith(unit) && ulen > unitLen) {
        factor = u.factor;
        unitLen = ulen;
      }
    }
    if (unitLen == 0) return fallback;  // no unit
    total += value * factor;
    i += unitLen;
    anyMatched = true;
  }
  return anyMatched ? total : fallback;
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
      QStringLiteral("Ghastty"),             // app_name
      uint(0),                               // replaces_id
      QStringLiteral("ghastty"),             // app_icon
      title,                                 // summary
      body,                                  // body
      QStringList(),                         // actions
      QVariantMap(),                         // hints
      -1,                                    // expire_timeout (default)
  });
  QDBusConnection::sessionBus().send(msg);  // fire-and-forget
}

// Drive the taskbar progress bar via the Unity LauncherEntry D-Bus API
// (honored by the KDE task manager), keyed to ghastty.desktop.
//
// Unity LauncherEntry does not have first-class ERROR / PAUSE /
// INDETERMINATE states. We approximate per progress-style:
//   - REMOVE: progress-visible=false
//   - SET / ERROR / PAUSE: progress-visible=true, progress=fraction;
//     ERROR + PAUSE additionally flag urgent=true so the launcher
//     marks attention (KDE/Plasma renders this as a bouncing icon).
//   - INDETERMINATE: progress-visible=true with fraction=0 — Unity
//     has no indeterminate phase, so a 0 progress is the closest
//     we can do. Plasma renders this as an empty bar; better than
//     dropping the state entirely.
static void postProgress(ghostty_action_progress_report_state_e state,
                         double fraction) {
  QDBusMessage msg = QDBusMessage::createSignal(
      QStringLiteral("/com/canonical/unity/launcherentry/ghastty"),
      QStringLiteral("com.canonical.Unity.LauncherEntry"),
      QStringLiteral("Update"));
  QVariantMap props;
  const bool visible = state != GHOSTTY_PROGRESS_STATE_REMOVE;
  if (state == GHOSTTY_PROGRESS_STATE_INDETERMINATE) fraction = 0.0;
  props[QStringLiteral("progress")] = fraction;
  props[QStringLiteral("progress-visible")] = visible;
  if (state == GHOSTTY_PROGRESS_STATE_ERROR ||
      state == GHOSTTY_PROGRESS_STATE_PAUSE) {
    props[QStringLiteral("urgent")] = true;
  }
  msg.setArguments(
      {QStringLiteral("application://ghastty.desktop"), QVariant(props)});
  QDBusConnection::sessionBus().send(msg);
}

// Open a URL through the desktop, routed by libghostty's open_url
// kind. The default `QDesktopServices::openUrl` for `text` payloads
// (e.g. the config file) lands in whatever the user has registered
// for `.txt`, which on most Linux desktops is a browser. xdg-open
// `--type=text` doesn't exist, but we can resolve the user's
// preferred text editor via `xdg-mime query default text/plain`,
// fall back to `$VISUAL` / `$EDITOR`, and finally let
// QDesktopServices try.
static void openUrlByKind(const QString &url,
                          ghostty_action_open_url_kind_e kind) {
  if (kind != GHOSTTY_ACTION_OPEN_URL_KIND_TEXT) {
    QDesktopServices::openUrl(
        QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile));
    return;
  }
  // Try to launch a registered text/plain handler. xdg-mime returns
  // a `.desktop` file id; gtk-launch (Debian) or dex (KDE) executes
  // it. If that fails, fall through to the env-editor path.
  const QString path =
      QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile).toLocalFile();
  const QString target = path.isEmpty() ? url : path;
  QProcess mime;
  mime.start(QStringLiteral("xdg-mime"),
             {QStringLiteral("query"), QStringLiteral("default"),
              QStringLiteral("text/plain")});
  mime.waitForFinished(500);
  const QString desktopId =
      QString::fromUtf8(mime.readAllStandardOutput()).trimmed();
  if (!desktopId.isEmpty()) {
    if (QProcess::startDetached(QStringLiteral("gtk-launch"),
                                {desktopId, target}))
      return;
    if (QProcess::startDetached(QStringLiteral("dex"),
                                {desktopId, target}))
      return;
  }
  // $VISUAL / $EDITOR fall-back, but only if it's a GUI editor: a
  // tty-only `vi` would steal the controlling terminal. We can't
  // know for certain, so try a curated list (mate-, gedit, kate,
  // gnome-text-editor, code) before bailing to QDesktopServices.
  static const char *kGuiEditors[] = {
      "gnome-text-editor", "gedit", "kate",  "kwrite",
      "code",              "mousepad", "leafpad", nullptr};
  for (const char **e = kGuiEditors; *e; ++e) {
    if (QStandardPaths::findExecutable(QString::fromLatin1(*e)).isEmpty())
      continue;
    if (QProcess::startDetached(QString::fromLatin1(*e), {target})) return;
  }
  QDesktopServices::openUrl(
      QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile));
}

bool MainWindow::initialize() {
  // First-call: build libghostty app + config via the singleton. The
  // singleton holds m_app / m_config / m_needsPremultiply; the
  // MainWindow s_app / s_config / s_needsPremultiply statics are now
  // forwarders that read it.
  if (!GhosttyApp::instance().ensureInitialized()) return false;
  // Mirror the singleton's pointers into the legacy statics so the
  // existing call sites (the rest of MainWindow.cpp + GhosttySurface)
  // keep working unchanged. Phases 1.1+ swap them out.
  s_app = GhosttyApp::instance().app();
  s_config = GhosttyApp::instance().config();
  s_needsPremultiply = GhosttyApp::instance().needsPremultiply();

  GhosttyApp::instance().registerWindow(this);

  // First window also caches the quit-after-last-window-closed state.
  // Subsequent windows skip it (the singleton already holds the live
  // value via its config; only the QApplication quit strategy is set
  // once here).
  if (GhosttyApp::instance().windows().size() == 1) {
    // quit-after-last-window-closed: Qt's native "quit on last window"
    // covers the common (no-delay) case; a configured delay is honored
    // through the libghostty quit_timer action (see handleQuitTimer).
    const bool quitAfter = configBool("quit-after-last-window-closed", true);
    // quit-after-last-window-closed-delay is a `?Duration` and Duration
    // is neither extern nor packed, so libghostty's ghostty_config_get
    // returns false for it. Read from disk and parse.
    const uint64_t delayNs = parseDurationNs(
        configValue(QStringLiteral("quit-after-last-window-closed-delay")), 0);
    const uint64_t delayMs = delayNs / 1000000ULL;
    const int delayMsInt = quitAfter
        ? static_cast<int>(std::min(delayMs, uint64_t(INT_MAX)))
        : 0;
    GhosttyApp::instance().setQuitDelayMs(delayMsInt);
    s_quitDelayMs = delayMsInt;  // mirror; phase 1.3 retires the static
    QApplication::setQuitOnLastWindowClosed(quitAfter && delayMsInt == 0);
  }

  // Per-window startup window state, applied before show(). None of it
  // applies to the quick terminal — that is a layer-shell surface.
  if (!m_quickTerminal) {
    // window-decoration `none` drops the native frame; `auto`/`server`/
    // `client` keep a decorated window (the compositor picks the side
    // on Wayland).
    if (configString("window-decoration") == QLatin1String("none"))
      setWindowFlag(Qt::FramelessWindowHint, true);
    // fullscreen wins over maximize; its enum is `false` when unset.
    const QString fullscreen = configString("fullscreen");
    if (!fullscreen.isEmpty() && fullscreen != QLatin1String("false"))
      setWindowState(windowState() | Qt::WindowFullScreen);
    else if (configBool("maximize", false))
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
  // Config.zig). configGet writes the value and returns true when the
  // optional is present. Both must be set to take effect (matching
  // the Config.zig doc comment). If unset, fall back to a cascade
  // offset from the previous window so Cmd+N spam doesn't pile every
  // window at the same origin — macOS does this via
  // NSWindow.cascadeTopLeft. Wayland compositors typically ignore
  // window placement requests; this is a hint at most.
  int16_t posX = 0, posY = 0;
  const bool haveX = configGet(s_config, &posX, "window-position-x");
  const bool haveY = configGet(s_config, &posY, "window-position-y");
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
    configGet(s_config, &initialWindow, "initial-window");
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
  // tab — its closeEvent runs pushWindowUndo and we don't want to
  // double-stack. Also skip the quick terminal (which doesn't push
  // to either stack by design).
  if (index >= 0 && m_tabs->count() > 1 && !m_quickTerminal)
    pushTabUndo(index);
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
  // pushTabUndo is no-op for the last tab in a window — that close
  // ends up triggering pushWindowUndo via closeEvent instead.
  if (m_tabs->count() > 1 && !m_quickTerminal) pushTabUndo(index);
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
  if (!chosen || !surfaceAlive(src)) return;
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
  pushWindowUndo();
  e->accept();
}

bool MainWindow::confirmCloseSurfaces(
    const QList<GhosttySurface *> &surfaces) {
  // Honor the `confirm-close-surface` config:
  //   false  -> never prompt
  //   true   -> prompt only when libghostty says a process is running
  //   always -> always prompt, even for surfaces with no live process
  // (libghostty Config.zig: ConfirmCloseSurface enum.)
  const QString mode = configString("confirm-close-surface");
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
  if (s_app && ghostty_app_needs_confirm_quit(s_app)) {
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
  w->setupLayerShell();
  w->animateQuickTerminalIn();
  return w;
}

// Read quick-terminal-animation-duration (seconds) and convert to ms.
static int quickTerminalAnimationMs(ghostty_config_t cfg) {
  double secs = 0.2;  // matches Config.zig default
  configGet(cfg, &secs, "quick-terminal-animation-duration");
  // Clamp to a sane range so a misconfigured 0 or negative value
  // doesn't make the window appear/disappear instantly without an
  // animation, and a very large value doesn't lock the user out.
  if (secs <= 0.0) return 0;
  return std::clamp(static_cast<int>(secs * 1000.0), 1, 1000);
}

void MainWindow::animateQuickTerminalIn() {
  setWindowOpacity(0.0);
  show();
  raise();
  activateWindow();
  const int ms = quickTerminalAnimationMs(s_config);
  if (ms <= 0) {
    setWindowOpacity(1.0);
    return;
  }
  // Stop any running fade so toggling rapidly doesn't stack
  // animations. The animation is parented to `this` so it dies
  // with the window.
  if (m_quickTerminalAnim) m_quickTerminalAnim->stop();
  else m_quickTerminalAnim = new QPropertyAnimation(this, "windowOpacity", this);
  m_quickTerminalAnim->setDuration(ms);
  m_quickTerminalAnim->setStartValue(0.0);
  m_quickTerminalAnim->setEndValue(1.0);
  m_quickTerminalAnim->setEasingCurve(QEasingCurve::OutCubic);
  m_quickTerminalAnim->start();
}

void MainWindow::animateQuickTerminalOut() {
  const int ms = quickTerminalAnimationMs(s_config);
  if (ms <= 0) {
    hide();
    return;
  }
  if (m_quickTerminalAnim) m_quickTerminalAnim->stop();
  else m_quickTerminalAnim = new QPropertyAnimation(this, "windowOpacity", this);
  m_quickTerminalAnim->setDuration(ms);
  m_quickTerminalAnim->setStartValue(windowOpacity());
  m_quickTerminalAnim->setEndValue(0.0);
  m_quickTerminalAnim->setEasingCurve(QEasingCurve::InCubic);
  // Disconnect any previous handler before reconnecting; otherwise a
  // toggle-out-then-in cycle accumulates handlers that all fire on
  // the next out.
  disconnect(m_quickTerminalAnim, &QPropertyAnimation::finished,
             this, nullptr);
  connect(m_quickTerminalAnim, &QPropertyAnimation::finished, this,
          [this]() { hide(); });
  m_quickTerminalAnim->start();
}

void MainWindow::setupLayerShell() {
  // LayerShellQt attaches to the native window; force it into being.
  winId();
  QWindow *handle = windowHandle();
  if (!handle) return;
  LayerShellQt::Window *ls = LayerShellQt::Window::get(handle);
  if (!ls) {
    // The Qt frontend targets Wayland exclusively (the project
    // builds against LayerShellQt for the dropdown). If we can't
    // get a layer-shell handle the platform isn't supported — log
    // and bail rather than silently degrading to a non-functional
    // regular window.
    std::fprintf(stderr,
                 "[ghastty] LayerShellQt::Window::get returned null; "
                 "the quick terminal needs a Wayland session with "
                 "wlr-layer-shell support (e.g. KWin, sway).\n");
    return;
  }
  using LSW = LayerShellQt::Window;

  ls->setLayer(LSW::LayerTop);
  const QString ki = configString("quick-terminal-keyboard-interactivity");
  ls->setKeyboardInteractivity(
      ki == QLatin1String("exclusive") ? LSW::KeyboardInteractivityExclusive
      : ki == QLatin1String("none")    ? LSW::KeyboardInteractivityNone
                                       : LSW::KeyboardInteractivityOnDemand);

  // quick-terminal-screen: pick which output to anchor on.
  //   `main`            → primary screen.
  //   `mouse`           → the screen the pointer is currently on.
  //   `macos-menu-bar`  → macOS-only; falls through to primary on
  //                       Linux.
  // LayerShellQt 6.6+ exposes setScreen(QScreen*) on the layer-shell
  // window directly; the older setScreenConfiguration is deprecated.
  // Pass null to fall back to the QWindow's screen (LayerShellQt's
  // documented default when neither setScreen nor
  // setWantsToBeOnActiveScreen is set).
  const QString screenMode = configString("quick-terminal-screen");
  QScreen *screen = nullptr;
  if (screenMode == QLatin1String("mouse")) {
    screen = QGuiApplication::screenAt(QCursor::pos());
  } else if (screenMode == QLatin1String("main") ||
             screenMode == QLatin1String("macos-menu-bar")) {
    screen = QGuiApplication::primaryScreen();
  }
  ls->setScreen(screen);
  if (!screen) screen = handle->screen();

  // quick-terminal-space-behavior (`remain` / `move`): macOS
  // controls whether the dropdown follows the active Space or pins
  // to the one it was opened on. Wayland's wlr-layer-shell has no
  // equivalent — the compositor always renders the surface on the
  // active workspace (KWin behaviour), which corresponds to `move`.
  // Achieving `remain` would need a per-workspace pin that no
  // mainstream compositor exposes; honour by no-op and document.
  Q_UNUSED(configString("quick-terminal-space-behavior"));

  const QSize scr = screen ? screen->size() : QSize(1920, 1080);

  // quick-terminal-size: primary is the edge-perpendicular extent.
  ghostty_config_quick_terminal_size_s qsz = {};
  configGet(s_config, &qsz, "quick-terminal-size");
  const auto toPx = [](const ghostty_quick_terminal_size_s &s, int dim,
                       int fallback) -> int {
    switch (s.tag) {
      case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
        return static_cast<int>(s.value.percentage / 100.0f * dim);
      case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
        return static_cast<int>(s.value.pixels);
      default:
        return fallback;
    }
  };

  const QString pos = configString("quick-terminal-position");
  LSW::Anchors anchors;
  QSize size;
  if (pos == QLatin1String("bottom")) {
    anchors = LSW::Anchors(LSW::AnchorBottom) | LSW::AnchorLeft |
              LSW::AnchorRight;
    size = {scr.width(), toPx(qsz.primary, scr.height(), 400)};
  } else if (pos == QLatin1String("left")) {
    anchors = LSW::Anchors(LSW::AnchorLeft) | LSW::AnchorTop |
              LSW::AnchorBottom;
    size = {toPx(qsz.primary, scr.width(), 400), scr.height()};
  } else if (pos == QLatin1String("right")) {
    anchors = LSW::Anchors(LSW::AnchorRight) | LSW::AnchorTop |
              LSW::AnchorBottom;
    size = {toPx(qsz.primary, scr.width(), 400), scr.height()};
  } else if (pos == QLatin1String("center")) {
    anchors = LSW::Anchors(LSW::AnchorNone);
    size = {toPx(qsz.primary, scr.width(), 800),
            toPx(qsz.secondary, scr.height(), 400)};
  } else {  // top (the default)
    anchors = LSW::Anchors(LSW::AnchorTop) | LSW::AnchorLeft |
              LSW::AnchorRight;
    size = {scr.width(), toPx(qsz.primary, scr.height(), 400)};
  }
  ls->setAnchors(anchors);
  // The layer-shell protocol takes the size from the underlying
  // wl_surface (i.e. the QWindow's size); LayerShellQt has no
  // setDesiredSize on this Qt branch.
  resize(size);
}

void MainWindow::changeEvent(QEvent *e) {
  // quick-terminal-autohide: fade out the dropdown when it loses
  // focus (use the configured animation duration so this matches
  // an explicit toggle).
  if (e->type() == QEvent::ActivationChange && m_quickTerminal &&
      isVisible() && !isActiveWindow() &&
      configBool("quick-terminal-autohide", true))
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
  // libghostty serializes packed structs into a c_uint bitfield via
  // c_get.zig: `ptr.* = @intCast(@as(Backing, @bitCast(value)));`.
  // SplitPreserveZoom = packed struct { navigation: bool } so bit 0
  // is `navigation`. Reading into a smaller C struct (sizeof
  // `bool`==1) under-sized the buffer and corrupted adjacent stack;
  // read into c_uint and mask the bits.
  unsigned int pzBits = 0;
  configGet(s_config, &pzBits, "split-preserve-zoom");
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
  unsigned int features = 0;
  if (!configGet(s_config, &features, "bell-features")) {
    features = BellAttention;
  }
  if (features & BellAttention) QApplication::alert(this);
  if (features & BellSystem) QApplication::beep();
  if (features & BellAudio) playBellAudio();

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

void MainWindow::playBellAudio() {
  if (m_bellAudioPath.isEmpty()) return;
  if (!m_bellPlayer) {
    m_bellAudio = new QAudioOutput(this);
    m_bellPlayer = new QMediaPlayer(this);
    m_bellPlayer->setAudioOutput(m_bellAudio);
  }
  m_bellAudio->setVolume(m_bellAudioVolume);
  // Stop first so a back-to-back bell restarts the clip from the
  // beginning. Without this, calling play() on an already-playing
  // QMediaPlayer is a no-op and rapid bells get silently swallowed.
  m_bellPlayer->stop();
  m_bellPlayer->setSource(QUrl::fromLocalFile(m_bellAudioPath));
  m_bellPlayer->play();
}

// Refresh every window's chrome from the current s_config: tab-bar
// policy, colour scheme, blur — plus window-level state that
// previously only applied at startup (window-decoration, fullscreen,
// maximize) and the quit-after-last-window-closed delay.
void MainWindow::refreshChrome() {
  // Refresh app-scoped state. quit-after-last-window-closed[-delay]
  // can change the delay or the quitOnLastWindowClosed strategy at
  // runtime; mirrors the calculation in initialize().
  if (s_config) {
    bool quitAfter = true;
    configGet(s_config, &quitAfter, "quit-after-last-window-closed");
    // Same Duration-decode workaround as initialize().
    const uint64_t delayNs = parseDurationNs(
        configValue(QStringLiteral("quit-after-last-window-closed-delay")), 0);
    const uint64_t delayMs = delayNs / 1000000ULL;
    const int delayMsInt = quitAfter
        ? static_cast<int>(std::min(delayMs, uint64_t(INT_MAX)))
        : 0;
    GhosttyApp::instance().setQuitDelayMs(delayMsInt);
    s_quitDelayMs = delayMsInt;  // mirror; phase 1.3 retires the static
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
        w->configString("window-decoration") == QLatin1String("none");
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
    const QString fs = w->configString("fullscreen");
    const bool wantFullscreen = !fs.isEmpty() && fs != QLatin1String("false");
    const bool wantMax = w->configBool("maximize", false);
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
  if (!s_app) return;
  // Re-read the config from disk in the same order as initialize().
  ghostty_config_t config = ghostty_config_new();
  ghostty_config_load_default_files(config);
  ghostty_config_load_cli_args(config);
  ghostty_config_load_recursive_files(config);
  ghostty_config_finalize(config);

  // Push to libghostty. App.updateConfig propagates the config to every
  // surface and fires CONFIG_CHANGE back at us — which only refreshes
  // chrome, never re-pushes, so this does not loop.
  ghostty_app_update_config(s_app, config);

  // Hand the new config to the singleton, which frees the previous one
  // (in the right order — libghostty borrows the previous until update
  // completes) and recomputes needsPremultiply.
  GhosttyApp::instance().replaceConfig(config);
  s_config = GhosttyApp::instance().config();
  s_needsPremultiply = GhosttyApp::instance().needsPremultiply();

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
  unsigned int notifBits = 0;
  const bool notifOk = configGet(s_config, &notifBits, "app-notifications");
  // configGet failure → defaults (both bits set) so the feature
  // still works as documented.
  if (!notifOk) notifBits = 0x3;
  const bool wantConfigReload = (notifBits & 0x2) != 0;
  if (wantConfigReload)
    postNotification(QStringLiteral("Ghostty"),
                     QStringLiteral("Configuration reloaded."));
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
// `window-step-resize` config asks Qt to resize in cell increments;
// QWidget::setSizeIncrement is honored on X11 by most WMs but is
// usually ignored by Wayland compositors (the protocol has no
// equivalent of WM_NORMAL_HINTS step). Best-effort: it works where
// it works, no-op otherwise. Config docs explicitly say "currently
// only supported on macOS / has no effect on Linux," so this is
// strictly a bonus.
void MainWindow::setCellSize(uint32_t w, uint32_t h) {
  m_cellSize = QSize(int(w), int(h));
  if (configBool("window-step-resize", false))
    setSizeIncrement(int(w), int(h));
  else
    setSizeIncrement(0, 0);  // back to pixel-precise
}

// Process-wide undo state — see MainWindow.h.
QList<MainWindow::UndoEntry> MainWindow::s_undoStack;
QList<MainWindow::UndoEntry> MainWindow::s_redoStack;
bool MainWindow::s_redoInProgress = false;

// Snapshot the tab at `index` (its tab text — last-known title) onto
// the undo stack. Called from closeTab / closeTabsByMode / right
// before the tab is removed. No-op while a redo is replaying.
void MainWindow::pushTabUndo(int index) {
  if (s_redoInProgress) return;
  if (index < 0 || index >= m_tabs->count()) return;
  UndoEntry e;
  e.kind = UndoEntry::Kind::Tab;
  e.pageTitles << m_tabs->tabText(index);
  s_undoStack.append(std::move(e));
  if (s_undoStack.size() > kUndoCap) s_undoStack.removeFirst();
  // A fresh close invalidates any pending redo: the new "future" no
  // longer matches what the redo stack would re-close.
  s_redoStack.clear();
}

// Snapshot every tab in this window before it goes away. Called from
// closeAllWindows and from closeEvent for the user-driven X. No-op
// while a redo is replaying.
void MainWindow::pushWindowUndo() {
  if (s_redoInProgress) return;
  if (m_quickTerminal || m_tabs->count() == 0) return;
  UndoEntry e;
  e.kind = UndoEntry::Kind::Window;
  for (int i = 0; i < m_tabs->count(); ++i)
    e.pageTitles << m_tabs->tabText(i);
  e.geometry = geometry();
  s_undoStack.append(std::move(e));
  if (s_undoStack.size() > kUndoCap) s_undoStack.removeFirst();
  s_redoStack.clear();
}

// Pop the most recent undo entry and revive it. A new tab/window is
// opened that inherits cwd from the active surface (libghostty
// supplies the cwd via inherited_config), and the saved title is
// reapplied as a manual tab-title override so it persists across
// shell prompts.
void MainWindow::undoLastClose() {
  if (s_undoStack.isEmpty()) return;
  const UndoEntry e = s_undoStack.takeLast();

  // The active window picks the new tab's parent surface for cwd
  // inheritance. Skip the quick terminal — it doesn't push undo
  // entries and isn't a meaningful target. Fall back to the most
  // recent regular window in registration order.
  auto isUndoTarget = [](MainWindow *w) {
    return w && !w->m_quickTerminal;
  };
  MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
  if (!isUndoTarget(active)) {
    active = nullptr;
    const QList<MainWindow *> &live = GhosttyApp::instance().windows();
    for (int i = live.size() - 1; i >= 0; --i) {
      if (isUndoTarget(live.at(i))) {
        active = live.at(i);
        break;
      }
    }
  }
  GhosttySurface *parent = active
      ? active->surfaceAt(active->m_tabs->currentIndex())
      : nullptr;

  if (e.kind == UndoEntry::Kind::Tab) {
    if (!active) return;
    GhosttySurface *s = active->newTab(parent ? parent->surface() : nullptr);
    if (s && !e.pageTitles.isEmpty())
      active->setTabTitleOverride(s, e.pageTitles.first());
  } else {
    // Window: open a fresh window, then add additional tabs to match
    // the saved tab count. We don't try to recreate the split tree
    // — that would require a real session save mechanism.
    MainWindow *w = MainWindow::newWindow(parent ? parent->surface() : nullptr);
    if (!w) return;
    if (e.geometry.isValid()) w->setGeometry(e.geometry);
    // Title for the (eventually created) first tab.
    if (!e.pageTitles.isEmpty()) {
      const QString first = e.pageTitles.first();
      QPointer<MainWindow> wp(w);
      QTimer::singleShot(0, w, [wp, first]() {
        if (!wp) return;
        if (auto *s = wp->surfaceAt(0)) wp->setTabTitleOverride(s, first);
      });
    }
    // Additional tabs for the rest of the saved set.
    for (int i = 1; i < e.pageTitles.size(); ++i) {
      const QString t = e.pageTitles.at(i);
      QPointer<MainWindow> wp(w);
      QTimer::singleShot(0, w, [wp, t]() {
        if (!wp) return;
        GhosttySurface *s =
            wp->newTab(wp->surfaceAt(0) ? wp->surfaceAt(0)->surface() : nullptr);
        if (s) wp->setTabTitleOverride(s, t);
      });
    }
  }
  s_redoStack.append(e);
  if (s_redoStack.size() > kUndoCap) s_redoStack.removeFirst();
}

// Redo: re-close whatever undo just opened. We don't have a handle on
// the revived widgets so we close the active window's current tab
// (or the active window itself for a Window entry); pragmatic,
// matches what a user normally means by "redo close-tab".
//
// pushTabUndo / pushWindowUndo are no-ops while s_redoInProgress is
// true, so the close paths below don't:
//   (a) clear s_redoStack — preserving the rest of the redo chain
//       so a sequence of REDOs works.
//   (b) push a fresh undo entry — a redo that re-closes shouldn't
//       feed itself a new undo or the user can ping-pong undo/redo
//       on a single past close indefinitely.
void MainWindow::redoLastClose() {
  if (s_redoStack.isEmpty()) return;
  UndoEntry e = s_redoStack.takeLast();

  MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
  if (!active) {
    const QList<MainWindow *> &live = GhosttyApp::instance().windows();
    if (!live.isEmpty()) active = live.last();
  }
  if (!active) {
    // No window to act on — restore the entry so the user can retry.
    s_redoStack.append(std::move(e));
    return;
  }

  s_redoInProgress = true;
  if (e.kind == UndoEntry::Kind::Tab) {
    const int idx = active->m_tabs->currentIndex();
    if (idx >= 0) active->closeTab(idx);
  } else {
    active->m_skipCloseConfirm = true;
    active->close();
  }
  s_redoInProgress = false;
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
  } else {  // auto (the default): hidden while there is a lone tab
    m_tabs->setTabBarAutoHide(true);
    // setTabBarAutoHide does not retroactively correct an explicitly
    // shown/hidden bar, so set the right state for the current count.
    m_tabs->tabBar()->setVisible(m_tabs->count() > 1);
  }

  // bell-audio-path / -volume: cached on the window so playBellAudio
  // doesn't re-scan the on-disk config on every bell. Refreshed on
  // each applyWindowConfig (i.e. at init and on reload).
  {
    QString path = configValue(QStringLiteral("bell-audio-path"));
    if (path.startsWith(QLatin1String("~/")))
      path = QDir::homePath() + path.mid(1);
    m_bellAudioPath = path;
    bool volOk = false;
    const double v =
        configValue(QStringLiteral("bell-audio-volume")).toDouble(&volOk);
    m_bellAudioVolume = volOk ? v : 0.5;
  }

  // window-title-font-family: apply to the tab bar (and the WM
  // title via Qt's window-title system font is harder to override
  // portably; the tab bar is what users actually look at). Empty /
  // unset reverts to the application font.
  const QString titleFamily = configValue(QStringLiteral("window-title-font-family"));
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
  const QString divider = configValue(QStringLiteral("split-divider-color"));
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
  const QString theme = configString("window-theme");
  Qt::ColorScheme scheme = Qt::ColorScheme::Unknown;
  if (theme == QLatin1String("dark")) {
    scheme = Qt::ColorScheme::Dark;
  } else if (theme == QLatin1String("light")) {
    scheme = Qt::ColorScheme::Light;
  } else if (theme == QLatin1String("ghostty")) {
    ghostty_config_color_s bg{};
    if (configGet(s_config, &bg, "background")) {
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
  // uses its own configured radius, so only on/off matters here.
  short blur = 0;
  configGet(s_config, &blur, "background-blur");
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

bool MainWindow::surfaceAlive(GhosttySurface *s) {
  if (!s) return false;
  for (MainWindow *w : GhosttyApp::instance().windows())
    if (w->m_surfaces.contains(s)) return true;
  return false;
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

// Queue `f` on `target`'s thread, but only if `target` is still alive
// when the slot runs (Qt cancels queued slots whose receiver was
// deleted). Cross-captured pointers must be wrapped in QPointer
// separately — `target` only protects itself.
template <class Target, class F>
static void post(Target *target, F &&f) {
  if (!target) return;
  QMetaObject::invokeMethod(target, std::forward<F>(f), Qt::QueuedConnection);
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
  // marshalled onto `win` so it is cancelled if that window goes away;
  // *cross*-captured pointers (e.g. `src` when posting to `win`) are
  // wrapped in QPointer so they're checked at lambda-execution time —
  // a multi-window + tear-off + close race could otherwise UAF.
  const QList<MainWindow *> &live_ = GhosttyApp::instance().windows();
  MainWindow *win = src ? src->owner()
                        : (live_.isEmpty() ? nullptr : live_.first());
  QPointer<MainWindow> winp(win);
  QPointer<GhosttySurface> srcp(src);

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
      // `parent` is a libghostty handle whose lifetime tracks `src`'s.
      // If `src` is gone by the time the lambda runs, drop the parent
      // and create an unparented tab.
      post(win, [winp, srcp]() {
        if (!winp) return;
        winp->newTab(srcp ? srcp->surface() : nullptr);
      });
      return true;
    }

    case GHOSTTY_ACTION_NEW_WINDOW:
      post(qApp, [srcp]() {
        MainWindow::newWindow(srcp ? srcp->surface() : nullptr);
      });
      return true;

    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->splitSurface(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB: {
      if (!src) return false;
      const ghostty_action_close_tab_mode_e mode = action.action.close_tab_mode;
      post(win, [winp, srcp, mode]() {
        if (!winp || !srcp) return;
        winp->closeTabsByMode(srcp, mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setSurfaceTitle(srcp, t);
      });
      return true;
    }

    case GHOSTTY_ACTION_SET_TAB_TITLE: {
      // A manual tab-title override (an empty string clears it).
      if (!src) return true;
      const char *title = action.action.set_tab_title.title;
      const QString t = QString::fromUtf8(title ? title : "");
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setTabTitleOverride(srcp, t);
      });
      return true;
    }

    case GHOSTTY_ACTION_PROMPT_TITLE: {
      const bool tabScope =
          action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB;
      // App-target: promote to the active window's current surface so a
      // global keybind can rename even when no surface is the action's
      // explicit target. Mirrors macOS NSApp.mainWindow promotion.
      GhosttySurface *target = src;
      const QList<MainWindow *> &live_pt = GhosttyApp::instance().windows();
      if (!target && !live_pt.isEmpty()) {
        MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
        if (!active) active = live_pt.first();
        if (active) target = active->surfaceAt(active->m_tabs->currentIndex());
      }
      if (!target) return false;
      QPointer<GhosttySurface> tp(target);
      post(target, [tp, tabScope]() {
        if (tp) tp->promptTitle(tabScope);
      });
      return true;
    }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      post(win, [winp, srcp]() {
        if (winp) winp->copyTitleToClipboard(srcp);
      });
      return true;

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      post(win, [winp]() {
        if (!winp) return;
        winp->resize(winp->m_defaultWindowSize.isValid()
                         ? winp->m_defaultWindowSize
                         : QSize(800, 600));
      });
      return true;

    case GHOSTTY_ACTION_KEY_SEQUENCE: {
      if (!src) return true;
      const ghostty_action_key_sequence_s ks = action.action.key_sequence;
      if (!ks.active) {
        post(src, [srcp]() {
          if (srcp) srcp->endKeySequence();
        });
        return true;
      }
      const QString chord = formatTrigger(ks.trigger);
      post(src, [srcp, chord]() {
        if (srcp) srcp->pushKeySequence(chord);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_TAB: {
      // Performable: return false on a single tab so the chord falls
      // through to the terminal. macOS does the same; GTK gates on
      // tabPage count > 1.
      if (!win || win->m_tabs->count() <= 1) return false;
      const ghostty_action_goto_tab_e tab = action.action.goto_tab;
      post(win, [winp, tab]() {
        if (winp) winp->gotoTab(tab);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_SPLIT: {
      // Performable: return false when the surface has no split sibling
      // — otherwise navigation chords (e.g. ctrl+alt+arrows) eat their
      // own keystrokes on an unsplit surface.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_goto_split_e dir = action.action.goto_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->gotoSplit(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_RESIZE_SPLIT: {
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_resize_split_s rs = action.action.resize_split;
      post(win, [winp, srcp, rs]() {
        if (winp && srcp) winp->resizeSplit(srcp, rs);
      });
      return true;
    }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->equalizeSplits(srcp);
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isFullScreen())
          winp->showNormal();
        else
          winp->showFullScreen();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isMaximized())
          winp->showNormal();
        else
          winp->showMaximized();
      });
      return true;

    case GHOSTTY_ACTION_QUIT:
      post(qApp, []() { MainWindow::closeAllWindows(/*thenQuit=*/true); });
      return true;
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      // Distinct from QUIT: close-all-windows leaves the process
      // alive when quit-after-last-window-closed is false. macOS
      // makes the same distinction.
      post(qApp,
           []() { MainWindow::closeAllWindows(/*thenQuit=*/false); });
      return true;

    case GHOSTTY_ACTION_QUIT_TIMER: {
      const bool start =
          action.action.quit_timer == GHOSTTY_QUIT_TIMER_START;
      post(qApp,
           [start]() { GhosttyApp::instance().handleQuitTimer(start); });
      return true;
    }

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED: {
      if (!src) return false;
      const ghostty_surface_message_childexited_s ce =
          action.action.child_exited;
      // Suppress the banner for fast-exiting children (e.g. an
      // intentional `exit 0` after a quick command). Match the macOS
      // gate: only show when runtime_ms is at least the configured
      // abnormal threshold (default 250ms). Banner = "the process
      // died unexpectedly," not "the process exited."
      uint32_t threshold = 250;
      configGet(s_config, &threshold, "abnormal-command-exit-runtime");
      if (ce.runtime_ms < threshold) return true;
      const int code = static_cast<int>(ce.exit_code);
      post(src, [srcp, code]() {
        if (srcp) srcp->showChildExited(code);
      });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      // Performable: only meaningful inside a split tree.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->toggleSplitZoom(srcp);
      });
      return true;

    case GHOSTTY_ACTION_OPEN_CONFIG: {
      // ghostty_config_open_path creates the config file if missing and
      // returns its path; opening it is the apprt's job. Route through
      // the text-kind opener so the user's configured editor (not a
      // browser via "text/plain → .txt") gets the file.
      ghostty_string_s path = ghostty_config_open_path();
      if (path.ptr && path.len) {
        const QString p =
            QString::fromUtf8(path.ptr, static_cast<int>(path.len));
        post(qApp, [p]() {
          openUrlByKind(p, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT);
        });
      }
      ghostty_string_free(path);
      return true;
    }

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      // Reload is app-scoped (the config is process-wide). Post to
      // qApp instead of the originating window so the reload still
      // happens if the window that issued the action is closed
      // between the dispatch and the queued slot.
      post(qApp, []() { MainWindow::reloadConfigGlobal(); });
      return true;

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      // A notification: libghostty already holds the new config (this
      // often fires as the echo of our own ghostty_app_update_config).
      // Re-pushing it would loop, so just refresh window chrome.
      post(qApp, []() { MainWindow::refreshChrome(); });
      return true;

    case GHOSTTY_ACTION_INITIAL_SIZE: {
      if (!win) return false;
      const ghostty_action_initial_size_s sz = action.action.initial_size;
      post(win, [winp, sz]() {
        if (!winp) return;
        // The action carries logical pixels; resize() takes the same.
        // The previous code divided by devicePixelRatioF, halving the
        // window on a 2x display.
        const QSize logical(static_cast<int>(sz.width),
                            static_cast<int>(sz.height));
        winp->m_defaultWindowSize = logical;  // for RESET_WINDOW_SIZE
        winp->resize(logical);
      });
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      post(win, [winp]() {
        if (winp) winp->close();
      });
      return true;

    case GHOSTTY_ACTION_RING_BELL:
      post(win, [winp, srcp]() {
        if (winp) winp->ringBell(srcp);
      });
      return true;

    case GHOSTTY_ACTION_MOUSE_SHAPE: {
      if (!src) return false;
      const Qt::CursorShape shape =
          mouseShapeToCursor(action.action.mouse_shape);
      post(src, [srcp, shape]() {
        if (srcp) srcp->setShape(shape);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK: {
      if (!src) return true;
      const ghostty_action_mouse_over_link_s l = action.action.mouse_over_link;
      const QString url =
          l.url && l.len ? QString::fromUtf8(l.url, l.len) : QString();
      post(src, [srcp, url]() {
        if (srcp) srcp->setLinkOverlay(url);
      });
      return true;
    }

    case GHOSTTY_ACTION_OPEN_URL: {
      const ghostty_action_open_url_s u = action.action.open_url;
      if (!u.url || !u.len) return true;
      const QString s = QString::fromUtf8(u.url, static_cast<int>(u.len));
      const ghostty_action_open_url_kind_e kind = u.kind;
      post(qApp, [s, kind]() { openUrlByKind(s, kind); });
      return true;
    }

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION: {
      const ghostty_action_desktop_notification_s n =
          action.action.desktop_notification;
      const QString title = QString::fromUtf8(n.title ? n.title : "");
      const QString body = QString::fromUtf8(n.body ? n.body : "");
      // Suppress notifications from the focused surface — the user
      // is already looking at it and the popup just doubles up.
      // macOS does the same gate; GTK gates on surface focus too.
      // App-target (no `src`) always fires.
      post(qApp, [title, body, srcp]() {
        if (srcp && srcp->hasFocus()) return;
        postNotification(title, body);
      });
      return true;
    }

    case GHOSTTY_ACTION_COMMAND_FINISHED: {
      // libghostty fires this for every command end; the apprt is
      // responsible for the notify-on-command-finish gate.
      if (!src) return true;
      const int code = action.action.command_finished.exit_code;
      const uint64_t duration = action.action.command_finished.duration;
      post(src, [srcp, winp, code, duration]() {
        if (!srcp || !winp) return;
        // The per-command "armed via context menu" path overrides
        // the never/unfocused gate (matches GTK's setup-menu).
        const bool armed = srcp->consumeCommandNotify();
        // notify-on-command-finish enum (string).
        const QString mode = winp->configString("notify-on-command-finish");
        bool fire = armed;
        if (!fire) {
          if (mode == QLatin1String("always")) fire = true;
          else if (mode == QLatin1String("unfocused") && !srcp->hasFocus())
            fire = true;
        }
        if (!fire) return;
        // -after Duration; default 5s. Duration isn't decodable via
        // ghostty_config_get (non-extern non-packed struct), so parse
        // from the on-disk config.
        const uint64_t afterNs = parseDurationNs(
            configValue(QStringLiteral("notify-on-command-finish-after")),
            5ULL * 1000 * 1000 * 1000);
        if (duration < afterNs) return;
        // -action: NotifyOnCommandFinishAction = packed struct
        // { bell: bool = true, notify: bool = false }. Serialized
        // as c_uint via c_get.zig; bit 0 = bell, bit 1 = notify.
        // A zero-init reads as no-bell-no-notify, which matches the
        // "configGet failed; nothing to do" semantics.
        unsigned int actBits = 0;
        const bool actOk =
            configGet(s_config, &actBits, "notify-on-command-finish-action");
        // configGet failure → fall back to the documented defaults
        // (bell=true, notify=false) so the feature still works.
        if (!actOk) actBits = 0x1;
        const bool actBell = (actBits & 0x1) != 0;
        const bool actNotify = (actBits & 0x2) != 0;
        if (actBell) winp->ringBell(srcp);
        if (actNotify || armed) {
          QString title;
          if (code < 0) title = QStringLiteral("Command Finished");
          else if (code == 0) title = QStringLiteral("Command Succeeded");
          else title = QStringLiteral("Command Failed");
          const QString body = code >= 0
              ? QStringLiteral("Exited with code %1").arg(code)
              : QStringLiteral("The command completed.");
          postNotification(title, body);
        }
      });
      return true;
    }

    case GHOSTTY_ACTION_MOVE_TAB: {
      // Surface-target only: an app-target MOVE_TAB has no meaningful
      // window to apply to (we'd just pick the first live one arbitrarily).
      // macOS returns false here — performable falls through to the
      // running terminal on no live window.
      if (target.tag != GHOSTTY_TARGET_SURFACE || !src) return false;
      // Performable: a single tab can't be reordered.
      if (!win || win->m_tabs->count() <= 1) return false;
      const int amount = static_cast<int>(action.action.move_tab.amount);
      post(win, [winp, amount]() {
        if (winp) winp->moveTab(amount);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY: {
      if (!src) return false;
      const bool visible =
          action.action.mouse_visibility != GHOSTTY_MOUSE_HIDDEN;
      post(src, [srcp, visible]() {
        // setMouseVisible preserves the requested shape so toggling
        // doesn't reset to ArrowCursor.
        if (srcp) srcp->setMouseVisible(visible);
      });
      return true;
    }

    case GHOSTTY_ACTION_RENDERER_HEALTH: {
      const bool unhealthy =
          action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY;
      if (unhealthy)
        std::fprintf(stderr, "[ghastty] renderer reported unhealthy\n");
      // Surface the state in the affected pane so the user sees it
      // without watching stderr. The overlay is a simple per-surface
      // pill (see GhosttySurface::setRendererHealth); it clears as
      // soon as libghostty reports HEALTHY again.
      if (src) post(src, [srcp, unhealthy]() {
        if (srcp) srcp->setRendererHealth(unhealthy);
      });
      return true;
    }

    case GHOSTTY_ACTION_SCROLLBAR: {
      if (!src) return false;
      const ghostty_action_scrollbar_s s = action.action.scrollbar;
      post(src, [srcp, s]() {
        if (srcp) srcp->updateScrollbar(s.total, s.offset, s.len);
      });
      return true;
    }

    case GHOSTTY_ACTION_PROGRESS_REPORT: {
      // Honor `progress-style`: when false, OSC 9;4 progress sequences
      // are silently ignored (no taskbar entry). It is a *bool* in
      // Config.zig — it MUST be read with configBool. configString
      // would hand ghostty_config_get a `const char**`; the 1-byte
      // bool write leaves a `0x1` pointer that QString::fromUtf8 then
      // dereferences and crashes on (e.g. when Claude emits progress).
      if (win && !win->configBool("progress-style", true)) return true;
      const ghostty_action_progress_report_s p = action.action.progress_report;
      const ghostty_action_progress_report_state_e state = p.state;
      const double fraction = p.progress >= 0 ? p.progress / 100.0 : 0.0;
      post(qApp,
           [state, fraction]() { postProgress(state, fraction); });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      post(qApp, []() { GhosttyApp::instance().toggleVisibility(); });
      return true;

    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      post(qApp, []() { GhosttyApp::instance().toggleQuickTerminal(); });
      return true;

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      post(win, [winp, srcp]() {
        if (winp) winp->toggleCommandPalette(srcp);
      });
      return true;

    case GHOSTTY_ACTION_START_SEARCH: {
      if (!src) return true;
      const char *needle = action.action.start_search.needle;
      const QString n = QString::fromUtf8(needle ? needle : "");
      post(src, [srcp, n]() {
        if (srcp) srcp->openSearch(n);
      });
      return true;
    }

    case GHOSTTY_ACTION_END_SEARCH:
      if (src)
        post(src, [srcp]() {
          if (srcp) srcp->closeSearch();
        });
      return true;

    case GHOSTTY_ACTION_SEARCH_TOTAL: {
      if (!src) return true;
      const int total = static_cast<int>(action.action.search_total.total);
      post(src, [srcp, total]() {
        if (srcp) srcp->setSearchTotal(total);
      });
      return true;
    }

    case GHOSTTY_ACTION_SEARCH_SELECTED: {
      if (!src) return true;
      const int sel =
          static_cast<int>(action.action.search_selected.selected);
      post(src, [srcp, sel]() {
        if (srcp) srcp->setSearchSelected(sel);
      });
      return true;
    }

    case GHOSTTY_ACTION_INSPECTOR: {
      if (!src) return true;
      const ghostty_action_inspector_e mode = action.action.inspector;
      post(src, [srcp, mode]() {
        if (srcp) srcp->toggleInspector(mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_RENDER_INSPECTOR: {
      // libghostty already has its own inspector redraw timer, but a
      // wakeup here keeps it tight.
      if (src)
        post(src, [srcp]() {
          if (srcp) srcp->refreshInspector();
        });
      return true;
    }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      if (!win) return false;
      post(win, [winp, srcp]() {
        if (winp) winp->presentTerminal(srcp.data());
      });
      return true;

    case GHOSTTY_ACTION_GOTO_WINDOW: {
      // Performable: return false on a single window so the chord
      // falls through to the terminal.
      if (GhosttyApp::instance().windows().size() <= 1) return false;
      const ghostty_action_goto_window_e dir = action.action.goto_window;
      post(qApp,
           [winp, dir]() { MainWindow::gotoWindow(winp.data(), dir); });
      return true;
    }

    case GHOSTTY_ACTION_FLOAT_WINDOW: {
      if (!win) return false;
      const ghostty_action_float_window_e mode = action.action.float_window;
      post(win, [winp, mode]() {
        if (winp) winp->setFloating(mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleWindowDecorations();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleBackgroundOpacity();
      });
      return true;

    case GHOSTTY_ACTION_SIZE_LIMIT: {
      if (!win) return false;
      const ghostty_action_size_limit_s sl = action.action.size_limit;
      post(win, [winp, sl]() {
        if (winp)
          winp->setSizeLimits(sl.min_width, sl.min_height,
                              sl.max_width, sl.max_height);
      });
      return true;
    }

    case GHOSTTY_ACTION_CELL_SIZE: {
      if (!win) return false;
      const ghostty_action_cell_size_s cs = action.action.cell_size;
      post(win, [winp, cs]() {
        if (winp) winp->setCellSize(cs.width, cs.height);
      });
      return true;
    }

    case GHOSTTY_ACTION_KEY_TABLE: {
      if (!src) return true;
      // KeyTable is libghostty's bindable-mode mechanism: ACTIVATE
      // pushes a named table onto the binding stack, DEACTIVATE pops
      // one, DEACTIVATE_ALL clears them. Reuse the keybind chord
      // overlay to surface "we're in mode X" to the user — not as
      // pretty as macOS's dedicated badge but adequate.
      const ghostty_action_key_table_s kt = action.action.key_table;
      QString label;
      if (kt.tag == GHOSTTY_KEY_TABLE_ACTIVATE && kt.value.activate.name &&
          kt.value.activate.len) {
        label = QString::fromUtf8(kt.value.activate.name,
                                  static_cast<int>(kt.value.activate.len));
      }
      post(src, [srcp, label]() {
        if (!srcp) return;
        if (label.isEmpty())
          srcp->endKeySequence();
        else
          srcp->pushKeySequence(QStringLiteral("[%1]").arg(label));
      });
      return true;
    }

    case GHOSTTY_ACTION_PWD: {
      // libghostty inherits a child's pwd through the surface tree
      // (ghostty_surface_inherited_config carries it across splits /
      // tabs), and re-fires this action whenever the cwd changes via
      // OSC 7 / shell integration. Stash it on the surface so future
      // chrome (worktree-aware tab decoration, "new tab here") can
      // read it without parsing /proc/<pid>/cwd. Empty pwd from
      // libghostty means "unknown / cleared" — pass it through so the
      // surface can drop a stale value.
      if (!src) return true;
      // libghostty's pwd is a sentinel-terminated Zig slice (see
      // src/apprt/action.zig:Pwd) — its C ptr is always non-null;
      // an "unknown / cleared" cwd is encoded as "".
      const QString s = QString::fromUtf8(action.action.pwd.pwd);
      post(src, [srcp, s]() {
        if (srcp) srcp->setPwd(s);
      });
      return true;
    }

    case GHOSTTY_ACTION_COLOR_CHANGE: {
      // OSC 4/10/11/12 colour change. libghostty already updates its
      // internal palette; the next render will reflect it. Dirty the
      // surface so the change is visible promptly.
      if (src) src->markDirty();
      // OSC 11 flips the effective background, which under
      // `window-theme = ghostty` controls the chrome's light/dark
      // scheme. The config-file `background` hasn't changed, so we
      // can't go through refreshChrome; instead, derive the scheme
      // straight from the action's RGB payload. macOS does the
      // analogous thing in its color-change handler.
      //
      // Note: Qt's setColorScheme is a process-global style hint, so
      // an OSC 11 from any window flips chrome on every window. This
      // matches applyWindowConfig (also a global call) and is the
      // documented Qt 6.8+ behaviour.
      if (action.action.color_change.kind ==
          GHOSTTY_ACTION_COLOR_KIND_BACKGROUND) {
        const ghostty_action_color_change_s c = action.action.color_change;
        post(qApp, [winp, c]() {
          if (!winp) return;
          if (winp->configString("window-theme") != QLatin1String("ghostty"))
            return;
          const double luma = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
          QGuiApplication::styleHints()->setColorScheme(
              luma < 128.0 ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
        });
      }
      return true;
    }

    case GHOSTTY_ACTION_READONLY:
      // Read-only mode: libghostty itself drops keystrokes; we have
      // no UI affordance (e.g. a padlock icon) so just acknowledge.
      return true;

    case GHOSTTY_ACTION_SECURE_INPUT:
      // Secure-input: macOS-only enable_secure_event_input() that
      // hides keystrokes from other apps. Wayland has no equivalent
      // (the compositor mediates input), so this is a documented
      // platform gap; acknowledge so the keybind isn't reported as
      // unhandled.
      return true;

    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
      // No in-app updater on Linux (distros / package managers handle
      // updates). Acknowledge so the keybind isn't unhandled.
      return true;

    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      // Tab overview is GTK's adw.TabOverview — a thumbnail grid of
      // tabs. Qt has no built-in equivalent and an ad-hoc Qt port
      // would be a feature in its own right; acknowledge for now.
      return true;

    case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR:
      // GTK-only debug action; no analogue.
      return true;

    case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      // libghostty defines this for iOS / on-screen-keyboard apprts.
      // Linux desktops have a system-managed virtual keyboard (e.g.
      // KDE's vkbd, GNOME's caribou) that the user toggles
      // out-of-band; nothing for the apprt to do. Acknowledge so the
      // keybind isn't reported as unhandled.
      return true;

    case GHOSTTY_ACTION_UNDO:
      post(qApp, []() { MainWindow::undoLastClose(); });
      return true;

    case GHOSTTY_ACTION_REDO:
      post(qApp, []() { MainWindow::redoLastClose(); });
      return true;

    default:
      return false;
  }
}

bool MainWindow::onReadClipboard(void *ud, ghostty_clipboard_e loc,
                                 void *state) {
  // surface userdata. Called synchronously by libghostty when a
  // surface needs clipboard contents (paste). This runs on the GUI
  // thread by construction: every libghostty entry point that
  // surfaces a paste lives behind ghostty_app_tick, which the
  // process-wide frame timer drives — and that timer is on the GUI
  // thread. QClipboard is GUI-thread-only, so reading directly here
  // is safe; surfaceAlive still validates the pointer in case a
  // surface is mid-destruction on this same thread.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surfaceAlive(surface) || !surface->surface()) return false;

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
  if (!surfaceAlive(surface) || !surface->surface()) return;

  QPointer<GhosttySurface> sp(surface);
  const QByteArray content(str);
  QMetaObject::invokeMethod(
      surface->owner(),
      [sp, content, state]() {
        if (!sp || !sp->surface()) return;
        QString preview = QString::fromUtf8(content);
        // Truncate by code unit but back off to a non-surrogate boundary
        // so we don't slice a surrogate pair half.
        if (preview.size() > 200) {
          int cut = 200;
          while (cut > 0 && preview.at(cut - 1).isHighSurrogate()) --cut;
          preview = preview.left(cut) + QStringLiteral("…");
        }
        // Destructive Paste / Cancel buttons, default Cancel —
        // mirrors the close-confirmation styling.
        QMessageBox box(sp->owner());
        box.setIcon(QMessageBox::Warning);
        box.setWindowTitle(QStringLiteral("Confirm Paste"));
        box.setText(QStringLiteral("The text being pasted may be unsafe."));
        box.setInformativeText(preview);
        QPushButton *paste = box.addButton(QStringLiteral("Paste"),
                                           QMessageBox::DestructiveRole);
        QPushButton *cancel = box.addButton(QStringLiteral("Cancel"),
                                            QMessageBox::RejectRole);
        box.setDefaultButton(cancel);
        box.exec();
        ghostty_surface_complete_clipboard_request(
            sp->surface(), content.constData(), state,
            box.clickedButton() == paste);
      },
      Qt::QueuedConnection);
}

void MainWindow::onWriteClipboard(void *ud, ghostty_clipboard_e loc,
                                  const ghostty_clipboard_content_s *content,
                                  size_t n, bool) {
  if (n == 0 || !content[0].data) return;
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surfaceAlive(surface)) return;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QString text = QString::fromUtf8(content[0].data);
  // The clipboard is process-global; route via qApp so a window dying
  // mid-flight does not strand the write.
  QMetaObject::invokeMethod(
      qApp,
      [text, mode]() { QGuiApplication::clipboard()->setText(text, mode); },
      Qt::QueuedConnection);
}

void MainWindow::onCloseSurface(void *ud, bool) {
  // surface userdata. Deferred out of this callback so the confirm
  // dialog cannot spin a nested event loop back into libghostty.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!surfaceAlive(surface)) return;
  MainWindow *self = surface->owner();
  QPointer<MainWindow> selfp(self);
  QPointer<GhosttySurface> sp(surface);
  QMetaObject::invokeMethod(
      self,
      [selfp, sp]() {
        if (!selfp || !sp) return;
        if (selfp->confirmCloseSurfaces({sp})) selfp->removeSurface(sp);
      },
      Qt::QueuedConnection);
}
