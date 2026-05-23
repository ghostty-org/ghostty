#pragma once

class QWidget;

// Free functions that drive the dropdown quick-terminal window: a
// wlr-layer-shell anchored surface, faded in/out via windowOpacity.
// `window` is the QWidget hosting the layer-shell surface
// (MainWindow with m_quickTerminal == true).
//
// The animation is parented to `window`'s child tree, so it dies
// with the window.
namespace quickterm {

// Configure the layer-shell anchor, screen, keyboard interactivity,
// and size from the `quick-terminal-*` config keys. Logs and bails
// when LayerShellQt isn't available — the Qt frontend is Wayland-
// only, so a missing layer-shell surface is a runtime configuration
// error, not a portability fallback.
void setupLayerShell(QWidget *window);

// Fade the window in: opacity 0 → 1 over
// `quick-terminal-animation-duration` seconds. show()/raise()/
// activateWindow() are called up front so the user gets the focus
// during the fade. A duration of 0 collapses to an immediate
// setWindowOpacity(1.0).
void animateIn(QWidget *window);

// Fade the window out and hide() on completion. Disconnects any
// previous `finished` handler before reconnecting so a rapid
// in/out/in cycle doesn't pile up handlers that all fire on the
// next `out`.
void animateOut(QWidget *window);

}  // namespace quickterm
