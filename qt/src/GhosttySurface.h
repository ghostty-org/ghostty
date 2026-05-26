#pragma once

#include <atomic>
#include <cstdint>
#include <memory>

#include <QImage>
#include <QMutex>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <QWidget>

#include "ghostty.h"
#include "vulkan/Host.h"

namespace wayland {
class SubsurfacePresenter;
}
namespace opengl {
class EglDmabufTarget;
}

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
class QPainter;
class OverlayScrollbar;

// One Ghostty terminal pane.
//
// Terminal pixels reach the screen via a wl_subsurface attached to
// the top-level QWindow's wl_surface (see wayland::SubsurfacePresenter).
// libghostty's renderer (Vulkan or OpenGL, picked at compile time
// via GHASTTY_USE_VULKAN) hands us a dmabuf fd per frame; we wrap
// it in a wl_buffer via zwp_linux_dmabuf_v1 and the compositor
// scans it out directly — no readback, no QPainter blit for the
// terminal area. Each pane in a split is a sibling subsurface
// under the same top-level wl_surface, positioned at its offset
// within the top-level via setPosition.
//
// This QWidget itself keeps WA_TranslucentBackground so the
// terminal area of the parent surface is transparent (the
// subsurface below shows through) and chrome (SearchBar,
// overlays, scrollbar) painted in paintEvent stays visible on top.
//
// Legacy fallback: if the compositor lacks the required Wayland
// globals (linux-dmabuf-v1, viewporter, subcompositor) or the
// renderer reports image_backed=false (NVIDIA Vulkan's
// legacy_copy path on this branch), the frame goes through a
// mmap+memcpy+QImage+QPainter::drawImage path instead.
class GhosttySurface : public QWidget, public vulkan::PresentSink {
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
  void clearCommandNotify() { m_notifyOnCommand = false; }
  bool commandNotifyArmed() const { return m_notifyOnCommand; }
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
  // Force an extra inspector repaint (RENDER_INSPECTOR action). The
  // inspector window has its own ~30Hz redraw timer; this just kicks
  // a Qt update so a libghostty-driven invalidation is visible
  // promptly.
  void refreshInspector();

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

  // Set the cursor shape from the libghostty MOUSE_SHAPE action.
  // Tracks the requested shape so MOUSE_VISIBILITY toggles can hide
  // and restore without forgetting it. macOS+GTK preserve shape
  // across visibility changes; the previous Qt code clobbered it
  // with Qt::ArrowCursor on un-hide.
  void setShape(Qt::CursorShape shape);
  // Hide or show the mouse cursor without changing its shape.
  void setMouseVisible(bool visible);

  // Show / hide the dedicated MOUSE_OVER_LINK URL overlay (a small
  // pill at the surface's bottom-left). Replaces the prior
  // setToolTip-based hint, which followed the cursor and only
  // appeared after the OS hover delay. macOS + GTK both render a
  // dedicated overlay.
  void setLinkOverlay(const QString &url);

  // Set / clear the renderer-health overlay. Driven by the
  // RENDERER_HEALTH action: the prior implementation only logged to
  // stderr, so a user whose GPU dropped the renderer never knew. A
  // small red pill at the surface's top-right surfaces the state.
  void setRendererHealth(bool unhealthy);

  // Tracked working directory (from the PWD action). Updated whenever
  // libghostty notifies the apprt that the surface's cwd has changed —
  // either at spawn (from inherited config) or via shell integration /
  // OSC 7. The value is currently stored only; future chrome
  // (worktree-aware tab decoration, "new tab here", proxy icon) reads
  // it via pwd().
  void setPwd(const QString &pwd);
  const QString &pwd() const { return m_pwd; }

  // Apprt-side entry point for the Vulkan `present` callback. Fires
  // on the renderer thread. Parks the dmabuf descriptor under
  // `m_pendingMutex` (plus, for the legacy fallback path, an
  // mmap+memcpy'd QImage) and wakes the GUI thread via
  // `QMetaObject::invokeMethod(this, drainVulkan, Qt::QueuedConnection)`.
  // The GUI thread either commits the dmabuf to the wl_subsurface
  // (zero-copy) or paints the QImage (fallback). The dropped-frame
  // counter `m_droppedFrames` makes any genuine queue-loss visible
  // (zero in the steady state).
  void presentVulkanDmabuf(
      int dmabuf_fd,
      quint32 drm_format,
      quint64 drm_modifier,
      quint32 width,
      quint32 height,
      quint32 stride,
      bool image_backed);

