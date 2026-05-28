#include "GhosttySurface.h"

#include "config/Config.h"
#include "input/XkbState.h"
#include "InspectorWindow.h"
#include "MainWindow.h"
#include "OverlayScrollbar.h"
#include "SearchBar.h"
#include "TabWidget.h"
#include "Util.h"
#ifdef GHASTTY_USE_VULKAN
#include "vulkan/Host.h"
#else
#include "opengl/EglDmabufTarget.h"
#endif
#include "wayland/DmabufRegistry.h"
#include "wayland/SubsurfacePresenter.h"

// Qt private Wayland headers — give us QtWaylandClient::QWaylandWindow,
// the QPA implementation for native Wayland QWindows. We cast our
// QWindow's QPA pointer to it and call commit() directly to force a
// parent wl_surface.commit; Qt's own backing-store flush doesn't
// fire for our translucent QWidget so the wl_subsurface (in sync
// mode) would never see its cached state applied otherwise. Built
// against Qt6::WaylandClientPrivate (see qt/CMakeLists.txt).
#include <QtWaylandClient/private/qwaylandwindow_p.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

#include <sys/mman.h>
#include <unistd.h>  // ::dup, ::close — own the dmabuf fd's lifetime

#include <QByteArray>
#include <QClipboard>
#include <QThread>
#include <QContextMenuEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QFocusEvent>
#include <QFont>
#include <QFontMetrics>
#include <QGuiApplication>
#include <QPlatformSurfaceEvent>
#include <QIcon>
#include <QInputDialog>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QKeySequence>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMimeData>
#include <QMouseEvent>
#include <QOffscreenSurface>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QOpenGLExtraFunctions>
#include <QOpenGLFunctions>
#include <QOpenGLShaderProgram>
#include <QOpenGLVertexArrayObject>
#include <QPainter>
#include <QMoveEvent>
#include <QResizeEvent>
#include <QSplitter>
#include <QString>
#include <QStringList>
#include <QSurfaceFormat>
#include <QTimer>
#include <QUrl>
#include <QWheelEvent>

GhosttySurface::GhosttySurface(ghostty_app_t app, MainWindow *owner,
                               ghostty_surface_t parent_surface)
    : m_app(app), m_owner(owner), m_parentSurface(parent_surface) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);  // deliver motion events for hover/link detection
  setAttribute(Qt::WA_InputMethodEnabled, true);  // IME composition
  setAcceptDrops(true);                           // file / text drops

  // Scrollback scrollbar: a floating overlay driven by SCROLLBAR
  // actions. Dragging it runs libghostty's scroll_to_row.
  m_scrollbar = new OverlayScrollbar(this);
  connect(m_scrollbar, &OverlayScrollbar::scrollToRow, this,
          [this](int row) {
            if (!m_surface) return;
            const QByteArray a =
                "scroll_to_row:" + QByteArray::number(row);
            ghostty_surface_binding_action(m_surface, a.constData(),
                                           a.size());
          });
  // The widget paints a per-pixel-alpha QImage of the terminal; a
  // translucent background lets that alpha reach the desktop.
  setAttribute(Qt::WA_TranslucentBackground);
  // NOTE: deliberately NOT calling setAttribute(Qt::WA_NativeWindow).
  // Forcing a per-pane native QWindow caused Qt to complain
  // ("QWidgetWindow must be a top level window") and rendered
  // split panes black: Qt's QSplitter-embedded child widgets can't
  // be shelled cleanly on Wayland. Instead, every GhosttySurface
  // shares the top-level QWindow's wl_surface (got via
  // `window()->windowHandle()` in the Show handler). Each pane's
  // wl_subsurface attaches to that shared parent, positioned at
  // the pane's offset within the top-level via `setPosition`.

  // Pick the renderer up-front so the rest of the surface setup
  // (GL context vs. Vulkan host) only touches the path we'll
  // actually use. The choice is wired in at compile time via the
  // `GHASTTY_USE_VULKAN` definition (set by CMake when
  // `GHASTTY_VARIANT=vulkan`), because libghostty itself is built
  // for exactly one renderer per .so and this binary is linked
  // against one of them — a runtime env-var override could only
  // produce a mismatch crash. Mixing GL+VK on the same process
  // (e.g. NVIDIA's coexistence on one Wayland surface) is also
  // reportedly fragile.
  // The "use Vulkan" decision is purely compile-time on this fork:
  // each binary is linked against exactly one libghostty.so variant
  // (opengl or vulkan). A runtime fallback would just mis-initialize
  // the surface against the wrong renderer.
  ghostty_surface_config_s sc =
      m_parentSurface
          ? ghostty_surface_inherited_config(m_parentSurface,
                                             GHOSTTY_SURFACE_CONTEXT_TAB)
          : ghostty_surface_config_new();

#ifdef GHASTTY_USE_VULKAN
  {
    vulkan::Host *vk_host = vulkan::Host::instance();
    if (vk_host == nullptr) {
      // libghostty was compiled with -Drenderer=vulkan and there's
      // no GL fallback available: libghostty's GL surface init
      // would crash on the first call. Fail loudly here.
      std::fprintf(stderr,
                   "[ghastty] Vulkan host bring-up failed (no Vulkan 1.3 "
                   "GPU with VK_KHR_external_memory_fd + "
                   "VK_EXT_external_memory_dma_buf). The Vulkan variant "
                   "of libghostty has no OpenGL fallback — exiting.\n");
      std::abort();
    }
    // Prime the compositor dmabuf modifier registry on THIS thread
    // (the GUI thread — surface ctors run there). The renderer
    // thread will read it lock-free via the
    // `get_supported_modifiers` platform callback. Idempotent if
    // another surface already primed it. Same lifetime guarantee
    // we used to achieve inside `Host::instance`'s `call_once`,
    // but kept on the wayland side of the layering boundary.
    ::wayland::primeDmabufModifierRegistry();
    m_useVulkan = true;
    sc.platform_tag = GHOSTTY_PLATFORM_VULKAN;
    sc.platform.vulkan = vk_host->asPlatform(this);

    // GUI-thread frame delivery is driven by
    // `QMetaObject::invokeMethod` (Qt::QueuedConnection) from
    // `presentVulkanDmabuf`. The earlier 2 ms safety-net polling
    // timer was removed once delivery was shown to be reliable;
    // any genuine loss is visible via the dropped-frame counter
    // logged from `presentVulkanDmabuf`.
  }
#else
  {
    // OpenGL path: stand up the private context + offscreen FBO
    // libghostty's GL renderer draws into.
    m_context = new QOpenGLContext(this);
    m_context->setFormat(QSurfaceFormat::defaultFormat());
    if (!m_context->create()) {
      std::fprintf(stderr, "[ghastty] GL context creation failed\n");
      return;
    }
    m_offscreen = new QOffscreenSurface(nullptr, this);
    m_offscreen->setFormat(m_context->format());
    m_offscreen->create();

    if (!makeCurrent()) {
      std::fprintf(stderr, "[ghastty] makeCurrent failed\n");
      return;
    }

    // A placeholder framebuffer; resizeEvent installs the real size.
    QOpenGLFramebufferObjectFormat fmt;
    fmt.setInternalTextureFormat(GL_RGBA8);
    m_fbw = m_fbh = 16;
    m_fbo = new QOpenGLFramebufferObject(QSize(m_fbw, m_fbh), fmt);

    sc.platform_tag = GHOSTTY_PLATFORM_OPENGL;
    sc.platform.opengl.userdata = this;
    sc.platform.opengl.get_proc_address = glGetProcAddress;
    sc.platform.opengl.make_current = glMakeCurrent;
    sc.platform.opengl.release_current = glReleaseCurrent;
    sc.platform.opengl.present = glPresent;
  }
#endif
  sc.userdata = this;
  sc.scale_factor = devicePixelRatioF();

  m_surface = ghostty_surface_new(m_app, &sc);
  if (!m_surface) {
    std::fprintf(stderr, "[ghastty] ghostty_surface_new failed\n");
    return;
  }

  // Immediately push a real surface size into libghostty so the
  // newly-spawned shell + PTY don't start at the 1×1 sentinel default.
  // Why this matters: ghostty_surface_new forks the shell process as
  // part of init; the PTY's winsize is read by the shell (and by tools
  // like fastfetch) IMMEDIATELY on startup. If the PTY is 1×1 at fork
  // time, fastfetch sees a 0-column terminal and falls back to rendering
  // its image at the source pixel dimensions — visible to the user as a
  // huge image filling the window on the 2nd tab (intermittent: the 1st
  // tab's slower cold-start gives the syncSurfaceSize from Show enough
  // time to land first; on 2nd-tab open everything is primed and
  // fastfetch races ahead of Show).
  //
  // For new tabs, inherit the parent surface's pixel size — that's
  // exactly the tab area's geometry, so it's already correct. For the
  // first surface (no parent) we can't do much here because the widget
  // hasn't been laid out yet (width()/height() are sizeHint defaults);
  // the existing Show + resizeEvent paths handle that case fine.
  if (m_parentSurface) {
    const ghostty_surface_size_s parent_sz =
        ghostty_surface_size(m_parentSurface);
    if (parent_sz.width_px > 1 && parent_sz.height_px > 1) {
      ghostty_surface_set_size(m_surface, parent_sz.width_px,
                               parent_sz.height_px);
    }
  }

  // initPremultiply creates a `QOpenGLVertexArrayObject` against the
  // private GL context. That context doesn't exist on the Vulkan
  // path, so skip the setup. The Vulkan renderer handles alpha
  // pre-multiplication itself (or doesn't need to — the dmabuf
  // contents are already in the host's expected order).
  if (!m_useVulkan && m_owner->needsPremultiply()) initPremultiply();

  // (No first-frame ctor gate — every variant we've tried so
  // far either captures a wrong-size frame and lets wp_viewport
  // stretch it over the kitty image quad, or doesn't actually
  // hide the transparent flash. Tracking proper fix via agent
  // investigation; for now the transparent flash on tab open
  // is the lesser evil vs broken image rendering.)
}

GhosttySurface::~GhosttySurface() {
  // The inspector window holds m_surface; destroy it before m_surface.
  // QPointer auto-nulls on a destroyed QObject, so .data() is safe.
  delete m_inspectorWindow.data();

  // Close any parked dup'd dmabuf fd left over from a renderer-
  // thread present that the GUI thread never got to drain (e.g.
  // surface destruction races a late renderer frame). The dup is
  // owned by us (created in presentVulkanDmabuf), so we have to
  // close it explicitly.
  {
    QMutexLocker lock(&m_pendingMutex);
    if (m_pendingDmabuf.fd >= 0) {
      ::close(m_pendingDmabuf.fd);
      m_pendingDmabuf.fd = -1;
    }
  }

  // Wake the renderer thread if it's parked in presentVulkanDmabuf's
  // CV wait BEFORE we hand the surface to libghostty for teardown.
  // ghostty_surface_free below shuts down + joins the renderer
  // thread; if that thread is blocked on our CV, the join either
  // hangs for our 100 ms timeout (best case) or races our mutex /
  // CV destruction once this body returns (worst case → SEGV when
  // the renderer wakes from the timeout and touches the destroyed
  // mutex). The predicate also checks m_hidden so the renderer
  // bails out without parking another frame.
  m_hidden.store(true, std::memory_order_release);
  {
    std::lock_guard<std::mutex> lg(m_compositorMutex);
    m_compositorReady = true;
  }
  m_compositorCv.notify_all();

  // GL teardown must happen with the context current. If makeCurrent
  // fails (e.g. the ctor failed before m_context could be created), we
  // still free m_surface — it carries no GL state of its own — and we
  // still delete the FBO and premult helpers. Deleting QOpenGL* objects
  // without a current context leaks the GL-side resource but is safe
  // CPU-side; that's the best we can do when the context is gone.
  const bool current = makeCurrent();
  if (m_surface) ghostty_surface_free(m_surface);
  delete m_fbo;
  delete m_premultProg;
  delete m_premultVao;
#ifndef GHASTTY_USE_VULKAN
  // m_eglTarget owns a GL texture + framebuffer + EGLImage + dmabuf
  // fd. Reset it explicitly here, while the context is (best-effort)
  // current — the implicit unique_ptr destructor would fire AFTER
  // doneCurrent() below, leaking the GL-side handles.
  // If makeCurrent failed (m_offscreen invalidated mid-teardown,
  // exactly the race the PlatformSurface handler also hits), the
  // GL texture+FBO leak — the fd is closed by the dtor regardless.
  // Log so the leak is visible, matching the PlatformSurface
  // handler's behavior.
  //
  // Vulkan-variant builds don't have m_eglTarget at all (the field
  // and its EglDmabufTarget type are preprocessed out), so the
  // whole block is excluded.
  if (m_eglTarget && m_context && !current) {
    std::fprintf(stderr,
                 "[ghastty] ~GhosttySurface: m_eglTarget reset without "
                 "current GL context (teardown race); GL texture+FBO "
                 "will leak, fd is still closed\n");
  }
  m_eglTarget.reset();
#endif
  if (current) m_context->doneCurrent();
}

