#include "ActionDispatcher.h"

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"

namespace actions {

bool dispatch(ghostty_app_t /*app*/, ghostty_target_s target,
              ghostty_action_s action) {
  // Resolve the action's target into a Context. The surface (if
  // any) is the libghostty userdata pointer carried on the target;
  // the window is the surface's owner, or — for app-level actions
  // — the first live window. Surface/window lifetimes are guarded
  // through the QPointer copies in Context (cancelled by Qt when
  // the QObject is destroyed).
  Context ctx;
  if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface)
    ctx.src = static_cast<GhosttySurface *>(
        ghostty_surface_userdata(target.target.surface));

  const QList<MainWindow *> &live = GhosttyApp::instance().windows();
  ctx.win = ctx.src ? ctx.src->owner()
                    : (live.isEmpty() ? nullptr : live.first());
  ctx.winp = ctx.win;
  ctx.srcp = ctx.src;

  // Route by action.tag to the matching domain handler. Each handler
  // owns a sub-switch over the tags it claims; an unrecognised tag
  // (not yet supported) falls through to `default: return false`,
  // which lets libghostty pass the chord through to the running
  // terminal.
  switch (action.tag) {
    // --- WindowActions.cpp ---
    case GHOSTTY_ACTION_NEW_WINDOW:
    case GHOSTTY_ACTION_CLOSE_WINDOW:
    case GHOSTTY_ACTION_GOTO_WINDOW:
    case GHOSTTY_ACTION_PRESENT_TERMINAL:
    case GHOSTTY_ACTION_FLOAT_WINDOW:
    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
    case GHOSTTY_ACTION_INITIAL_SIZE:
    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
    case GHOSTTY_ACTION_SIZE_LIMIT:
    case GHOSTTY_ACTION_CELL_SIZE:
    case GHOSTTY_ACTION_QUIT:
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
    case GHOSTTY_ACTION_QUIT_TIMER:
    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      return handleWindow(ctx, action, target);

    // --- TabActions.cpp ---
    case GHOSTTY_ACTION_NEW_TAB:
    case GHOSTTY_ACTION_CLOSE_TAB:
    case GHOSTTY_ACTION_GOTO_TAB:
    case GHOSTTY_ACTION_MOVE_TAB:
    case GHOSTTY_ACTION_SET_TAB_TITLE:
    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      return handleTab(ctx, action);

    // --- SplitActions.cpp ---
    case GHOSTTY_ACTION_NEW_SPLIT:
    case GHOSTTY_ACTION_GOTO_SPLIT:
    case GHOSTTY_ACTION_RESIZE_SPLIT:
    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      return handleSplit(ctx, action);

    // --- ChromeActions.cpp ---
    case GHOSTTY_ACTION_RENDER:
    case GHOSTTY_ACTION_SET_TITLE:
    case GHOSTTY_ACTION_PROMPT_TITLE:
    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
    case GHOSTTY_ACTION_COLOR_CHANGE:
    case GHOSTTY_ACTION_RENDERER_HEALTH:
    case GHOSTTY_ACTION_KEY_SEQUENCE:
    case GHOSTTY_ACTION_KEY_TABLE:
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
    case GHOSTTY_ACTION_SCROLLBAR:
    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
    case GHOSTTY_ACTION_START_SEARCH:
    case GHOSTTY_ACTION_END_SEARCH:
    case GHOSTTY_ACTION_SEARCH_TOTAL:
    case GHOSTTY_ACTION_SEARCH_SELECTED:
    case GHOSTTY_ACTION_INSPECTOR:
    case GHOSTTY_ACTION_RENDER_INSPECTOR:
      return handleChrome(ctx, action);

    // --- InputActions.cpp ---
    case GHOSTTY_ACTION_MOUSE_SHAPE:
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
    case GHOSTTY_ACTION_PWD:
      return handleInput(ctx, action);

    // --- SystemActions.cpp ---
    case GHOSTTY_ACTION_RING_BELL:
    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
    case GHOSTTY_ACTION_COMMAND_FINISHED:
    case GHOSTTY_ACTION_PROGRESS_REPORT:
    case GHOSTTY_ACTION_OPEN_URL:
    case GHOSTTY_ACTION_OPEN_CONFIG:
    case GHOSTTY_ACTION_RELOAD_CONFIG:
    case GHOSTTY_ACTION_CONFIG_CHANGE:
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
    case GHOSTTY_ACTION_UNDO:
    case GHOSTTY_ACTION_REDO:
    case GHOSTTY_ACTION_READONLY:
    case GHOSTTY_ACTION_SECURE_INPUT:
    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
    case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR:
    case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      return handleSystem(ctx, action);

    default:
      return false;
  }
}

}  // namespace actions
