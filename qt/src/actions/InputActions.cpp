#include "ActionDispatcher.h"

#include <QString>
#include <Qt>

#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

// Map a libghostty mouse shape to the nearest Qt cursor.
static Qt::CursorShape mouseShapeToCursor(ghostty_action_mouse_shape_e s) {
  switch (s) {
    case GHOSTTY_MOUSE_SHAPE_TEXT:
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return Qt::IBeamCursor;
    case GHOSTTY_MOUSE_SHAPE_POINTER:
    case GHOSTTY_MOUSE_SHAPE_ALIAS: return Qt::PointingHandCursor;
    case GHOSTTY_MOUSE_SHAPE_WAIT:
    case GHOSTTY_MOUSE_SHAPE_PROGRESS: return Qt::WaitCursor;
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
    case GHOSTTY_MOUSE_SHAPE_CELL: return Qt::CrossCursor;
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
    case GHOSTTY_MOUSE_SHAPE_NO_DROP: return Qt::ForbiddenCursor;
    case GHOSTTY_MOUSE_SHAPE_GRAB: return Qt::OpenHandCursor;
    case GHOSTTY_MOUSE_SHAPE_GRABBING: return Qt::ClosedHandCursor;
    case GHOSTTY_MOUSE_SHAPE_MOVE:
    case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return Qt::SizeAllCursor;
    case GHOSTTY_MOUSE_SHAPE_COPY: return Qt::DragCopyCursor;
    case GHOSTTY_MOUSE_SHAPE_HELP: return Qt::WhatsThisCursor;
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return Qt::SizeHorCursor;
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return Qt::SizeVerCursor;
    case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return Qt::SizeBDiagCursor;
    case GHOSTTY_MOUSE_SHAPE_NW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return Qt::SizeFDiagCursor;
    default: return Qt::ArrowCursor;  // DEFAULT, CONTEXT_MENU, zoom, ...
  }
}

bool handleInput(const Context &ctx, const ghostty_action_s &action) {
  GhosttySurface *src = ctx.src;
  QPointer<GhosttySurface> srcp = ctx.srcp;

  switch (action.tag) {
    case GHOSTTY_ACTION_MOUSE_SHAPE: {
      if (!src) return false;
      const Qt::CursorShape shape =
          mouseShapeToCursor(action.action.mouse_shape);
      post(src, [srcp, shape]() {
        if (srcp) srcp->setShape(shape);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY: {
      if (!src) return false;
      const bool visible =
          action.action.mouse_visibility != GHOSTTY_MOUSE_HIDDEN;
      post(src, [srcp, visible]() {
        // setMouseVisible preserves the requested shape so toggling
        // doesn't reset to ArrowCursor.
        if (srcp) srcp->setMouseVisible(visible);
      });
      return true;
    }

    case GHOSTTY_ACTION_PWD: {
      // libghostty inherits a child's pwd through the surface tree
      // (ghostty_surface_inherited_config carries it across splits /
      // tabs), and re-fires this action whenever the cwd changes via
      // OSC 7 / shell integration. Stash it on the surface so future
      // chrome (worktree-aware tab decoration, "new tab here") can
      // read it without parsing /proc/<pid>/cwd. Empty pwd from
      // libghostty means "unknown / cleared" — pass it through so the
      // surface can drop a stale value.
      if (!src) return true;
      // libghostty's pwd is a sentinel-terminated Zig slice (see
      // src/apprt/action.zig:Pwd) — its C ptr is always non-null;
      // an "unknown / cleared" cwd is encoded as "".
      const QString s = QString::fromUtf8(action.action.pwd.pwd);
      post(src, [srcp, s]() {
        if (srcp) srcp->setPwd(s);
      });
      return true;
    }

    default:
      return false;
  }
}

}  // namespace actions