bool GhosttySurface::makeCurrent() {
  return m_context && m_offscreen && m_offscreen->isValid() &&
         m_context->makeCurrent(m_offscreen);
}

// --- rendering ------------------------------------------------------

// Re-sync the framebuffer and libghostty surface to the widget's current
// size and device pixel ratio. Driven by resizeEvent and by
// DevicePixelRatioChange: on Wayland the fractional scale settles
// asynchronously, after the window has already first appeared.
void GhosttySurface::syncSurfaceSize() {
  if (!m_surface) return;

  // Render at the display's device-pixel resolution. devicePixelRatioF()
  // is the true (possibly fractional) scale because main() selects the
  // PassThrough rounding policy.
  const double dpr = devicePixelRatioF();
  // The terminal fills the full width; the scrollbar is a thin overlay
  // floating on top, so it does not subtract from the grid. Round-to-
  // nearest rather than truncate so a fractional DPR (e.g. 1.5) doesn't
  // shave a pixel off the framebuffer relative to the QImage blit.
  const int w = std::max(1, static_cast<int>(std::lround(width() * dpr)));
  const int h = std::max(1, static_cast<int>(std::lround(height() * dpr)));
  if (w == m_fbw && h == m_fbh &&
      dpr == m_fbDpr.load(std::memory_order_relaxed))
    return;
  m_fbw = w;
  m_fbh = h;
  m_fbDpr.store(dpr, std::memory_order_release);

  // Vulkan path: libghostty manages the target image itself (it
  // allocates the dmabuf-exportable VkImage). Tell it the new
  // pixel size + DPR, then drive a synchronous draw at the new
  // size so the QPaintEvent Qt will deliver right after this
  // resizeEvent returns paints the new geometry — not the previous
  // frame in the previous-size corner with the surrounding area
  // showing the parent window background.
  //
  // First-frame caveat: `ghostty_surface_draw` deadlocked during
  // bring-up when called before the renderer thread had emitted
  // anything (first-show races a not-yet-ready Vulkan host setup).
  // Gate the synchronous draw on already having a frame —
  // `m_image.isNull()` is true exclusively until the first frame
  // imports. Before then we keep the original "mark dirty + let
  // the timer pick it up" path.
  if (m_useVulkan) {
    ghostty_surface_set_content_scale(m_surface, dpr, dpr);
    ghostty_surface_set_size(m_surface, static_cast<uint32_t>(w),
                             static_cast<uint32_t>(h));

    // Subsurface (zero-copy) path: synchronously render at the new
    // size and dispatch the resulting dmabuf to the presenter BEFORE
    // returning from resizeEvent. That ensures our wl_subsurface
    // has its new-size buffer attached + committed before Qt's
    // following parent-surface commit lands at the new geometry —
    // without this, the compositor sees one frame where the parent
    // surface is already at the new size but our subsurface is
    // still at the old one, and the parent's translucent QWidget
    // background shows through the gap. Counterpart of the
    // m_image.isNull() drain below, which served the same purpose
    // before the subsurface present path replaced the QImage one.
    if (m_useSubsurface.load(std::memory_order_acquire) &&
        m_subsurfacePresenter &&
        !m_hidden.load(std::memory_order_acquire)) {
      // Skip while hidden: Qt delivers synthetic resize events to
      // hidden widgets when a parent layout changes (e.g. a
      // QSplitter rearranged while a tab is offscreen). Triggering
      // a synchronous draw + drainVulkan + forceParentCommit on a
      // hidden subsurface would re-attach a buffer to the
      // supposed-to-be-detached subsurface, the same ghosting
      // condition `m_hidden` exists to prevent on the DPR-change
      // path. The next Show event resets sizing state and triggers
      // a fresh sync, so dropping this is safe.
      //
      // wp_viewport-stretch the existing buffer to the new dest so
      // the subsurface keeps covering the whole new parent area.
      // Without this the subsurface stays at its old buffer size at
      // position (0,0) and the area beyond it is uncovered — the
      // parent QWidget's bg-color paint can't reliably catch up
      // during a fast drag, so the gap shows through to whatever is
      // behind the window. The stretch is bilinear-filtered (text
      // briefly distorts), but full coverage with mildly distorted
      // text is the lesser evil vs. a transparent gap or jumping
      // back to a solid bg-color flood. The sync-mode child commit
      // is cached until parent commits, so forceParentCommit applies
      // it now.
      m_subsurfacePresenter->resizeDestination(width(), height());
      forceParentCommit();
      // Do NOT call ghostty_surface_draw / drainVulkan here. The
      // ghostty_surface_set_size above mails the IO thread, which
      // mails the renderer thread (`.resize` message) and notifies
      // its wakeup (see termio/Termio.zig:500–502). The renderer
      // thread produces the next frame at the new size on its own
      // clock and it lands via presentVulkanDmabuf → drainVulkan →
      // forceParentCommit, replacing the stretched buffer. Running
      // ghostty_surface_draw inline here blocks the GUI thread on a
      // full Vulkan render per resize event during a continuous
      // drag (compositor delivers events at 60–120 Hz), lagging
      // both window edge tracking and content reflow.
      return;
    }

    if (!m_image.isNull()) {
      // Legacy QImage fallback path (presenter absent — e.g. the
      // compositor refused linux-dmabuf-v1, or we're in the
      // first-show window before presenter init). Drain m_pending
      // into m_image so the next paintEvent has the new-size frame.
      ghostty_surface_draw(m_surface);
      QImage frame;
      {
        QMutexLocker lock(&m_pendingMutex);
        frame = std::move(m_pending);
      }
      if (!frame.isNull()) m_image = std::move(frame);
      update();
      return;
    }
    markDirty();
    return;
  }

#ifndef GHASTTY_USE_VULKAN
  // OpenGL path. Vulkan-variant builds always take the `m_useVulkan`
  // branch above and never reach here; the entire block is excluded
  // at preprocessor time so the Vulkan binary doesn't pull in
  // EglDmabufTarget (and transitively libEGL).
  if (!makeCurrent()) return;
  m_eglTarget.reset();
  delete m_fbo;
  m_fbo = nullptr;

  // The GL path always renders into m_fbo first (regular GL_RGBA8
  // FBO, GL's native bottom-left origin). When the subsurface
  // presenter is up + EGL_MESA_image_dma_buf_export is available,
  // we ALSO allocate m_eglTarget (a dmabuf-backed texture+FBO) and
  // glBlitFramebuffer m_fbo → m_eglTarget with an inverted dst rect
  // to flip Y on the way out — Wayland/DRM samples top-down, so
  // without the flip the terminal would render upside-down. We
  // can't use the linux-dmabuf-v1 Y_INVERT buffer flag because
  // some compositors (KWin) reject it with "dma-buf flags are not
  // supported".
  //
  // When m_eglTarget isn't available we fall back to the legacy
  // m_fbo->toImage() + QPainter blit path (QImage handles its own
  // Y flip).
  QOpenGLFramebufferObjectFormat fmt;
  fmt.setInternalTextureFormat(GL_RGBA8);
  m_fbo = new QOpenGLFramebufferObject(QSize(w, h), fmt);

  if (m_subsurfacePresenter) {
    m_eglTarget = opengl::EglDmabufTarget::create(m_context, w, h);
    if (m_eglTarget) {
      m_useSubsurface.store(true, std::memory_order_release);
    } else {
      m_useSubsurface.store(false, std::memory_order_release);
    }
  } else {
    m_useSubsurface.store(false, std::memory_order_release);
  }

  ghostty_surface_set_content_scale(m_surface, dpr, dpr);
  ghostty_surface_set_size(m_surface, static_cast<uint32_t>(w),
                           static_cast<uint32_t>(h));
  renderTerminal();
#endif
}

void GhosttySurface::moveEvent(QMoveEvent *) {
  // When the splitter divider drags or a new pane gets inserted,
  // our offset within the top-level changes. Update the
  // wl_subsurface position so the terminal pixels follow the
  // widget.
  if (m_subsurfacePresenter && window()) {
    const QPoint pos = mapTo(window(), QPoint(0, 0));
    m_subsurfacePresenter->setPosition(pos.x(), pos.y());
    forceParentCommit();
  }
}

void GhosttySurface::resizeEvent(QResizeEvent *) {
  layoutScrollbar();
  syncSurfaceSize();
  // Resize can also shift our position within the top-level (e.g.
  // a sibling pane growing pushes us right). Update position too.
  if (m_subsurfacePresenter && window()) {
    const QPoint pos = mapTo(window(), QPoint(0, 0));
    m_subsurfacePresenter->setPosition(pos.x(), pos.y());
    // forceParentCommit happens inside syncSurfaceSize's
    // drainVulkan/renderTerminal path, so we don't double up here.
  }
  if (m_exitOverlay) m_exitOverlay->setGeometry(rect());
  if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
    m_keySeqOverlay->move(8, height() - m_keySeqOverlay->height() - 8);
  if (m_linkOverlay && m_linkOverlay->isVisible()) {
    int y = height() - m_linkOverlay->height() - 8;
    if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
      y -= m_keySeqOverlay->height() + 4;
    m_linkOverlay->move(8, y);
  }
  if (m_healthOverlay && m_healthOverlay->isVisible())
    m_healthOverlay->move(width() - m_healthOverlay->width() - 8, 8);
  layoutSearchBar();
  showResizeOverlay();
}

