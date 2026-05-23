#include "ActionDispatcher.h"

#include <QApplication>
#include <QSize>
#include <QTimer>

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

bool handleWindow(const Context &ctx, const ghostty_action_s &action,
                  ghostty_target_s target) {
  // Captures referenced by the queued lambdas below.
  MainWindow *win = ctx.win;
  GhosttySurface *src = ctx.src;
  QPointer<MainWindow> winp = ctx.winp;
  QPointer<GhosttySurface> srcp = ctx.srcp;
  (void)target;  // (only used by tab actions)

  switch (action.tag) {
    case GHOSTTY_ACTION_NEW_WINDOW:
      post(qApp, [srcp]() {
        MainWindow::newWindow(srcp ? srcp->surface() : nullptr);
      });
      return true;

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      post(win, [winp]() {
        if (winp) winp->close();
      });
      return true;

    case GHOSTTY_ACTION_GOTO_WINDOW: {
      // Performable: return false on a single window so the chord
      // falls through to the terminal.
      if (GhosttyApp::instance().windows().size() <= 1) return false;
      const ghostty_action_goto_window_e dir = action.action.goto_window;
      post(qApp,
           [winp, dir]() { MainWindow::gotoWindow(winp.data(), dir); });
      return true;
    }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      if (!win) return false;
      post(win, [winp, srcp]() {
        if (winp) winp->presentTerminal(srcp.data());
      });
      return true;

    case GHOSTTY_ACTION_FLOAT_WINDOW: {
      if (!win) return false;
      const ghostty_action_float_window_e mode = action.action.float_window;
      post(win, [winp, mode]() {
        if (winp) winp->setFloating(mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleWindowDecorations();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleBackgroundOpacity();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isFullScreen())
          winp->showNormal();
        else
          winp->showFullScreen();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isMaximized())
          winp->showNormal();
        else
          winp->showMaximized();
      });
      return true;

    case GHOSTTY_ACTION_INITIAL_SIZE: {
      if (!win) return false;
      const ghostty_action_initial_size_s sz = action.action.initial_size;
      post(win, [winp, sz]() {
        if (!winp) return;
        // The action carries logical pixels; resize() takes the same.
        // The previous code divided by devicePixelRatioF, halving the
        // window on a 2x display.
        const QSize logical(static_cast<int>(sz.width),
                            static_cast<int>(sz.height));
        winp->setDefaultWindowSize(logical);  // for RESET_WINDOW_SIZE
        winp->resize(logical);
      });
      return true;
    }

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      post(win, [winp]() {
        if (!winp) return;
        const QSize def = winp->defaultWindowSize();
        winp->resize(def.isValid() ? def : QSize(800, 600));
      });
      return true;

    case GHOSTTY_ACTION_SIZE_LIMIT: {
      if (!win) return false;
      const ghostty_action_size_limit_s sl = action.action.size_limit;
      post(win, [winp, sl]() {
        if (winp)
          winp->setSizeLimits(sl.min_width, sl.min_height,
                              sl.max_width, sl.max_height);
      });
      return true;
    }

    case GHOSTTY_ACTION_CELL_SIZE: {
      if (!win) return false;
      const ghostty_action_cell_size_s cs = action.action.cell_size;
      post(win, [winp, cs]() {
        if (winp) winp->setCellSize(cs.width, cs.height);
      });
      return true;
    }

    case GHOSTTY_ACTION_QUIT:
      post(qApp, []() { MainWindow::closeAllWindows(/*thenQuit=*/true); });
      return true;

    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      // Distinct from QUIT: close-all-windows leaves the process
      // alive when quit-after-last-window-closed is false. macOS
      // makes the same distinction.
      post(qApp,
           []() { MainWindow::closeAllWindows(/*thenQuit=*/false); });
      return true;

    case GHOSTTY_ACTION_QUIT_TIMER: {
      const bool start =
          action.action.quit_timer == GHOSTTY_QUIT_TIMER_START;
      post(qApp,
           [start]() { GhosttyApp::instance().handleQuitTimer(start); });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      post(qApp, []() { GhosttyApp::instance().toggleVisibility(); });
      return true;

    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      post(qApp, []() { GhosttyApp::instance().toggleQuickTerminal(); });
      return true;

    default:
      // Unreachable — dispatch() routes only window-domain tags here.
      return false;
  }
  // Mark `src` used (silences -Wunused-variable when no case touches
  // the surface; some window actions ignore it).
  (void)src;
}

}  // namespace actions