  // `vulkan::PresentSink` override. Thin forward to
  // `presentVulkanDmabuf` so the existing implementation (and its
  // doc comment above) stays where it is. Called by `vulkan::Host`'s
  // present-callback trampoline on the libghostty renderer thread.
  void presentDmabuf(int dmabuf_fd, std::uint32_t drm_format,
                      std::uint64_t drm_modifier, std::uint32_t width,
                      std::uint32_t height, std::uint32_t stride,
                      bool image_backed) override {
    presentVulkanDmabuf(dmabuf_fd, drm_format, drm_modifier, width,
                         height, stride, image_backed);
  }

  // GUI-thread drain step: hands the most recent pending frame
  // either to the SubsurfacePresenter (zero-copy path) or the
  // QImage paint pipeline (fallback). Idempotent: returns
  // immediately if nothing's pending. Invoked from the polling
  // safety net AND from queued invocations triggered by the
  // renderer thread.
  Q_INVOKABLE void drainVulkan();

  // Force a wl_surface.commit on our parent native window via the
  // QtWaylandClient::QWaylandWindow private API. The wl_subsurface
  // is in sync mode, so child state changes only apply when the
  // parent commits — but Qt's backing-store flush doesn't fire for
  // a translucent QWidget with no paint damage. Calling this after
  // every child commit ensures the cached child state actually
  // reaches the compositor. Returns false on non-Wayland QPA or if
  // the cast fails (no Qt private headers available).
  bool forceParentCommit();

protected:
  bool event(QEvent *) override;
  void paintEvent(QPaintEvent *) override;
  void resizeEvent(QResizeEvent *) override;
  void moveEvent(QMoveEvent *) override;

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
  void leaveEvent(QEvent *) override;       // libghostty hover reset
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
  void paintResizeOverlay(QPainter &painter);  // draws ^ in paintEvent
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

  // Private offscreen GL context libghostty renders into. Null for
  // the Vulkan-backed renderer (libghostty hands frames back via a
  // dmabuf fd to the apprt's `present` callback — no GL involved).
  QOpenGLContext *m_context = nullptr;
  QOffscreenSurface *m_offscreen = nullptr;
  QOpenGLFramebufferObject *m_fbo = nullptr;
  // Dmabuf-exporting GL target (zero-copy path). Set when the EGL
  // display advertises EGL_MESA_image_dma_buf_export and the
  // wl_subsurface presenter is up; the renderer draws into this
  // texture-backed framebuffer and we attach its fd straight to the
  // subsurface — no glReadPixels, no QImage, no QPainter blit.
  // Stays null when EGL support is missing or the subsurface failed
  // to bring up, and the legacy m_fbo path runs as fallback.
  std::unique_ptr<opengl::EglDmabufTarget> m_eglTarget;
  QImage m_image;                      // last frame, read back from m_fbo

  // True when this surface is using the Vulkan platform. The
  // paintEvent uses this to draw a visible placeholder when no
  // dmabuf has been imported yet; once
  // `presentVulkanDmabuf` has filled `m_image` the placeholder
  // gives way to the actual rendered content.
  bool m_useVulkan = false;

  // Cross-thread frame handoff for the Vulkan path. The renderer
  // thread calls `presentVulkanDmabuf` with a borrowed dmabuf fd
  // and posts a queued `drainVulkan` invocation; the GUI thread
  // runs `drainVulkan` and routes the parked descriptor through
  // either the wl_subsurface presenter (zero-copy) or the
  // mmap+memcpy+QImage fallback. The dropped-frame counter
  // (`m_droppedFrames`) surfaces any queue-loss that ever happens
  // in practice — the earlier safety-net polling timer was
  // removed once delivery was shown to be reliable.
  //
  // `m_useSubsurface` is set once on the GUI thread when the
  // presenter comes up; the renderer thread reads it acquire-style
  // to decide which path to populate per frame.
  std::atomic<bool> m_useSubsurface{false};
  // Subsurface (zero-copy) path: renderer thread parks the
  // borrowed-fd descriptor here; GUI-thread timer hands it to the
  // presenter.
  struct PendingDmabuf {
    int fd = -1;
    quint32 drm_format = 0;
    quint64 drm_modifier = 0;
    quint32 width = 0;
    quint32 height = 0;
    quint32 stride = 0;
  };
  PendingDmabuf m_pendingDmabuf;
  // Legacy (mmap+memcpy) path: kept as a fallback when the
  // presenter isn't available (e.g. compositor missing
  // linux-dmabuf-v1). When the subsurface path is active this stays
  // null and paintEvent skips its blit.
  QImage m_pending;
  QMutex m_pendingMutex;