bool GhosttySurface::event(QEvent *e) {
  // The device pixel ratio can change without a resize — the Wayland
  // fractional scale settling after startup, or a move between monitors.
  // Re-sync so the framebuffer matches and the readback is tagged with
  // that same ratio; otherwise paintEvent blits the frame at the wrong
  // size (the FBO was sized at one DPR, the image tagged with another).
  // Skip while hidden: syncSurfaceSize triggers a synchronous
  // ghostty_surface_draw + drainVulkan + forceParentCommit in the
  // Vulkan+subsurface path. Forcing a parent commit while we're
  // supposed to be detached re-attaches a buffer to the now-hidden
  // subsurface, which is the same ghosting condition `m_hidden`
  // exists to prevent. The next Show event resets `m_fbw=m_fbh=-1`
  // and triggers a fresh syncSurfaceSize anyway, so dropping this
  // call costs nothing.
  if (e->type() == QEvent::DevicePixelRatioChange &&
      !m_hidden.load(std::memory_order_acquire)) {
    syncSurfaceSize();
  }

  // PlatformSurface events fire when Qt creates / destroys the native
  // QWindow's wl_surface. This happens not just at first show but
  // also when the QWidget gets re-parented (e.g. dropped into a
  // QSplitter as a new split pane), when toggling fullscreen, or on
  // screen change. Without tracking this our SubsurfacePresenter
  // stays bound to a destroyed parent wl_surface — splits show
  // black, etc. Drop the presenter on SurfaceAboutToBeDestroyed and
  // let the next Show / SurfaceCreated path recreate it against the
  // new parent.
  if (e->type() == QEvent::PlatformSurface) {
    const auto type =
        static_cast<QPlatformSurfaceEvent *>(e)->surfaceEventType();
    if (type == QPlatformSurfaceEvent::SurfaceAboutToBeDestroyed) {
      m_useSubsurface.store(false, std::memory_order_release);
      // Invalidate the QWaylandWindow cache used by
      // forceParentCommit — the QPlatformWindow we cached is about
      // to be destroyed. The next forceParentCommit call against
      // a fresh QPA handle will re-do the dynamic_cast.
      m_cachedWaylandWindow = nullptr;
      // EglDmabufTarget's destructor deletes a GL framebuffer +
      // texture allocated against `m_context`; without that
      // context current its `QOpenGLContext::currentContext()`
      // check sees the wrong (or no) context and silently skips
      // the gl* calls, leaking the resources every time Qt
      // re-creates the QPA window (QSplitter reparent, fullscreen
      // toggle, screen change). Make the owning context current
      // before tearing down. Vulkan-variant builds have no
      // `m_context` or `m_eglTarget` and the whole block is
      // preprocessed out below.
#ifndef GHASTTY_USE_VULKAN
      if (m_eglTarget) {
        if (m_context) {
          // Best-effort: if makeCurrent fails (the QOffscreenSurface
          // is already invalidated by the platform-surface
          // teardown — exactly when this branch fires), the reset
          // below will leak the GL texture+FBO. Log so the leak
          // is visible instead of silent. The fd inside
          // EglDmabufTarget is closed by its dtor regardless of
          // GL-context state, so the kernel-side resource is
          // released either way.
          if (!makeCurrent()) {
            std::fprintf(stderr,
                         "[ghastty] EglDmabufTarget reset without "
                         "current GL context (PlatformSurface teardown "
                         "race); GL texture+FBO will leak, fd is "
                         "still closed\n");
          }
        }
        m_eglTarget.reset();
      }
#endif
      m_subsurfacePresenter.reset();
      // Presenter is gone — no frame_done callback will arrive.
      // Reset the gate so the rebuilt presenter's first present
      // (on next Show) goes through immediately, AND wake the
      // renderer thread in case it's parked in the wait_for so
      // it can re-check m_hidden and bail.
      {
        std::lock_guard<std::mutex> lg(m_compositorMutex);
        m_compositorReady = true;
      }
      m_compositorCv.notify_all();
      // Presenter rebuild on next Show needs a fresh frame to
      // attach; until then paintEvent should fall back to the
      // bg-color placeholder.
      m_subsurfaceHasFrame.store(false, std::memory_order_release);
    }
    // SurfaceCreated is handled implicitly: the next QEvent::Show
    // (which Qt always fires after the platform surface comes up)
    // sees a null m_subsurfacePresenter and rebuilds it against the
    // fresh windowHandle().
  }
  // Visibility transitions: tell libghostty so its renderer thread
  // can bail out of updateFrame while the surface is hidden (a
  // non-current tab, a minimised window, the quick terminal faded
  // out). On visibility regain libghostty rebuilds + draws to catch
  // up. Mirrors the GTK frontend's glareaMap / glareaUnmap →
  // updateOcclusion path (ghostty-org/ghostty#12760) — keeps idle
  // background tabs at ~0% CPU instead of churning the renderer.
  //
  // Qt fires QEvent::Show / QEvent::Hide when the widget itself
  // becomes effectively visible to the user, including transitively
  // via parent hide / tab switch on QTabWidget. The GLArea-style
  // map/unmap signals are the same semantic.
  if (m_surface) {
    if (e->type() == QEvent::Show) {
      ghostty_surface_set_occlusion(m_surface, true);
      // Clear the present-gate latch: subsequent frames go through
      // the subsurface as normal.
      m_hidden.store(false, std::memory_order_release);
      // Defensive re-sync of the surface size to libghostty. On a
      // brand-new tab Qt fires resizeEvent right after Show and
      // syncSurfaceSize runs from there — but on a tab SWAP (the
      // 2nd tab replaces the 1st in the tab area), the widget
      // reuses the existing layout slot at the same size. Qt does
      // NOT fire resizeEvent in that case, so syncSurfaceSize
      // never runs, libghostty stays at its default 800×600 surface
      // size, and the renderer's first frame goes out at 800×600.
      // If the widget happens to ALSO be 800×600 (small windows,
      // unlikely but possible), the wrong-size drop guard in
      // drainVulkan misses, the wrong-size frame is attached,
      // wp_viewport stretches it… and the custom shader's
      // resolution uniform (set from libghostty's 800×600 surface
      // size, not the widget's real size) makes the shader draw at
      // the wrong scale → the iChannel0 texture renders at full
      // image size instead of the configured background pattern.
      // Calling syncSurfaceSize here ensures libghostty is told
      // about the widget's actual size before the renderer's next
      // frame, regardless of whether resizeEvent fires.
      syncSurfaceSize();
      // Re-attach the last-presented dmabuf immediately on Show.
      // Without this, Hide had attached a NULL buffer (so the
      // pane's old frame wouldn't ghost over the active tab) and
      // the subsurface area paints through to whatever is behind
      // the window (WA_TranslucentBackground) for the few frames
      // before the renderer thread produces a new frame for this
      // surface — visible as a brief flash on every tab switch.
      // The cached buffer is at most one frame stale.
      if (m_subsurfacePresenter && m_subsurfacePresenter->reattachCached()) {
        // The reattach committed on the CHILD wl_subsurface; in
        // sync mode that commit is cached until the parent
        // wl_surface commits too. Force the parent commit
        // explicitly so the buffer actually becomes visible —
        // without this, Hide left the subsurface with a NULL
        // buffer, our re-attach caches the previous buffer's
        // state, and the compositor doesn't apply it until
        // some unrelated parent paint fires.
        forceParentCommit();
        // Qt's QWaylandWindow::commit() queues the parent
        // commit into the libwayland-client send buffer but
        // doesn't wl_display_flush() — meaning the commit can
        // sit there until Qt's next event-loop iteration
        // flushes (or some other code path triggers a flush).
        // That delay is the intermittent tab-switch flash: the
        // paint event fires next, fills the terminal area
        // transparent (m_subsurfaceHasFrame=true just set), but
        // the subsurface commit hasn't reached the compositor
        // yet, so user sees through to the parent → through to
        // whatever is behind the window. Explicitly flushing the
        // wl_display here forces both the child reattach commit
        // (which reattachCached already flushed) AND the parent
        // commit (just queued by forceParentCommit) to the
        // compositor in one go.
        m_subsurfacePresenter->flushDisplay();
        // Cached buffer is now visible → paintEvent should fall
        // through to the transparent-fill path (subsurface
        // shows through). The cached buffer may be one frame
        // stale, but that's strictly better than a flash of
        // background color before the renderer's next frame
        // overwrites it.
        m_subsurfaceHasFrame.store(true, std::memory_order_release);
      }
      // First successful Show is also when our native QWindow exists
      // and we can safely look up the Wayland parent wl_surface.
      // Lazy-init the subsurface presenter once and keep it for the
      // widget's lifetime — tying it to Show/Hide would churn the
      // wl_subsurface on every tab switch. Re-creation on real
      // native-surface lifecycle changes is handled by the
      // QEvent::PlatformSurface branch above.
      if (!m_subsurfacePresenter) {
        // Use the TOP-LEVEL QWindow's wl_surface as the parent for
        // our subsurface — NOT this widget's own QWindow. Each pane
        // in a split is a sibling subsurface under the same
        // top-level wl_surface, positioned via setPosition. This
        // avoids forcing WA_NativeWindow on embedded children
        // (which made Qt unhappy with QSplitter).
        QWindow *top = window() ? window()->windowHandle() : nullptr;
        if (!top) {
          std::fprintf(stderr,
                       "[ghastty] GhosttySurface::event(Show): "
                       "top-level windowHandle() is null, will retry "
                       "next show\n");
        }
        if (top) {
          m_subsurfacePresenter =
              wayland::SubsurfacePresenter::tryCreate(top);
          if (m_subsurfacePresenter) {
            // Set initial position to our offset within the top-level.
            // moveEvent updates it on layout changes.
            const QPoint pos = mapTo(window(), QPoint(0, 0));
            m_subsurfacePresenter->setPosition(pos.x(), pos.y());
            // Wire compositor-paced presents: the presenter requests
            // a wl_surface.frame callback on every commit; when the
            // compositor signals ready, onWaylandFrameReady flips
            // m_compositorReady and re-pumps drainVulkan.
            m_subsurfacePresenter->setOnFrameReady(
                [this]() { onWaylandFrameReady(); });
            // Fresh presenter starts in "ready to present" state —
            // first present goes through immediately; subsequent
            // presents wait for the frame callback.
            m_compositorReady = true;
            if (m_useVulkan) {
              m_useSubsurface.store(true, std::memory_order_release);
            } else {
              // OpenGL path: re-sync the framebuffer so
              // syncSurfaceSize can build an EglDmabufTarget.
              m_fbw = m_fbh = -1;
              syncSurfaceSize();
            }
          }
        }
      }
    } else if (e->type() == QEvent::Hide) {
      // Set the present-gate FIRST so any racing renderer frame
      // (libghostty's render thread may produce one more after
      // set_occlusion returns) is blocked from re-attaching a
      // buffer in presentVulkanDmabuf / drainVulkan / renderTerminal.
      m_hidden.store(true, std::memory_order_release);
      ghostty_surface_set_occlusion(m_surface, false);
      // Detach the subsurface buffer so this pane's last frame
      // doesn't ghost on top of whatever the now-active tab is
      // showing. The next Show + render reattaches a buffer and
      // makes it visible again.
      if (m_subsurfacePresenter) {
        m_subsurfacePresenter->hide();
        forceParentCommit();
        // Flush so the NULL-attach + parent commit reach the
        // compositor before the NEW active tab's Show fires its
        // own reattach. Without this, the two parent commits can
        // race in Qt's send buffer and the compositor sees them
        // out of order or in different frames.
        m_subsurfacePresenter->flushDisplay();
      }
      // No buffer is attached anymore; the next paintEvent should
      // paint the background placeholder until the next real frame
      // arrives. reattachCached on the following Show will flip
      // this back to true via drainVulkan when the renderer
      // delivers a matching-size frame.
      m_subsurfaceHasFrame.store(false, std::memory_order_release);
      // Wake the renderer thread if it's parked in
      // presentVulkanDmabuf's wait_for; the predicate sees
      // m_hidden=true (already set above) and the renderer bails
      // without parking another frame.
      {
        std::lock_guard<std::mutex> lg(m_compositorMutex);
        m_compositorReady = true;
      }
      m_compositorCv.notify_all();
    }
  }
  return QWidget::event(e);
}

void GhosttySurface::renderIfDirty() {
  if (m_dirty.exchange(false)) renderTerminal();
}

void GhosttySurface::layoutScrollbar() {
  if (!m_scrollbar) return;
  // Always positioned (even while faded out) so it is placed correctly
  // the moment it is revealed.
  m_scrollbar->setGeometry(width() - OverlayScrollbar::kWidth, 0,
                           OverlayScrollbar::kWidth, height());
}

// `scrollbar = never` in the config hides the scrollbar unconditionally;
// `system` (the default) shows it whenever there is scrollback.
bool GhosttySurface::scrollbarAllowed() const {
  // config::get is null-safe (returns false when handle() is null),
  // so we only need the "could not read" → default-to-showing path.
  const char *value = nullptr;
  if (config::get(&value, "scrollbar") && value)
    return qstrcmp(value, "never") != 0;
  return true;  // unknown — default to showing
}

void GhosttySurface::updateScrollbar(uint64_t total, uint64_t offset,
                                     uint64_t len) {
  if (!m_scrollbar) return;
  if (!scrollbarAllowed() || total <= len) {
    m_scrollbar->setMetrics(0, 0, 0);
    m_scrollbar->hide();
    return;
  }
  m_scrollbar->setMetrics(total, offset, len);

  // Overlay behaviour: reveal the scrollbar on scroll activity, but not
  // for output that merely follows the bottom of the buffer.
  const bool atBottom = offset + len >= total;
  if (!atBottom || !m_scrollAtBottom) flashScrollbar();
  m_scrollAtBottom = atBottom;
}

// Reveal the overlay scrollbar (it fades itself back out when idle).
void GhosttySurface::flashScrollbar() {
  if (!m_scrollbar || !scrollbarAllowed()) return;
  // Handle colour: light on a dark terminal, dark on a light one.
  ghostty_config_color_s bg{};
  if (config::get(&bg, "background")) {
    const double luma = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b;
    m_scrollbar->setHandleColor(luma < 128.0 ? QColor(235, 235, 235)
                                             : QColor(45, 45, 45));
  }
  layoutScrollbar();
  m_scrollbar->reveal();
}

