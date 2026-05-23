#include "UndoStack.h"

#include <QApplication>
#include <QList>
#include <QPointer>
#include <QTimer>

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"

namespace undo {

namespace {

// Bounded undo / redo stacks (tail = most recent). A push past the cap
// drops the oldest entry. The redo stack is cleared by every fresh
// close — a new "future" no longer matches what redo would re-close.
constexpr int kCap = 16;

QList<Entry> &undoStack() {
  static QList<Entry> s;
  return s;
}

QList<Entry> &redoStack() {
  static QList<Entry> s;
  return s;
}

// True while undo::redoLast is replaying. push* is gated on this so a
// redo that re-closes doesn't:
//   (a) clear the redo stack (the rest of the redo chain stays
//       playable), and
//   (b) push a fresh undo entry (otherwise the user can ping-pong
//       undo/redo on a single past close indefinitely).
bool g_redoInProgress = false;

// Pick the active window for an undo target. Skips the quick terminal
// (it doesn't push undo entries, so re-opening into it isn't
// meaningful). Falls back to the most recent registered regular
// window. Returns nullptr if no regular window exists.
MainWindow *activeUndoTarget() {
  auto isUndoTarget = [](MainWindow *w) {
    return w && !w->isQuickTerminal();
  };
  MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
  if (isUndoTarget(active)) return active;
  const QList<MainWindow *> &live = GhosttyApp::instance().windows();
  for (int i = live.size() - 1; i >= 0; --i) {
    if (isUndoTarget(live.at(i))) return live.at(i);
  }
  return nullptr;
}

// Pick the window the user is currently looking at for a redo. Unlike
// undo, redo doesn't filter the quick terminal — REDO without an
// active regular window leaves the entry in place (caller restores).
MainWindow *activeRedoTarget() {
  MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
  if (active) return active;
  const QList<MainWindow *> &live = GhosttyApp::instance().windows();
  return live.isEmpty() ? nullptr : live.last();
}

void pushUndo(Entry e) {
  QList<Entry> &s = undoStack();
  s.append(std::move(e));
  if (s.size() > kCap) s.removeFirst();
  // A fresh close invalidates any pending redo: the future the redo
  // stack would replay no longer matches the world.
  redoStack().clear();
}

}  // namespace

void pushTab(const QString &tabText) {
  if (g_redoInProgress) return;
  Entry e;
  e.kind = Entry::Kind::Tab;
  e.pageTitles << tabText;
  pushUndo(std::move(e));
}

void pushWindow(const QStringList &tabTitles, const QRect &geometry,
                bool quickTerminal) {
  if (g_redoInProgress) return;
  if (quickTerminal || tabTitles.isEmpty()) return;
  Entry e;
  e.kind = Entry::Kind::Window;
  e.pageTitles = tabTitles;
  e.geometry = geometry;
  pushUndo(std::move(e));
}

void undoLast() {
  QList<Entry> &s = undoStack();
  if (s.isEmpty()) return;
  const Entry e = s.takeLast();

  MainWindow *active = activeUndoTarget();
  GhosttySurface *parent = active ? active->currentSurface() : nullptr;

  if (e.kind == Entry::Kind::Tab) {
    if (!active) return;  // dropping the entry: no target to revive into
    GhosttySurface *fresh =
        active->newTab(parent ? parent->surface() : nullptr);
    if (fresh && !e.pageTitles.isEmpty())
      active->setTabTitleOverride(fresh, e.pageTitles.first());
  } else {
    // Window: spawn a fresh window, then queue extra tabs to match
    // the saved tab count. We don't try to recreate the split tree
    // — that would need a real session save mechanism.
    MainWindow *w =
        MainWindow::newWindow(parent ? parent->surface() : nullptr);
    if (!w) return;
    if (e.geometry.isValid()) w->setGeometry(e.geometry);
    if (!e.pageTitles.isEmpty()) {
      const QString first = e.pageTitles.first();
      QPointer<MainWindow> wp(w);
      QTimer::singleShot(0, w, [wp, first]() {
        if (!wp) return;
        if (auto *fresh = wp->surfaceAt(0))
          wp->setTabTitleOverride(fresh, first);
      });
    }
    for (int i = 1; i < e.pageTitles.size(); ++i) {
      const QString t = e.pageTitles.at(i);
      QPointer<MainWindow> wp(w);
      QTimer::singleShot(0, w, [wp, t]() {
        if (!wp) return;
        GhosttySurface *first = wp->surfaceAt(0);
        GhosttySurface *fresh =
            wp->newTab(first ? first->surface() : nullptr);
        if (fresh) wp->setTabTitleOverride(fresh, t);
      });
    }
  }

  QList<Entry> &r = redoStack();
  r.append(e);
  if (r.size() > kCap) r.removeFirst();
}

void redoLast() {
  QList<Entry> &r = redoStack();
  if (r.isEmpty()) return;
  Entry e = r.takeLast();

  MainWindow *active = activeRedoTarget();
  if (!active) {
    // No window to act on — restore the entry so the user can retry.
    r.append(std::move(e));
    return;
  }

  g_redoInProgress = true;
  if (e.kind == Entry::Kind::Tab) {
    active->closeCurrentTabForRedo();
  } else {
    active->closeForRedo();
  }
  g_redoInProgress = false;
}

}  // namespace undo
