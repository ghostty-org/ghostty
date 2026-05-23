#pragma once

#include <QList>

#include "ghostty.h"

class MainWindow;

// Process-wide libghostty integration.
//
// Owns the single ghostty_app_t and ghostty_config_t instances that
// drive every window in the process, plus the derived needsPremultiply
// flag that the surfaces' renderer reads when blitting frames.
//
// Singleton — there is never more than one libghostty app per
// process. Construction is deferred to the first instance() call so
// QApplication can exist before the singleton is built.
//
// Phase 1.0 scope: only the libghostty handles + bring-up / teardown
// live here. The frame timer, runtime callbacks, window registry,
// undo stack, quit-timer state, and action dispatch all stay on
// MainWindow for now; subsequent phases migrate them.
class GhosttyApp {
public:
  static GhosttyApp &instance();

  // libghostty handles. Null until ensureInitialized() succeeds.
  ghostty_app_t app() const { return m_app; }
  ghostty_config_t config() const { return m_config; }
  bool needsPremultiply() const { return m_needsPremultiply; }

  // Builds the libghostty config + app the first time it's called,
  // wiring the runtime callback bundle that MainWindow currently
  // hosts (onWakeup / onAction / onReadClipboard / ... — all still
  // implemented on MainWindow during phase 1.0).
  //
  // Re-entrant: subsequent calls early-return true.
  // Returns false on libghostty init failure.
  bool ensureInitialized();

  // Refresh m_config + m_needsPremultiply from disk (called from
  // MainWindow::reloadConfigGlobal). The caller is responsible for
  // pushing the new config to libghostty (ghostty_app_update_config)
  // and refreshing window chrome — those iterate the window list,
  // which still lives on MainWindow during phase 1.0.
  void replaceConfig(ghostty_config_t new_config);

  // Free m_app + m_config. Called from MainWindow::~MainWindow when
  // the last window goes away. Idempotent.
  void teardown();

  // ---- window registry --------------------------------------------
  //
  // Every live MainWindow registers itself here at construction and
  // removes itself at destruction. Replaces the MainWindow::s_windows
  // static.

  void registerWindow(MainWindow *w);
  void unregisterWindow(MainWindow *w);
  const QList<MainWindow *> &windows() const { return m_windows; }

private:
  GhosttyApp() = default;
  ~GhosttyApp();
  GhosttyApp(const GhosttyApp &) = delete;
  GhosttyApp &operator=(const GhosttyApp &) = delete;

  ghostty_app_t m_app = nullptr;
  ghostty_config_t m_config = nullptr;
  bool m_needsPremultiply = false;

  // Live MainWindow list. Order is registration order; MainWindow
  // relies on that for cascade-position fallback (see newWindow), the
  // GOTO_WINDOW cycle, and the "most recent regular window" lookup
  // in undoLastClose. Migrated wholesale from MainWindow::s_windows.
  QList<MainWindow *> m_windows;
};
