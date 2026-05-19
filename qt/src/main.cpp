#include <cstdio>

#include <QApplication>
#include <QIcon>
#include <QSurfaceFormat>

#include "GlobalShortcuts.h"
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

  // Match the installed ghastty.desktop: this becomes the Wayland app-id
  // (and X11 WM_CLASS), so the compositor associates the window with the
  // desktop entry — taskbar icon, launcher identity.
  QGuiApplication::setDesktopFileName(QStringLiteral("ghastty"));

  // The window icon, embedded so it works even running from the build
  // tree (when ghastty.desktop / the icon theme are not yet installed).
  QGuiApplication::setWindowIcon(QIcon(QStringLiteral(":/ghastty.svg")));

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

  // Register global shortcuts via the XDG portal so the quick terminal
  // can be toggled while Ghostty is unfocused. Keys are assigned by the
  // desktop (KDE System Settings -> Shortcuts).
  GlobalShortcuts globalShortcuts;
  QObject::connect(&globalShortcuts, &GlobalShortcuts::activated,
                   [](const QString &id) {
                     if (id == QLatin1String("toggle-quick-terminal"))
                       MainWindow::toggleQuickTerminal();
                     else if (id == QLatin1String("toggle-visibility"))
                       MainWindow::toggleVisibility();
                   });

  return app.exec();
}
