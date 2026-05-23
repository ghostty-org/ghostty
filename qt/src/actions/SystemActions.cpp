#include "ActionDispatcher.h"

#include <cstdio>

#include <QApplication>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDesktopServices>
#include <QProcess>
#include <QStandardPaths>
#include <QString>
#include <QStringLiteral>
#include <QUrl>
#include <QVariant>
#include <QVariantMap>

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

// Drive the taskbar progress bar via the Unity LauncherEntry D-Bus API
// (honored by the KDE task manager), keyed to ghastty.desktop.
//
// Unity LauncherEntry does not have first-class ERROR / PAUSE /
// INDETERMINATE states. We approximate per progress-style:
//   - REMOVE: progress-visible=false
//   - SET / ERROR / PAUSE: progress-visible=true, progress=fraction;
//     ERROR + PAUSE additionally flag urgent=true so the launcher
//     marks attention (KDE/Plasma renders this as a bouncing icon).
//   - INDETERMINATE: progress-visible=true with fraction=0 — Unity
//     has no indeterminate phase, so a 0 progress is the closest
//     we can do. Plasma renders this as an empty bar; better than
//     dropping the state entirely.
static void postProgress(ghostty_action_progress_report_state_e state,
                         double fraction) {
  QDBusMessage msg = QDBusMessage::createSignal(
      QStringLiteral("/com/canonical/unity/launcherentry/ghastty"),
      QStringLiteral("com.canonical.Unity.LauncherEntry"),
      QStringLiteral("Update"));
  QVariantMap props;
  const bool visible = state != GHOSTTY_PROGRESS_STATE_REMOVE;
  if (state == GHOSTTY_PROGRESS_STATE_INDETERMINATE) fraction = 0.0;
  props[QStringLiteral("progress")] = fraction;
  props[QStringLiteral("progress-visible")] = visible;
  if (state == GHOSTTY_PROGRESS_STATE_ERROR ||
      state == GHOSTTY_PROGRESS_STATE_PAUSE) {
    props[QStringLiteral("urgent")] = true;
  }
  msg.setArguments(
      {QStringLiteral("application://ghastty.desktop"), QVariant(props)});
  QDBusConnection::sessionBus().send(msg);
}

// Open a URL through the desktop, routed by libghostty's open_url
// kind. The default `QDesktopServices::openUrl` for `text` payloads
// (e.g. the config file) lands in whatever the user has registered
// for `.txt`, which on most Linux desktops is a browser. xdg-open
// `--type=text` doesn't exist, but we can resolve the user's
// preferred text editor via `xdg-mime query default text/plain`,
// fall back to `$VISUAL` / `$EDITOR`, and finally let
// QDesktopServices try.
static void openUrlByKind(const QString &url,
                          ghostty_action_open_url_kind_e kind) {
  if (kind != GHOSTTY_ACTION_OPEN_URL_KIND_TEXT) {
    QDesktopServices::openUrl(
        QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile));
    return;
  }
  // Try to launch a registered text/plain handler. xdg-mime returns
  // a `.desktop` file id; gtk-launch (Debian) or dex (KDE) executes
  // it. If that fails, fall through to the env-editor path.
  const QString path =
      QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile).toLocalFile();
  const QString target = path.isEmpty() ? url : path;
  QProcess mime;
  mime.start(QStringLiteral("xdg-mime"),
             {QStringLiteral("query"), QStringLiteral("default"),
              QStringLiteral("text/plain")});
  mime.waitForFinished(500);
  const QString desktopId =
      QString::fromUtf8(mime.readAllStandardOutput()).trimmed();
  if (!desktopId.isEmpty()) {
    if (QProcess::startDetached(QStringLiteral("gtk-launch"),
                                {desktopId, target}))
      return;
    if (QProcess::startDetached(QStringLiteral("dex"),
                                {desktopId, target}))
      return;
  }
  // $VISUAL / $EDITOR fall-back, but only if it's a GUI editor: a
  // tty-only `vi` would steal the controlling terminal. We can't
  // know for certain, so try a curated list (mate-, gedit, kate,
  // gnome-text-editor, code) before bailing to QDesktopServices.
  static const char *kGuiEditors[] = {
      "gnome-text-editor", "gedit", "kate",  "kwrite",
      "code",              "mousepad", "leafpad", nullptr};
  for (const char **e = kGuiEditors; *e; ++e) {
    if (QStandardPaths::findExecutable(QString::fromLatin1(*e)).isEmpty())
      continue;
    if (QProcess::startDetached(QString::fromLatin1(*e), {target})) return;
  }
  QDesktopServices::openUrl(
      QUrl::fromUserInput(url, QString(), QUrl::AssumeLocalFile));
}