void GhosttySurface::renderTerminal() {
  if (!m_surface) return;

  // Don't render / present while hidden — the subsurface is already
  // detached from a buffer by Hide; doing more work here would just
  // race a stale frame back into view on the next compositor cycle.
  if (m_hidden.load(std::memory_order_acquire)) return;

  // Vulkan path: libghostty owns its target VkImage; it renders into
  // it directly and presents via the apprt dmabuf callback. No GL
  // context, no FBO, no readback — just kick the draw and let the
  // platform-side `present` machinery wire the result back to us.
  if (m_useVulkan) {
    ghostty_surface_draw(m_surface);
    return;
  }

#ifndef GHASTTY_USE_VULKAN
  // OpenGL path. Vulkan-variant builds always take the early
  // `m_useVulkan` return above; preprocessing the block out keeps
  // the Vulkan binary free of EglDmabufTarget (and libEGL).
  if (!makeCurrent()) return;
  if (!m_eglTarget && !m_fbo) return;

  // Two output sinks. Both paths render into the same primary FBO
  // first (m_fbo, regular GL_RGBA8, GL's native bottom-left origin).
  //   - EglDmabufTarget present (zero-copy): glBlitFramebuffer
  //     m_fbo into the dmabuf-backed FBO with an inverted dst rect
  //     to flip Y on the way out (Wayland/DRM samples top-down;
  //     the linux-dmabuf-v1 Y_INVERT buffer flag would do this
  //     compositor-side but KWin and others reject it as "dma-buf
  //     flags are not supported"). Hand the dmabuf to the
  //     subsurface presenter.
  //   - QImage fallback: glReadPixels into a QImage (which handles
  //     its own Y flip) and let paintEvent blit it via QPainter.
  //     Used when the EGL dmabuf path isn't available.
  m_fbo->bind();
  m_context->functions()->glViewport(0, 0, m_fbw, m_fbh);
  ghostty_surface_draw(m_surface);
  premultiplyFramebuffer();

  if (m_eglTarget && m_subsurfacePresenter) {
    // QOpenGLExtraFunctions exposes glBlitFramebuffer (GL 3.0+);
    // QOpenGLFunctions doesn't. We pinned to OpenGL 4.3 elsewhere
    // so the entry point is always available.
    auto *xf = m_context->extraFunctions();
    xf->glBindFramebuffer(GL_READ_FRAMEBUFFER, m_fbo->handle());
    xf->glBindFramebuffer(GL_DRAW_FRAMEBUFFER, m_eglTarget->framebuffer());
    // Inverted dst rect (y1 > y0) tells glBlitFramebuffer to flip
    // vertically while copying. Matches the Y_INVERT semantic
    // without needing compositor support for the flag.
    xf->glBlitFramebuffer(0, 0, m_fbw, m_fbh,
                          0, m_fbh, m_fbw, 0,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
    xf->glBindFramebuffer(GL_FRAMEBUFFER, 0);
    m_subsurfacePresenter->presentDmabuf(
        m_eglTarget->fd(), m_eglTarget->drmFormat(),
        m_eglTarget->drmModifier(),
        static_cast<quint32>(m_eglTarget->width()),
        static_cast<quint32>(m_eglTarget->height()), m_eglTarget->stride(),
        width(), height(),
        /*y_invert*/ false);
    // Sync-mode subsurface caches child state until the parent
    // commits. Force the parent commit ourselves — same call the
    // Vulkan drainVulkan path makes — otherwise the child state
    // (new buffer, new position, new dest, hide()) never applies
    // and the GL pane shows stale / black / ghosted content.
    forceParentCommit();
    // Flip the "real subsurface frame attached" flag so paintEvent
    // stops drawing m_image over the subsurface. Without this,
    // paintEvent unconditionally blits stale m_image content onto
    // the parent QWidget (which is stacked ABOVE the subsurface
    // via place_below), and the user sees the m_image as a weird
    // overlay with the real subsurface terminal pixels "ghosting"
    // through. Mirrors the Vulkan drainVulkan path's flag set.
    m_subsurfaceHasFrame.store(true, std::memory_order_release);
    // The terminal pixels reach the compositor via the subsurface,
    // not via QPainter — but chrome (overlays, dim, bell flash)
    // still goes through paintEvent. update() schedules that.
    update();
    return;
  }

  // Read the frame back as a premultiplied, top-down QImage, tagged with
  // the ratio the framebuffer was sized at so paintEvent can blit it 1:1
  // at its true logical size. Using the live devicePixelRatioF() here
  // would mis-size the blit if the DPR changed since syncSurfaceSize ran.
  // (Scaling it to the widget instead made the whole frame — images
  // included — rubber-band while a resize was in flight.)
  m_image = m_fbo->toImage();
  m_image.setDevicePixelRatio(m_fbDpr.load(std::memory_order_acquire));
  m_fbo->release();

  update();
#endif
}

void GhosttySurface::paintEvent(QPaintEvent *) {
  // Subsurface zero-copy path: the wl_subsurface IS the terminal
  // pixels — they reach the compositor without ever touching our
  // QPainter. With `WA_TranslucentBackground` set, the QWidget
  // paints transparent over the subsurface so chrome (dim overlay,
  // bell flash, resize hint) still composites on top.
  const bool subsurfaceActive =
      m_useSubsurface.load(std::memory_order_acquire) && m_subsurfacePresenter;
  const bool subsurfaceHasFrame =
      m_subsurfaceHasFrame.load(std::memory_order_acquire);
  // On the Vulkan path we always paint, even before the subsurface
  // presenter has been created (presenter is lazy-init'd in the
  // first Show event — paintEvent can fire earlier on a fresh
  // tab/window). For OpenGL we keep the legacy early-return when
  // there's no QImage to blit.
  if (!m_useVulkan && !subsurfaceActive && m_image.isNull()) return;
  QPainter painter(this);
  if (m_useVulkan) {
    // The wl_subsurface (when active) is stacked BELOW the parent
    // surface so Qt's chrome (SearchBar, overlays) painted later in
    // this paintEvent remains visible. For the terminal pixels
    // themselves to show through, the parent's backing store must
    // be transparent in the terminal area. WA_TranslucentBackground
    // sets WA_NoSystemBackground, which means Qt does NOT auto-
    // clear the backing store between paints — so without an
    // explicit fill, stale/uninitialized pixels obscure the
    // subsurface below.
    painter.setCompositionMode(QPainter::CompositionMode_Source);
    if (subsurfaceActive && subsurfaceHasFrame) {
      // Real frame attached: fill transparent so the subsurface
      // shows through; chrome painted afterwards composites on top.
      painter.fillRect(rect(), Qt::transparent);
    } else {
      // Either the subsurface presenter hasn't been created yet
      // (new-tab paintEvent fires before Show creates it) or no
      // matching-size dmabuf has been attached yet (new-tab bring-
      // up before drainVulkan accepts a real-size frame). Either
      // way the subsurface area would paint as transparent → flash
      // through to whatever is behind the window. Paint the
      // terminal's configured background color so the user sees an
      // empty terminal rather than a transparent flash. The brief
      // paint is replaced by the subsurface content as soon as a
      // matching-size frame attaches.
      QColor fill = QColor(0, 0, 0);  // safe fallback if no config
      ghostty_config_color_s bg{};
      if (config::get(&bg, "background")) {
        fill = QColor(bg.r, bg.g, bg.b);
      }
      painter.fillRect(rect(), fill);
    }
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
  } else {
    // OpenGL path. When the subsurface presenter is active and has
    // a real frame attached, the terminal pixels reach the
    // compositor via the wl_subsurface (stacked BELOW the parent
    // QWidget via place_below). We must paint the parent's
    // terminal area transparent so the subsurface shows through —
    // mirroring the Vulkan branch above. Drawing m_image here
    // overwrites the transparent backing store with whatever
    // m_image last held (which is stale, because the subsurface
    // path in renderTerminal SKIPS the `m_image = m_fbo->toImage()`
    // readback), and the result is a "ghost overlay" effect where
    // the user sees m_image stacked above the live subsurface
    // pixels.
    painter.setCompositionMode(QPainter::CompositionMode_Source);
    if (subsurfaceActive && subsurfaceHasFrame) {
      painter.fillRect(rect(), Qt::transparent);
    } else if (subsurfaceActive) {
      // Subsurface presenter is up but the first real frame hasn't
      // attached yet (new-tab bring-up or post-resize gap). Paint
      // the terminal's configured background color over the
      // transparent parent so the user sees an empty terminal
      // rather than a transparent flash. Same placeholder logic as
      // the Vulkan branch.
      QColor fill = QColor(0, 0, 0);  // safe fallback
      ghostty_config_color_s bg{};
      if (config::get(&bg, "background")) {
        fill = QColor(bg.r, bg.g, bg.b);
      }
      painter.fillRect(rect(), fill);
    } else {
      // Legacy QImage fallback path — the subsurface presenter is
      // absent (compositor refused linux-dmabuf-v1 or
      // EglDmabufTarget::create failed) and the renderer fell
      // back to glReadPixels into m_image. Blit it 1:1. m_image
      // carries the device pixel ratio, so the QPointF overload
      // draws it at its true logical size.
      painter.drawImage(QPointF(0, 0), m_image);
    }
  }

  // Unfocused-split dimming: a translucent fill over an inactive pane.
  // Only split panes (a QSplitter parent) are dimmed, matching GTK.
  if (!hasFocus() && qobject_cast<QSplitter *>(parentWidget())) {
    double opacity = 0.7;  // default: 70% opaque
    // On read failure opacity keeps the default; the success bit
    // isn't load-bearing.
    (void)config::get(&opacity, "unfocused-split-opacity");
    if (opacity < 1.0) {
      QColor fill(0, 0, 0);  // default: dim toward black
      ghostty_config_color_s c{};
      if (config::get(&c, "unfocused-split-fill"))
        fill = QColor(c.r, c.g, c.b);
      fill.setAlphaF(1.0 - opacity);
      painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
      painter.fillRect(rect(), fill);
    }
  }

  // Bell `border` feature: a brief attention flash over the terminal.
  if (m_bellFlash) {
    painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
    painter.setPen(QPen(QColor(255, 96, 96, 230), 3));
    painter.setBrush(Qt::NoBrush);
    painter.drawRect(QRectF(rect()).adjusted(1.5, 1.5, -1.5, -1.5));
  }

  // Transient "cols × rows" overlay, on top of everything else.
  paintResizeOverlay(painter);
}

void GhosttySurface::flashBorder() {
  m_bellFlash = true;
  update();
  QTimer::singleShot(160, this, [this]() {
    m_bellFlash = false;
    update();
  });
}

void GhosttySurface::setShape(Qt::CursorShape shape) {
  m_cursorShape = shape;
  if (m_mouseVisible) setCursor(shape);
}

void GhosttySurface::setMouseVisible(bool visible) {
  if (m_mouseVisible == visible) return;
  m_mouseVisible = visible;
  setCursor(visible ? m_cursorShape : Qt::BlankCursor);
}

// A small translucent overlay label (key-sequence / resize display).
static QLabel *makeOverlayLabel(QWidget *parent) {
  auto *label = new QLabel(parent);
  label->setAttribute(Qt::WA_TransparentForMouseEvents);
  label->setStyleSheet(QStringLiteral(
      "background: rgba(0,0,0,0.75); color: #f0f0f0; font-size: 13px;"
      "padding: 4px 10px; border-radius: 4px;"));
  label->hide();
  return label;
}

void GhosttySurface::promptTitle(bool tabScope) {
  bool ok = false;
  const QString title = QInputDialog::getText(
      this,
      tabScope ? QStringLiteral("Change Tab Title")
               : QStringLiteral("Change Title"),
      QStringLiteral("Title:"), QLineEdit::Normal, QString(), &ok);
  if (!ok || !m_surface) return;
  // The keybind action round-trips through libghostty, which emits
  // SET_TAB_TITLE / SET_TITLE back to apply it (an empty title resets).
  const QByteArray act =
      (tabScope ? QByteArrayLiteral("set_tab_title:")
                : QByteArrayLiteral("set_surface_title:")) +
      title.toUtf8();
  ghostty_surface_binding_action(m_surface, act.constData(), act.size());
}

void GhosttySurface::pushKeySequence(const QString &chord) {
  m_keySeq.append(chord);
  if (!m_keySeqOverlay) m_keySeqOverlay = makeOverlayLabel(this);
  m_keySeqOverlay->setText(m_keySeq.join(QStringLiteral("  ")));
  m_keySeqOverlay->adjustSize();
  m_keySeqOverlay->move(8, height() - m_keySeqOverlay->height() - 8);
  m_keySeqOverlay->show();
  m_keySeqOverlay->raise();
}

void GhosttySurface::endKeySequence() {
  m_keySeq.clear();
  if (m_keySeqOverlay) m_keySeqOverlay->hide();
}

void GhosttySurface::setLinkOverlay(const QString &url) {
  if (url.isEmpty()) {
    if (m_linkOverlay) m_linkOverlay->hide();
    return;
  }
  if (!m_linkOverlay) m_linkOverlay = makeOverlayLabel(this);
  // Cap very long URLs so the overlay doesn't span the whole pane.
  // 80 chars is enough to recognise hostnames + the path prefix; an
  // ellipsis in the middle preserves both halves so a query string
  // reveal still includes the host.
  QString display = url;
  constexpr int kCap = 80;
  if (display.size() > kCap) {
    const int half = (kCap - 1) / 2;
    display = display.left(half) + QStringLiteral("…") +
              display.right(kCap - 1 - half);
  }
  m_linkOverlay->setText(display);
  m_linkOverlay->adjustSize();
  // Bottom-left, but offset upward when the keybind-chord overlay is
  // visible so they don't stack on top of each other.
  int yBase = height() - m_linkOverlay->height() - 8;
  if (m_keySeqOverlay && m_keySeqOverlay->isVisible())
    yBase -= m_keySeqOverlay->height() + 4;
  m_linkOverlay->move(8, yBase);
  m_linkOverlay->show();
  m_linkOverlay->raise();
}

void GhosttySurface::setRendererHealth(bool unhealthy) {
  if (!unhealthy) {
    if (m_healthOverlay) m_healthOverlay->hide();
    return;
  }
  if (!m_healthOverlay) {
    // Reuses the standard overlay style but with a destructive accent;
    // top-right rather than the bottom-left that key-chord/link share so
    // it doesn't fight them when both are visible at once.
    m_healthOverlay = new QLabel(this);
    m_healthOverlay->setAttribute(Qt::WA_TransparentForMouseEvents);
    m_healthOverlay->setStyleSheet(QStringLiteral(
        "background: rgba(180,30,30,0.85); color: #ffffff;"
        "font-size: 12px; padding: 4px 10px; border-radius: 4px;"));
  }
  m_healthOverlay->setText(QStringLiteral("renderer unhealthy"));
  m_healthOverlay->adjustSize();
  m_healthOverlay->move(width() - m_healthOverlay->width() - 8, 8);
  m_healthOverlay->show();
  m_healthOverlay->raise();
}

void GhosttySurface::setPwd(const QString &pwd) {
  if (m_pwd == pwd) return;
  m_pwd = pwd;
}

void GhosttySurface::toggleInspector(ghostty_action_inspector_e mode) {
  const bool visible = m_inspectorWindow && m_inspectorWindow->isVisible();
  bool show;
  switch (mode) {
    case GHOSTTY_INSPECTOR_SHOW: show = true; break;
    case GHOSTTY_INSPECTOR_HIDE: show = false; break;
    default: show = !visible; break;  // GHOSTTY_INSPECTOR_TOGGLE
  }
  if (show) {
    if (!m_inspectorWindow)
      m_inspectorWindow = new InspectorWindow(m_surface);
    m_inspectorWindow->show();
    m_inspectorWindow->raise();
    m_inspectorWindow->activateWindow();
  } else if (m_inspectorWindow) {
    m_inspectorWindow->hide();
  }
}

void GhosttySurface::refreshInspector() {
  if (m_inspectorWindow) m_inspectorWindow->update();
}

void GhosttySurface::openSearch(const QString &prefill) {
  if (!m_searchBar) m_searchBar = new SearchBar(this);
  m_searchBar->open(prefill);
  layoutSearchBar();
}

void GhosttySurface::closeSearch() {
  if (m_searchBar) m_searchBar->hide();
}

void GhosttySurface::setSearchTotal(int total) {
  if (m_searchBar) m_searchBar->setTotal(total);
}

void GhosttySurface::setSearchSelected(int selected) {
  if (m_searchBar) m_searchBar->setSelected(selected);
}

void GhosttySurface::layoutSearchBar() {
  if (!m_searchBar || !m_searchBar->isVisible()) return;
  m_searchBar->adjustSize();
  // Top-right, kept clear of the overlay scrollbar's strip.
  m_searchBar->move(
      width() - m_searchBar->width() - OverlayScrollbar::kWidth - 8, 8);
}

// Called from resizeEvent for every size change. The overlay is drawn
// in paintEvent (see m_resizeOverlayVisible there) rather than as a
// child QLabel: a child widget composited over this surface gets
// covered / flickers while the surface repaints rapidly during a
// resize. Here we just refresh the text and (re)arm the hide timer on
// EVERY resize event, so the overlay stays up for the whole drag and
// only fades once resizing actually stops.
void GhosttySurface::showResizeOverlay() {
  if (!m_surface || !m_owner) return;
  const ghostty_surface_size_s sz = ghostty_surface_size(m_surface);

  const QString mode = config::string("resize-overlay");
  if (mode == QLatin1String("never")) return;

  if (sz.columns != m_lastCols || sz.rows != m_lastRows) {
    const bool first = !m_firstGridSeen;
    m_lastCols = sz.columns;
    m_lastRows = sz.rows;
    m_firstGridSeen = true;
    // `after-first`: stay silent for the surface's very first grid.
    if (mode == QLatin1String("after-first") && first) return;
    m_resizeOverlayText =
        QStringLiteral("%1 × %2").arg(sz.columns).arg(sz.rows);
  }
  // Nothing to announce yet (a pixel-only resize before the first grid,
  // or `after-first` still waiting on the surface's initial grid).
  if (m_resizeOverlayText.isEmpty()) return;

  m_resizeOverlayVisible = true;

  // ghostty_config_get returns a Duration through Duration.cval(),
  // which is MILLISECONDS — use it as-is. Dividing by 1e6 here (the
  // value was misnamed "durNs") turned the 750ms default into 0, so
  // the hide timer fired on the next event-loop tick and the overlay
  // vanished the instant it appeared.
  unsigned long long durCfgMs = 0;
  const bool durOk = config::get(&durCfgMs, "resize-overlay-duration");
  // Clamp before narrowing: a Duration's millisecond value can exceed
  // INT_MAX, and a wrapped negative int would make QTimer::start()
  // reject the interval, leaving the overlay stuck on screen.
  const int durMs =
      (durOk && durCfgMs > 0)
          ? static_cast<int>(std::min<unsigned long long>(
                durCfgMs, std::numeric_limits<int>::max()))
          : 750;
  if (!m_resizeHideTimer) {
    m_resizeHideTimer = new QTimer(this);
    m_resizeHideTimer->setSingleShot(true);
    connect(m_resizeHideTimer, &QTimer::timeout, this, [this]() {
      m_resizeOverlayVisible = false;
      update();
    });
  }
  m_resizeHideTimer->start(durMs);
  update();
}

// Draw the transient "cols × rows" overlay onto the current frame.
// Called from paintEvent so the overlay is composited in the same pass
// as the terminal image — it cannot be covered or flicker.
void GhosttySurface::paintResizeOverlay(QPainter &painter) {
  if (!m_resizeOverlayVisible || m_resizeOverlayText.isEmpty()) return;

  QFont f = font();
  f.setPixelSize(13);
  const QFontMetrics fm(f);
  const int padX = 10, padY = 4;
  const QSize ts = fm.size(Qt::TextSingleLine, m_resizeOverlayText);
  const qreal boxW = ts.width() + 2 * padX;
  const qreal boxH = ts.height() + 2 * padY;

  // resize-overlay-position: center / {top,bottom}-{left,center,right}.
  const QString pos = config::string("resize-overlay-position");
  const qreal m = 8;
  qreal x = (width() - boxW) / 2;
  qreal y = (height() - boxH) / 2;
  if (pos.contains(QLatin1String("left"))) x = m;
  else if (pos.contains(QLatin1String("right"))) x = width() - boxW - m;
  if (pos.contains(QLatin1String("top"))) y = m;
  else if (pos.contains(QLatin1String("bottom"))) y = height() - boxH - m;

  const QRectF box(x, y, boxW, boxH);
  painter.setCompositionMode(QPainter::CompositionMode_SourceOver);
  painter.setRenderHint(QPainter::Antialiasing, true);
  painter.setPen(Qt::NoPen);
  painter.setBrush(QColor(0, 0, 0, 191));  // rgba(0,0,0,0.75)
  painter.drawRoundedRect(box, 4, 4);
  painter.setFont(f);
  painter.setPen(QColor(0xf0, 0xf0, 0xf0));
  painter.drawText(box, Qt::AlignCenter, m_resizeOverlayText);
}

void GhosttySurface::showChildExited(int exitCode) {
  if (m_exitOverlay) return;  // already shown

  // Defer the banner briefly. A normal `exit` closes the surface within
  // a frame or two (libghostty calls close() right after this action),
  // and we don't want the banner to flash in that case. The QObject-
  // context singleShot is cancelled if the surface is destroyed first,
  // so the banner only appears for surfaces that actually persist (an
  // abnormal exit, or `wait-after-command`).
  QTimer::singleShot(120, this, [this, exitCode]() { buildExitOverlay(exitCode); });
}

void GhosttySurface::buildExitOverlay(int exitCode) {
  if (m_exitOverlay) return;

  // A translucent banner over the terminal. It is transparent to mouse
  // events so a click lands on this widget and dismisses it (see
  // mousePressEvent / keyPressEvent).
  m_exitOverlay = new QLabel(this);
  m_exitOverlay->setAlignment(Qt::AlignCenter);
  m_exitOverlay->setWordWrap(true);
  m_exitOverlay->setAttribute(Qt::WA_TransparentForMouseEvents);
  m_exitOverlay->setStyleSheet(QStringLiteral(
      "background: rgba(0,0,0,0.65); color: #e0e0e0; font-size: 14px;"));
  const QString code = exitCode >= 0
                           ? QStringLiteral(" (code %1)").arg(exitCode)
                           : QString();
  m_exitOverlay->setText(QStringLiteral(
      "Process exited%1\nPress any key or click to close").arg(code));
  m_exitOverlay->setGeometry(rect());
  m_exitOverlay->show();
  m_exitOverlay->raise();
}

// libghostty's renderer outputs premultiplied alpha — except a custom
// shader runs as a final Shadertoy-style pass and those conventionally
// emit *straight* alpha (RGB not scaled by alpha). QPainter and the
// compositor expect premultiplied, so a straight framebuffer renders the
// terminal color at full strength and reads as opaque. Fix it by
// premultiplying the framebuffer in place before reading it back.
//
// This runs only when a custom shader is configured: without one the
// renderer's output is already premultiplied and a second pass would
// wrongly darken the background.
void GhosttySurface::initPremultiply() {
  m_premultVao = new QOpenGLVertexArrayObject(this);
  m_premultVao->create();

  m_premultProg = new QOpenGLShaderProgram(this);
  // A single oversized triangle covering the viewport; positions are
  // derived from gl_VertexID so no vertex buffer is needed.
  m_premultProg->addShaderFromSourceCode(QOpenGLShader::Vertex,
                                         R"(#version 330 core
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
})");
  // The fragment color is irrelevant: the blend below uses a source
  // factor of zero, so only the destination framebuffer and its alpha
  // matter.
  m_premultProg->addShaderFromSourceCode(QOpenGLShader::Fragment,
                                         R"(#version 330 core
out vec4 fragColor;
void main() { fragColor = vec4(1.0); }
)");
  m_premultProg->link();
}

