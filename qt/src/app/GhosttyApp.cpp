#include "GhosttyApp.h"

#include <cstdio>

#include <QByteArray>
#include <QCoreApplication>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QString>

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
  // surface, and app-level actions via the MainWindow window registry.
  rt.userdata = nullptr;
  rt.supports_selection_clipboard = true;
  // Phase 1.0: every callback still lives on MainWindow. Phase 1.1
  // moves them onto GhosttyApp and the registration switches to
  // GhosttyApp::onWakeup et al.
  rt.wakeup_cb = MainWindow::onWakeup;
  rt.action_cb = MainWindow::onAction;
  rt.read_clipboard_cb = MainWindow::onReadClipboard;
  rt.confirm_read_clipboard_cb = MainWindow::onConfirmReadClipboard;
  rt.write_clipboard_cb = MainWindow::onWriteClipboard;
  rt.close_surface_cb = MainWindow::onCloseSurface;

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
}

void GhosttyApp::teardown() {
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
