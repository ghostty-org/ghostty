#pragma once

#include <atomic>

#include <QList>
#include <QSize>
#include <QWidget>

#include "ghostty.h"

class QAudioOutput;
class QCloseEvent;
class QMediaPlayer;
class QShowEvent;
class QSplitter;
class TabWidget;
class QPropertyAnimation;
class QTimer;
class CommandPalette;
class GhosttySurface;

// A top-level window presenting terminal surfaces as tabs; each tab may
// be subdivided into splits. The libghostty app and config are shared
// process-wide across every window (the static s_* members below).
//
// Widget tree: QTabWidget -> tab page (QWidget) -> split tree, where a
// node is either a GhosttySurface (a QOpenGLWidget) or a QSplitter of
// two such nodes.
class MainWindow : public QWidget {
  Q_OBJECT

public:
  MainWindow();
  ~MainWindow() override;

  // Per-window setup. The first call also creates the shared libghostty
  // app and config; later windows reuse them. Call once before show().
  bool initialize();

  // Open a new top-level window, sharing the libghostty app, with one
  // tab whose surface inherits from `parent` (may be null).
  static MainWindow *newWindow(ghostty_surface_t parent);

  // Show or hide every window at once (TOGGLE_VISIBILITY).
  static void toggleVisibility();

  // Show/hide the dropdown quick terminal, creating it on first use
  // (TOGGLE_QUICK_TERMINAL). There is at most one per process.
  static void toggleQuickTerminal();

  // Quick-terminal slide/fade animation per quick-terminal-animation-
  // duration. Implemented as a windowOpacity fade because Qt's layer-
  // shell doesn't expose a usable position-based slide API.
  void animateQuickTerminalIn();
  void animateQuickTerminalOut();

  // Open a new tab. `parent` (may be null) is the surface whose working
  // directory etc. the new surface should inherit.
  GhosttySurface *newTab(ghostty_surface_t parent);

  // Split `target`'s pane in two, adding a new surface beside it.
  GhosttySurface *splitSurface(GhosttySurface *target,
                               ghostty_action_split_direction_e dir);

  // Remove a single surface: collapses its split, or closes the tab if
  // it was the tab's only surface (and the window if it was the last).
  void removeSurface(GhosttySurface *surface);

  // Update the tab label and window title for `surface`.
  void setSurfaceTitle(GhosttySurface *surface, const QString &title);

  // The live libghostty config (for keybind lookups, etc.).
  ghostty_config_t config() const { return s_config; }

  // Whether a custom shader is configured. With one, libghostty's final
  // framebuffer is non-premultiplied and surfaces must premultiply it
  // before Qt composites (see GhosttySurface::premultiplyFramebuffer).
  bool needsPremultiply() const { return s_needsPremultiply; }

  // Whether `focus-follows-mouse` is enabled — a GhosttySurface grabs
  // focus when the pointer enters it.
  bool focusFollowsMouse() const;

protected:
  bool event(QEvent *) override;
  void showEvent(QShowEvent *) override;
  // Honors `confirm-close-surface`: prompts if a surface has a running
  // process, and ignores the event if the user declines.
  void closeEvent(QCloseEvent *) override;
  // Drives quick-terminal autohide on loss of activation.
  void changeEvent(QEvent *) override;

private slots:
  void onTabCloseRequested(int index);
  void onCurrentChanged(int index);

private:
  // Create the first tab once the device pixel ratio has settled.
  void createFirstTab();

  // 60fps frame timer body. Static because there is only one timer
  // per process — N windows pointing at the same shared ghostty_app_t.
  // Ticks libghostty once and renders any dirty surface across every
  // window.
  static void frame();

  void closeTab(int index);
  // Honor close-tab-mode (THIS / OTHER / RIGHT) from libghostty.
  void closeTabsByMode(GhosttySurface *src,
                       ghostty_action_close_tab_mode_e mode);
  // Right-click context menu over a tab (Close / Close Others /
  // Close Tabs to the Right / Rename), wired from
  // TabWidget::tabContextMenuRequested.
  void showTabContextMenu(int index, const QPoint &globalPos);
  // Tear tab `index` out into a new window (tabTornOff signal).
  void detachTab(int index);
  // Move `page` (a tab and its surfaces) from `src` into this window.
  void adoptTab(MainWindow *src, QWidget *page);
  GhosttySurface *surfaceAt(int index) const;
  int tabIndexForSurface(GhosttySurface *surface) const;
  QList<GhosttySurface *> surfacesInTab(int index) const;

  // Keybind-driven navigation between tabs and split panes.
  void gotoTab(ghostty_action_goto_tab_e tab);
  void gotoSplit(GhosttySurface *from, ghostty_action_goto_split_e dir);
  void resizeSplit(GhosttySurface *from, ghostty_action_resize_split_s rs);
  void equalizeSplits(GhosttySurface *from);
  void moveTab(int amount);  // reorder the current tab by `amount`

  // Ring the terminal bell, honoring the `bell-features` config.
  void ringBell(GhosttySurface *surface);
  void playBellAudio();

  // Bell `title` feature: prefix a tab's title while any surface in it
  // has an unacknowledged bell.
  bool tabBellMarked(int tab) const;

  // Recompute a tab's displayed text from its stored base (terminal)
  // title and manual override, plus any bell mark. Tab data holds a
  // {base, override} QStringList.
  void updateTabText(int tab);
  // Set/clear a tab's manual title override (empty string clears it);
  // while set, SET_TITLE no longer changes the tab text.
  void setTabTitleOverride(GhosttySurface *surface, const QString &title);
  // Copy the current tab's effective title to the clipboard.
  void copyTitleToClipboard(GhosttySurface *src);

