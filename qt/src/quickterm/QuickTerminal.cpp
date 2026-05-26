#include "QuickTerminal.h"

#include <algorithm>
#include <cstdio>

#include <QCursor>
#include <QEasingCurve>
#include <QGuiApplication>
#include <QScreen>
#include <QSize>
#include <QString>
#include <QStringLiteral>
#include <QVariantAnimation>
#include <QWidget>
#include <QWindow>

#include <LayerShellQt/window.h>

#include "../config/Config.h"
#include "../wayland/AlphaModifier.h"
#include "ghostty.h"

namespace quickterm {

namespace {

// Anim and toggle live on the QObject child tree of `window`, so
// they die with it. We keep the QPropertyAnimation as a dynamic
// property so callers don't need to thread it through. The "_q_"
// underscore-prefix space is reserved by Qt; any other prefix is
// fine and the dotted form keeps it visibly application-scoped.
constexpr const char *kAnimProperty = "ghastty.quickterm.anim";

// Read quick-terminal-animation-duration (seconds) and convert to ms.
// Clamps to a sane range so a misconfigured 0/negative value doesn't
// make the window appear/disappear instantly without an animation,
// and a very large value doesn't lock the user out.
int animationMs() {
  double secs = 0.2;  // matches Config.zig default
  // On read failure secs keeps the default; the success bit isn't
  // load-bearing.
  (void)config::get(&secs, "quick-terminal-animation-duration");
  if (secs <= 0.0) return 0;
  return std::clamp(static_cast<int>(secs * 1000.0), 1, 1000);
}

// Apply opacity to the window. Uses wp_alpha_modifier_v1 when the
// compositor supports it (real per-surface alpha multiplier on the
// compositor side); otherwise falls through to a no-op (the
// animation still runs but the window just appears at the end —
// previously this called QWindow::setOpacity which spammed
// "This plugin does not support setting window opacity" warnings
// on every animation tick because QtWayland's QPA plugin has no
// implementation).
void applyOpacity(QWidget *window, double opacity) {
  QWindow *handle = window->windowHandle();
  if (!handle) return;
  wayland::AlphaModifier::setOpacity(handle, opacity);
}

// Lazily fetch (or build) the per-window opacity animation, parented
// to `window` so its lifetime tracks the widget's. We use
// QVariantAnimation (not QPropertyAnimation on windowOpacity) so
// the per-tick value is delivered to our applyOpacity handler
// instead of QWindow::setOpacity (which QtWayland's QPA plugin
// doesn't implement — see applyOpacity comment).
QVariantAnimation *animFor(QWidget *window) {
  auto *existing = window->property(kAnimProperty).value<QVariantAnimation *>();
  if (existing) return existing;
  auto *anim = new QVariantAnimation(window);
  QObject::connect(anim, &QVariantAnimation::valueChanged, window,
                   [window](const QVariant &v) {
                     applyOpacity(window, v.toDouble());
                   });
  window->setProperty(kAnimProperty,
                      QVariant::fromValue<QVariantAnimation *>(anim));
  return anim;
}

}  // namespace

void setupLayerShell(QWidget *window) {
  // LayerShellQt attaches to the native window; force it into being.
  window->winId();
  QWindow *handle = window->windowHandle();
  if (!handle) return;
  LayerShellQt::Window *ls = LayerShellQt::Window::get(handle);
  if (!ls) {
    // The Qt frontend targets Wayland exclusively (the project
    // builds against LayerShellQt for the dropdown). If we can't
    // get a layer-shell handle the platform isn't supported — log
    // and bail rather than silently degrading to a non-functional
    // regular window.
    std::fprintf(stderr,
                 "[ghastty] LayerShellQt::Window::get returned null; "
                 "the quick terminal needs a Wayland session with "
                 "wlr-layer-shell support (e.g. KWin, sway).\n");
    return;
  }
  using LSW = LayerShellQt::Window;

  ls->setLayer(LSW::LayerTop);
  const QString ki = config::string("quick-terminal-keyboard-interactivity");
  ls->setKeyboardInteractivity(
      ki == QLatin1String("exclusive") ? LSW::KeyboardInteractivityExclusive
      : ki == QLatin1String("none")    ? LSW::KeyboardInteractivityNone
                                       : LSW::KeyboardInteractivityOnDemand);

  // quick-terminal-screen: pick which output to anchor on.
  //   `main`            → primary screen.
  //   `mouse`           → the screen the pointer is currently on.
  //   `macos-menu-bar`  → macOS-only; falls through to primary on
  //                       Linux.
  // LayerShellQt 6.6+ exposes setScreen(QScreen*) on the layer-shell
  // window directly; the older setScreenConfiguration is deprecated.
  // Pass null to fall back to the QWindow's screen (LayerShellQt's
  // documented default when neither setScreen nor
  // setWantsToBeOnActiveScreen is set).
  const QString screenMode = config::string("quick-terminal-screen");
  QScreen *screen = nullptr;
  if (screenMode == QLatin1String("mouse")) {
    screen = QGuiApplication::screenAt(QCursor::pos());
  } else if (screenMode == QLatin1String("main") ||
             screenMode == QLatin1String("macos-menu-bar")) {
    screen = QGuiApplication::primaryScreen();
  }
  ls->setScreen(screen);
  // For sizing only — LayerShellQt already has the anchor screen above
  // (or fell back to the QWindow's screen via setScreen(nullptr)). We
  // need a non-null QScreen below to read its pixel dimensions.
  if (!screen) screen = handle->screen();

  // quick-terminal-space-behavior (`remain` / `move`) is intentionally
  // not read: macOS controls whether the dropdown follows the active
  // Space or pins to the one it was opened on, but Wayland's
  // wlr-layer-shell has no equivalent — the compositor always renders
  // the surface on the active workspace (KWin behaviour), which
  // corresponds to `move`. Achieving `remain` would need a
  // per-workspace pin that no mainstream compositor exposes; honour
  // by no-op and document.

  const QSize scr = screen ? screen->size() : QSize(1920, 1080);

  // quick-terminal-size: primary is the edge-perpendicular extent.
  // On read failure qsz stays zero-initialized and toPx falls back to
  // its `fallback` argument; the success bit isn't load-bearing.
  ghostty_config_quick_terminal_size_s qsz = {};
  (void)config::get(&qsz, "quick-terminal-size");
  const auto toPx = [](const ghostty_quick_terminal_size_s &s, int dim,
                       int fallback) -> int {
    switch (s.tag) {
      case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
        return static_cast<int>(s.value.percentage / 100.0f * dim);
      case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
        return static_cast<int>(s.value.pixels);
      default:
        return fallback;
    }
  };

  const QString pos = config::string("quick-terminal-position");
  LSW::Anchors anchors;
  QSize size;
  if (pos == QLatin1String("bottom")) {
    anchors = LSW::Anchors(LSW::AnchorBottom) | LSW::AnchorLeft |
              LSW::AnchorRight;
    size = {scr.width(), toPx(qsz.primary, scr.height(), 400)};
  } else if (pos == QLatin1String("left")) {
    anchors = LSW::Anchors(LSW::AnchorLeft) | LSW::AnchorTop |
              LSW::AnchorBottom;
    size = {toPx(qsz.primary, scr.width(), 400), scr.height()};
  } else if (pos == QLatin1String("right")) {
    anchors = LSW::Anchors(LSW::AnchorRight) | LSW::AnchorTop |
              LSW::AnchorBottom;
    size = {toPx(qsz.primary, scr.width(), 400), scr.height()};
  } else if (pos == QLatin1String("center")) {
    anchors = LSW::Anchors(LSW::AnchorNone);
    size = {toPx(qsz.primary, scr.width(), 800),
            toPx(qsz.secondary, scr.height(), 400)};
  } else {  // top (the default)
    anchors = LSW::Anchors(LSW::AnchorTop) | LSW::AnchorLeft |
              LSW::AnchorRight;
    size = {scr.width(), toPx(qsz.primary, scr.height(), 400)};
  }
  ls->setAnchors(anchors);
  // The layer-shell protocol takes the size from the underlying
  // wl_surface (i.e. the QWindow's size); LayerShellQt has no
  // setDesiredSize on this Qt branch.
  window->resize(size);
}

void animateIn(QWidget *window) {
  // Show with opacity 0 first so the compositor never paints a
  // fully-opaque frame before the animation kicks in. The
  // QVariantAnimation valueChanged → applyOpacity path needs the
  // wl_surface to exist, which means after show(). We call
  // applyOpacity twice on either side of show() — once at 0.0 as
  // a best-effort pre-show (no-op if wl_surface isn't up yet),
  // once at 0.0 immediately after to lock in the start state.
  applyOpacity(window, 0.0);
  window->show();
  window->raise();
  window->activateWindow();
  applyOpacity(window, 0.0);
  const int ms = animationMs();
  if (ms <= 0) {
    applyOpacity(window, 1.0);
    return;
  }
  // Stop any running fade so toggling rapidly doesn't stack
  // animations.
  QVariantAnimation *anim = animFor(window);
  anim->stop();
  // animateOut leaves a `finished -> hide()` handler attached to the
  // shared animation object. If a fade-out was interrupted by this
  // fade-in (rapid out/in cycle), the leftover handler would fire at
  // the end of the in-fade and silently hide the just-revealed
  // window — clear it before starting.
  QObject::disconnect(anim, &QVariantAnimation::finished, window, nullptr);
  anim->setDuration(ms);
  anim->setStartValue(0.0);
  anim->setEndValue(1.0);
  anim->setEasingCurve(QEasingCurve::OutCubic);
  anim->start();
}

void animateOut(QWidget *window) {
  const int ms = animationMs();
  if (ms <= 0) {
    window->hide();
    return;
  }
  QVariantAnimation *anim = animFor(window);
  anim->stop();
  anim->setDuration(ms);
  // Start from the animation's last delivered value if we have one
  // (a rapid in-then-out cycle interrupts at some intermediate
  // alpha); otherwise assume the window was fully visible.
  const QVariant cur = anim->currentValue();
  anim->setStartValue(cur.isValid() ? cur.toDouble() : 1.0);
  anim->setEndValue(0.0);
  anim->setEasingCurve(QEasingCurve::InCubic);
  // Disconnect any previous handler before reconnecting; otherwise a
  // toggle-out-then-in cycle accumulates handlers that all fire on
  // the next out.
  QObject::disconnect(anim, &QVariantAnimation::finished, window, nullptr);
  QObject::connect(anim, &QVariantAnimation::finished, window,
                   [window]() { window->hide(); });
  anim->start();
}

}  // namespace quickterm