void GhosttySurface::premultiplyFramebuffer() {
  if (!m_premultProg || !m_premultProg->isLinked()) return;
  auto *f = m_context->functions();

  // result.rgb = src.rgb*0 + dst.rgb*dst.a ; alpha left untouched by the
  // color mask. This multiplies every pixel's RGB by its own alpha.
  f->glViewport(0, 0, m_fbw, m_fbh);
  f->glDisable(GL_SCISSOR_TEST);
  f->glDisable(GL_DEPTH_TEST);
  f->glEnable(GL_BLEND);
  f->glBlendFuncSeparate(GL_ZERO, GL_DST_ALPHA, GL_ZERO, GL_ONE);
  f->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_FALSE);

  m_premultVao->bind();
  m_premultProg->bind();
  f->glDrawArrays(GL_TRIANGLES, 0, 3);
  m_premultProg->release();
  m_premultVao->release();

  f->glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  f->glDisable(GL_BLEND);
}

// --- input ----------------------------------------------------------

void GhosttySurface::sendKey(QKeyEvent *ev, ghostty_input_action_e action) {
  if (!m_surface) return;

  // Forward committed text only for printable input; control characters
  // and special keys (Enter, Tab, arrows, Ctrl+letter, ...) are encoded
  // by libghostty from the physical keycode + modifiers.
  // The QByteArray below is stack-local; ghostty_surface_key is
  // synchronous and copies any text it needs internally, so the buffer
  // only has to live across this call.
  const QByteArray text = ev->text().toUtf8();
  const bool printable =
      !text.isEmpty() &&
      static_cast<unsigned char>(text.front()) >= 0x20 &&
      static_cast<unsigned char>(text.front()) != 0x7f;

  // The Wayland plugin reports the XKB keycode via nativeScanCode(),
  // which is libghostty's Linux-native input format.
  const uint32_t keycode = ev->nativeScanCode();

  // OR in any right-side bit for this keycode (e.g. Right-Shift sets
  // SHIFT_RIGHT alongside SHIFT) and the live Caps/Num lock state
  // from XkbTracker. macOS + GTK populate all of these; without
  // them, keybinds like `right_shift+x` can't distinguish from
  // `left_shift+x` and the kitty CSI-u encoding loses the lock bits.
  const ghostty_input_mods_e mods = static_cast<ghostty_input_mods_e>(
      translateMods(ev->modifiers()) |
      XkbState::instance().sideBitsForKeycode(keycode) |
      XkbState::instance().lockMods());

  // XKB lookups:
  //   unshifted_codepoint — what this physical key would produce with
  //   no mods (e.g. ';' for the Shift+; → ':' event). Without it
  //   libghostty's kitty encoder mis-handles punctuation release
  //   events.
  //   consumed_mods — modifiers the layout consumed to produce the
  //   event's text. Computed for every event, not just printable
  //   ones: function / keypad / Backspace / arrows can have layout-
  //   consumed mods (Caps Lock for letter case, Mode_Switch for
  //   layout shifts on Backspace) the encoder needs to strip. macOS
  //   + GTK both compute it unconditionally.
  const ghostty_input_key_s k{
      .action = action,
      .mods = mods,
      .consumed_mods = XkbState::instance().consumedMods(keycode, mods),
      .keycode = keycode,
      .text = printable ? text.constData() : nullptr,
      .unshifted_codepoint = XkbState::instance().unshiftedCodepoint(keycode),
      .composing = false,
  };
  ghostty_surface_key(m_surface, k);
}

void GhosttySurface::sendMouseButton(QMouseEvent *ev,
                                     ghostty_input_mouse_state_e state) {
  if (!m_surface) return;
  ghostty_input_mouse_button_e button;
  switch (ev->button()) {
    case Qt::LeftButton: button = GHOSTTY_MOUSE_LEFT; break;
    case Qt::RightButton: button = GHOSTTY_MOUSE_RIGHT; break;
    case Qt::MiddleButton: button = GHOSTTY_MOUSE_MIDDLE; break;
    // Side / extra buttons (back, forward, etc.). macOS handles
    // NSEvent buttonNumber 3-10 and GTK handles GDK button 4-11;
    // Qt's ExtraButton1..ExtraButton8 cover the same hardware. The
    // libghostty C ABI defines FOUR..ELEVEN, so map by index.
    case Qt::ExtraButton1: button = GHOSTTY_MOUSE_FOUR; break;
    case Qt::ExtraButton2: button = GHOSTTY_MOUSE_FIVE; break;
    case Qt::ExtraButton3: button = GHOSTTY_MOUSE_SIX; break;
    case Qt::ExtraButton4: button = GHOSTTY_MOUSE_SEVEN; break;
    case Qt::ExtraButton5: button = GHOSTTY_MOUSE_EIGHT; break;
    case Qt::ExtraButton6: button = GHOSTTY_MOUSE_NINE; break;
    case Qt::ExtraButton7: button = GHOSTTY_MOUSE_TEN; break;
    case Qt::ExtraButton8: button = GHOSTTY_MOUSE_ELEVEN; break;
    default: button = GHOSTTY_MOUSE_UNKNOWN; break;
  }
  ghostty_surface_mouse_button(m_surface, state, button,
                               translateMods(ev->modifiers()));
}

