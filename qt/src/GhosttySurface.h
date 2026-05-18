#pragma once

#include <QWindow>

#include <EGL/egl.h>

#include "ghostty.h"

class MainWindow;
struct wl_egl_window;  // Wayland; opaque

// One Ghostty terminal surface, rendered into a QWindow. The QWindow is
// embedded into a MainWindow tab via QWidget::createWindowContainer.
//
// Rendering uses raw EGL rather than QOpenGLContext: libghostty's
// renderer thread, which makes the GL context current, is not a QThread.
class GhosttySurface : public QWindow {
  Q_OBJECT

public:
  GhosttySurface(ghostty_app_t app, MainWindow *owner);
  ~GhosttySurface() override;

  // Create the EGL context and the libghostty surface. When `parent` is
  // non-null the new surface inherits its working directory etc.
  bool initialize(ghostty_surface_t parent);

  ghostty_surface_t surface() const { return m_surface; }
  MainWindow *owner() const { return m_owner; }

protected:
  void exposeEvent(QExposeEvent *) override;
  void resizeEvent(QResizeEvent *) override;
  void keyPressEvent(QKeyEvent *) override;
  void keyReleaseEvent(QKeyEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void wheelEvent(QWheelEvent *) override;
  void focusInEvent(QFocusEvent *) override;
  void focusOutEvent(QFocusEvent *) override;

private:
  bool setupEgl();
  void updateSize();
  void sendKey(QKeyEvent *, ghostty_input_action_e action);
  void sendMouseButton(QMouseEvent *, ghostty_input_mouse_state_e state);

  // GL context callbacks (run on libghostty's renderer thread).
  static void *glGetProcAddress(void *ud, const char *name);
  static void glMakeCurrent(void *ud);
  static void glReleaseCurrent(void *ud);
  static void glPresent(void *ud);

  ghostty_app_t m_app;   // shared; owned by MainWindow
  MainWindow *m_owner;   // not owned

  EGLDisplay m_eglDisplay = EGL_NO_DISPLAY;
  EGLContext m_eglContext = EGL_NO_CONTEXT;
  EGLSurface m_eglSurface = EGL_NO_SURFACE;
  // Non-null only on Wayland: the EGL window surface is backed by a
  // wl_egl_window rather than a native X11 window.
  wl_egl_window *m_wlEglWindow = nullptr;

  ghostty_surface_t m_surface = nullptr;
};
