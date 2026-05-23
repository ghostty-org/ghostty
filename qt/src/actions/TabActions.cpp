#include "ActionDispatcher.h"

#include <QString>
#include <QStringLiteral>

#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

bool handleTab(const Context &ctx, const ghostty_action_s &action) {
  MainWindow *win = ctx.win;
  GhosttySurface *src = ctx.src;
  QPointer<MainWindow> winp = ctx.winp;
  QPointer<GhosttySurface> srcp = ctx.srcp;

  switch (action.tag) {
    case GHOSTTY_ACTION_NEW_TAB: {
      if (!win) return false;
      // `parent` is a libghostty handle whose lifetime tracks `src`'s.
      // If `src` is gone by the time the lambda runs, drop the parent
      // and create an unparented tab.
      post(win, [winp, srcp]() {
        if (!winp) return;
        winp->newTab(srcp ? srcp->surface() : nullptr);
      });
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB: {
      if (!src) return false;
      const ghostty_action_close_tab_mode_e mode = action.action.close_tab_mode;
      post(win, [winp, srcp, mode]() {
        if (!winp || !srcp) return;
        winp->closeTabsByMode(srcp, mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_TAB: {
      // Performable: return false on a single tab so the chord falls
      // through to the terminal. macOS does the same; GTK gates on
      // tabPage count > 1.
      if (!win || win->tabCount() <= 1) return false;
      const ghostty_action_goto_tab_e tab = action.action.goto_tab;
      post(win, [winp, tab]() {
        if (winp) winp->gotoTab(tab);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOVE_TAB: {
      // Surface-target only: an app-target MOVE_TAB has no
      // meaningful window to apply to (we'd just pick the first
      // live one arbitrarily). macOS returns false here —
      // performable falls through to the running terminal on no
      // live window.
      if (!src) return false;
      // Performable: a single tab can't be reordered.
      if (!win || win->tabCount() <= 1) return false;
      const int amount = static_cast<int>(action.action.move_tab.amount);
      post(win, [winp, amount]() {
        if (winp) winp->moveTab(amount);
      });
      return true;
    }

    case GHOSTTY_ACTION_SET_TAB_TITLE: {
      // A manual tab-title override (an empty string clears it).
      if (!src) return true;
      const char *title = action.action.set_tab_title.title;
      const QString t = QString::fromUtf8(title ? title : "");
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setTabTitleOverride(srcp, t);
      });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      // Tab overview is GTK's adw.TabOverview — a thumbnail grid of
      // tabs. Qt has no built-in equivalent and an ad-hoc Qt port
      // would be a feature in its own right; acknowledge for now.
      return true;

    default:
      // Unreachable — dispatch() routes only tab-domain tags here.
      return false;
  }
}

}  // namespace actions
