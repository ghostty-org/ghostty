#pragma once

#include <atomic>

#include <QList>
#include <QWidget>

#include "ghostty.h"

class QAudioOutput;
class QMediaPlayer;
class QShowEvent;
class QSplitter;
class QTabWidget;
class GhosttySurface;

// The top-level window. Owns the shared ghostty_app_t and presents
// terminal surfaces as tabs; each tab may be subdivided into splits.
//
// Widget tree: QTabWidget -> tab page (QWidget) -> split tree, where a
// node is either a GhosttySurface (a QOpenGLWidget) or a QSplitter of
// two such nodes.
class MainWindow : public QWidget {
  Q_OBJECT

public:
  MainWindow();
  ~MainWindow() override;

  // Create the libghostty app and the first tab. Call once before show().
  bool initialize();

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
  ghostty_config_t config() const { return m_config; }

  // Whether a custom shader is configured. With one, libghostty's final
  // framebuffer is non-premultiplied and surfaces must premultiply it
  // before Qt composites (see GhosttySurface::premultiplyFramebuffer).
  bool needsPremultiply() const { return m_needsPremultiply; }

public slots:
  void tick();

protected:
  bool event(QEvent *) override;
  void showEvent(QShowEvent *) override;

private slots:
  void onTabCloseRequested(int index);
  void onCurrentChanged(int index);

private:
  // Create the first tab once the device pixel ratio has settled.
  void createFirstTab();

  // 60fps frame timer: ticks libghostty and renders any dirty surface.
  void frame();

  void closeTab(int index);
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
  void refreshTabTitle(int tab);

  // Config: rebuild from disk (reloadConfig) or apply one libghostty
  // handed us (applyConfig), pushing it to the app and every surface.
  void reloadConfig();
  void applyConfig(ghostty_config_t config);

  // Toggle a split pane filling its tab. Re-parents the surface out of
  // / back into the splitter tree.
  void toggleSplitZoom(GhosttySurface *surface);

  // Runtime callbacks dispatched by libghostty. wakeup/action carry the
  // app userdata; clipboard/close carry the surface userdata.
  static void onWakeup(void *ud);
  static bool onAction(ghostty_app_t, ghostty_target_s, ghostty_action_s);
  static bool onReadClipboard(void *ud, ghostty_clipboard_e, void *state);
  static void onConfirmReadClipboard(void *ud, const char *, void *state,
                                     ghostty_clipboard_request_e);
  static void onWriteClipboard(void *ud, ghostty_clipboard_e,
                               const ghostty_clipboard_content_s *, size_t,
                               bool);
  static void onCloseSurface(void *ud, bool process_active);

  ghostty_config_t m_config = nullptr;
  ghostty_app_t m_app = nullptr;
  QTabWidget *m_tabs = nullptr;
  QList<GhosttySurface *> m_surfaces;  // every live surface
  bool m_needsPremultiply = false;     // a custom shader is configured
  bool m_firstTabPending = true;       // first tab is created on show()

  // Coalesces wakeup-driven ticks: a tick is queued at most once at a
  // time, so a busy surface can't flood the event loop. Set from
  // onWakeup (possibly off-thread), cleared at the start of tick().
  std::atomic<bool> m_tickPending{false};

  // Split-zoom state: the surface temporarily filling its tab, the
  // splitter it came from, its index there, and the stashed tree root.
  GhosttySurface *m_zoomed = nullptr;
  QWidget *m_zoomRoot = nullptr;
  QSplitter *m_zoomSplitter = nullptr;
  int m_zoomIndex = 0;

  // Bell audio playback; created lazily on the first audio bell.
  QMediaPlayer *m_bellPlayer = nullptr;
  QAudioOutput *m_bellAudio = nullptr;
};
