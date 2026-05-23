#include "ActionDispatcher.h"

#include "../MainWindow.h"

namespace actions {

bool dispatch(ghostty_app_t app,
              ghostty_target_s target,
              ghostty_action_s action) {
  // Phase 2.0: forward to the legacy switch on MainWindow. Phase
  // 2.1+ retire MainWindow::onAction and absorb the body here.
  return MainWindow::onAction(app, target, action);
}

}  // namespace actions