bool handleSystem(const Context &ctx, const ghostty_action_s &action) {
  MainWindow *win = ctx.win;
  GhosttySurface *src = ctx.src;
  QPointer<MainWindow> winp = ctx.winp;
  QPointer<GhosttySurface> srcp = ctx.srcp;

  switch (action.tag) {
    case GHOSTTY_ACTION_RING_BELL:
      post(win, [winp, srcp]() {
        if (winp) winp->ringBell(srcp);
      });
      return true;

    case GHOSTTY_ACTION_DESKTOP_NOTIFICATION: {
      const ghostty_action_desktop_notification_s n =
          action.action.desktop_notification;
      const QString title = QString::fromUtf8(n.title ? n.title : "");
      const QString body = QString::fromUtf8(n.body ? n.body : "");
      // Suppress notifications from the focused surface — the user
      // is already looking at it and the popup just doubles up.
      // macOS does the same gate; GTK gates on surface focus too.
      // App-target (no `src`) always fires.
      post(qApp, [title, body, srcp]() {
        if (srcp && srcp->hasFocus()) return;
        postNotification(title, body);
      });
      return true;
    }

    case GHOSTTY_ACTION_COMMAND_FINISHED: {
      // libghostty fires this for every command end; the apprt is
      // responsible for the notify-on-command-finish gate.
      if (!src) return true;
      const int code = action.action.command_finished.exit_code;
      const uint64_t duration = action.action.command_finished.duration;
      post(src, [srcp, winp, code, duration]() {
        if (!srcp || !winp) return;
        // The per-command "armed via context menu" path overrides
        // the never/unfocused gate (matches GTK's setup-menu).
        const bool armed = srcp->consumeCommandNotify();
        // notify-on-command-finish enum (string).
        const QString mode = winp->configString("notify-on-command-finish");
        bool fire = armed;
        if (!fire) {
          if (mode == QLatin1String("always")) fire = true;
          else if (mode == QLatin1String("unfocused") && !srcp->hasFocus())
            fire = true;
        }
        if (!fire) return;
        // -after Duration; default 5s. Duration isn't decodable via
        // ghostty_config_get (non-extern non-packed struct), so parse
        // from the on-disk config.
        const uint64_t afterNs = parseDurationNs(
            configValue(QStringLiteral("notify-on-command-finish-after")),
            5ULL * 1000 * 1000 * 1000);
        if (duration < afterNs) return;
        // -action: NotifyOnCommandFinishAction = packed struct
        // { bell: bool = true, notify: bool = false }. Serialized
        // as c_uint via c_get.zig; bit 0 = bell, bit 1 = notify.
        // A zero-init reads as no-bell-no-notify, which matches the
        // "configGet failed; nothing to do" semantics.
        unsigned int actBits = 0;
        const bool actOk = configGet(
            GhosttyApp::instance().config(), &actBits,
            "notify-on-command-finish-action");
        // configGet failure → fall back to the documented defaults
        // (bell=true, notify=false) so the feature still works.
        if (!actOk) actBits = 0x1;
        const bool actBell = (actBits & 0x1) != 0;
        const bool actNotify = (actBits & 0x2) != 0;
        if (actBell) winp->ringBell(srcp);
        if (actNotify || armed) {
          QString title;
          if (code < 0) title = QStringLiteral("Command Finished");
          else if (code == 0) title = QStringLiteral("Command Succeeded");
          else title = QStringLiteral("Command Failed");
          const QString body = code >= 0
              ? QStringLiteral("Exited with code %1").arg(code)
              : QStringLiteral("The command completed.");
          postNotification(title, body);
        }
      });
      return true;
    }

    case GHOSTTY_ACTION_PROGRESS_REPORT: {
      // Honor `progress-style`: when false, OSC 9;4 progress
      // sequences are silently ignored (no taskbar entry). It is a
      // *bool* in Config.zig — it MUST be read with configBool.
      // configString would hand ghostty_config_get a `const char**`;
      // the 1-byte bool write leaves a `0x1` pointer that
      // QString::fromUtf8 then dereferences and crashes on (e.g.
      // when Claude emits progress).
      if (win && !win->configBool("progress-style", true)) return true;
      const ghostty_action_progress_report_s p = action.action.progress_report;
      const ghostty_action_progress_report_state_e state = p.state;
      const double fraction = p.progress >= 0 ? p.progress / 100.0 : 0.0;
      post(qApp,
           [state, fraction]() { postProgress(state, fraction); });
      return true;
    }

    case GHOSTTY_ACTION_OPEN_URL: {
      const ghostty_action_open_url_s u = action.action.open_url;
      if (!u.url || !u.len) return true;
      const QString s = QString::fromUtf8(u.url, static_cast<int>(u.len));
      const ghostty_action_open_url_kind_e kind = u.kind;
      post(qApp, [s, kind]() { openUrlByKind(s, kind); });
      return true;
    }

    case GHOSTTY_ACTION_OPEN_CONFIG: {
      // ghostty_config_open_path creates the config file if missing
      // and returns its path; opening it is the apprt's job. Route
      // through the text-kind opener so the user's configured editor
      // (not a browser via "text/plain → .txt") gets the file.
      ghostty_string_s path = ghostty_config_open_path();
      if (path.ptr && path.len) {
        const QString p =
            QString::fromUtf8(path.ptr, static_cast<int>(path.len));
        post(qApp, [p]() {
          openUrlByKind(p, GHOSTTY_ACTION_OPEN_URL_KIND_TEXT);
        });
      }
      ghostty_string_free(path);
      return true;
    }

    case GHOSTTY_ACTION_RELOAD_CONFIG:
      // Reload is app-scoped (the config is process-wide). Post to
      // qApp instead of the originating window so the reload still
      // happens if the window that issued the action is closed
      // between the dispatch and the queued slot.
      post(qApp, []() { MainWindow::reloadConfigGlobal(); });
      return true;

    case GHOSTTY_ACTION_CONFIG_CHANGE:
      // A notification: libghostty already holds the new config
      // (this often fires as the echo of our own
      // ghostty_app_update_config). Re-pushing it would loop, so just
      // refresh window chrome.
      post(qApp, []() { MainWindow::refreshChrome(); });
      return true;

    case GHOSTTY_ACTION_SHOW_CHILD_EXITED: {
      if (!src) return false;
      const ghostty_surface_message_childexited_s ce =
          action.action.child_exited;
      // Suppress the banner for fast-exiting children (e.g. an
      // intentional `exit 0` after a quick command). Match the macOS
      // gate: only show when runtime_ms is at least the configured
      // abnormal threshold (default 250ms). Banner = "the process
      // died unexpectedly," not "the process exited."
      uint32_t threshold = 250;
      configGet(GhosttyApp::instance().config(), &threshold,
                "abnormal-command-exit-runtime");
      if (ce.runtime_ms < threshold) return true;
      const int code = static_cast<int>(ce.exit_code);
      post(src, [srcp, code]() {
        if (srcp) srcp->showChildExited(code);
      });
      return true;
    }

    case GHOSTTY_ACTION_UNDO:
      post(qApp, []() { MainWindow::undoLastClose(); });
      return true;

    case GHOSTTY_ACTION_REDO:
      post(qApp, []() { MainWindow::redoLastClose(); });
      return true;

    // ---- no-op acks ----

    case GHOSTTY_ACTION_READONLY:
      // Read-only mode: libghostty itself drops keystrokes; we have
      // no UI affordance (e.g. a padlock icon) so just acknowledge.
      return true;

    case GHOSTTY_ACTION_SECURE_INPUT:
      // Secure-input: macOS-only enable_secure_event_input() that
      // hides keystrokes from other apps. Wayland has no equivalent
      // (the compositor mediates input), so this is a documented
      // platform gap; acknowledge so the keybind isn't reported as
      // unhandled.
      return true;

    case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
      // No in-app updater on Linux (distros / package managers
      // handle updates). Acknowledge so the keybind isn't unhandled.
      return true;

    case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR:
      // GTK-only debug action; no analogue.
      return true;

    case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      // libghostty defines this for iOS / on-screen-keyboard
      // apprts. Linux desktops have a system-managed virtual
      // keyboard (e.g. KDE's vkbd, GNOME's caribou) that the user
      // toggles out-of-band; nothing for the apprt to do.
      // Acknowledge so the keybind isn't reported as unhandled.
      return true;

    default:
      return false;
  }
}

}  // namespace actions
