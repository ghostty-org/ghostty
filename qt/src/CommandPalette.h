#pragma once

#include <QPointer>
#include <QWidget>

class GhosttySurface;
class QLineEdit;
class QListView;
class QSortFilterProxyModel;
class QStandardItemModel;
class QTimer;

// A searchable command palette (the TOGGLE_COMMAND_PALETTE action).
//
// It lists the commands from the `command-palette-entry` config (a
// large built-in default set plus any user additions) and runs the
// chosen command's keybind action on the active surface. Shown as a
// Qt::Popup over its owner — Qt anchors it to the parent window (so it
// places correctly on Wayland) and dismisses it on an outside click.
class CommandPalette : public QWidget {
  Q_OBJECT

public:
  explicit CommandPalette(QWidget *owner);

  // Show the palette for `surface` (populating from the live config),
  // or hide it if already visible.
  void toggleFor(GhosttySurface *surface);

protected:
  bool eventFilter(QObject *obj, QEvent *event) override;

private:
  void populate();       // (re)load the command list from config
  void runSelected();    // execute the highlighted command
  void moveSelection(int delta);
  void selectFirstRow();

  // Owner window the palette centres over. QPointer so a window
  // closed while the palette is hidden doesn't leave us with a
  // dangling raw pointer (toggleFor dereferences it for placement).
  QPointer<QWidget> m_owner;
  QLineEdit *m_search = nullptr;
  QListView *m_list = nullptr;
  QStandardItemModel *m_model = nullptr;
  QSortFilterProxyModel *m_filter = nullptr;
  QTimer *m_filterDebounce = nullptr;  // coalesces rapid keystrokes
  QPointer<GhosttySurface> m_surface;  // active surface; may go away
};
