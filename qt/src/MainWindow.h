#pragma once

#include <atomic>

#include <QList>
#include <QRect>
#include <QSize>
#include <QStringList>
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

  // UNDO / REDO close-tab/window. The libghostty actions carry no
  // payload — the apprt is responsible for tracking what was closed
  // and reviving it. macOS uses NSUndoManager; we keep a small bounded
  // stack of "snapshots" per kind. Surfaces themselves can't be
  // revived (the child PTY is gone) — undo opens a fresh tab/window
  // and reapplies the saved title; the new surface inherits cwd from
  // the active surface (matching macOS, which also spawns a fresh
  // shell rather than re-attaching).
  static void undoLastClose();
  static void redoLastClose();

  // PRESENT_TERMINAL: bring this window to front and focus the surface.
  void presentTerminal(GhosttySurface *surface);
  // GOTO_WINDOW: cycle to the previous/next window in registration order.
  static void gotoWindow(MainWindow *from,
                         ghostty_action_goto_window_e dir);
  // FLOAT_WINDOW / TOGGLE_WINDOW_DECORATIONS / TOGGLE_BACKGROUND_OPACITY:
  // simple per-window toggles with the requested mode.
  void setFloating(ghostty_action_float_window_e mode);
  void toggleWindowDecorations();
  void toggleBackgroundOpacity();
  // SIZE_LIMIT: clamp the window's resizable range to libghostty's
  // computed cell-based limits. CELL_SIZE: store the cell size for
  // future grid-snap resizing (no-op until a resize-snap feature lands).
  void setSizeLimits(uint32_t minW, uint32_t minH, uint32_t maxW,
                     uint32_t maxH);
  void setCellSize(uint32_t w, uint32_t h);

  // Whether a custom shader is configured. With one, libghostty's final
  // framebuffer is non-premultiplied and surfaces must premultiply it
  // before Qt composites (see GhosttySurface::premultiplyFramebuffer).
  bool needsPremultiply() const { return s_needsPremultiply; }

  // Whether `focus-follows-mouse` is enabled — a GhosttySurface grabs
  // focus when the pointer enters it.
  bool focusFollowsMouse() const;

  // Live surface list owned by this window. Read by GhosttyApp::frame
  // to walk every surface for renderIfDirty without exposing the
  // private m_surfaces member.
  const QList<GhosttySurface *> &surfaces() const { return m_surfaces; }

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
  // GhosttyApp registers our static runtime callbacks (onWakeup,
  // onAction, ...) with libghostty. Phase 1.0 only — phase 1.1
  // moves the callbacks onto GhosttyApp itself and drops this.
  friend class GhosttyApp;

  // Create the first tab once the device pixel ratio has settled.
  void createFirstTab();

  // The frame-timer body lives on GhosttyApp::frame (process-wide).

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

  // Close every window, optionally quitting the process. Prompts once
  // via ghostty_app_needs_confirm_quit. `thenQuit=true` is the QUIT
  // action's behavior (close everything and end the process);
  // `thenQuit=false` is CLOSE_ALL_WINDOWS, which leaves the process
  // alive when `quit-after-last-window-closed=false` is set —
  // matching macOS where close-all and quit are distinct.
  static void closeAllWindows(bool thenQuit);

  // The quit-after-last-window-closed timer lives on
  // GhosttyApp::handleQuitTimer.

  // Toggle a split pane filling its tab. Re-parents the surface out of
  // / back into the splitter tree.
  void toggleSplitZoom(GhosttySurface *surface);

  // Runtime callbacks dispatched by libghostty. action is app-level
  // (routed via the target surface or the GhosttyApp window
  // registry); clipboard/close carry the surface userdata. wakeup
  // moved to GhosttyApp::onWakeup in phase 1.2.
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
  // Last cell size reported by libghostty for this window's surfaces
  // (CELL_SIZE action). Stored so future grid-snap resizing can use
  // it; not used yet beyond bookkeeping.
  QSize m_cellSize;
  // Floating-window state: set when the user toggles via FLOAT_WINDOW.
  // Tracked separately from windowFlags() because Qt's
  // WindowStaysOnTopHint pokes other state on Wayland.
  bool m_floating = false;
  // Tracks whether window decorations are currently suppressed via
  // TOGGLE_WINDOW_DECORATIONS (separate from the config-driven init).
  bool m_decorationsHidden = false;
  // Tracks whether background-opacity is currently bypassed via
  // TOGGLE_BACKGROUND_OPACITY (forces the window opaque regardless
  // of `background-opacity`).
  bool m_opacityForcedOpaque = false;

  // Process-shared libghostty state: one app and config drive every
  // window. Created by the first initialize(), freed with the last
  // window. The live window list lives on GhosttyApp; the s_app /
  // s_config / s_needsPremultiply statics here are mirror caches kept
  // in sync with GhosttyApp::instance() to limit phase-1 callsite
  // churn — they retire as call sites move to the singleton.
  static ghostty_app_t s_app;
  static ghostty_config_t s_config;
  static bool s_needsPremultiply;      // a custom shader is configured
  // Mirror of GhosttyApp::quitDelayMs; phase 1.3 retires it when the
  // remaining call site (closeAllWindows) moves to the singleton.
  static int s_quitDelayMs;            // 0 = no delay configured
  static MainWindow *s_quickTerminal;  // the one quick terminal, if any

  // Snapshot of a closed tab or window for undo/redo. `pageTitles`
  // holds each tab's last-known title (window snapshots have N tabs;
  // tab snapshots have one). `geometry` is unused for tab snapshots.
  // `kind` distinguishes the two so REDO can reclose the right thing.
  struct UndoEntry {
    enum class Kind { Tab, Window } kind = Kind::Tab;
    QStringList pageTitles;
    QRect geometry;
  };
  // Bounded undo/redo stacks (tail = most recent). Each tab/window
  // close pushes an entry, capped at kUndoCap; opening a new
  // tab/window via undo pushes onto the redo stack. While
  // `s_redoInProgress` is true, the close paths that normally
  // mutate these stacks (pushTabUndo / pushWindowUndo) become
  // no-ops — a redo is replaying a previous close and shouldn't
  // also feed itself a fresh undo entry that the user will then
  // unwind into a loop.
  static QList<UndoEntry> s_undoStack;
  static QList<UndoEntry> s_redoStack;
  static bool s_redoInProgress;
  static constexpr int kUndoCap = 16;
  // Push a snapshot for the tab at `index` onto s_undoStack and
  // clear the redo stack (a new close invalidates a forward redo).
  void pushTabUndo(int index);
  // Push a snapshot of every tab in this window onto s_undoStack as a
  // single Window entry; called from closeAllWindows / closeEvent.
  void pushWindowUndo();

  // Wakeup tick coalescing lives on GhosttyApp::m_tickPending.

  // Split-zoom state: the surface temporarily filling its tab, the
  // splitter it came from, its index there, and the stashed tree root.
  GhosttySurface *m_zoomed = nullptr;
  QWidget *m_zoomRoot = nullptr;
  QSplitter *m_zoomSplitter = nullptr;
  int m_zoomIndex = 0;

  // Bell audio playback; created lazily on the first audio bell.
  // The bell-audio-path / -volume values are cached at window setup
  // and refreshed on reload so the bell hot path doesn't re-scan
  // the on-disk config file.
  QMediaPlayer *m_bellPlayer = nullptr;
  QAudioOutput *m_bellAudio = nullptr;
  QString m_bellAudioPath;       // expanded; empty if no clip configured
  double m_bellAudioVolume = 0.5;

  // The command palette; created lazily on first use.
  CommandPalette *m_commandPalette = nullptr;
};
