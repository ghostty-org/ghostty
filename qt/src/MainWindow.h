#pragma once

#include <QList>
#include <QSize>
#include <QWidget>

#include "ghostty.h"

class BellPlayer;
class QCloseEvent;
class QShowEvent;
class QSplitter;
class TabWidget;
class QTimer;
class CommandPalette;
class GhosttySurface;

// A top-level window presenting terminal surfaces as tabs; each tab may
// be subdivided into splits. The libghostty app and config are shared
// process-wide via GhosttyApp::instance(); MainWindow's config() and
// needsPremultiply() forward there.
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

  // Build the process's single quick-terminal MainWindow on demand:
  // a layer-shell dropdown anchored to a screen edge, faded in
  // immediately. Called from GhosttyApp::toggleQuickTerminal on first
  // use. Returns nullptr on init failure.
  static MainWindow *makeQuickTerminal();

  // Quick-terminal slide/fade animation per quick-terminal-animation-
  // duration. Implemented as a windowOpacity fade because Qt's layer-
  // shell doesn't expose a usable position-based slide API.
  void animateQuickTerminalIn();
  void animateQuickTerminalOut();
  bool isQuickTerminal() const { return m_quickTerminal; }

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

  // The live libghostty config (for keybind lookups, etc.). Forwards
  // to GhosttyApp::instance().config(); kept on MainWindow as a thin
  // shim so external callers (GhosttySurface, InspectorWindow) don't
  // need to take a dependency on app/GhosttyApp.h.
  ghostty_config_t config() const;

  // UNDO / REDO close-tab/window action handlers — thin wrappers that
  // drive undo::undoLast / undo::redoLast. The undo state lives in
  // qt/src/undo/UndoStack; the comment there explains the lifetime
  // and replay model.
  static void undoLastClose();
  static void redoLastClose();

  // Replay-side hooks used by undo::redoLast. closeCurrentTabForRedo
  // closes whichever tab is currently active (Tab redo); closeForRedo
  // closes the entire window (Window redo). Both bypass the
  // close-confirm prompt — the user already accepted the close once.
  void closeCurrentTabForRedo();
  void closeForRedo();

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
  // Forwards to GhosttyApp::instance().needsPremultiply().
  bool needsPremultiply() const;

  // Whether `focus-follows-mouse` is enabled — a GhosttySurface grabs
  // focus when the pointer enters it.
  bool focusFollowsMouse() const;

  // Live surface list owned by this window. Read by GhosttyApp::frame
  // to walk every surface for renderIfDirty without exposing the
  // private m_surfaces member.
  const QList<GhosttySurface *> &surfaces() const { return m_surfaces; }

  // Whether `s` is one of this window's surfaces. Used by
  // GhosttyApp::surfaceAlive to validate libghostty userdata pointers
  // against a destruction race on worker-thread callbacks.
  bool ownsSurface(GhosttySurface *s) const {
    return m_surfaces.contains(s);
  }

  // ---- libghostty-driven mutations -------------------------------
  //
  // Called from the per-domain handlers in qt/src/actions/ in
  // response to libghostty actions. They are not part of the
  // user-facing keybind/menu API; they need public visibility so
  // the dispatcher can route to them through the public surface
  // (no friend declarations).
  void closeTabsByMode(GhosttySurface *src,
                       ghostty_action_close_tab_mode_e mode);
  void gotoTab(ghostty_action_goto_tab_e tab);
  void gotoSplit(GhosttySurface *from, ghostty_action_goto_split_e dir);
  void resizeSplit(GhosttySurface *from, ghostty_action_resize_split_s rs);
  void equalizeSplits(GhosttySurface *from);
  void moveTab(int amount);
  void ringBell(GhosttySurface *surface);
  void setTabTitleOverride(GhosttySurface *surface, const QString &title);
  void copyTitleToClipboard(GhosttySurface *src);
  void toggleCommandPalette(GhosttySurface *surface);
  void toggleSplitZoom(GhosttySurface *surface);
  bool confirmCloseSurfaces(const QList<GhosttySurface *> &surfaces);

  // ---- libghostty-driven gating accessors ------------------------

  // Tab count, used by GOTO_TAB / MOVE_TAB performable checks.
  int tabCount() const;
  // First surface in the currently-visible tab, or nullptr. Used by
  // PROMPT_TITLE app-target promotion.
  GhosttySurface *currentSurface() const;
  // First surface in the tab at `index`, or nullptr. Used by
  // undo::undoLast to title-tag the revived tab/window.
  GhosttySurface *surfaceAt(int index) const;
  // Default size cached on INITIAL_SIZE for RESET_WINDOW_SIZE.
  QSize defaultWindowSize() const { return m_defaultWindowSize; }
  void setDefaultWindowSize(QSize s) { m_defaultWindowSize = s; }

  // App-scoped reload entry point and chrome refresh. Both are
  // called from actions::dispatch (RELOAD_CONFIG, CONFIG_CHANGE).
  static void reloadConfigGlobal();
  static void refreshChrome();

  // Close every window, optionally quitting the process. Prompts
  // once via ghostty_app_needs_confirm_quit. `thenQuit=true` is the
  // QUIT action's behavior; `thenQuit=false` is CLOSE_ALL_WINDOWS.
  static void closeAllWindows(bool thenQuit);

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

  void closeTab(int index);
  // Right-click context menu over a tab (Close / Close Others /
  // Close Tabs to the Right / Rename), wired from
  // TabWidget::tabContextMenuRequested.
  void showTabContextMenu(int index, const QPoint &globalPos);
  // Tear tab `index` out into a new window (tabTornOff signal).
  void detachTab(int index);
  // Move `page` (a tab and its surfaces) from `src` into this window.
  void adoptTab(MainWindow *src, QWidget *page);
  int tabIndexForSurface(GhosttySurface *surface) const;
  QList<GhosttySurface *> surfacesInTab(int index) const;

  // Bell `title` feature: prefix a tab's title while any surface in it
  // has an unacknowledged bell.
  bool tabBellMarked(int tab) const;

  // Recompute a tab's displayed text from its stored base (terminal)
  // title and manual override, plus any bell mark. Tab data holds a
  // {base, override} QStringList.
  void updateTabText(int tab);

  // Rebuild the config from disk and push it to libghostty.
  void reloadConfig();

  // Apply config-driven window settings that may change on reload: the
  // tab-bar visibility policy and the light/dark colour scheme.
  void applyWindowConfig();

  // Apply the `background-blur` config to this window via the KWin
  // compositor (see WindowBlur).
  void applyBlur();

  TabWidget *m_tabs = nullptr;
  QList<GhosttySurface *> m_surfaces;  // every live surface in this window
  bool m_firstTabPending = true;       // first tab is created on show()
  ghostty_surface_t m_firstTabParent = nullptr;  // inherited by the 1st tab
  bool m_skipCloseConfirm = false;     // close already confirmed elsewhere
  bool m_quickTerminal = false;        // this is the dropdown quick terminal
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

  // The libghostty app + config + derived state all live on
  // GhosttyApp::instance(). MainWindow's config() / needsPremultiply()
  // accessors forward to it.

  // The undo/redo stacks live in qt/src/undo/UndoStack — see comment
  // there for the lifecycle and replay semantics.

  // Wakeup tick coalescing lives on GhosttyApp::m_tickPending.

  // Split-zoom state: the surface temporarily filling its tab, the
  // splitter it came from, its index there, and the stashed tree root.
  GhosttySurface *m_zoomed = nullptr;
  QWidget *m_zoomRoot = nullptr;
  QSplitter *m_zoomSplitter = nullptr;
  int m_zoomIndex = 0;

  // Bell audio playback; lives in qt/src/bell/BellPlayer. Created
  // lazily on the first applyWindowConfig pass so refreshFromConfig
  // can prime its cached path/volume.
  BellPlayer *m_bellPlayer = nullptr;

  // The command palette; created lazily on first use.
  CommandPalette *m_commandPalette = nullptr;
};
