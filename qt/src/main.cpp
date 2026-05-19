#include <cstdio>

#include <QApplication>
#include <QSurfaceFormat>

#include "MainWindow.h"
#include "ghostty.h"

int main(int argc, char **argv) {
  // Use the display's true fractional scale rather than rounding it up
  // (Wayland otherwise reports e.g. 2.0 for a 1.2x display, which scales
  // the terminal up).
  QGuiApplication::setHighDpiScaleFactorRoundingPolicy(
      Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);

  // Multiple GL surfaces compose reliably with a shared GL context.
  QApplication::setAttribute(Qt::AA_ShareOpenGLContexts);

  // Ghostty's OpenGL renderer requires at least OpenGL 4.3 core.
  QSurfaceFormat fmt;
  fmt.setRenderableType(QSurfaceFormat::OpenGL);
  fmt.setProfile(QSurfaceFormat::CoreProfile);
  fmt.setVersion(4, 3);
  fmt.setAlphaBufferSize(8);  // allow a translucent terminal background
  QSurfaceFormat::setDefaultFormat(fmt);

  QApplication app(argc, argv);

  // Match the installed ghostty.desktop: this becomes the Wayland app-id
  // (and X11 WM_CLASS), so the compositor associates the window with the
  // desktop entry — taskbar icon, launcher identity.
  QGuiApplication::setDesktopFileName(QStringLiteral("ghostty"));

  // We keep the user's system widget style rather than forcing Fusion.
  // Some styles dim and blur translucent windows, which masks the
  // terminal's own background-opacity: Kvantum themes do this when
  // `blurring`/`reduce_window_opacity` are set. The fix belongs in the
  // style's config, not here — for Kvantum, add "ghostty" to the
  // theme's `opaque` app list (the same opt-out video players use).

  // ghostty_init must run *after* QApplication: QApplication strips its
  // own options (e.g. -style) out of argv in place, and libghostty later
  // re-scans that array for CLI config — scanning the pre-strip array
  // would walk past its end into freed/null entries.
  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr, "[ghostty] ghostty_init failed\n");
    return 1;
  }

  // The first window; further windows are opened on demand by the
  // new_window action. Each window owns itself (WA_DeleteOnClose).
  if (!MainWindow::newWindow(nullptr)) {
    std::fprintf(stderr, "[ghostty] window initialization failed\n");
    return 1;
  }

  return app.exec();
}
