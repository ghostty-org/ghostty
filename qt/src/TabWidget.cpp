#include "TabWidget.h"

#include <cstring>

#include <QByteArray>
#include <QDataStream>
#include <QDrag>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QPixmap>
#include <QPointer>
#include <QRect>

namespace {
// MIME role carrying a pointer-to-originating-TabBar so a receiving
// bar's dropEvent can mark the originator's m_dropHandled. We can't
// rely on QDrag::exec()'s return value on Wayland, and a process-wide
// "drop handled" flag races with simultaneous tear-offs in different
// windows.
constexpr char kTearOffOriginRole[] = "application/x-ghastty-tab-origin";

QByteArray encodeOrigin(TabBar *bar) {
  // Pack the raw pointer; the source process owns it for the lifetime
  // of the drag. We never dereference unless we're in the same process,
  // and a tear-off across processes is meaningless.
  QByteArray bytes(reinterpret_cast<const char *>(&bar), sizeof(bar));
  return bytes;
}

TabBar *decodeOrigin(const QByteArray &bytes) {
  if (bytes.size() != sizeof(TabBar *)) return nullptr;
  TabBar *bar;
  std::memcpy(&bar, bytes.constData(), sizeof(bar));
  return bar;
}
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
  // Tag the drag with a pointer to this bar so the receiving bar's
  // dropEvent can mark *our* m_dropHandled — a process-global flag
  // would race with simultaneous tear-offs in other windows.
  mime->setData(QString::fromLatin1(kTearOffOriginRole), encodeOrigin(this));
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
  // window. m_dropHandled — set by a TabBar::dropEvent on the
  // originating bar — is the signal, since QDrag::exec()'s result is
  // unreliable across surfaces on Wayland.
  m_dropHandled = false;
  drag->exec(Qt::MoveAction);

  m_tearing = false;
  m_pressIndex = -1;
  if (!m_dropHandled) emit tabTornOff(index);
}

void TabBar::dragEnterEvent(QDragEnterEvent *e) {
  if (e->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime)))
    e->acceptProposedAction();
}

void TabBar::dropEvent(QDropEvent *e) {
  // Dropping a tear-off back on a tab bar cancels it. Mark the flag on
  // the *originating* bar (carried in the MIME payload), not this one
  // — a tear-off can be dropped onto a different window's bar.
  if (e->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime))) {
    if (TabBar *origin = decodeOrigin(
            e->mimeData()->data(QString::fromLatin1(kTearOffOriginRole))))
      origin->m_dropHandled = true;
    else
      m_dropHandled = true;  // fallback: mark ourselves
    e->acceptProposedAction();
  }
}

TabWidget::TabWidget(QWidget *parent) : QTabWidget(parent) {
  auto *bar = new TabBar(this);
  bar->setAcceptDrops(true);  // so a tear-off can be dropped back on it
  setTabBar(bar);  // protected on QTabWidget; accessible to this subclass
  connect(bar, &TabBar::tabTornOff, this, &TabWidget::tabTornOff);
}