void GhosttySurface::keyPressEvent(QKeyEvent *ev) {
  // While the child-exited overlay is up, any key dismisses it (closes
  // the pane) instead of reaching the dead terminal.
  if (m_exitOverlay) {
    m_owner->removeSurface(this);
    return;
  }
  sendKey(ev,
          ev->isAutoRepeat() ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS);
}

void GhosttySurface::keyReleaseEvent(QKeyEvent *ev) {
  // Qt synthesizes a release before each auto-repeat press; drop those.
  if (ev->isAutoRepeat()) return;
  sendKey(ev, GHOSTTY_ACTION_RELEASE);
}

// A right-click opens the context menu (contextMenuEvent) unless the
// running program is capturing the mouse, in which case it gets the
// click. Returns true if the click was for the menu and should not be
// forwarded to the terminal.
bool GhosttySurface::rightClickOpensMenu(QMouseEvent *ev) const {
  return ev->button() == Qt::RightButton && m_surface &&
         !ghostty_surface_mouse_captured(m_surface);
}

void GhosttySurface::mousePressEvent(QMouseEvent *ev) {
  if (m_exitOverlay) {
    m_owner->removeSurface(this);
    return;
  }
  // Click-to-focus: if the surface didn't have focus, this click is
  // grabbing focus rather than a real interaction with the running
  // program. macOS + GTK suppress the matching mouse-up so vim, less,
  // etc. don't see a stray button-up event. We mirror that by setting
  // a one-shot flag the matching release consults.
  const bool wasFocused = hasFocus();
  setFocus();
  if (!wasFocused && ev->button() == Qt::LeftButton)
    m_suppressNextLeftRelease = true;

  // Right-click: send the press to libghostty BEFORE deciding to
  // open the context menu. macOS + GTK both do this so the core can
  // word-select on right-press and then we open the menu over the
  // selection. If the running program is mouse-captured, the press
  // is forwarded as a real button event.
  sendMouseButton(ev, GHOSTTY_MOUSE_PRESS);
}

void GhosttySurface::mouseReleaseEvent(QMouseEvent *ev) {
  // Suppress the release of a focus-grabbing click — see press above.
  if (ev->button() == Qt::LeftButton && m_suppressNextLeftRelease) {
    m_suppressNextLeftRelease = false;
    return;
  }
  sendMouseButton(ev, GHOSTTY_MOUSE_RELEASE);
}

// The keybind bound to `action` in the live config, as a QKeySequence
// for a context-menu hint. Empty if unbound or not displayable
// (CATCH_ALL, an unmapped physical key, etc.).
QKeySequence GhosttySurface::shortcutFor(const char *action) const {
  if (!m_owner || !m_owner->config()) return {};
  const ghostty_input_trigger_s t =
      ghostty_config_trigger(m_owner->config(), action, qstrlen(action));

  const QString key = triggerKeyName(t);
  if (key.isEmpty()) return {};

  QString seq;
  if (t.mods & GHOSTTY_MODS_CTRL) seq += QStringLiteral("Ctrl+");
  if (t.mods & GHOSTTY_MODS_ALT) seq += QStringLiteral("Alt+");
  if (t.mods & GHOSTTY_MODS_SHIFT) seq += QStringLiteral("Shift+");
  // QKeySequence parses Meta+ as the Super/Logo key on Linux.
  if (t.mods & GHOSTTY_MODS_SUPER) seq += QStringLiteral("Meta+");
  return QKeySequence(seq + key);
}

void GhosttySurface::contextMenuEvent(QContextMenuEvent *ev) {
  // Let a mouse-capturing program have the right-click; also suppress
  // the menu while the child-exited overlay is up.
  if (!m_surface || m_exitOverlay ||
      ghostty_surface_mouse_captured(m_surface))
    return;

  QMenu menu(this);
  // Each item carries its libghostty keybind-action string in data();
  // exec() returns the chosen action and we run it once, below. Icons
  // come from the system theme; the shortcut hint from the live config.
  const auto add = [this](QMenu *into, const char *label, const char *icon,
                          const char *action, bool enabled) {
    QAction *a = into->addAction(QString::fromUtf8(label));
    a->setData(QString::fromUtf8(action));
    a->setEnabled(enabled);
    if (QIcon themed = QIcon::fromTheme(QString::fromUtf8(icon));
        !themed.isNull())
      a->setIcon(themed);
    if (QKeySequence sc = shortcutFor(action); !sc.isEmpty())
      a->setShortcut(sc);
  };

  add(&menu, "Copy", "edit-copy", "copy_to_clipboard",
      ghostty_surface_has_selection(m_surface));
  add(&menu, "Paste", "edit-paste", "paste_from_clipboard",
      !QGuiApplication::clipboard()->text().isEmpty());
  add(&menu, "Select All", "edit-select-all", "select_all", true);
  add(&menu, "Find…", "edit-find", "start_search", true);
  // "Notify on Next Command Finish" is a togglable arm. We render the
  // checked state with a themed checkmark icon in the regular icon
  // column rather than QAction::setCheckable() — Breeze/KDE draws the
  // checkable indicator in its own column, misaligned with the rest
  // of the menu's icons. The bell icon previously used here was also
  // misleading (suggested a stateless trigger, not a one-shot flag).
  {
    QAction *notify = menu.addAction(
        QStringLiteral("Notify on Next Command Finish"));
    notify->setData(QStringLiteral("@notify-command"));
    if (commandNotifyArmed()) {
      QIcon ok = QIcon::fromTheme(QStringLiteral("emblem-ok"));
      if (ok.isNull())
        ok = QIcon::fromTheme(QStringLiteral("object-select"));
      if (ok.isNull()) ok = QIcon::fromTheme(QStringLiteral("dialog-ok"));
      if (!ok.isNull()) notify->setIcon(ok);
    }
    if (QKeySequence sc = shortcutFor("@notify-command"); !sc.isEmpty())
      notify->setShortcut(sc);
  }
  menu.addSeparator();
  add(&menu, "Clear", "edit-clear-all", "clear_screen", true);
  add(&menu, "Reset", "view-refresh", "reset", true);
  menu.addSeparator();

  QMenu *split = menu.addMenu(
      QIcon::fromTheme(QStringLiteral("view-split-left-right")),
      QStringLiteral("Split"));
  add(split, "Change Title…", "document-edit", "prompt_surface_title", true);
  add(split, "Split Right", "view-split-left-right", "new_split:right", true);
  add(split, "Split Down", "view-split-top-bottom", "new_split:down", true);
  add(split, "Split Left", "view-split-left-right", "new_split:left", true);
  add(split, "Split Up", "view-split-top-bottom", "new_split:up", true);

  QMenu *tab = menu.addMenu(QIcon::fromTheme(QStringLiteral("tab-new")),
                            QStringLiteral("Tab"));
  add(tab, "Change Tab Title…", "document-edit", "prompt_tab_title", true);
  add(tab, "New Tab", "tab-new", "new_tab", true);
  add(tab, "Close Tab", "tab-close", "close_tab", true);

  QMenu *window = menu.addMenu(QIcon::fromTheme(QStringLiteral("window-new")),
                               QStringLiteral("Window"));
  add(window, "New Window", "window-new", "new_window", true);
  add(window, "Close Window", "window-close", "close_window", true);

  menu.addSeparator();
  QMenu *config = menu.addMenu(QIcon::fromTheme(QStringLiteral("configure")),
                               QStringLiteral("Config"));
  add(config, "Open Config", "document-open", "open_config", true);
  add(config, "Reload Config", "view-refresh", "reload_config", true);

  QAction *chosen = menu.exec(ev->globalPos());
  if (!chosen || !m_surface) return;
  const QString data = chosen->data().toString();

  // Toggle the one-shot "command finished" notification (no keybind
  // action). Not a checkable QAction — see the icon-column comment in
  // the menu-build section above — so flip by reading the current
  // armed state.
  if (data == QLatin1String("@notify-command")) {
    if (commandNotifyArmed())
      clearCommandNotify();
    else
      armCommandNotify();
    return;
  }

  // The title items have no apprt-side prompt in libghostty: collect the
  // text here and apply it via promptTitle (the set_*_title keybind).
  if (data == QLatin1String("prompt_surface_title") ||
      data == QLatin1String("prompt_tab_title")) {
    promptTitle(data == QLatin1String("prompt_tab_title"));
    return;
  }

  const QByteArray action = data.toUtf8();
  ghostty_surface_binding_action(m_surface, action.constData(),
                                 action.size());
}

void GhosttySurface::dragEnterEvent(QDragEnterEvent *ev) {
  // Accept a tab tear-off drag too — not to handle it, but so Qt does
  // not paint a "forbidden" cursor while a torn-off tab hovers the
  // terminal. The tear-off still completes as a new window (only a tab
  // bar's drop cancels it).
  if (ev->mimeData()->hasUrls() || ev->mimeData()->hasText() ||
      ev->mimeData()->hasFormat(QString::fromLatin1(kGhosttyTabMime)))
    ev->acceptProposedAction();
}

// Quote `s` for a POSIX shell using $'…' encoding. Mirrors
// macOS Ghostty.Shell.escape and GTK ShellEscapeWriter — handles
// embedded quotes, backslashes, newlines, and control chars; bash's
// `'\''` trick fails on dash/zsh + non-printable bytes.
static QString shellQuote(const QString &s) {
  QString out;
  out.reserve(s.size() + 4);
  out += QLatin1String("$'");
  for (QChar ch : s) {
    const ushort c = ch.unicode();
    if (c == '\\' || c == '\'')
      out += QLatin1Char('\\'), out += ch;
    else if (c == '\n')
      out += QLatin1String("\\n");
    else if (c == '\r')
      out += QLatin1String("\\r");
    else if (c == '\t')
      out += QLatin1String("\\t");
    else if (c < 0x20)
      out += QString::asprintf("\\x%02x", c);
    else
      out += ch;
  }
  out += QLatin1Char('\'');
  return out;
}

void GhosttySurface::dropEvent(QDropEvent *ev) {
  const QMimeData *mime = ev->mimeData();
  // A tab tear-off released on the terminal: accept it cleanly and let
  // the tear-off code turn it into a new window.
  if (mime->hasFormat(QString::fromLatin1(kGhosttyTabMime))) {
    ev->acceptProposedAction();
    return;
  }
  QString text;
  if (mime->hasUrls()) {
    // Distinguish file URLs from non-file URLs (http://, etc). File
    // URLs become shell-quoted paths joined with spaces; non-file URLs
    // paste as plain text. macOS + GTK both make this distinction
    // (otherwise dragging a link from a browser yields a quoted
    // command-line argument instead of pasting the URL).
    QStringList parts;
    for (const QUrl &url : mime->urls()) {
      if (url.isLocalFile())
        parts << shellQuote(url.toLocalFile());
      else
        parts << url.toString();
    }
    text = parts.join(QLatin1Char(' '));
  } else if (mime->hasText()) {
    text = mime->text();
  }
  if (text.isEmpty()) return;
  commitText(text);
  ev->acceptProposedAction();
}

void GhosttySurface::mouseMoveEvent(QMouseEvent *ev) {
  if (!m_surface) return;
  // ghostty_surface_mouse_pos wants unscaled (logical) coordinates — it
  // applies the content scale itself. Passing device pixels double-scales
  // the position and drifts the selection on HiDPI displays.
  ghostty_surface_mouse_pos(m_surface, ev->position().x(),
                            ev->position().y(),
                            translateMods(ev->modifiers()));

  // Reveal the overlay scrollbar when the pointer reaches the right
  // edge. While it is visible the scrollbar widget grabs the strip
  // itself; this only fires once it has faded out and been hidden.
  if (ev->position().x() >= width() - OverlayScrollbar::kWidth)
    flashScrollbar();
}

void GhosttySurface::wheelEvent(QWheelEvent *ev) {
  if (!m_surface) return;
  // libghostty's ScrollMods is a packed u8: bit 0 = precision (high-res
  // / pixel-precise), bits 1-3 = momentum phase (none/began/changed/
  // ended/cancelled/may_begin) per src/input/mouse.zig.
  //
  // Trackpads and high-resolution mice fill in pixelDelta; classic
  // notched wheels only fill angleDelta (120 units per notch). When
  // pixelDelta is present we feed that, divide by an approximate cell
  // height (we don't have it from libghostty here, so use 16 logical
  // pixels — close enough for smooth-scroll feel) and flag the event
  // as precision so kitty's smooth-scroll engages. Otherwise we fall
  // back to the classic "120 units == one notch" path.
  double dx = 0.0, dy = 0.0;
  int mods = 0;
  const QPoint pd = ev->pixelDelta();
  if (!pd.isNull()) {
    constexpr double kCellPx = 16.0;
    dx = pd.x() / kCellPx;
    dy = pd.y() / kCellPx;
    mods |= 1;  // ScrollMods.precision
  } else {
    const QPoint a = ev->angleDelta();
    dx = a.x() / 120.0;
    dy = a.y() / 120.0;
  }

  // ScrollMods.momentum (3-bit field at bit 1). Qt only signals the
  // ScrollBegin/ScrollUpdate/ScrollEnd phases on trackpads.
  switch (ev->phase()) {
    case Qt::ScrollBegin:    mods |= (1 /*began*/) << 1; break;
    case Qt::ScrollUpdate:   mods |= (3 /*changed*/) << 1; break;
    case Qt::ScrollEnd:      mods |= (4 /*ended*/) << 1; break;
    case Qt::ScrollMomentum: mods |= (3 /*changed*/) << 1; break;
    default: break;  // NoScrollPhase: treat as a discrete notch
  }
  ghostty_surface_mouse_scroll(m_surface, dx, dy, mods);
  flashScrollbar();  // mouse-wheel scrolling reveals the overlay scrollbar
}

