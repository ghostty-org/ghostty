#pragma once

#include <QImage>
#include <QWidget>

#include "ghostty.h"

class MainWindow;
class QOffscreenSurface;
class QOpenGLContext;
class QOpenGLFramebufferObject;
class QOpenGLShaderProgram;
class QOpenGLVertexArrayObject;

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

public slots:
  // Render a fresh frame (the libghostty RENDER action).
  void requestRender();

protected:
  bool event(QEvent *) override;
  void paintEvent(QPaintEvent *) override;
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
  bool makeCurrent();
  void syncSurfaceSize();
  void renderTerminal();
  void sendKey(QKeyEvent *, ghostty_input_action_e action);
  void sendMouseButton(QMouseEvent *, ghostty_input_mouse_state_e state);

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
};
