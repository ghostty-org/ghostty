#include "GhosttyApp.h"

#include <cstdio>

#include <QApplication>
#include <QByteArray>
#include <QClipboard>
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QGuiApplication>
#include <QMessageBox>
#include <QMetaObject>
#include <QPointer>
#include <QPushButton>
#include <QString>
#include <QTimer>

#include "../GhosttySurface.h"
#include "../MainWindow.h"

// Process-wide libghostty state. Only the libghostty handles + their
// bring-up / teardown lifecycle live here in phase 1.0; the runtime
// callbacks (onWakeup, onAction, onReadClipboard, ...) and the window
// registry, undo stack, frame timer, etc. all still live on
// MainWindow and migrate in subsequent phases.

// Whether the Ghostty config enables a custom shader. libghostty does
// not expose this through ghostty_config_get (`custom-shader` is a
// repeatable path), so scan the primary config file directly. Same
// implementation MainWindow had before — moved here because
// needsPremultiply is now an app-level fact.
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

GhosttyApp &GhosttyApp::instance() {
  // Static-local singleton: deterministic destruction at process exit
  // (after Qt has already torn down QObject children). Construction
  // is deferred until the first call so QApplication exists by then.
  static GhosttyApp self;
  return self;
}

GhosttyApp::~GhosttyApp() {
  // Backstop for an early-exit path (ghostty_init failure inside
  // main()). The normal teardown runs from the last MainWindow's dtor.
  teardown();
}

bool GhosttyApp::ensureInitialized() {
  if (m_app) return true;

  // Load configuration in the same order as the reference apprt.
  m_config = ghostty_config_new();
  ghostty_config_load_default_files(m_config);
  ghostty_config_load_cli_args(m_config);
  ghostty_config_load_recursive_files(m_config);
  ghostty_config_finalize(m_config);
  m_needsPremultiply = configHasCustomShader();

  ghostty_runtime_config_s rt = {};
  // No app userdata: actions are routed to a window via their target
  // surface, and app-level actions via the GhosttyApp window registry.
  rt.userdata = nullptr;
  rt.supports_selection_clipboard = true;
  // onAction stays on MainWindow until phase 2 introduces the
  // ActionDispatcher; the rest are owned by GhosttyApp.
  rt.wakeup_cb = GhosttyApp::onWakeup;
  rt.action_cb = MainWindow::onAction;
  rt.read_clipboard_cb = GhosttyApp::onReadClipboard;
  rt.confirm_read_clipboard_cb = GhosttyApp::onConfirmReadClipboard;
  rt.write_clipboard_cb = GhosttyApp::onWriteClipboard;
  rt.close_surface_cb = GhosttyApp::onCloseSurface;

  m_app = ghostty_app_new(&rt, m_config);
  if (!m_app) {
    std::fprintf(stderr, "[ghastty] ghostty_app_new failed\n");
    ghostty_config_free(m_config);
    m_config = nullptr;
    return false;
  }
  return true;
}

void GhosttyApp::replaceConfig(ghostty_config_t new_config) {
  // libghostty keeps borrowed references to the previous config (the
  // surface message queue), so the new must be installed and the old
  // freed in this order.
  if (m_config && m_config != new_config) ghostty_config_free(m_config);
  m_config = new_config;
  m_needsPremultiply = configHasCustomShader();
}

void GhosttyApp::registerWindow(MainWindow *w) {
  m_windows.append(w);
}

void GhosttyApp::unregisterWindow(MainWindow *w) {
  m_windows.removeOne(w);
  if (m_quickTerminal == w) m_quickTerminal = nullptr;
}

void GhosttyApp::toggleVisibility() {
  // If anything is showing, hide everything; otherwise reveal it all.
  bool anyVisible = false;
  for (MainWindow *w : m_windows)
    if (w->isVisible()) {
      anyVisible = true;
      break;
    }
  for (MainWindow *w : m_windows) {
    if (anyVisible) {
      w->hide();
    } else {
      w->show();
      w->raise();
      w->activateWindow();
    }
  }
}

