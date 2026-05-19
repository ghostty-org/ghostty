#pragma once

#include <QPoint>
#include <QTabBar>
#include <QTabWidget>

class QDragEnterEvent;
class QDropEvent;
class QMouseEvent;

// MIME type marking a Ghostty tab tear-off drag. Recognised by tab bars
// (to cancel the tear-off) and by terminal surfaces (to accept the drag
// so no "forbidden" cursor is shown over a Ghostty window).
inline constexpr char kGhosttyTabMime[] = "application/x-ghostty-tab";

// A QTabBar that tears a tab off into its own window when it is dragged
// clear of the bar. QTabBar's built-in movable behaviour still handles
// reordering within the bar; once the pointer leaves the bar a QDrag
// takes over so a snapshot of the tab follows the cursor.
class TabBar : public QTabBar {
  Q_OBJECT

public:
  explicit TabBar(QWidget *parent = nullptr) : QTabBar(parent) {}

signals:
  // The tab was dragged off and released clear of its window.
  void tabTornOff(int index);

protected:
  void mousePressEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  // Accept a tear-off drag dropped back on a tab bar (cancels it).
  void dragEnterEvent(QDragEnterEvent *) override;
  void dropEvent(QDropEvent *) override;

private:
  void startTearOff(QMouseEvent *e);

  int m_pressIndex = -1;   // tab under the press, or -1
  QPoint m_pressPos;       // press point, for the drag hot spot
  bool m_tearing = false;  // a tear-off QDrag is in progress
};

// A QTabWidget wired to the tear-off-aware TabBar.
class TabWidget : public QTabWidget {
  Q_OBJECT

public:
  explicit TabWidget(QWidget *parent = nullptr);

signals:
  void tabTornOff(int index);
};
