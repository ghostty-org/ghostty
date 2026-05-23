#include "ActionDispatcher.h"

#include <cstdio>

#include <QApplication>
#include <QByteArray>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDesktopServices>
#include <QGuiApplication>
#include <QPointer>
#include <QProcess>
#include <QSize>
#include <QSplitter>
#include <QStandardPaths>
#include <QString>
#include <QStringList>
#include <QStringLiteral>
#include <QStyleHints>
#include <QUrl>
#include <QVariant>
#include <QVariantMap>
#include <Qt>

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

// File-local helpers used only by the dispatcher.

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

// Map a libghostty mouse shape to the nearest Qt cursor.
static Qt::CursorShape mouseShapeToCursor(ghostty_action_mouse_shape_e s) {
  switch (s) {
    case GHOSTTY_MOUSE_SHAPE_TEXT:
    case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return Qt::IBeamCursor;
    case GHOSTTY_MOUSE_SHAPE_POINTER:
    case GHOSTTY_MOUSE_SHAPE_ALIAS: return Qt::PointingHandCursor;
    case GHOSTTY_MOUSE_SHAPE_WAIT:
    case GHOSTTY_MOUSE_SHAPE_PROGRESS: return Qt::WaitCursor;
    case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
    case GHOSTTY_MOUSE_SHAPE_CELL: return Qt::CrossCursor;
    case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
    case GHOSTTY_MOUSE_SHAPE_NO_DROP: return Qt::ForbiddenCursor;
    case GHOSTTY_MOUSE_SHAPE_GRAB: return Qt::OpenHandCursor;
    case GHOSTTY_MOUSE_SHAPE_GRABBING: return Qt::ClosedHandCursor;
    case GHOSTTY_MOUSE_SHAPE_MOVE:
    case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: return Qt::SizeAllCursor;
    case GHOSTTY_MOUSE_SHAPE_COPY: return Qt::DragCopyCursor;
    case GHOSTTY_MOUSE_SHAPE_HELP: return Qt::WhatsThisCursor;
    case GHOSTTY_MOUSE_SHAPE_COL_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: return Qt::SizeHorCursor;
    case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: return Qt::SizeVerCursor;
    case GHOSTTY_MOUSE_SHAPE_NE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: return Qt::SizeBDiagCursor;
    case GHOSTTY_MOUSE_SHAPE_NW_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_SE_RESIZE:
    case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: return Qt::SizeFDiagCursor;
    default: return Qt::ArrowCursor;  // DEFAULT, CONTEXT_MENU, zoom, ...
  }
}