void GhosttyApp::toggleQuickTerminal() {
  if (m_quickTerminal) {
    if (m_quickTerminal->isVisible())
      m_quickTerminal->animateQuickTerminalOut();
    else
      m_quickTerminal->animateQuickTerminalIn();
    return;
  }
  // First use: build the dedicated quick-terminal window. It registers
  // itself via the standard registerWindow path; we additionally
  // remember it as the singleton dropdown so a second toggle-call
  // animates rather than building another window.
  m_quickTerminal = MainWindow::makeQuickTerminal();
}

void GhosttyApp::ensureFrameTimer() {
  if (m_frameTimer) return;
  // Process-wide 60fps frame timer: a backstop tick plus rendering.
  // onWakeup drives extra ticks between frames for input
  // responsiveness. One timer covers every window — N windows would
  // otherwise produce N ticks per 16ms for the same shared
  // ghostty_app_t.
  m_frameTimer = new QTimer(qApp);
  QObject::connect(m_frameTimer, &QTimer::timeout, qApp,
                   [this]() { frame(); });
  m_frameTimer->start(16);
}

void GhosttyApp::handleQuitTimer(bool start) {
  // Only meaningful when a delay is configured; otherwise Qt's
  // quitOnLastWindowClosed already handles the quit.
  if (m_quitDelayMs <= 0) return;
  if (start) {
    if (!m_quitTimer) {
      // Parent to qApp for consistency with m_frameTimer; teardown()
      // still deletes it explicitly when the last window closes.
      m_quitTimer = new QTimer(qApp);
      m_quitTimer->setSingleShot(true);
      QObject::connect(m_quitTimer, &QTimer::timeout, qApp,
                       &QApplication::quit);
    }
    m_quitTimer->start(m_quitDelayMs);
  } else if (m_quitTimer) {
    m_quitTimer->stop();
  }
}

void GhosttyApp::frame() {
  if (!m_app) return;
  ghostty_app_tick(m_app);
  // Rendering happens only here, so a flood of RENDER actions cannot
  // saturate the GUI thread — each surface renders at most once a
  // frame. One pass across every window: the shared ghostty_app_t
  // was already ticked once above.
  //
  // Iterate via QPointer snapshots so a render-driven close
  // (renderer-unhealthy chain, child-exited press, etc.) that
  // destroys a window or surface mid-frame can't UAF the iterator
  // or the inner-loop receiver.
  QList<QPointer<MainWindow>> windows;
  windows.reserve(m_windows.size());
  for (MainWindow *w : m_windows) windows.append(w);
  for (const QPointer<MainWindow> &wp : windows) {
    if (!wp) continue;
    QList<QPointer<GhosttySurface>> surfaces;
    const QList<GhosttySurface *> &surfList = wp->surfaces();
    surfaces.reserve(surfList.size());
    for (GhosttySurface *s : surfList) surfaces.append(s);
    for (const QPointer<GhosttySurface> &sp : surfaces) {
      if (!wp || !sp) continue;
      sp->renderIfDirty();
    }
  }
}

void GhosttyApp::onWakeup(void *) {
  // Coalesce: queue a shared-app tick only when one is not already
  // pending, so a chatty surface cannot flood the event loop. May be
  // called off-thread, so it marshals onto qApp (always alive) rather
  // than any particular window. The m_app check inside the lambda
  // guards against the last window being destroyed (which calls
  // teardown and frees m_app) between this wakeup and the queued
  // tick draining.
  GhosttyApp &self = instance();
  if (self.m_tickPending.exchange(true)) return;
  QMetaObject::invokeMethod(
      qApp,
      []() {
        GhosttyApp &s = instance();
        s.m_tickPending.store(false);
        if (s.m_app) ghostty_app_tick(s.m_app);
      },
      Qt::QueuedConnection);
}