void GhosttySurface::enterEvent(QEnterEvent *ev) {
  // focus-follows-mouse: take focus when the pointer enters this pane.
  if (m_owner && m_owner->focusFollowsMouse() && !hasFocus()) setFocus();
  // Tell libghostty about the actual cursor position so hover state
  // and OSC-8 link arming reset from any stale (-1, -1) sentinel.
  // macOS does this in mouseEntered (SurfaceView_AppKit.swift:920);
  // GTK does it in ecMouseEnter (apprt/gtk/class/surface.zig).
  if (m_surface)
    ghostty_surface_mouse_pos(m_surface, ev->position().x(),
                              ev->position().y(),
                              translateMods(QGuiApplication::keyboardModifiers()));
}

void GhosttySurface::leaveEvent(QEvent *) {
  // libghostty's "no cursor here" sentinel: pass (-1, -1) so any
  // hover-armed state (URL underline, mouse-report sequences for an
  // OSC-8 link) clears once the pointer leaves the pane. macOS and
  // GTK both do this; without it the arm state would survive until
  // the next move event.
  if (m_surface)
    ghostty_surface_mouse_pos(m_surface, -1, -1,
                              translateMods(QGuiApplication::keyboardModifiers()));
}

void GhosttySurface::focusInEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, true);
  update();  // repaint without the unfocused-split dim
}

void GhosttySurface::focusOutEvent(QFocusEvent *) {
  if (m_surface) ghostty_surface_set_focus(m_surface, false);
  update();  // repaint with the unfocused-split dim (if a split pane)
}

// Insert a string of committed text (an IME commit) as terminal input.
void GhosttySurface::commitText(const QString &text) {
  if (!m_surface || text.isEmpty()) return;
  const QByteArray utf8 = text.toUtf8();
  const ghostty_input_key_s k{
      .action = GHOSTTY_ACTION_PRESS,
      .mods = GHOSTTY_MODS_NONE,
      .consumed_mods = GHOSTTY_MODS_NONE,
      .keycode = 0,
      .text = utf8.constData(),
      .unshifted_codepoint = 0,
      .composing = false,
  };
  ghostty_surface_key(m_surface, k);
}

void GhosttySurface::inputMethodEvent(QInputMethodEvent *ev) {
  if (m_surface) {
    const QString preeditStr = ev->preeditString();
    const QString commitStr = ev->commitString();

    // Forward the in-progress composition for inline display, then any
    // finalized text. A well-behaved IME sends an empty preedit string
    // alongside the commit, so this order matches GTK: clear, then commit.
    const QByteArray preedit = preeditStr.toUtf8();
    ghostty_surface_preedit(
        m_surface, preedit.isEmpty() ? nullptr : preedit.constData(),
        static_cast<uintptr_t>(preedit.size()));

    // Only commit when the text is the result of real IME composition —
    // either the preceding event left us in preedit, or this event has
    // active preedit alongside the commit. On Wayland's text-input-v3
    // (KDE Plasma 6 with no IME), the compositor sends a commit for
    // every plain ASCII character it also delivers as a key event;
    // forwarding both here would double every keystroke (the visible
    // symptom: ":" in nvim arriving as "::").
    if (!commitStr.isEmpty() && (m_hadPreedit || !preeditStr.isEmpty()))
      commitText(commitStr);
    m_hadPreedit = !preeditStr.isEmpty();
  }
  ev->accept();
}

QVariant GhosttySurface::inputMethodQuery(Qt::InputMethodQuery query) const {
  switch (query) {
    case Qt::ImEnabled:
      return true;
    case Qt::ImCursorRectangle: {
      // Anchor the IME candidate window at the terminal cursor.
      // libghostty reports the cursor in device pixels; the IME wants
      // logical widget coordinates, so divide by the surface's DPR.
      if (!m_surface) return QRect();
      const ghostty_surface_cursor_position_s c =
          ghostty_surface_cursor_position(m_surface);
      // m_fbDpr defaults to 1.0 and only ever takes positive values
      // from syncSurfaceSize, so dividing is always safe.
      const double dpr = m_fbDpr.load(std::memory_order_acquire);
      return QRect(static_cast<int>(c.x / dpr),
                   static_cast<int>(c.y / dpr),
                   std::max(1, static_cast<int>(c.width / dpr)),
                   std::max(1, static_cast<int>(c.height / dpr)));
    }
    default:
      return QWidget::inputMethodQuery(query);
  }
}

// --- libghostty GL platform callbacks --------------------------------

void *GhosttySurface::glGetProcAddress(void *, const char *name) {
  QOpenGLContext *ctx = QOpenGLContext::currentContext();
  return ctx ? reinterpret_cast<void *>(ctx->getProcAddress(name)) : nullptr;
}

void GhosttySurface::glMakeCurrent(void *ud) {
  static_cast<GhosttySurface *>(ud)->makeCurrent();
}

void GhosttySurface::glReleaseCurrent(void *) {
  // No-op: renderTerminal makes the context current around each frame.
}

void GhosttySurface::glPresent(void *) {
  // No-op: the frame is read back from the framebuffer, not swapped.
}

// --- libghostty Vulkan present path ----------------------------------

void GhosttySurface::presentVulkanDmabuf(
    int dmabuf_fd,
    quint32 drm_format,
    quint64 drm_modifier,
    quint32 width,
    quint32 height,
    quint32 stride,
    bool image_backed) {
  // Called from the renderer thread. Two paths, picked per frame
  // based on whether the wl_subsurface presenter is up:
  //
  //   Subsurface (zero-copy): park the dmabuf metadata; GUI thread
  //   wraps the fd in a wl_buffer and attach/commits to our
  //   wl_subsurface. The compositor scans it out directly.
  //
  //   Fallback (legacy mmap+memcpy): map the fd, copy into a
  //   QImage, GUI thread paints via QPainter. Used when the
  //   subsurface presenter failed to come up (e.g. compositor
  //   missing linux-dmabuf-v1).
  //
  // The fd is a borrow per the `ghostty_platform_vulkan_s` contract;
  // libghostty closes it when the underlying memory is freed. In
  // the subsurface path the wayland client lib SCM_RIGHTS-dups the
  // fd so the compositor's reference outlives our park-and-drain.

  // The subsurface path requires `image_backed` (i.e. the renderer
  // is in `.direct` mode and the fd points at a VkImage). When the
  // renderer falls back to `.legacy_copy` — NVIDIA today, the fd is
  // a VkBuffer — linux-dmabuf-v1 import would fail with
  // `invalid_wl_buffer` and that's a fatal protocol error on the
  // wl_display. So we gate per-frame and stay on the QImage path
  // when the fd isn't compositor-importable.
  const bool useSubsurface =
      image_backed && m_useSubsurface.load(std::memory_order_acquire);

  // Per-surface one-shot breadcrumb so logs confirm the dmabuf
  // hand-off is wired for each pane/split independently. Subsequent
  // frames are silent so we don't spam stderr. The compare_exchange
  // ensures exactly one thread wins the right to emit the log even
  // if two renderer-thread frames race the first present — relaxed
  // ordering is fine since the only state we publish is the bool
  // itself.
  bool expected = false;
  if (m_loggedFirstFrame.compare_exchange_strong(
          expected, true, std::memory_order_relaxed)) {
    std::fprintf(stderr,
                 "[ghastty] first dmabuf for surface=%p: fd=%d %ux%u "
                 "stride=%u fourcc=0x%08x mod=0x%llx image_backed=%d path=%s\n",
                 static_cast<void *>(this), dmabuf_fd, width, height, stride,
                 drm_format, static_cast<unsigned long long>(drm_modifier),
                 image_backed ? 1 : 0, useSubsurface ? "subsurface" : "qimage");
  }

  // Validate the renderer-supplied dimensions. width / height /
  // stride are all u32 and the multiplications below would wrap if
  // they're hostile/buggy:
  //   - `width * 4` (the minimum acceptable stride) wraps for
  //     width >= 0x40000000, accepting any stride.
  //   - `stride * height` (the legacy mmap path's byte count) wraps
  //     to a small size_t when promoted on platforms where size_t
  //     is 32-bit, causing an under-mapped buffer that we then
  //     read past.
  // Cap on a sane upper bound — 65536×65536 dwarfs any plausible
  // terminal — and check that stride*height doesn't exceed
  // SIZE_MAX before promoting.
  constexpr quint32 MAX_DIM = 65536;
  // Cap stride at MAX_DIM × 4 (BGRA8) × a small slack factor for
  // tiled formats: ~4× the width-derived minimum is enough for any
  // legitimate vendor tiling, and it keeps `stride * height`
  // below ~64 GiB even at MAX_DIM. The previous lower-only bound
  // let a pathological renderer with stride near UINT32_MAX and
  // height=MAX_DIM reach mmap with a ~280 TB request.
  constexpr quint32 MAX_STRIDE = MAX_DIM * 16;
  if (dmabuf_fd < 0 || width == 0 || height == 0) return;
  if (width > MAX_DIM || height > MAX_DIM) return;
  if (stride < static_cast<quint64>(width) * 4) return;
  if (stride > MAX_STRIDE) return;
  // stride*height as 64-bit and check the size_t fit explicitly.
  const quint64 bytes64 = static_cast<quint64>(stride) * height;
  if (bytes64 > std::numeric_limits<std::size_t>::max()) return;

  // Don't park / dispatch frames while we're hidden — racing the
  // renderer's final post-Hide frame past presenter.hide() is what
  // restores the ghost on tab switch.
  if (m_hidden.load(std::memory_order_acquire)) return;

  if (useSubsurface) {
    // Backpressure the renderer thread to the compositor's refresh
    // rate. Block here until the GUI thread's wl_surface.frame
    // callback (onWaylandFrameReady) signals that the previous
    // commit has retired and the compositor is ready for the next
    // one. Without this, the renderer's 125 FPS draw timer keeps
    // submitting GPU work that the paced GUI thread discards —
    // wasted GPU + renderer-thread CPU.
    //
    // 100 ms timeout is a safety net: if the compositor stalls
    // (lid closed, monitor disconnect, application minimized
    // mid-flight) we don't want the renderer thread blocked
    // forever. On timeout we proceed and overwrite the parked
    // dmabuf — same drop semantic as pre-backpressure. The
    // predicate also bails on m_hidden so Hide can wake the
    // renderer immediately without paying the timeout.
    {
      std::unique_lock<std::mutex> lk(m_compositorMutex);
      m_compositorCv.wait_for(lk, std::chrono::milliseconds(100),
                              [this] {
                                return m_compositorReady ||
                                       m_hidden.load(std::memory_order_acquire);
                              });
      // If Hide fired while we were waiting, bail without parking
      // the frame — the GUI thread's drainVulkan would drop it
      // anyway on the m_hidden check below.
      if (m_hidden.load(std::memory_order_acquire)) return;
      m_compositorReady = false;
    }

    // Dup the dmabuf fd BEFORE parking. The fd from libghostty is
    // only guaranteed valid inside this present() callback —
    // libghostty's Target.deinit (which fires on resize, including
    // the size-1×1 → real-size resize that happens on every new
    // surface bring-up) closes it. If the GUI thread is busy with
    // tab creation when drainVulkan would run, the parked fd can
    // be reaped under it before create_immed reaches the SCM_RIGHTS
    // dup — manifests as `dup failed: Bad file descriptor` →
    // wl_display protocol error 9 → the whole Wayland connection
    // dies (verified user-side, "2nd time this has happened
    // while opening tabs").
    //
    // Our dup owns its own kernel ref, independent of libghostty's
    // close. drainVulkan closes the dup after presentDmabuf hands
    // it to create_immed (which SCM_RIGHTS-dups again into the
    // compositor's address space). One dup per frame; cheap.
    const int parked_fd = ::dup(dmabuf_fd);
    if (parked_fd < 0) {
      // Out of fds or other syscall failure. Drop the frame; renderer
      // will deliver another one next compositor refresh.
      m_compositorReady = true;  // unblock our own backpressure
      m_compositorCv.notify_all();
      return;
    }

    // Subsurface path. Park the descriptor under the mutex (so
    // a concurrent drainVulkan sees a consistent snapshot) and
    // wake the GUI thread. Frame-drop semantics: at most one frame
    // is parked. With the backpressure above, overwrites should be
    // rare — they happen only when the renderer's wait timed out
    // before the GUI thread consumed the previous park, or on the
    // first-frame bring-up race.
    bool overwrote = false;
    int prev_fd = -1;
    {
      QMutexLocker lock(&m_pendingMutex);
      overwrote = m_pendingDmabuf.fd >= 0;
      // Snapshot the prior parked fd so we can close it OUTSIDE
      // the mutex — we own it (it's a prior dup).
      if (overwrote) prev_fd = m_pendingDmabuf.fd;
      m_pendingDmabuf = PendingDmabuf{
          parked_fd, drm_format, drm_modifier, width, height, stride,
      };
    }
    // Close any overwritten prior dup so we don't leak fds in the
    // (rare) drop case.
    if (prev_fd >= 0) ::close(prev_fd);
    // (No first-frame signal — paired with the ctor gate removal.)
    if (overwrote) {
      const auto count = m_droppedFrames.fetch_add(
          1, std::memory_order_relaxed) + 1;
      // Log the first 3 drops + every 60th thereafter — silent in
      // the steady state, audible on sustained backlog.
      if (count <= 3 || count % 60 == 0) {
        std::fprintf(stderr,
                     "[ghastty] surface=%p dropped frame "
                     "(parked one not yet drained, total=%llu)\n",
                     static_cast<void *>(this),
                     static_cast<unsigned long long>(count));
      }
    }
    // Dedupe queued drainVulkan: only post if no prior post is
    // still pending. drainVulkan clears m_drainScheduled before
    // checking the pending dmabuf, so a renderer frame parked
    // between "clear" and "consume" still kicks a fresh queued
    // drain. The atomic CAS is wait-free; the false→true winner
    // posts, others skip.
    bool was_scheduled = false;
    if (m_drainScheduled.compare_exchange_strong(
            was_scheduled, true, std::memory_order_acq_rel)) {
      QMetaObject::invokeMethod(this, "drainVulkan",
                                Qt::QueuedConnection);
    }
    return;
  }

  // Fallback: mmap + memcpy into a QImage. `bytes64` was computed
  // and bounds-checked above.
  const size_t bytes = static_cast<size_t>(bytes64);
  void *mapped = ::mmap(nullptr, bytes, PROT_READ, MAP_SHARED, dmabuf_fd, 0);
  if (mapped == MAP_FAILED) {
    std::fprintf(stderr, "[ghastty] mmap of dmabuf fd=%d failed: %s\n",
                 dmabuf_fd, std::strerror(errno));
    return;
  }
  // drm_format ARGB8888 (0x34325241 = "AR24") matches QImage's
  // ARGB32 byte order on little-endian (B,G,R,A in memory). The
  // renderer's fragment shaders output premultiplied alpha into
  // `VK_FORMAT_B8G8R8A8_SRGB`, so the buffer is sRGB-encoded
  // premultiplied ARGB — exactly what Format_ARGB32_Premultiplied
  // expects. Reject any other fourcc loudly: QImage's
  // Format_ARGB32_Premultiplied has fixed channel order, and
  // pretending an XRGB / ABGR / 10-bit buffer matches it would
  // produce wrong colors silently.
  constexpr uint32_t kDrmFormatArgb8888 = 0x34325241;  // 'AR24'
  if (drm_format != kDrmFormatArgb8888) {
    std::fprintf(stderr,
                 "[ghastty] surface=%p dropping legacy mmap frame: "
                 "drm_format=0x%08x not supported (only 'AR24' / "
                 "ARGB8888 maps to QImage::Format_ARGB32_Premultiplied)\n",
                 static_cast<void *>(this), drm_format);
    ::munmap(mapped, bytes);
    return;
  }
  const QImage stamped(
      static_cast<const uchar *>(mapped),
      static_cast<int>(width),
      static_cast<int>(height),
      static_cast<int>(stride),
      QImage::Format_ARGB32_Premultiplied);
  QImage owned = stamped.copy();
  ::munmap(mapped, bytes);

  const double dpr_now = m_fbDpr.load(std::memory_order_acquire);
  if (dpr_now > 0) owned.setDevicePixelRatio(dpr_now);
  bool overwrote_legacy = false;
  {
    QMutexLocker lock(&m_pendingMutex);
    overwrote_legacy = !m_pending.isNull();
    m_pending = std::move(owned);
  }
  if (overwrote_legacy) {
    const auto count = m_droppedFrames.fetch_add(
        1, std::memory_order_relaxed) + 1;
    if (count <= 3 || count % 60 == 0) {
      std::fprintf(stderr,
                   "[ghastty] surface=%p dropped frame "
                   "(legacy QImage path, total=%llu)\n",
                   static_cast<void *>(this),
                   static_cast<unsigned long long>(count));
    }
  }
  // Same dedupe as the subsurface path: at most one queued drain
  // pending at a time. drainVulkan resets the flag before consuming.
  bool was_scheduled = false;
  if (m_drainScheduled.compare_exchange_strong(
          was_scheduled, true, std::memory_order_acq_rel)) {
    QMetaObject::invokeMethod(this, "drainVulkan", Qt::QueuedConnection);
  }
}

