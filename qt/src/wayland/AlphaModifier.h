// Per-window alpha multiplier via wp_alpha_modifier_v1.
//
// QtWayland's QPA plugin doesn't implement QWindow::setOpacity (it
// logs "This plugin does not support setting window opacity" on
// every call). For the QuickTerminal fade-in/out we need real
// per-surface alpha, so we drive the wp_alpha_modifier_v1 staging
// Wayland protocol ourselves.
//
// Compositor support (as of 2026-05): KWin (KDE 6+), wlroots
// (≥0.17), Hyprland — yes. mutter/GNOME — no. If the protocol
// isn't advertised, `setOpacity` returns false and the caller can
// either skip the animation or fall back to instant show/hide.
//
// Wayland-only by project decision (see feedback-qt-no-x11 memory).

#pragma once

struct wp_alpha_modifier_v1;
struct wp_alpha_modifier_surface_v1;
class QWindow;

namespace wayland {

class AlphaModifier {
public:
  // Returns true if the compositor advertises wp_alpha_modifier_v1
  // and we've successfully bound it. Cheap after the first call
  // (the binding is cached process-wide). Use this to decide
  // whether to drive an opacity animation or fall through to
  // instant show/hide.
  static bool supported();

  // Set the window's alpha multiplier in [0.0, 1.0]. Must be
  // called on the GUI thread (the thread that owns wl_display
  // dispatch). Returns false if `window`'s native wl_surface
  // isn't available yet (e.g. before first show), or if the
  // compositor doesn't support the protocol.
  //
  // The wp_alpha_modifier_surface_v1 object is created lazily per
  // wl_surface and cached for the surface's lifetime — repeated
  // calls during an animation just emit set_multiplier + commit.
  static bool setOpacity(QWindow *window, double opacity);

  // Release the per-surface alpha modifier object for this window.
  // Call when the window is being destroyed (or before re-creating
  // its native surface). Equivalent to set_multiplier(UINT32_MAX)
  // followed by destroy on the surface object.
  static void detach(QWindow *window);
};

}  // namespace wayland
