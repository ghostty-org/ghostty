#pragma once

#include <atomic>

#include <QImage>
#include <QPointer>
#include <QStringList>
#include <QWidget>

#include "ghostty.h"

class MainWindow;
class QContextMenuEvent;
class QDragEnterEvent;
class QDropEvent;
class QEnterEvent;
class QTimer;
class InspectorWindow;
class SearchBar;
class QInputMethodEvent;
class QKeySequence;
class QLabel;
class QOffscreenSurface;
class QOpenGLContext;
class QOpenGLFramebufferObject;
class QOpenGLShaderProgram;
class QOpenGLVertexArrayObject;
class OverlayScrollbar;

// One Ghostty terminal pane.
//
// libghostty's OpenGL renderer draws the terminal into an offscreen
// framebuffer owned by a private QOpenGLContext (there is no on-screen
// GL surface). Each frame is read back into a QImage and painted with
// QPainter. That keeps this an ordinary translucent QWidget, so it
// embeds in the QTabWidget / QSplitter tree and its transparent
// background composites to the desktop exactly like the rest of the
// widget chrome — avoiding QOpenGLWidget (composites opaque on Wayland)
// and an embedded QOpenGLWindow (does not present when embedded).
class GhosttySurface : public QWidget {
  Q_OBJECT

public:
  // `parent_surface` (may be null) is the surface whose working
  // directory etc. a new surface should inherit.
  GhosttySurface(ghostty_app_t app, MainWindow *owner,
                 ghostty_surface_t parent_surface);
  ~GhosttySurface() override;

  ghostty_surface_t surface() const { return m_surface; }
  MainWindow *owner() const { return m_owner; }
  // Reassign the owning window (used when a tab is torn off into one).
  void setOwner(MainWindow *owner) { m_owner = owner; }

  // Show a dismissable "process exited" overlay over the terminal. The
  // surface stays open until the user dismisses it (key or click).
  void showChildExited(int exitCode);

  // Arm a one-shot desktop notification for the next command to finish
  // (context-menu item); consumeCommandNotify reads-and-clears the flag.
  void armCommandNotify() { m_notifyOnCommand = true; }
  bool consumeCommandNotify() {
    const bool armed = m_notifyOnCommand;
    m_notifyOnCommand = false;
    return armed;
  }

public:
  // Render coalescing: markDirty() flags the surface (called from the
  // RENDER action, possibly off-thread); renderIfDirty(), called once a
  // frame by MainWindow, does the actual render.
  void markDirty() { m_dirty.store(true); }
  void renderIfDirty();

  // Reflect a libghostty SCROLLBAR action: total scrollback rows, the
  // viewport-top row, and the visible row count.
  void updateScrollbar(uint64_t total, uint64_t offset, uint64_t len);

  // Open the title-change dialog (PROMPT_TITLE action / context menu);
  // `tabScope` picks the tab vs surface title.
  void promptTitle(bool tabScope);

  // Pending-keybind chord overlay, driven by the KEY_SEQUENCE action:
  // pushKeySequence appends a chord, endKeySequence clears the overlay.
  void pushKeySequence(const QString &chord);
  void endKeySequence();

  // Show/hide/toggle the terminal inspector window (INSPECTOR action).
  void toggleInspector(ghostty_action_inspector_e mode);

  // In-terminal search (the *_SEARCH actions): openSearch shows the
  // search bar (optionally pre-filled), closeSearch hides it, and the
  // setSearch* calls mirror libghostty's reported match counters.
  void openSearch(const QString &prefill);
  void closeSearch();
  void setSearchTotal(int total);
  void setSearchSelected(int selected);

  // Bell `border` feature: briefly flash a border over the terminal.
  void flashBorder();
  // Bell `title` feature: mark/unmark an unacknowledged bell. MainWindow
  // prefixes the tab title while any surface in the tab is marked.
  void setBellTitle(bool marked) { m_bellTitle = marked; }
  bool bellTitle() const { return m_bellTitle; }

protected:
  bool event(QEvent *) override;
  void paintEvent(QPaintEvent *) override;
  void resizeEvent(QResizeEvent *) override;

  // Disable Qt's Tab/Backtab focus traversal so those keys reach
  // keyPressEvent and can be forwarded to the terminal.
  bool focusNextPrevChild(bool) override { return false; }

