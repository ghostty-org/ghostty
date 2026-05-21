#include <cstdio>

#include <QApplication>
#include <QCoreApplication>
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

  // QSettings storage path keys: applicationName + organizationDomain.
  // Used by the inspector window's geometry autosave (and any future
  // QSettings-backed UI state) — the keys go to
  // ~/.config/ghastty/ghastty.conf.
  QCoreApplication::setApplicationName(QStringLiteral("ghastty"));
  QCoreApplication::setOrganizationDomain(QStringLiteral("ghastty"));

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
    std::fprintf(stderr, "[ghastty] ghostty_init failed\n");
    return 1;
  }

  // initial-window: when false, start headless (no window opens at
  // launch). Combined with quit-after-last-window-closed=false this
  // is how a user runs ghastty as a daemon for the global quick-
  // terminal shortcut. We need the libghostty app first, so spin up
  // a temporary "config bootstrap" by opening + immediately closing
  // a window — but cheaper: peek at the config directly here.
  // ghostty_init has already run, but the libghostty app is built
  // by the first MainWindow::initialize. There is no app-less
  // accessor for the config, so we open the window and close if the
  // bool is false. Cheaper alternative: set a static flag and have
  // initialize() bail before show.
  if (!MainWindow::newWindow(nullptr)) {
    std::fprintf(stderr, "[ghastty] window initialization failed\n");
    return 1;
  }
  if (!MainWindow::wantsInitialWindow()) MainWindow::closeInitialWindow();

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
