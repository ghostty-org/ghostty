#pragma once

#include <QHash>
#include <QWidget>

#include "ghostty.h"

class QTabWidget;
class GhosttySurface;

// The top-level window. Owns the shared ghostty_app_t and presents one
// or more terminal surfaces as tabs.
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

  // Remove the tab hosting `surface`; closes the window if it was last.
  void removeSurface(GhosttySurface *surface);

  // Update the tab label and window title for `surface`.
  void setSurfaceTitle(GhosttySurface *surface, const QString &title);

public slots:
  void tick();

private slots:
  void onTabCloseRequested(int index);
  void onCurrentChanged(int index);

private:
  GhosttySurface *surfaceAt(int index) const;
  int indexOfSurface(GhosttySurface *surface) const;

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

  // Each surface mapped to the container widget that hosts it in a tab.
  QHash<GhosttySurface *, QWidget *> m_containers;
};
