#include "ActionDispatcher.h"

#include <QApplication>
#include <QGuiApplication>
#include <QString>
#include <QStringLiteral>
#include <QStyleHints>
#include <Qt>

#include "../app/GhosttyApp.h"
#include "../GhosttySurface.h"
#include "../MainWindow.h"
#include "../Util.h"

namespace actions {

bool handleChrome(const Context &ctx, const ghostty_action_s &action) {
  MainWindow *win = ctx.win;
  GhosttySurface *src = ctx.src;
  QPointer<MainWindow> winp = ctx.winp;
  QPointer<GhosttySurface> srcp = ctx.srcp;

  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      // Mark the surface dirty; the frame timer renders it. No event
      // is queued here — a busy surface would otherwise flood the loop.
      if (src) src->markDirty();
      return true;

    case GHOSTTY_ACTION_SET_TITLE: {
      const char *title = action.action.set_title.title;
      if (!title || !src) return true;
      const QString t = QString::fromUtf8(title);
      post(win, [winp, srcp, t]() {
        if (winp && srcp) winp->setSurfaceTitle(srcp, t);
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

    case GHOSTTY_ACTION_SCROLLBAR: {
      if (!src) return false;
      const ghostty_action_scrollbar_s s = action.action.scrollbar;
      post(src, [srcp, s]() {
        if (srcp) srcp->updateScrollbar(s.total, s.offset, s.len);
      });
      return true;
    }

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

    default:
      return false;
  }
}

}  // namespace actions
