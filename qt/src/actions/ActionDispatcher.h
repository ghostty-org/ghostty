#pragma once

#include "ghostty.h"

// Dispatches libghostty action callbacks (the action_cb registered in
// GhosttyApp::ensureInitialized) to per-domain handlers.
//
// Returns true if the action was handled or no-op-acknowledged, false
// to let libghostty pass the chord through to the running terminal
// program (the "performable" semantics for actions like GOTO_TAB on a
// single-tab window).
//
// Threading: actions arrive on libghostty's worker thread. Handlers
// marshal Qt work onto the GUI thread via QMetaObject::invokeMethod
// (Qt::QueuedConnection); the QPointer-wrapped receiver+captures
// inside the queued lambdas guard against UAF if a window or surface
// is destroyed between dispatch and slot execution.
//
// Phase 2.0 scope: this is a forwarder to the legacy
// MainWindow::onAction body. Subsequent steps (2.1-2.9) move the
// switch body and per-domain handlers into this file and the
// matching <Domain>Actions.cpp siblings.
namespace actions {

bool dispatch(ghostty_app_t app,
              ghostty_target_s target,
              ghostty_action_s action);

}  // namespace actions