void GhosttyApp::teardown() {
  // Stop and free the timers BEFORE draining queued events: a final
  // frame timeout could otherwise dispatch through the queue and
  // tick the about-to-be-freed app.
  if (m_frameTimer) {
    m_frameTimer->stop();
    delete m_frameTimer;
    m_frameTimer = nullptr;
  }
  if (m_quitTimer) {
    delete m_quitTimer;
    m_quitTimer = nullptr;
  }

  // Drain qApp-targeted MetaCalls posted by worker-thread libghostty
  // callbacks (closeAllWindows, refreshChrome, OPEN_URL, postProgress,
  // handleQuitTimer, NEW_WINDOW, CONFIG_CHANGE, ...) — these are the
  // ones that can still touch m_app / m_config after their original
  // window has gone. Lambdas posted to per-window/per-surface
  // receivers are auto-cancelled by Qt when those receivers are
  // deleted, so they don't need draining.
  //
  // sendPostedEvents only drains the named receiver, not its
  // children — which is exactly what we want here.
  QCoreApplication::sendPostedEvents(qApp, QEvent::MetaCall);
  if (m_app) {
    ghostty_app_free(m_app);
    m_app = nullptr;
  }
  if (m_config) {
    ghostty_config_free(m_config);
    m_config = nullptr;
  }
  m_needsPremultiply = false;
}

bool GhosttyApp::surfaceAlive(GhosttySurface *s) const {
  if (!s) return false;
  for (MainWindow *w : m_windows)
    if (w->ownsSurface(s)) return true;
  return false;
}

bool GhosttyApp::onReadClipboard(void *ud, ghostty_clipboard_e loc,
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
  if (!instance().surfaceAlive(surface) || !surface->surface()) return false;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QByteArray text = QGuiApplication::clipboard()->text(mode).toUtf8();
  ghostty_surface_complete_clipboard_request(surface->surface(),
                                             text.constData(), state, true);
  return true;
}

void GhosttyApp::onConfirmReadClipboard(void *ud, const char *str,
                                        void *state,
                                        ghostty_clipboard_request_e) {
  // libghostty asks for confirmation when a paste looks unsafe. The
  // dialog MUST be deferred: this callback runs inside libghostty,
  // and a modal dialog here spins a nested event loop that re-enters
  // libghostty through the render tick — a crash/freeze. `state` is
  // a completion token valid until used; `str` is not, so copy it.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!instance().surfaceAlive(surface) || !surface->surface()) return;

  QPointer<GhosttySurface> sp(surface);
  const QByteArray content(str);
  QMetaObject::invokeMethod(
      surface->owner(),
      [sp, content, state]() {
        if (!sp || !sp->surface()) return;
        QString preview = QString::fromUtf8(content);
        // Truncate by code unit but back off to a non-surrogate
        // boundary so we don't slice a surrogate pair half.
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

void GhosttyApp::onWriteClipboard(void *ud, ghostty_clipboard_e loc,
                                  const ghostty_clipboard_content_s *content,
                                  size_t n, bool) {
  if (n == 0 || !content[0].data) return;
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!instance().surfaceAlive(surface)) return;

  const QClipboard::Mode mode = loc == GHOSTTY_CLIPBOARD_SELECTION
                                    ? QClipboard::Selection
                                    : QClipboard::Clipboard;
  const QString text = QString::fromUtf8(content[0].data);
  // The clipboard is process-global; route via qApp so a window
  // dying mid-flight does not strand the write.
  QMetaObject::invokeMethod(
      qApp,
      [text, mode]() { QGuiApplication::clipboard()->setText(text, mode); },
      Qt::QueuedConnection);
}

void GhosttyApp::onCloseSurface(void *ud, bool) {
  // surface userdata. Deferred out of this callback so the confirm
  // dialog cannot spin a nested event loop back into libghostty.
  auto *surface = static_cast<GhosttySurface *>(ud);
  if (!instance().surfaceAlive(surface)) return;
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
