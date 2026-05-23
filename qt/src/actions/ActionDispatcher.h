#pragma once

#include <QPointer>

#include "ghostty.h"

class GhosttySurface;
class MainWindow;

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
// Layout: dispatch() in ActionDispatcher.cpp resolves the target into
// the Context below and forwards to the matching domain handler:
//
//   WindowActions.cpp  — window/process lifecycle, fullscreen,
//                        floating, decorations, sizing
//   TabActions.cpp     — tab lifecycle, tab title, tab navigation
//   SplitActions.cpp   — split create / navigate / resize / equalize /
//                        zoom
//   ChromeActions.cpp  — surface title prompts, color scheme, key
//                        sequence overlay, search, inspector,
//                        scrollbar, link overlay
//   InputActions.cpp   — mouse shape, mouse visibility, pwd
//   SystemActions.cpp  — desktop notifications, command-finished,
//                        progress, bell, URL/config opening, reload,
//                        undo/redo, child-exited banner, no-op acks
namespace actions {

// Resolved per-action context. Built once in dispatch() from the raw
// ghostty_target_s; passed by const reference to every handler so the
// signatures stay short.
struct Context {
  // The owning window for this action: the target surface's window,
  // or (for app-level actions) the first live window. May be null if
  // there are no live windows.
  MainWindow *win = nullptr;
  // The target surface, if any. Null for app-level actions.
  GhosttySurface *src = nullptr;
  // QPointer-wrapped equivalents — capture these (not the raw
  // pointers) into queued lambdas. Qt nulls a QPointer when the
  // QObject is destroyed, so the lambda runs safely even if the
  // window/surface dies between dispatch and slot execution.
  QPointer<MainWindow> winp;
  QPointer<GhosttySurface> srcp;
};

// Public entry point — registered as ghostty_runtime_config_s::action_cb
// in GhosttyApp::ensureInitialized.
bool dispatch(ghostty_app_t app,
              ghostty_target_s target,
              ghostty_action_s action);

// Per-domain handlers. Each takes the resolved Context and the full
// ghostty_action_s so it can pull out the action-specific union
// member it needs. Each returns true/false per the libghostty
// action-cb contract (false = "not handled, let the chord fall
// through to the terminal"). Domains that don't recognize the action
// tag should not be called — dispatch() routes by tag.
//
// Tags routed to each handler are declared in the domain header.
bool handleWindow(const Context &ctx, const ghostty_action_s &action,
                  ghostty_target_s target);
bool handleTab(const Context &ctx, const ghostty_action_s &action);
bool handleSplit(const Context &ctx, const ghostty_action_s &action);
bool handleChrome(const Context &ctx, const ghostty_action_s &action);
bool handleInput(const Context &ctx, const ghostty_action_s &action);
bool handleSystem(const Context &ctx, const ghostty_action_s &action);

}  // namespace actions
