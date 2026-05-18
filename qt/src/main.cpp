#include <cstdio>

#include <QApplication>
#include <QSurfaceFormat>

#include "MainWindow.h"
#include "ghostty.h"

int main(int argc, char **argv) {
  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr, "[ghostty-qt] ghostty_init failed\n");
    return 1;
  }

  // Multiple QOpenGLWidgets compose reliably with a shared GL context.
  QApplication::setAttribute(Qt::AA_ShareOpenGLContexts);

  // Ghostty's OpenGL renderer requires at least OpenGL 4.3 core.
  QSurfaceFormat fmt;
  fmt.setRenderableType(QSurfaceFormat::OpenGL);
  fmt.setProfile(QSurfaceFormat::CoreProfile);
  fmt.setVersion(4, 3);
  QSurfaceFormat::setDefaultFormat(fmt);

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
