#include "TabWidget.h"

#include <cstring>

#include <QByteArray>
#include <QContextMenuEvent>
#include <QCoreApplication>
#include <QDataStream>
#include <QDrag>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>
#include <QMouseEvent>
#include <QPixmap>
#include <QPointer>
#include <QRect>
#include <QSet>

namespace {
// MIME role carrying a tagged origin record so a receiving bar's
// dropEvent can mark the originator's m_dropHandled. Can't rely on
// QDrag::exec()'s return value on Wayland, and a process-wide "drop
// handled" flag races simultaneous tear-offs in different windows.
constexpr char kTearOffOriginRole[] = "application/x-ghastty-tab-origin";

// Process-local set of live TabBars so decodeOrigin can validate the
// pointer before dereferencing it (cross-process Wayland delivery, or
// the originating bar dying during drag->exec, would otherwise UAF).
QSet<TabBar *> &liveTabBars() {
  static QSet<TabBar *> s;
  return s;
}

// Origin payload: the source PID followed by the originating TabBar*.
// The PID rejects cross-process delivery; the live-set check rejects
// same-process pointers whose target was destroyed mid-drag.
struct OriginPayload {
  qint64 pid;
  TabBar *bar;
};

QByteArray encodeOrigin(TabBar *bar) {
  OriginPayload p{QCoreApplication::applicationPid(), bar};
  QByteArray bytes(reinterpret_cast<const char *>(&p), sizeof(p));
  return bytes;
}

TabBar *decodeOrigin(const QByteArray &bytes) {
  if (bytes.size() != sizeof(OriginPayload)) return nullptr;
  OriginPayload p;
  std::memcpy(&p, bytes.constData(), sizeof(p));
  if (p.pid != QCoreApplication::applicationPid()) return nullptr;
  if (!liveTabBars().contains(p.bar)) return nullptr;
  return p.bar;
}
}  // namespace

TabBar::TabBar(QWidget *parent) : QTabBar(parent) {
  liveTabBars().insert(this);
  // Truncate long titles with an ellipsis instead of letting a single
  // tab consume the whole bar. Matches the upstream GTK frontend
  // (Adw.TabBar, which clamps + ellipsizes) and macOS (Cocoa tabs use
  // lineBreakMode = byTruncatingTail).
  setElideMode(Qt::ElideRight);
  // Tabs size to content (subject to the per-tab cap from tabSizeHint
  // below), leaving room on the bar rather than expanding to fill.
  setExpanding(false);
  // When tabs still don't fit (many tabs, all near the cap), Qt
  // shows left/right scroll arrows instead of shrinking each tab to
  // an unreadable sliver.
  setUsesScrollButtons(true);
}

TabBar::~TabBar() { liveTabBars().remove(this); }

QSize TabBar::tabSizeHint(int index) const {
  // Cap at ~28em — wide enough for a typical "shell — repo (branch)"
  // title, narrow enough that 5+ tabs fit on a 1280-px window without
  // triggering scroll arrows. Below the cap, fall back to Qt's
  // content-fit hint so short titles still get short tabs.
  const QSize base = QTabBar::tabSizeHint(index);
  const int cap = fontMetrics().averageCharWidth() * 28 +
                  // include the close-button width when the tab is
                  // closable, so the title clamp matches actual
                  // available text space.
                  (tabsClosable() ? 28 : 0);
  if (base.width() <= cap) return base;
  return QSize(cap, base.height());
}

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
  //
  // drag->exec spins a nested event loop. Anything queued onto this
  // bar's window — a libghostty close action, the user closing the
  // window mid-drag — can `delete this` while exec runs. Watch our own
  // lifetime via QPointer and bail out before any post-exec member
  // access if we've been deleted.
  m_dropHandled = false;
  QPointer<TabBar> self(this);
  drag->exec(Qt::MoveAction);
  if (!self) return;

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

void TabBar::contextMenuEvent(QContextMenuEvent *e) {
  // Find which tab the right-click landed on; if it missed every
  // tab, do nothing (no menu over empty bar area). globalPos() is
  // ready for QMenu::exec on the parent side.
  const int idx = tabAt(e->pos());
  if (idx < 0) return;
  emit tabContextMenuRequested(idx, e->globalPos());
  e->accept();
}

TabWidget::TabWidget(QWidget *parent) : QTabWidget(parent) {
  auto *bar = new TabBar(this);
  bar->setAcceptDrops(true);  // so a tear-off can be dropped back on it
  setTabBar(bar);  // protected on QTabWidget; accessible to this subclass
  connect(bar, &TabBar::tabTornOff, this, &TabWidget::tabTornOff);
  connect(bar, &TabBar::tabContextMenuRequested,
          this, &TabWidget::tabContextMenuRequested);
}
