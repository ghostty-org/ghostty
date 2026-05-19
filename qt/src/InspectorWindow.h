#pragma once

#include <QImage>
#include <QWidget>

#include "ghostty.h"

class QOffscreenSurface;
class QOpenGLContext;
class QOpenGLFramebufferObject;
class QTimer;

// A window hosting libghostty's terminal inspector — a Dear ImGui debug
// UI. libghostty renders the inspector through ghostty_inspector_opengl_*
// into an offscreen framebuffer owned by a private QOpenGLContext; each
// frame is read back into a QImage and painted, mirroring how
// GhosttySurface composites the terminal.
class InspectorWindow : public QWidget {
  Q_OBJECT

public:
  // `surface` is the terminal surface being inspected.
  explicit InspectorWindow(ghostty_surface_t surface);
  ~InspectorWindow() override;

protected:
  void paintEvent(QPaintEvent *) override;
  void resizeEvent(QResizeEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void wheelEvent(QWheelEvent *) override;
  void keyPressEvent(QKeyEvent *) override;
  void keyReleaseEvent(QKeyEvent *) override;
  void focusInEvent(QFocusEvent *) override;
  void focusOutEvent(QFocusEvent *) override;

private:
  bool makeCurrent();
  void renderFrame();              // render the inspector, read it back
  void syncSize();                 // push the size/scale to libghostty
  void sendMouseButton(QMouseEvent *, ghostty_input_mouse_state_e state);

  ghostty_surface_t m_surface;
  ghostty_inspector_t m_inspector = nullptr;

  // Private offscreen GL context the inspector renders into.
  QOpenGLContext *m_context = nullptr;
  QOffscreenSurface *m_offscreen = nullptr;
  QOpenGLFramebufferObject *m_fbo = nullptr;
  QImage m_image;                  // last frame, read back from m_fbo
  QTimer *m_timer = nullptr;       // drives ~30fps redraws while visible
  bool m_glReady = false;          // ghostty_inspector_opengl_init done
};
