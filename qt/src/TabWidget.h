#pragma once

#include <QMetaType>
#include <QPoint>
#include <QString>
#include <QTabBar>
#include <QTabWidget>

class QDragEnterEvent;
class QDropEvent;
class QMouseEvent;

// MIME type marking a Ghastty tab tear-off drag. Recognised by tab bars
// (to cancel the tear-off) and by terminal surfaces (to accept the drag
// so no "forbidden" cursor is shown over a Ghastty window).
inline constexpr char kGhosttyTabMime[] = "application/x-ghastty-tab";

// Per-tab data stored in QTabBar::tabData. `base` is the terminal-set
// title (libghostty SET_TITLE); `override` is a manual user-set title
// (libghostty SET_TAB_TITLE). updateTabText shows override when set,
// otherwise base.
struct TabData {
  QString base;
  QString override_;  // `override` is a reserved C++ identifier
};
Q_DECLARE_METATYPE(TabData)

// A QTabBar that tears a tab off into its own window when it is dragged
// clear of the bar. QTabBar's built-in movable behaviour still handles
// reordering within the bar; once the pointer leaves the bar a QDrag
// takes over so a snapshot of the tab follows the cursor.
class TabBar : public QTabBar {
  Q_OBJECT

public:
  explicit TabBar(QWidget *parent = nullptr);
  ~TabBar() override;

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

  // Cap a tab's width so a single long terminal title can't take the
  // entire bar. Matches the GTK frontend's Adw.TabBar (which clamps
  // width and ellipsizes) and the macOS Cocoa tabs (which use
  // lineBreakMode = byTruncatingTail). Without this, Qt's default is
  // "size to fit full text," and a long working-directory title
  // pushes every other tab off-screen.
  QSize tabSizeHint(int index) const override;

private:
  void startTearOff(QMouseEvent *e);

  int m_pressIndex = -1;   // tab under the press, or -1
  QPoint m_pressPos;       // press point, for the drag hot spot
  bool m_tearing = false;  // a tear-off QDrag is in progress
  bool m_dropHandled = false;  // a TabBar dropEvent caught our tear-off
};

// A QTabWidget wired to the tear-off-aware TabBar.
class TabWidget : public QTabWidget {
  Q_OBJECT

public:
  explicit TabWidget(QWidget *parent = nullptr);

signals:
  void tabTornOff(int index);
};
