#include "QuickTerminal.h"

#include <algorithm>
#include <cstdio>

#include <QCursor>
#include <QEasingCurve>
#include <QGuiApplication>
#include <QPropertyAnimation>
#include <QScreen>
#include <QSize>
#include <QString>
#include <QStringLiteral>
#include <QWidget>
#include <QWindow>

#include <LayerShellQt/window.h>

#include "../config/Config.h"
#include "ghostty.h"

namespace quickterm {

namespace {

// Anim and toggle live on the QObject child tree of `window`, so
// they die with it. We keep the QPropertyAnimation as a dynamic
// property so callers don't need to thread it through.
constexpr const char *kAnimProperty = "_ghastty_qt_anim";

// Read quick-terminal-animation-duration (seconds) and convert to ms.
// Clamps to a sane range so a misconfigured 0/negative value doesn't
// make the window appear/disappear instantly without an animation,
// and a very large value doesn't lock the user out.
int animationMs() {
  double secs = 0.2;  // matches Config.zig default
  config::get(&secs, "quick-terminal-animation-duration");
  if (secs <= 0.0) return 0;
  return std::clamp(static_cast<int>(secs * 1000.0), 1, 1000);
}

// Lazily fetch (or build) the per-window opacity animation, parented
// to `window` so its lifetime tracks the widget's.
QPropertyAnimation *animFor(QWidget *window) {
  auto *existing = window->property(kAnimProperty).value<QPropertyAnimation *>();
  if (existing) return existing;
  auto *anim = new QPropertyAnimation(window, "windowOpacity", window);
  window->setProperty(kAnimProperty,
                      QVariant::fromValue<QPropertyAnimation *>(anim));
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
  ghostty_config_quick_terminal_size_s qsz = {};
  config::get(&qsz, "quick-terminal-size");
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
  window->setWindowOpacity(0.0);
  window->show();
  window->raise();
  window->activateWindow();
  const int ms = animationMs();
  if (ms <= 0) {
    window->setWindowOpacity(1.0);
    return;
  }
  // Stop any running fade so toggling rapidly doesn't stack
  // animations.
  QPropertyAnimation *anim = animFor(window);
  anim->stop();
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
  QPropertyAnimation *anim = animFor(window);
  anim->stop();
  anim->setDuration(ms);
  anim->setStartValue(window->windowOpacity());
  anim->setEndValue(0.0);
  anim->setEasingCurve(QEasingCurve::InCubic);
  // Disconnect any previous handler before reconnecting; otherwise a
  // toggle-out-then-in cycle accumulates handlers that all fire on
  // the next out.
  QObject::disconnect(anim, &QPropertyAnimation::finished, window, nullptr);
  QObject::connect(anim, &QPropertyAnimation::finished, window,
                   [window]() { window->hide(); });
  anim->start();
}

}  // namespace quickterm
