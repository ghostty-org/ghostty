#include "WindowBlur.h"

#include <cstdlib>
#include <cstring>

#include <QGuiApplication>
#include <QHash>
#include <QString>
#include <QWidget>
#include <QWindow>
#include <qpa/qplatformnativeinterface.h>

#include <wayland-client.h>

#include <xcb/xcb.h>

#include "blur-client-protocol.h"

namespace {

// --- Wayland (org_kde_kwin_blur) -------------------------------------

// Found while enumerating the registry; cached for the process.
struct BlurGlobals {
  org_kde_kwin_blur_manager *manager = nullptr;
  bool searched = false;
};

void registryGlobal(void *data, wl_registry *registry, uint32_t name,
                     const char *interface, uint32_t) {
  auto *g = static_cast<BlurGlobals *>(data);
  if (std::strcmp(interface, org_kde_kwin_blur_manager_interface.name) == 0)
    g->manager = static_cast<org_kde_kwin_blur_manager *>(wl_registry_bind(
        registry, name, &org_kde_kwin_blur_manager_interface, 1));
}
void registryGlobalRemove(void *, wl_registry *, uint32_t) {}

const wl_registry_listener kRegistryListener = {registryGlobal,
                                                registryGlobalRemove};

// Bind the KWin blur manager, enumerating the registry on a private
// event queue so this never dispatches Qt's own Wayland events.
org_kde_kwin_blur_manager *blurManager(wl_display *display) {
  static BlurGlobals globals;
  if (globals.searched) return globals.manager;
  globals.searched = true;

  wl_event_queue *queue = wl_display_create_queue(display);
  wl_registry *registry = wl_display_get_registry(display);
  wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(registry), queue);
  wl_registry_add_listener(registry, &kRegistryListener, &globals);
  wl_display_roundtrip_queue(display, queue);
  wl_registry_destroy(registry);
  // The manager outlives this private queue, so move it (and the blur
  // objects later created from it) back to the display's default queue
  // before the private queue is destroyed.
  if (globals.manager)
    wl_proxy_set_queue(reinterpret_cast<wl_proxy *>(globals.manager), nullptr);
  wl_event_queue_destroy(queue);
  return globals.manager;
}

// The live blur object per window — kept so it can be released when
// blur is turned off, re-applied on a config change, or the window
// itself is destroyed.
static QHash<QWindow *, org_kde_kwin_blur *> &waylandBlurs() {
  static QHash<QWindow *, org_kde_kwin_blur *> blurs;
  return blurs;
}

void applyWayland(QWindow *window, bool enabled) {
  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return;
  auto *display = static_cast<wl_display *>(
      native->nativeResourceForIntegration("wl_display"));
  auto *surface = static_cast<wl_surface *>(
      native->nativeResourceForWindow("surface", window));
  if (!display || !surface) return;

  org_kde_kwin_blur_manager *manager = blurManager(display);
  if (!manager) return;  // compositor advertises no blur support

  auto &blurs = waylandBlurs();
  // `take` returns and removes the prior blur if any. Knowing whether
  // we're seeing this window for the first time decides whether we
  // need a fresh `destroyed` connection — re-applying blur on an
  // already-tracked window must NOT add a second connection.
  const bool firstTime = !blurs.contains(window);
  if (org_kde_kwin_blur *old = blurs.take(window))
    org_kde_kwin_blur_release(old);

  if (enabled) {
    org_kde_kwin_blur *blur = org_kde_kwin_blur_manager_create(manager,
                                                               surface);
    org_kde_kwin_blur_set_region(blur, nullptr);  // null = whole surface
    org_kde_kwin_blur_commit(blur);
    blurs.insert(window, blur);

    // Release the blur object when the window goes away. Connect once
    // per window — repeated applyBlur(window, true) calls would
    // otherwise stack N stale lambdas on the destroyed signal.
    if (firstTime) {
      QObject::connect(window, &QWindow::destroyed, qApp, [window]() {
        auto &b = waylandBlurs();
        if (org_kde_kwin_blur *old = b.take(window))
          org_kde_kwin_blur_release(old);
      });
    }
  } else {
    org_kde_kwin_blur_manager_unset(manager, surface);
  }
  wl_display_flush(display);
}

// --- X11 (_KDE_NET_WM_BLUR_BEHIND_REGION) ----------------------------

void applyX11(QWindow *window, bool enabled) {
  QPlatformNativeInterface *native = QGuiApplication::platformNativeInterface();
  if (!native) return;
  auto *conn = static_cast<xcb_connection_t *>(
      native->nativeResourceForIntegration("connection"));
  if (!conn) return;
  const auto xid = static_cast<xcb_window_t>(window->winId());

  static const char kName[] = "_KDE_NET_WM_BLUR_BEHIND_REGION";
  xcb_intern_atom_reply_t *reply = xcb_intern_atom_reply(
      conn, xcb_intern_atom(conn, 0, std::strlen(kName), kName), nullptr);
  if (!reply) return;
  const xcb_atom_t atom = reply->atom;
  std::free(reply);

  if (enabled)
    // An empty region property blurs the whole window.
    xcb_change_property(conn, XCB_PROP_MODE_REPLACE, xid, atom,
                        XCB_ATOM_CARDINAL, 32, 0, nullptr);
  else
    xcb_delete_property(conn, xid, atom);
  xcb_flush(conn);
}

}  // namespace

void applyWindowBlur(QWidget *window, bool enabled) {
  if (!window) return;
  QWindow *handle = window->windowHandle();
  if (!handle) return;  // not a native window yet

  const QString platform = QGuiApplication::platformName();
  if (platform.startsWith(QLatin1String("wayland")))
    applyWayland(handle, enabled);
  else if (platform == QLatin1String("xcb"))
    applyX11(handle, enabled);
}
