#include "TabWidget.h"

#include <QDrag>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QPixmap>
#include <QRect>

namespace {
// Set by a TabBar::dropEvent during an in-flight tear-off. It is the
// reliable "released on a tab bar" signal: QDrag::exec()'s return value
// cannot be trusted across surfaces on Wayland.
bool g_tabDropHandled = false;
}  // namespace

void TabBar::mousePressEvent(QMouseEvent *e) {
  if (e->button() == Qt::LeftButton) {
    m_pressIndex = tabAt(e->position().toPoint());
    m_pressPos = e->position().toPoint();
  }
  QTabBar::mousePressEvent(e);
}

void TabBar::mouseMoveEvent(QMouseEvent *e) {
  // While the pointer is on the bar, QTabBar reorders normally. Once it
  // leaves the bar in any direction, hand off to a tear-off drag.
  const bool leftBar =
      m_pressIndex >= 0 && count() > 1 && !m_tearing &&
      !rect().adjusted(-20, -20, 20, 20).contains(e->position().toPoint());
  if (leftBar) {
    startTearOff(e);
    return;
  }
  QTabBar::mouseMoveEvent(e);
}

void TabBar::mouseReleaseEvent(QMouseEvent *e) {
  m_pressIndex = -1;
  QTabBar::mouseReleaseEvent(e);
}

void TabBar::startTearOff(QMouseEvent *e) {
  m_tearing = true;

  // End QTabBar's internal move-drag so the tab settles back into the
  // bar rather than staying "lifted".
  QMouseEvent release(QEvent::MouseButtonRelease, e->position(),
                      e->globalPosition(), Qt::LeftButton, Qt::NoButton,
                      e->modifiers());
  QTabBar::mouseReleaseEvent(&release);

  // The dragged tab is the current one; its index is stable now that any
  // in-bar reorder has settled.
  const int index = currentIndex();
  if (index < 0) {
    m_tearing = false;
    return;
  }

  // A snapshot of the tab follows the cursor for the duration of the drag.
  const QRect tabBox = tabRect(index);
  QDrag *drag = new QDrag(this);
  auto *mime = new QMimeData;
  mime->setData(QString::fromLatin1(kGhosttyTabMime), QByteArray());
  drag->setMimeData(mime);
  drag->setPixmap(grab(tabBox));
  drag->setHotSpot(m_pressPos - tabBox.topLeft());
  // A tear-off has no real drop target. A 1x1 transparent cursor
  // suppresses the "forbidden" cursor Qt would otherwise show over
  // non-accepting areas — releasing there is a valid outcome.
  QPixmap blank(1, 1);
  blank.fill(Qt::transparent);
  drag->setDragCursor(blank, Qt::IgnoreAction);
  drag->setDragCursor(blank, Qt::MoveAction);

  // Released on a tab bar cancels the tear-off; released anywhere else
  // (the terminal, another window, the desktop) tears it into a new
  // window. g_tabDropHandled — set by TabBar::dropEvent — is the
  // signal, since QDrag::exec()'s result is unreliable across surfaces
  // on Wayland.
  g_tabDropHandled = false;
  drag->exec(Qt::MoveAction);

  m_tearing = false;
  m_pressIndex = -1;
  if (!g_tabDropHandled) emit tabTornOff(index);
}

void TabBar::dragEnterEvent(QDragEnterEvent *e) {
  if (e->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime)))
    e->acceptProposedAction();
}

void TabBar::dropEvent(QDropEvent *e) {
  // Dropping a tear-off back on a tab bar cancels it.
  if (e->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime))) {
    g_tabDropHandled = true;
    e->acceptProposedAction();
  }
}

TabWidget::TabWidget(QWidget *parent) : QTabWidget(parent) {
  auto *bar = new TabBar(this);
  bar->setAcceptDrops(true);  // so a tear-off can be dropped back on it
  setTabBar(bar);  // protected on QTabWidget; accessible to this subclass
  connect(bar, &TabBar::tabTornOff, this, &TabWidget::tabTornOff);
}
