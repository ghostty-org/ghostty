#include "ActionDispatcher.h"

#include <QSplitter>
#include <QWidget>

#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

bool handleSplit(const Context &ctx, const ghostty_action_s &action) {
  GhosttySurface *src = ctx.src;
  QPointer<MainWindow> winp = ctx.winp;
  QPointer<GhosttySurface> srcp = ctx.srcp;
  MainWindow *win = ctx.win;
  (void)win;

  switch (action.tag) {
    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->splitSurface(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_SPLIT: {
      // Performable: return false when the surface has no split
      // sibling — otherwise navigation chords (e.g. ctrl+alt+arrows)
      // eat their own keystrokes on an unsplit surface.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_goto_split_e dir = action.action.goto_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->gotoSplit(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_RESIZE_SPLIT: {
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_resize_split_s rs = action.action.resize_split;
      post(win, [winp, srcp, rs]() {
        if (winp && srcp) winp->resizeSplit(srcp, rs);
      });
      return true;
    }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->equalizeSplits(srcp);
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      // Performable: only meaningful inside a split tree.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->toggleSplitZoom(srcp);
      });
      return true;

    default:
      return false;
  }
}

}  // namespace actions
