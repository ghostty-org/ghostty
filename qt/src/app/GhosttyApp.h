#pragma once

#include <atomic>

#include <QList>

#include "ghostty.h"

class MainWindow;
class QTimer;

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

  // The dropdown quick terminal, if it exists. There is at most one
  // per process. Owned by Qt (WA_DeleteOnClose); GhosttyApp holds a
  // non-owning pointer so toggleQuickTerminal can find it.
  MainWindow *quickTerminal() const { return m_quickTerminal; }

  // App-scoped show/hide of every regular window. Replaces
  // MainWindow::toggleVisibility().
  void toggleVisibility();

  // Show/hide the dropdown, creating it on first use. Replaces
  // MainWindow::toggleQuickTerminal().
  void toggleQuickTerminal();

  // ---- frame + quit timers ----------------------------------------

  // Build the process-wide 60Hz frame timer if not already running.
  // Idempotent. Called from MainWindow::initialize() on first window.
  void ensureFrameTimer();

  // Start / stop the natural-close quit timer per
  // quit-after-last-window-closed-delay. No-op when delay is 0.
  void handleQuitTimer(bool start);

  // quit-after-last-window-closed-delay (ms). 0 means no delay.
  int quitDelayMs() const { return m_quitDelayMs; }
  void setQuitDelayMs(int ms) { m_quitDelayMs = ms; }

  // ---- libghostty runtime callbacks (registered in ensureInitialized).
  static void onWakeup(void *ud);
  static bool onReadClipboard(void *ud, ghostty_clipboard_e, void *state);
  static void onConfirmReadClipboard(void *ud, const char *, void *state,
                                     ghostty_clipboard_request_e);
  static void onWriteClipboard(void *ud, ghostty_clipboard_e,
                               const ghostty_clipboard_content_s *, size_t,
                               bool);
  static void onCloseSurface(void *ud, bool process_active);

  // True if the surface pointer (a libghostty userdata) is still owned
  // by a live MainWindow. Worker-thread callbacks use this to gate
  // against a destruction race.
  bool surfaceAlive(GhosttySurface *s) const;

private:
  GhosttyApp() = default;
  ~GhosttyApp();
  GhosttyApp(const GhosttyApp &) = delete;
  GhosttyApp &operator=(const GhosttyApp &) = delete;

  // Frame-timer body: ticks libghostty once and renders every dirty
  // surface across every window. Process-wide so N windows don't
  // produce N ticks per 16ms for the same shared app.
  void frame();

  ghostty_app_t m_app = nullptr;
  ghostty_config_t m_config = nullptr;
  bool m_needsPremultiply = false;

  // Live MainWindow list. Order is registration order; MainWindow
  // relies on that for cascade-position fallback (see newWindow), the
  // GOTO_WINDOW cycle, and the "most recent regular window" lookup
  // in undoLastClose. Migrated wholesale from MainWindow::s_windows.
  QList<MainWindow *> m_windows;

  // The dropdown quick terminal, if any. Non-owning.
  MainWindow *m_quickTerminal = nullptr;

  // Process-wide 60Hz frame timer (parented to qApp). Replaces a
  // per-window timer so N windows don't fire N ticks at the same
  // shared ghostty_app_t.
  QTimer *m_frameTimer = nullptr;

  // Delayed quit-after-last-window-closed timer (parented to qApp).
  // m_quitDelayMs is the configured delay in milliseconds; 0 disables.
  QTimer *m_quitTimer = nullptr;
  int m_quitDelayMs = 0;

  // Coalesces wakeup-driven ticks: at most one tick is queued at a
  // time so a busy surface can't flood the event loop.
  std::atomic<bool> m_tickPending{false};
};
