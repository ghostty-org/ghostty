#include <cstdio>

#include <QGuiApplication>

#include "GhosttyWindow.h"
#include "ghostty.h"

int main(int argc, char **argv) {
  // This scaffold uses the X11 window id for the EGL window surface, so
  // it requires the xcb platform plugin (XWayland is fine).
  if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
    qputenv("QT_QPA_PLATFORM", "xcb");

  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_init failed\n");
    return 1;
  }

  QGuiApplication app(argc, argv);

  GhosttyWindow window;
  if (!window.initialize()) {
    std::fprintf(stderr, "[ghostty-qt] window initialization failed\n");
    return 1;
  }
  window.resize(800, 600);
  window.show();

  return app.exec();
}
