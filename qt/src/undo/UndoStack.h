#pragma once

#include <QList>
#include <QRect>
#include <QString>
#include <QStringList>

class MainWindow;

// Process-wide undo / redo of closed tabs and windows.
//
// libghostty's UNDO / REDO actions carry no payload — the apprt
// remembers what was closed and revives it. Surfaces themselves can't
// be revived (the child PTY is gone), so undo opens a fresh tab/window
// and reapplies the saved title; the new surface inherits cwd from
// the active surface, matching macOS (which also spawns a fresh
// shell rather than re-attaching).
//
// State lives in this file's anonymous namespace; callers see only
// the four push / replay functions. push* are no-ops while a redo is
// replaying so the redo path doesn't feed itself.
namespace undo {

// Snapshot of one closed tab or window. Window snapshots carry every
// tab's last-known title and the window's geometry; tab snapshots
// carry one title and an unused geometry.
struct Entry {
  enum class Kind { Tab, Window } kind = Kind::Tab;
  QStringList pageTitles;
  QRect geometry;
};

// Snapshot a closed tab — its last-known display text — onto the
// undo stack. Callers MUST exclude quick-terminal and last-tab
// closes (the latter routes through pushWindow via closeEvent).
void pushTab(const QString &tabText);

// Snapshot every tab's title plus the window's geometry as a single
// Window entry. Excluded for the quick terminal and for empty
// windows.
void pushWindow(const QStringList &tabTitles, const QRect &geometry,
                bool quickTerminal);

// Pop the most recent entry and revive it: open a fresh tab or
// window, set the saved title(s) as a manual override, and push the
// entry onto the redo stack. No-op if the stack is empty.
void undoLast();

// Pop the most recent redo entry and re-close the active window's
// current tab (Tab entries) or the active window itself (Window
// entries). No-op if the stack is empty or no active window exists.
void redoLast();

}  // namespace undo