void GhosttySurface::onWaylandFrameReady() {
  // Compositor has signaled it's ready for our next commit. Flip
  // the gate and wake the renderer thread, which is blocked in
  // presentVulkanDmabuf's wait_for. The renderer will produce its
  // next frame; nothing for us to drain right now (there's no
  // pending dmabuf — the renderer is waiting BEFORE parking).
  {
    std::lock_guard<std::mutex> lg(m_compositorMutex);
    m_compositorReady = true;
  }
  m_compositorCv.notify_all();
}

void GhosttySurface::drainVulkan() {
  // Release the dedupe slot FIRST so a renderer frame parked while
  // this drain runs can immediately schedule its own queued drain
  // (instead of the next post being silently dropped). The atomic
  // ordering: clear-before-consume means a presentVulkanDmabuf that
  // races us still wins the CAS and posts a follow-up drain, so no
  // parked frame is forgotten.
  m_drainScheduled.store(false, std::memory_order_release);

  // Subsurface (zero-copy) path: take the parked dmabuf descriptor
  // under the mutex, then dispatch it to the presenter outside the
  // lock so a renderer-thread `presentVulkanDmabuf` parking the
  // next frame doesn't block on wl_display_flush.
  if (m_hidden.load(std::memory_order_acquire)) {
    // Clear the parked descriptor on hide so the next post-Show
    // present doesn't see a "stale frame still pending" state and
    // spuriously bump m_droppedFrames every Hide/Show cycle. The
    // parked fd is our own dup (created in presentVulkanDmabuf),
    // so we have to close it explicitly to avoid leaking fds on
    // Hide/Show cycles.
    int parked = -1;
    {
      QMutexLocker lock(&m_pendingMutex);
      parked = m_pendingDmabuf.fd;
      m_pendingDmabuf.fd = -1;
    }
    if (parked >= 0) ::close(parked);
    return;
  }
  if (m_useSubsurface.load(std::memory_order_acquire) &&
      m_subsurfacePresenter) {
    // No gate check here: the renderer thread's wait in
    // presentVulkanDmabuf already paced us, so a parked dmabuf
    // means the compositor was ready when the renderer claimed
    // the slot. Just consume + commit.
    PendingDmabuf frame;
    {
      QMutexLocker lock(&m_pendingMutex);
      if (m_pendingDmabuf.fd < 0) return;
      frame = m_pendingDmabuf;
      m_pendingDmabuf.fd = -1;  // mark consumed
    }
    // Wrong-size guard: drop frames whose dimensions don't match
    // the widget's current device-pixel size. The renderer thread
    // produces frames at libghostty's known surface size, which
    // lags the Qt widget's actual layout-determined size during
    // new-tab bring-up (libghostty starts at the default 800×600
    // until the first resizeEvent → ghostty_surface_set_size lands
    // on the renderer thread). Attaching such a wrong-size dmabuf
    // here lets wp_viewport stretch it to widget size — image-
    // pipeline math evaluated against the renderer's smaller
    // viewport produces quads that cover the entire stretched
    // area, manifesting as kitty images rendered at full window
    // size. Drop silently; paintEvent paints the configured
    // background color in the meantime (see m_subsurfaceHasFrame).
    const double dpr_drop = devicePixelRatioF();
    const quint32 expected_w = static_cast<quint32>(
        std::max(1, static_cast<int>(std::lround(width() * dpr_drop))));
    const quint32 expected_h = static_cast<quint32>(
        std::max(1, static_cast<int>(std::lround(height() * dpr_drop))));
    if (frame.width != expected_w || frame.height != expected_h) {
      ::close(frame.fd);
      return;
    }

    // Logical widget size = wp_viewport destination. Buffer is at
    // device pixels (frame.width × frame.height); viewport stretches
    // it to (width(), height()) surface-local coords. Handles
    // fractional DPR correctly without forcing buffer_scale to an
    // integer.
    m_subsurfacePresenter->presentDmabuf(
        frame.fd, frame.drm_format, frame.drm_modifier, frame.width,
        frame.height, frame.stride, width(), height());
    // Subsurface is in sync mode; child commit is cached. Force the
    // parent wl_surface.commit so the cached state applies and the
    // frame becomes visible.
    forceParentCommit();
    // Mark "real frame is attached" so paintEvent stops painting
    // the background-color placeholder and lets the subsurface
    // show through. Release-ordering: paint may be on a different
    // thread (Qt event loop is single-threaded but the atomic
    // contract is cheap to honor).
    const bool placeholder_to_real =
        !m_subsurfaceHasFrame.exchange(true, std::memory_order_acq_rel);
    if (placeholder_to_real) {
      // First real frame after the placeholder paint. The
      // placeholder painted an OPAQUE bg color over the terminal
      // area; the subsurface is stacked BELOW the parent surface,
      // so the parent's opaque pixels obscure the subsurface.
      // Without forcing a fresh paintEvent here, the placeholder
      // visibly persists in the parent backing store until some
      // unrelated event triggers a repaint — that's the "tab
      // opens, sits at bg color, suddenly snaps to real content"
      // jank. update() schedules a paintEvent which (now that
      // m_subsurfaceHasFrame is true) will fill the terminal
      // area transparent and let the subsurface show through.
      update();
    }
    // Close OUR dup of the dmabuf fd now that presentDmabuf has
    // handed it to create_immed (which SCM_RIGHTS-dup'd it again
    // for the compositor's view, or did a cache hit and didn't
    // touch the fd at all — either way we don't need it past this
    // point). Closing here keeps fd usage bounded; without it
    // we'd leak one dup per frame.
    ::close(frame.fd);
    return;
  }

  // Fallback: hand the QImage to paintEvent.
  QImage frame;
  {
    QMutexLocker lock(&m_pendingMutex);
    if (m_pending.isNull()) return;
    frame = std::move(m_pending);
  }
  m_image = std::move(frame);
  update();
}

bool GhosttySurface::forceParentCommit() {
  // Commit the TOP-LEVEL QWindow's wl_surface — the parent of our
  // wl_subsurface. We do NOT have a per-pane native QWindow (see
  // ctor comment about WA_NativeWindow), so windowHandle() on this
  // widget is null; reach the top-level via `window()->windowHandle()`.
  //
  // QtWaylandClient::QWaylandWindow is Qt's private QPA impl
  // (Qt6::WaylandClientPrivate). Calling commit() on it flushes
  // Qt's pending wl_surface state plus any cached child subsurface
  // state from our sync-mode commits.
  QWindow *top = window() ? window()->windowHandle() : nullptr;
  if (!top) return false;
  QPlatformWindow *qpa = top->handle();
  if (!qpa) return false;

  // Use the cached cast result if it points at the current QPA
  // handle. The `dynamic_cast` is the expensive step and this
  // function is on the present hot path. Cache invalidation is
  // event-driven: `PlatformSurfaceAboutToBeDestroyed` (see
  // `event()` above) nulls `m_cachedWaylandWindow` before Qt
  // destroys the QPA. The address-equality check below is purely
  // a "did Qt swap the QPA out from under us via some path that
  // didn't fire the event" sanity check — it does NOT defend
  // against heap reuse (a freed-then-reallocated QPA at the same
  // address would compare equal). Single-allocation Qt QPA
  // lifecycles make heap reuse a non-issue here in practice.
  auto *wl = static_cast<QtWaylandClient::QWaylandWindow *>(m_cachedWaylandWindow);
  if (wl == nullptr || static_cast<QPlatformWindow *>(wl) != qpa) {
    wl = dynamic_cast<QtWaylandClient::QWaylandWindow *>(qpa);
    m_cachedWaylandWindow = wl;
  }
  if (!wl) return false;
  wl->commit();
  return true;
}

// (Frame delivery to GhosttySurface is now via the
// `vulkan::PresentSink` interface declared in `vulkan/Host.h`.
// `vulkan::Host`'s present-callback trampoline calls
// `static_cast<vulkan::PresentSink*>(userdata)->presentDmabuf(...)`,
// which `GhosttySurface::presentDmabuf` (inline forwarder in the
// header) routes to `presentVulkanDmabuf` above. No cross-TU
// `extern void presentToGhosttySurface` symbol any more.)
