#pragma once

#include <QOpenGLWidget>

#include "ghostty.h"

class MainWindow;

// One Ghostty terminal surface, rendered with a QOpenGLWidget.
//
// libghostty draws on the GUI thread — the embedded apprt sets
// must_draw_from_app_thread for the OpenGL renderer — so rendering is
// driven straight from paintGL. Qt owns the GL context and composites
// the widget, which works identically on X11 and Wayland.
class GhosttySurface : public QOpenGLWidget {
  Q_OBJECT

public:
  // `parent_surface` (may be null) is the surface whose working
  // directory etc. a new surface should inherit.
  GhosttySurface(ghostty_app_t app, MainWindow *owner,
                 ghostty_surface_t parent_surface);
  ~GhosttySurface() override;

  ghostty_surface_t surface() const { return m_surface; }
  MainWindow *owner() const { return m_owner; }

protected:
  void initializeGL() override;
  void paintGL() override;
  void resizeGL(int w, int h) override;

  void keyPressEvent(QKeyEvent *) override;
  void keyReleaseEvent(QKeyEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void wheelEvent(QWheelEvent *) override;
  void focusInEvent(QFocusEvent *) override;
  void focusOutEvent(QFocusEvent *) override;

private:
  void syncSize();
  void sendKey(QKeyEvent *, ghostty_input_action_e action);
  void sendMouseButton(QMouseEvent *, ghostty_input_mouse_state_e state);

  // libghostty GL platform callbacks (all run on the GUI thread).
  static void *glGetProcAddress(void *ud, const char *name);
  static void glMakeCurrent(void *ud);
  static void glReleaseCurrent(void *ud);
  static void glPresent(void *ud);

  ghostty_app_t m_app;                 // shared; owned by MainWindow
  MainWindow *m_owner;                 // not owned
  ghostty_surface_t m_parentSurface;   // inherited-config source; may be null
  ghostty_surface_t m_surface = nullptr;

  // Last framebuffer size pushed to libghostty, to skip redundant work.
  int m_lastW = 0;
  int m_lastH = 0;
};