  void keyPressEvent(QKeyEvent *) override;
  void keyReleaseEvent(QKeyEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void contextMenuEvent(QContextMenuEvent *) override;
  void dragEnterEvent(QDragEnterEvent *) override;
  void dropEvent(QDropEvent *) override;
  void wheelEvent(QWheelEvent *) override;
  void enterEvent(QEnterEvent *) override;  // focus-follows-mouse
  void focusInEvent(QFocusEvent *) override;
  void focusOutEvent(QFocusEvent *) override;

  // IME composition: preedit text is forwarded to libghostty for inline
  // display; committed text is inserted as input.
  void inputMethodEvent(QInputMethodEvent *) override;
  QVariant inputMethodQuery(Qt::InputMethodQuery) const override;

private:
  bool makeCurrent();
  void syncSurfaceSize();
  void renderTerminal();
  void layoutScrollbar();          // position the scrollbar at the edge
  bool scrollbarAllowed() const;   // false when `scrollbar = never`
  void flashScrollbar();           // reveal the overlay scrollbar, arm hide
  void buildExitOverlay(int exitCode);
  void showResizeOverlay();        // transient grid-size overlay on resize
  void repositionResizeOverlay();  // re-place overlay for current widget size
  void layoutSearchBar();          // position the search bar at the top edge
  void sendKey(QKeyEvent *, ghostty_input_action_e action);
  void commitText(const QString &text);
  void sendMouseButton(QMouseEvent *, ghostty_input_mouse_state_e state);
  bool rightClickOpensMenu(QMouseEvent *ev) const;

  // The keybind currently bound to `action` (for context-menu hints),
  // or an empty sequence if none / not displayable.
  QKeySequence shortcutFor(const char *action) const;

  // Premultiply the framebuffer's alpha; only used when a custom shader
  // is configured (see GhosttySurface.cpp).
  void initPremultiply();
  void premultiplyFramebuffer();

  // libghostty GL platform callbacks (all run on the GUI thread).
  static void *glGetProcAddress(void *ud, const char *name);
  static void glMakeCurrent(void *ud);
  static void glReleaseCurrent(void *ud);
  static void glPresent(void *ud);

  ghostty_app_t m_app;                 // shared; owned by MainWindow
  MainWindow *m_owner;                 // not owned
  ghostty_surface_t m_parentSurface;   // inherited-config source; may be null
  ghostty_surface_t m_surface = nullptr;

  // Private offscreen GL context libghostty renders into.
  QOpenGLContext *m_context = nullptr;
  QOffscreenSurface *m_offscreen = nullptr;
  QOpenGLFramebufferObject *m_fbo = nullptr;
  QImage m_image;                      // last frame, read back from m_fbo

  // GL objects for the alpha-premultiply pass.
  QOpenGLShaderProgram *m_premultProg = nullptr;
  QOpenGLVertexArrayObject *m_premultVao = nullptr;

  int m_fbw = 0;                       // framebuffer size, device pixels
  int m_fbh = 0;
  double m_fbDpr = 1.0;                // DPR the framebuffer was sized at

  QLabel *m_exitOverlay = nullptr;     // "process exited" banner; lazily made
  QLabel *m_keySeqOverlay = nullptr;   // pending keybind chord; lazily made
  QStringList m_keySeq;                // accumulated pending chords
  QLabel *m_resizeOverlay = nullptr;   // transient "cols x rows"; lazily made
  QTimer *m_resizeHideTimer = nullptr; // auto-hides m_resizeOverlay
  bool m_firstGridSeen = false;        // for `resize-overlay = after-first`
  int m_lastCols = 0;                  // last grid size, to detect changes
  int m_lastRows = 0;
  SearchBar *m_searchBar = nullptr;    // in-terminal search; lazily made
  // Terminal inspector window; lazily made. QPointer so a WM-driven
  // close (treated as hide) or a parent-destroyed cascade leaves the
  // pointer null instead of dangling.
  QPointer<InspectorWindow> m_inspectorWindow;
  OverlayScrollbar *m_scrollbar = nullptr;  // floating scrollback scrollbar
  bool m_scrollAtBottom = true;        // viewport is following the buffer tail
  bool m_notifyOnCommand = false;      // one-shot: notify on next cmd finish
  bool m_bellFlash = false;            // bell `border` flash in progress
  bool m_bellTitle = false;            // unacknowledged bell `title` mark
  // Tracks whether the prior inputMethodEvent reported active preedit.
  // Used to distinguish a real post-composition commit (forward to the
  // terminal) from the duplicate ASCII commit that Wayland's
  // text-input-v3 fires alongside a keyPressEvent (drop it — the key
  // event will deliver the same text).
  bool m_hadPreedit = false;
  std::atomic<bool> m_dirty{false};    // a frame render is pending
};
