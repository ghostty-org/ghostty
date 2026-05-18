#include <cstdio>

#include <QApplication>

#include "MainWindow.h"
#include "ghostty.h"

int main(int argc, char **argv) {
  // Default to xcb: the X11 path is stable. The Wayland-native path
  // (GhosttySurface's wl_egl_window branch) is experimental — opt in
  // with QT_QPA_PLATFORM=wayland. On a Wayland session xcb runs under
  // XWayland.
  if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
    qputenv("QT_QPA_PLATFORM", "xcb");

  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_init failed\n");
    return 1;
  }

  QApplication app(argc, argv);

  MainWindow window;
  if (!window.initialize()) {
    std::fprintf(stderr, "[ghostty-qt] window initialization failed\n");
    return 1;
  }
  window.resize(800, 600);
  window.show();

  return app.exec();
}
