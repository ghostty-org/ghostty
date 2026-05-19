#pragma once

#include <QFrame>

class GhosttySurface;
class QLabel;
class QLineEdit;
class QTimer;

// An in-terminal search bar overlaying a GhosttySurface.
//
// The query is fed to libghostty through keybind actions (`search:`,
// `navigate_search:`, `end_search`) — the same path the macOS frontend
// uses — and the match counter mirrors the SEARCH_TOTAL and
// SEARCH_SELECTED actions libghostty reports back. Match highlighting
// in the terminal is drawn by the shared core renderer.
//
// It is a themed QFrame: the panel, field and buttons all use the
// active Qt style/palette rather than hardcoded colours.
class SearchBar : public QFrame {
  Q_OBJECT

public:
  explicit SearchBar(GhosttySurface *surface);

  // Show the bar, focused, optionally pre-filled with a needle.
  void open(const QString &prefill);

  // Match counts reported by libghostty; -1 means none/unknown.
  void setTotal(int total);
  void setSelected(int selected);

protected:
  bool eventFilter(QObject *obj, QEvent *event) override;

private:
  void sendQuery();              // push the field text as `search:<text>`
  void navigate(bool next);      // `navigate_search:next` / `:previous`
  void runAction(const char *action);
  void updateCount();
  void positionCount();          // place the counter inside the field

  GhosttySurface *m_surface;     // not owned
  QLineEdit *m_field = nullptr;
  QLabel *m_count = nullptr;     // match counter, shown inside m_field
  QTimer *m_debounce = nullptr;  // coalesces keystrokes into one query
  int m_total = -1;
  int m_selected = -1;
};
