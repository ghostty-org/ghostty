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

  // Use the Fusion style rather than KDE's Breeze. Breeze unconditionally
  // applies a blur-behind (frosted-glass) effect to any translucent
  // window — which our terminal is — and offers no way to opt out. That
  // blur masks the real background transparency; Fusion has no such
  // behaviour. The widget style is otherwise nearly invisible here (the
  // terminal is GL-rendered; the only Qt chrome is an auto-hidden tab
  // bar), so this costs nothing visible.
  QApplication::setStyle(QStringLiteral("Fusion"));

  // ghostty_init must run *after* QApplication: QApplication strips its
  // own options (e.g. -style) out of argv in place, and libghostty later
  // re-scans that array for CLI config — scanning the pre-strip array
  // would walk past its end into freed/null entries.
  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_init failed\n");
    return 1;
  }

  MainWindow window;
  if (!window.initialize()) {
    std::fprintf(stderr, "[ghostty-qt] window initialization failed\n");
    return 1;
  }
  window.resize(800, 600);
  window.show();

  return app.exec();
}