bool dispatch(ghostty_app_t /*app*/, ghostty_target_s target,
              ghostty_action_s action) {
  // The surface this action targets, if any.
  GhosttySurface *src = nullptr;
  if (target.tag == GHOSTTY_TARGET_SURFACE && target.target.surface)
    src = static_cast<GhosttySurface *>(
        ghostty_surface_userdata(target.target.surface));

  // The window the action applies to: the target surface's window,
  // or (for app-level actions) any live window. Surface/window work
  // is marshalled onto `win` so it is cancelled if that window goes
  // away; *cross*-captured pointers (e.g. `src` when posting to
  // `win`) are wrapped in QPointer so they're checked at lambda-
  // execution time — a multi-window + tear-off + close race could
  // otherwise UAF.
  const QList<MainWindow *> &live = GhosttyApp::instance().windows();
  MainWindow *win = src ? src->owner()
                        : (live.isEmpty() ? nullptr : live.first());
  QPointer<MainWindow> winp(win);
  QPointer<GhosttySurface> srcp(src);

  // Actions may be dispatched from non-GUI threads, so window-touching
  // work is marshalled onto the GUI thread.
  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      // Mark the surface dirty; the frame timer renders it. No event
      // is queued here — a busy surface would otherwise flood the loop.
      if (src) src->markDirty();
      return true;

    case GHOSTTY_ACTION_NEW_TAB: {
      if (!win) return false;
      // `parent` is a libghostty handle whose lifetime tracks `src`'s.
      // If `src` is gone by the time the lambda runs, drop the parent
      // and create an unparented tab.
      post(win, [winp, srcp]() {
        if (!winp) return;
        winp->newTab(srcp ? srcp->surface() : nullptr);
      });
      return true;
    }

    case GHOSTTY_ACTION_NEW_WINDOW:
      post(qApp, [srcp]() {
        MainWindow::newWindow(srcp ? srcp->surface() : nullptr);
      });
      return true;

    case GHOSTTY_ACTION_NEW_SPLIT: {
      if (!src) return false;
      const ghostty_action_split_direction_e dir = action.action.new_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->splitSurface(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_TAB: {
      if (!src) return false;
      const ghostty_action_close_tab_mode_e mode = action.action.close_tab_mode;
      post(win, [winp, srcp, mode]() {
        if (!winp || !srcp) return;
        winp->closeTabsByMode(srcp, mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setSurfaceTitle(srcp, t);
      });
      return true;
    }

    case GHOSTTY_ACTION_SET_TAB_TITLE: {
      // A manual tab-title override (an empty string clears it).
      if (!src) return true;
      const char *title = action.action.set_tab_title.title;
      const QString t = QString::fromUtf8(title ? title : "");
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setTabTitleOverride(srcp, t);
      });
      return true;
    }

    case GHOSTTY_ACTION_PROMPT_TITLE: {
      const bool tabScope =
          action.action.prompt_title == GHOSTTY_PROMPT_TITLE_TAB;
      // App-target: promote to the active window's current surface so
      // a global keybind can rename even when no surface is the
      // action's explicit target. Mirrors macOS NSApp.mainWindow
      // promotion.
      GhosttySurface *t = src;
      const QList<MainWindow *> &allWindows = GhosttyApp::instance().windows();
      if (!t && !allWindows.isEmpty()) {
        MainWindow *active = qobject_cast<MainWindow *>(qApp->activeWindow());
        if (!active) active = allWindows.first();
        if (active) t = active->currentSurface();
      }
      if (!t) return false;
      QPointer<GhosttySurface> tp(t);
      post(t, [tp, tabScope]() {
        if (tp) tp->promptTitle(tabScope);
      });
      return true;
    }

    case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
      post(win, [winp, srcp]() {
        if (winp) winp->copyTitleToClipboard(srcp);
      });
      return true;

    case GHOSTTY_ACTION_RESET_WINDOW_SIZE:
      post(win, [winp]() {
        if (!winp) return;
        const QSize def = winp->defaultWindowSize();
        winp->resize(def.isValid() ? def : QSize(800, 600));
      });
      return true;

    case GHOSTTY_ACTION_KEY_SEQUENCE: {
      if (!src) return true;
      const ghostty_action_key_sequence_s ks = action.action.key_sequence;
      if (!ks.active) {
        post(src, [srcp]() {
          if (srcp) srcp->endKeySequence();
        });
        return true;
      }
      const QString chord = formatTrigger(ks.trigger);
      post(src, [srcp, chord]() {
        if (srcp) srcp->pushKeySequence(chord);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_TAB: {
      // Performable: return false on a single tab so the chord falls
      // through to the terminal. macOS does the same; GTK gates on
      // tabPage count > 1.
      if (!win || win->tabCount() <= 1) return false;
      const ghostty_action_goto_tab_e tab = action.action.goto_tab;
      post(win, [winp, tab]() {
        if (winp) winp->gotoTab(tab);
      });
      return true;
    }

    case GHOSTTY_ACTION_GOTO_SPLIT: {
      // Performable: return false when the surface has no split
      // sibling — otherwise navigation chords (e.g. ctrl+alt+arrows)
      // eat their own keystrokes on an unsplit surface.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_goto_split_e dir = action.action.goto_split;
      post(win, [winp, srcp, dir]() {
        if (winp && srcp) winp->gotoSplit(srcp, dir);
      });
      return true;
    }

    case GHOSTTY_ACTION_RESIZE_SPLIT: {
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      const ghostty_action_resize_split_s rs = action.action.resize_split;
      post(win, [winp, srcp, rs]() {
        if (winp && srcp) winp->resizeSplit(srcp, rs);
      });
      return true;
    }

    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->equalizeSplits(srcp);
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_FULLSCREEN:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isFullScreen())
          winp->showNormal();
        else
          winp->showFullScreen();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_MAXIMIZE:
      if (!win) return false;
      post(win, [winp]() {
        if (!winp) return;
        if (winp->isMaximized())
          winp->showNormal();
        else
          winp->showMaximized();
      });
      return true;

    case GHOSTTY_ACTION_QUIT:
      post(qApp, []() { MainWindow::closeAllWindows(/*thenQuit=*/true); });
      return true;
    case GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
      // Distinct from QUIT: close-all-windows leaves the process
      // alive when quit-after-last-window-closed is false. macOS
      // makes the same distinction.
      post(qApp,
           []() { MainWindow::closeAllWindows(/*thenQuit=*/false); });
      return true;

    case GHOSTTY_ACTION_QUIT_TIMER: {
      const bool start =
          action.action.quit_timer == GHOSTTY_QUIT_TIMER_START;
      post(qApp,
           [start]() { GhosttyApp::instance().handleQuitTimer(start); });
      return true;
    }

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

    case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
      // Performable: only meaningful inside a split tree.
      if (!src ||
          !qobject_cast<QSplitter *>(src->parentWidget()))
        return false;
      post(win, [winp, srcp]() {
        if (winp && srcp) winp->toggleSplitZoom(srcp);
      });
      return true;

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

    case GHOSTTY_ACTION_INITIAL_SIZE: {
      if (!win) return false;
      const ghostty_action_initial_size_s sz = action.action.initial_size;
      post(win, [winp, sz]() {
        if (!winp) return;
        // The action carries logical pixels; resize() takes the same.
        // The previous code divided by devicePixelRatioF, halving the
        // window on a 2x display.
        const QSize logical(static_cast<int>(sz.width),
                            static_cast<int>(sz.height));
        winp->setDefaultWindowSize(logical);  // for RESET_WINDOW_SIZE
        winp->resize(logical);
      });
      return true;
    }

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      post(win, [winp]() {
        if (winp) winp->close();
      });
      return true;

    case GHOSTTY_ACTION_RING_BELL:
      post(win, [winp, srcp]() {
        if (winp) winp->ringBell(srcp);
      });
      return true;

    case GHOSTTY_ACTION_MOUSE_SHAPE: {
      if (!src) return false;
      const Qt::CursorShape shape =
          mouseShapeToCursor(action.action.mouse_shape);
      post(src, [srcp, shape]() {
        if (srcp) srcp->setShape(shape);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_OVER_LINK: {
      if (!src) return true;
      const ghostty_action_mouse_over_link_s l = action.action.mouse_over_link;
      const QString url =
          l.url && l.len ? QString::fromUtf8(l.url, l.len) : QString();
      post(src, [srcp, url]() {
        if (srcp) srcp->setLinkOverlay(url);
      });
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

    case GHOSTTY_ACTION_MOVE_TAB: {
      // Surface-target only: an app-target MOVE_TAB has no
      // meaningful window to apply to (we'd just pick the first
      // live one arbitrarily). macOS returns false here —
      // performable falls through to the running terminal on no
      // live window.
      if (target.tag != GHOSTTY_TARGET_SURFACE || !src) return false;
      // Performable: a single tab can't be reordered.
      if (!win || win->tabCount() <= 1) return false;
      const int amount = static_cast<int>(action.action.move_tab.amount);
      post(win, [winp, amount]() {
        if (winp) winp->moveTab(amount);
      });
      return true;
    }

    case GHOSTTY_ACTION_MOUSE_VISIBILITY: {
      if (!src) return false;
      const bool visible =
          action.action.mouse_visibility != GHOSTTY_MOUSE_HIDDEN;
      post(src, [srcp, visible]() {
        // setMouseVisible preserves the requested shape so toggling
        // doesn't reset to ArrowCursor.
        if (srcp) srcp->setMouseVisible(visible);
      });
      return true;
    }

    case GHOSTTY_ACTION_RENDERER_HEALTH: {
      const bool unhealthy =
          action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY;
      if (unhealthy)
        std::fprintf(stderr, "[ghastty] renderer reported unhealthy\n");
      // Surface the state in the affected pane so the user sees it
      // without watching stderr. The overlay is a simple per-surface
      // pill (see GhosttySurface::setRendererHealth); it clears as
      // soon as libghostty reports HEALTHY again.
      if (src) post(src, [srcp, unhealthy]() {
        if (srcp) srcp->setRendererHealth(unhealthy);
      });
      return true;
    }

    case GHOSTTY_ACTION_SCROLLBAR: {
      if (!src) return false;
      const ghostty_action_scrollbar_s s = action.action.scrollbar;
      post(src, [srcp, s]() {
        if (srcp) srcp->updateScrollbar(s.total, s.offset, s.len);
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

    case GHOSTTY_ACTION_TOGGLE_VISIBILITY:
      post(qApp, []() { GhosttyApp::instance().toggleVisibility(); });
      return true;

    case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL:
      post(qApp, []() { GhosttyApp::instance().toggleQuickTerminal(); });
      return true;

    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      post(win, [winp, srcp]() {
        if (winp) winp->toggleCommandPalette(srcp);
      });
      return true;

    case GHOSTTY_ACTION_START_SEARCH: {
      if (!src) return true;
      const char *needle = action.action.start_search.needle;
      const QString n = QString::fromUtf8(needle ? needle : "");
      post(src, [srcp, n]() {
        if (srcp) srcp->openSearch(n);
      });
      return true;
    }

    case GHOSTTY_ACTION_END_SEARCH:
      if (src)
        post(src, [srcp]() {
          if (srcp) srcp->closeSearch();
        });
      return true;

    case GHOSTTY_ACTION_SEARCH_TOTAL: {
      if (!src) return true;
      const int total = static_cast<int>(action.action.search_total.total);
      post(src, [srcp, total]() {
        if (srcp) srcp->setSearchTotal(total);
      });
      return true;
    }

    case GHOSTTY_ACTION_SEARCH_SELECTED: {
      if (!src) return true;
      const int sel =
          static_cast<int>(action.action.search_selected.selected);
      post(src, [srcp, sel]() {
        if (srcp) srcp->setSearchSelected(sel);
      });
      return true;
    }

    case GHOSTTY_ACTION_INSPECTOR: {
      if (!src) return true;
      const ghostty_action_inspector_e mode = action.action.inspector;
      post(src, [srcp, mode]() {
        if (srcp) srcp->toggleInspector(mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_RENDER_INSPECTOR: {
      // libghostty already has its own inspector redraw timer, but
      // a wakeup here keeps it tight.
      if (src)
        post(src, [srcp]() {
          if (srcp) srcp->refreshInspector();
        });
      return true;
    }

    case GHOSTTY_ACTION_PRESENT_TERMINAL:
      if (!win) return false;
      post(win, [winp, srcp]() {
        if (winp) winp->presentTerminal(srcp.data());
      });
      return true;

    case GHOSTTY_ACTION_GOTO_WINDOW: {
      // Performable: return false on a single window so the chord
      // falls through to the terminal.
      if (GhosttyApp::instance().windows().size() <= 1) return false;
      const ghostty_action_goto_window_e dir = action.action.goto_window;
      post(qApp,
           [winp, dir]() { MainWindow::gotoWindow(winp.data(), dir); });
      return true;
    }

    case GHOSTTY_ACTION_FLOAT_WINDOW: {
      if (!win) return false;
      const ghostty_action_float_window_e mode = action.action.float_window;
      post(win, [winp, mode]() {
        if (winp) winp->setFloating(mode);
      });
      return true;
    }

    case GHOSTTY_ACTION_TOGGLE_WINDOW_DECORATIONS:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleWindowDecorations();
      });
      return true;

    case GHOSTTY_ACTION_TOGGLE_BACKGROUND_OPACITY:
      if (!win) return false;
      post(win, [winp]() {
        if (winp) winp->toggleBackgroundOpacity();
      });
      return true;

    case GHOSTTY_ACTION_SIZE_LIMIT: {
      if (!win) return false;
      const ghostty_action_size_limit_s sl = action.action.size_limit;
      post(win, [winp, sl]() {
        if (winp)
          winp->setSizeLimits(sl.min_width, sl.min_height,
                              sl.max_width, sl.max_height);
      });
      return true;
    }

    case GHOSTTY_ACTION_CELL_SIZE: {
      if (!win) return false;
      const ghostty_action_cell_size_s cs = action.action.cell_size;
      post(win, [winp, cs]() {
        if (winp) winp->setCellSize(cs.width, cs.height);
      });
      return true;
    }

    case GHOSTTY_ACTION_KEY_TABLE: {
      if (!src) return true;
      // KeyTable is libghostty's bindable-mode mechanism: ACTIVATE
      // pushes a named table onto the binding stack, DEACTIVATE pops
      // one, DEACTIVATE_ALL clears them. Reuse the keybind chord
      // overlay to surface "we're in mode X" to the user — not as
      // pretty as macOS's dedicated badge but adequate.
      const ghostty_action_key_table_s kt = action.action.key_table;
      QString label;
      if (kt.tag == GHOSTTY_KEY_TABLE_ACTIVATE && kt.value.activate.name &&
          kt.value.activate.len) {
        label = QString::fromUtf8(kt.value.activate.name,
                                  static_cast<int>(kt.value.activate.len));
      }
      post(src, [srcp, label]() {
        if (!srcp) return;
        if (label.isEmpty())
          srcp->endKeySequence();
        else
          srcp->pushKeySequence(QStringLiteral("[%1]").arg(label));
      });
      return true;
    }

    case GHOSTTY_ACTION_PWD: {
      // libghostty inherits a child's pwd through the surface tree
      // (ghostty_surface_inherited_config carries it across splits /
      // tabs), and re-fires this action whenever the cwd changes via
      // OSC 7 / shell integration. Stash it on the surface so future
      // chrome (worktree-aware tab decoration, "new tab here") can
      // read it without parsing /proc/<pid>/cwd. Empty pwd from
      // libghostty means "unknown / cleared" — pass it through so the
      // surface can drop a stale value.
      if (!src) return true;
      // libghostty's pwd is a sentinel-terminated Zig slice (see
      // src/apprt/action.zig:Pwd) — its C ptr is always non-null;
      // an "unknown / cleared" cwd is encoded as "".
      const QString s = QString::fromUtf8(action.action.pwd.pwd);
      post(src, [srcp, s]() {
        if (srcp) srcp->setPwd(s);
      });
      return true;
    }

    case GHOSTTY_ACTION_COLOR_CHANGE: {
      // OSC 4/10/11/12 colour change. libghostty already updates its
      // internal palette; the next render will reflect it. Dirty the
      // surface so the change is visible promptly.
      if (src) src->markDirty();
      // OSC 11 flips the effective background, which under
      // `window-theme = ghostty` controls the chrome's light/dark
      // scheme. The config-file `background` hasn't changed, so we
      // can't go through refreshChrome; instead, derive the scheme
      // straight from the action's RGB payload. macOS does the
      // analogous thing in its color-change handler.
      //
      // Note: Qt's setColorScheme is a process-global style hint, so
      // an OSC 11 from any window flips chrome on every window. This
      // matches applyWindowConfig (also a global call) and is the
      // documented Qt 6.8+ behaviour.
      if (action.action.color_change.kind ==
          GHOSTTY_ACTION_COLOR_KIND_BACKGROUND) {
        const ghostty_action_color_change_s c = action.action.color_change;
        post(qApp, [winp, c]() {
          if (!winp) return;
          if (winp->configString("window-theme") != QLatin1String("ghostty"))
            return;
          const double luma = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
          QGuiApplication::styleHints()->setColorScheme(
              luma < 128.0 ? Qt::ColorScheme::Dark : Qt::ColorScheme::Light);
        });
      }
      return true;
    }

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

    case GHOSTTY_ACTION_TOGGLE_TAB_OVERVIEW:
      // Tab overview is GTK's adw.TabOverview — a thumbnail grid of
      // tabs. Qt has no built-in equivalent and an ad-hoc Qt port
      // would be a feature in its own right; acknowledge for now.
      return true;

    case GHOSTTY_ACTION_SHOW_GTK_INSPECTOR:
      // GTK-only debug action; no analogue.
      return true;

    case GHOSTTY_ACTION_SHOW_ON_SCREEN_KEYBOARD:
      // libghostty defines this for iOS / on-screen-keyboard apprts.
      // Linux desktops have a system-managed virtual keyboard (e.g.
      // KDE's vkbd, GNOME's caribou) that the user toggles
      // out-of-band; nothing for the apprt to do. Acknowledge so
      // the keybind isn't reported as unhandled.
      return true;

    case GHOSTTY_ACTION_UNDO:
      post(qApp, []() { MainWindow::undoLastClose(); });
      return true;

    case GHOSTTY_ACTION_REDO:
      post(qApp, []() { MainWindow::redoLastClose(); });
      return true;

    default:
      return false;
  }
}

}  // namespace actions
