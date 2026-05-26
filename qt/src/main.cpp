#include <cstdio>
#include <cstdlib>
#include <cstring>

// (The atexit hook to ghastty_glslang_finalize_process that used
// to live here was removed: now that build-time SPV precompile
// is in place, the runtime libghostty no longer calls the glslang
// shim at all for built-ins, so the shim's symbols get DCE'd out
// of libghostty.so. The cosmetic FinalizeProcess+popAll cleanup
// also didn't reduce heaptrack's reported leak in practice, so
// the call wasn't pulling its weight anyway.)

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

// Default-disable MangoHud for this process. The Vulkan implicit
// layer hooks every vkQueueSubmit / vkAcquireNextImage / etc. to
// render its own overlay, which on this branch's animated-shader
// + multi-pane workload added ~25% extra main-thread CPU at idle
// (measured against a baseline of ~10% for the Wayland-buffer
// cache path). For a terminal, that's a steep tax on a feature
// users typically associate with games. A system-wide MANGOHUD=1
// (common in `~/.profile` for users who want the HUD on games) is
// explicitly OVERRIDDEN here — the user is invoking ghastty, not
// a game, and we don't want them to silently pay 25% extra CPU.
//
// Two layers of MangoHud's loading model:
//   - VK_LOADER_LAYERS_DISABLE: Vulkan loader skips the layer
//     entirely (no interception overhead).
//   - DISABLE_MANGOHUD: belt-and-suspenders if the loader didn't
//     honor the env var (older loaders) or another runtime force-
//     loaded the layer through a different path.
//
// Escape hatch: GHASTTY_ALLOW_OVERLAY=1 skips the guard entirely
// so a user who genuinely wants MangoHud on the terminal (e.g.
// debugging the renderer with the HUD's frame-time graph) can
// opt back in without removing the layer JSON system-wide.
//
// setenv overwrite=1 throughout: the whole point is to override a
// pre-existing MANGOHUD=1 / DISABLE_MANGOHUD=0 / etc.
static void defaultDisableMangoHud() {
  if (const char *opt = ::getenv("GHASTTY_ALLOW_OVERLAY");
      opt && opt[0] == '1') return;
  ::setenv("MANGOHUD", "0", 1);
  ::setenv("DISABLE_MANGOHUD", "1", 1);
  ::setenv("VK_LOADER_LAYERS_DISABLE", "*MANGOHUD*", 1);
}

int main(int argc, char **argv) {
  // Set the env BEFORE Qt's QApplication ctor (which can probe
  // GL/Vulkan via QPA) and before the CLI action path (since
  // libghostty action handlers may also touch the renderer).
  defaultDisableMangoHud();

  // (Build-time SPV precompile means the runtime libghostty no
  // longer invokes glslang for built-in shaders, so the per-
  // thread TPoolAllocator pages we used to leak from first-
  // surface init don't exist on the Vulkan variant anymore. No
  // atexit cleanup needed.)

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

  // The Vulkan host is intentionally NOT bootstrapped here: doing it
  // before any window is mapped on Wayland can interact badly with
  // Qt's Wayland integration (the VkInstance starts grabbing display
  // resources before Qt has finished its own connection setup, and
  // on some compositor + driver combos the result is a process that
  // runs but never actually displays a window). It's brought up
  // lazily on the first surface that needs it — see
  // `GhosttySurface.cpp`.

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