  // Rebuild the config from disk and push it to libghostty.
  void reloadConfig();
  // App-scoped reload entry point. The config is process-wide (statics
  // in this class), so reload from any window has the same effect; the
  // RELOAD_CONFIG action posts to qApp via this static so the reload
  // can't be cancelled by the source window closing mid-dispatch.
  static void reloadConfigGlobal();
  // Refresh every window's chrome from the current config (used after a
  // reload and on the CONFIG_CHANGE notification).
  static void refreshChrome();

  // Typed wrappers over ghostty_config_get. configString also serves
  // enum keys — libghostty returns an enum as its tag name string.
  QString configString(const char *key) const;
  bool configBool(const char *key, bool fallback) const;

  // Apply config-driven window settings that may change on reload: the
  // tab-bar visibility policy and the light/dark colour scheme.
  void applyWindowConfig();

  // Apply the `background-blur` config to this window via the KWin
  // compositor (see WindowBlur).
  void applyBlur();

  // Turn this window into a layer-shell dropdown anchored to a screen
  // edge, per the `quick-terminal-*` config. Quick-terminal only.
  void setupLayerShell();

  // Show/hide the command palette (TOGGLE_COMMAND_PALETTE), scoped to
  // `surface` for executing the chosen command.
  void toggleCommandPalette(GhosttySurface *surface);

  // Prompt (per `confirm-close-surface`) before closing `surfaces`.
  // Returns true if the close may proceed.
  bool confirmCloseSurfaces(const QList<GhosttySurface *> &surfaces);

  // Close every window, optionally quitting the process; prompts once
  // via ghostty_app_needs_confirm_quit.
  static void closeAllWindows();

  // Wire the libghostty quit_timer action to a delayed QApplication
  // quit, gated on `quit-after-last-window-closed`.
  static void handleQuitTimer(bool start);

  // Toggle a split pane filling its tab. Re-parents the surface out of
  // / back into the splitter tree.
  void toggleSplitZoom(GhosttySurface *surface);

  // Runtime callbacks dispatched by libghostty. wakeup/action are
  // app-level (routed via the target surface or s_windows); clipboard/
  // close carry the surface userdata.
  static void onWakeup(void *ud);
  static bool onAction(ghostty_app_t, ghostty_target_s, ghostty_action_s);
  static bool onReadClipboard(void *ud, ghostty_clipboard_e, void *state);
  static void onConfirmReadClipboard(void *ud, const char *, void *state,
                                     ghostty_clipboard_request_e);
  static void onWriteClipboard(void *ud, ghostty_clipboard_e,
                               const ghostty_clipboard_content_s *, size_t,
                               bool);
  static void onCloseSurface(void *ud, bool process_active);

  // True if `s` is still owned by some live MainWindow. The surface
  // userdata callbacks above use this to validate a libghostty-supplied
  // pointer before dereferencing — a worker-thread callback can race
  // the GhosttySurface destructor.
  static bool surfaceAlive(GhosttySurface *s);

  TabWidget *m_tabs = nullptr;
  QList<GhosttySurface *> m_surfaces;  // every live surface in this window
  bool m_firstTabPending = true;       // first tab is created on show()
  ghostty_surface_t m_firstTabParent = nullptr;  // inherited by the 1st tab
  bool m_skipCloseConfirm = false;     // close already confirmed elsewhere
  bool m_quickTerminal = false;        // this is the dropdown quick terminal
  // Per-window opacity animation for the quick terminal (fade in/out
  // using quick-terminal-animation-duration). Lazily created.
  QPropertyAnimation *m_quickTerminalAnim = nullptr;
  QSize m_defaultWindowSize;           // for RESET_WINDOW_SIZE; from INITIAL_SIZE

  // Process-shared libghostty state: one app and config drive every
  // window. Created by the first initialize(), freed with the last
  // window. s_windows tracks every live window.
  static ghostty_app_t s_app;
  static ghostty_config_t s_config;
  static bool s_needsPremultiply;      // a custom shader is configured
  static QList<MainWindow *> s_windows;
  static QTimer *s_quitTimer;          // delayed quit-after-last-window
  static int s_quitDelayMs;            // 0 = no delay configured
  static MainWindow *s_quickTerminal;  // the one quick terminal, if any
  // Process-wide 60Hz frame timer. Replaces a per-window timer, so N
  // windows do not produce N ghostty_app_tick calls every 16ms for the
  // same shared app.
  static QTimer *s_frameTimer;

  // Coalesces wakeup-driven ticks: a tick is queued at most once at a
  // time, so a busy surface can't flood the event loop.
  static std::atomic<bool> s_tickPending;

  // Split-zoom state: the surface temporarily filling its tab, the
  // splitter it came from, its index there, and the stashed tree root.
  GhosttySurface *m_zoomed = nullptr;
  QWidget *m_zoomRoot = nullptr;
  QSplitter *m_zoomSplitter = nullptr;
  int m_zoomIndex = 0;

  // Bell audio playback; created lazily on the first audio bell.
  QMediaPlayer *m_bellPlayer = nullptr;
  QAudioOutput *m_bellAudio = nullptr;

  // The command palette; created lazily on first use.
  CommandPalette *m_commandPalette = nullptr;
};