  // GL objects for the alpha-premultiply pass.
  QOpenGLShaderProgram *m_premultProg = nullptr;
  QOpenGLVertexArrayObject *m_premultVao = nullptr;

  int m_fbw = 0;                       // framebuffer size, device pixels
  int m_fbh = 0;
  // DPR the framebuffer was sized at. Atomic because the renderer
  // thread reads it from `presentVulkanDmabuf` to tag the legacy
  // QImage path while the GUI thread writes it from
  // `syncSurfaceSize`. `double` writes aren't guaranteed atomic
  // across threads on every architecture; std::atomic<double> uses
  // CAS-loop fallbacks where needed.
  std::atomic<double> m_fbDpr{1.0};    // DPR the framebuffer was sized at

  QLabel *m_exitOverlay = nullptr;     // "process exited" banner; lazily made
  QLabel *m_keySeqOverlay = nullptr;   // pending keybind chord; lazily made
  QLabel *m_linkOverlay = nullptr;     // MOUSE_OVER_LINK URL hint; lazily made
  QLabel *m_healthOverlay = nullptr;   // RENDERER_HEALTH=unhealthy; lazily made
  QStringList m_keySeq;                // accumulated pending chords
  // The transient "cols × rows" overlay is painted directly in
  // paintEvent (not a child widget) so it is part of the terminal frame
  // and cannot be covered or flicker while the surface repaints during
  // a resize. m_resizeHideTimer clears m_resizeOverlayVisible when the
  // resize stops; m_resizeOverlayText is the text to draw.
  QTimer *m_resizeHideTimer = nullptr;
  QString m_resizeOverlayText;
  bool m_resizeOverlayVisible = false;
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
  // Set when a left-click grabbed focus from elsewhere; cleared on
  // the matching mouse-up so the click that grabbed focus isn't
  // also reported to the running program. macOS + GTK do the same
  // (suppressNextLeftMouseUp / suppress_left_mouse_release).
  bool m_suppressNextLeftRelease = false;
  // Last requested cursor shape (from MOUSE_SHAPE) and visibility
  // (from MOUSE_VISIBILITY). Tracked separately so toggling
  // visibility doesn't reset the shape.
  Qt::CursorShape m_cursorShape = Qt::IBeamCursor;
  bool m_mouseVisible = true;
  // Tracks whether the prior inputMethodEvent reported active preedit.
  // Used to distinguish a real post-composition commit (forward to the
  // terminal) from the duplicate ASCII commit that Wayland's
  // text-input-v3 fires alongside a keyPressEvent (drop it — the key
  // event will deliver the same text).
  bool m_hadPreedit = false;
  std::atomic<bool> m_dirty{false};    // a frame render is pending
  // Tracked working directory from the PWD action; empty until the
  // first PWD notification (libghostty fires one at spawn from the
  // inherited config, then on every cwd change).
  QString m_pwd;

  // Wayland subsurface for the GPU-direct present path. Lazily
  // created on first `QEvent::Show` once the top-level QWindow
  // exists; null if the compositor lacks the required globals
  // (linux-dmabuf-v1, viewporter, subcompositor), in which case
  // the legacy mmap+memcpy+QImage+QPainter path renders pixels.
  std::unique_ptr<wayland::SubsurfacePresenter> m_subsurfacePresenter;
  // Per-surface latch for the first-dmabuf log breadcrumb so each
  // pane / split prints its own line on first frame. Atomic because
  // the renderer thread is what hits `presentVulkanDmabuf` and the
  // first-frame check would otherwise race a sibling renderer
  // thread on the same widget — relaxed CAS means at most one log
  // line per surface, even under concurrent first frames.
  std::atomic<bool> m_loggedFirstFrame{false};

  // Count of frames overwritten in `m_pendingDmabuf` before the GUI
  // thread drained them. Each overwrite is a missed compositor
  // present — fd lifetime is unaffected (libghostty owns the
  // dmabuf), but a sustained nonzero rate means the GUI thread is
  // falling behind the renderer. Logged sparsely from
  // `presentVulkanDmabuf`.
  std::atomic<std::uint64_t> m_droppedFrames{0};
  // Set true on QEvent::Hide, false on QEvent::Show. Guards the
  // present path against a race where libghostty's renderer thread
  // fires one more frame after we've detached the subsurface
  // buffer on Hide — without this gate, that stray frame re-
  // attaches a buffer and the now-inactive tab ghosts on top of
  // whatever tab the user just switched to. `std::atomic` because
  // the renderer thread reads it in `presentVulkanDmabuf` /
  // `drainVulkan` while the GUI thread writes from event().
  std::atomic<bool> m_hidden{false};
};
