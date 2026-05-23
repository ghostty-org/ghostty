#include <cstdio>

#include <QApplication>
#include <QCoreApplication>
#include <QIcon>
#include <QSurfaceFormat>

#include "app/GhosttyApp.h"
#include "GlobalShortcuts.h"
#include "MainWindow.h"
#include "ghostty.h"

// True when any argv entry starts with `+` — i.e. the user invoked a
// libghostty CLI action (`+show-config`, `+list-fonts`, `+version`, …).
// We detect early so the CLI path can run without paying the cost of
// constructing a QApplication (which opens a Wayland connection
// only to exit).
static bool isCliActionInvocation(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    if (argv[i] && argv[i][0] == '+') return true;
  }
  return false;
}

int main(int argc, char **argv) {
  // CLI action fast path: skip Qt entirely. ghostty_init parses argv
  // for the `+action`; ghostty_cli_try_action runs it and exits the
  // process. If something fails (unknown action, multiple actions),
  // ghostty_init returns non-zero and we surface the same help hint
  // macOS does.
  if (isCliActionInvocation(argc, argv)) {
    if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
      std::fprintf(
          stderr,
          "Ghastty failed to initialize! If you're executing Ghastty from\n"
          "the command line then this is usually because an invalid action\n"
          "or multiple actions were specified. Actions start with the `+`\n"
          "character.\n\n"
          "View all available actions by running `ghastty +help`.\n");
      return 1;
    }
    ghostty_cli_try_action();
    // ghostty_cli_try_action exits the process when an action ran; if
    // it returned, no `+action` was actually parseable from argv —
    // bail out rather than fall through to the GUI with leftover
    // junk in argv.
    std::fprintf(stderr, "[ghastty] no CLI action ran; aborting\n");
    return 1;
  }

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

  // QSettings storage path keys: applicationName + organizationName.
  // Used by the inspector window's geometry autosave (and any future
  // QSettings-backed UI state) — the keys go to
  // ~/.config/ghastty/ghastty.conf. We pass the same string to both
  // because we don't run a multi-app suite under a parent
  // organization.
  QCoreApplication::setApplicationName(QStringLiteral("ghastty"));
  QCoreApplication::setOrganizationName(QStringLiteral("ghastty"));

  // Match the installed ghastty.desktop: this becomes the Wayland app-id
  // so the compositor associates the window with the desktop entry —
  // taskbar icon, launcher identity.
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
  // would walk past its end into freed/null entries. The CLI-action
  // fast path above already initialised libghostty for `+action`
  // invocations and exited; everything reaching here is a GUI launch.
  if (ghostty_init(static_cast<uintptr_t>(argc), argv) != GHOSTTY_SUCCESS) {
    std::fprintf(stderr,
                 "[ghastty] ghostty_init failed; check `ghastty +help`\n");
    return 1;
  }

  // initial-window: when false, start headless (no window mapped at
  // launch). Combined with quit-after-last-window-closed=false this
  // is how a user runs ghastty as a daemon for the global quick-
  // terminal shortcut. The first MainWindow::newWindow internally
  // checks the config and skips show() — so the libghostty app +
  // config still get built, but no QWindow ever appears.
  if (!MainWindow::newWindow(nullptr)) {
    std::fprintf(stderr, "[ghastty] window initialization failed\n");
    return 1;
  }

  // Register global shortcuts via the XDG portal so the quick terminal
  // can be toggled while Ghostty is unfocused. Keys are assigned by the
  // desktop (KDE System Settings -> Shortcuts).
  GlobalShortcuts globalShortcuts;
  QObject::connect(&globalShortcuts, &GlobalShortcuts::activated,
                   [](const QString &id) {
                     if (id == QLatin1String("toggle-quick-terminal"))
                       GhosttyApp::instance().toggleQuickTerminal();
                     else if (id == QLatin1String("toggle-visibility"))
                       GhosttyApp::instance().toggleVisibility();
                   });

  return app.exec();
}
