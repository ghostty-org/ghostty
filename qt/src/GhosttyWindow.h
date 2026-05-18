#pragma once

#include <QWindow>

#include <EGL/egl.h>

#include "ghostty.h"

// A single Ghostty terminal surface hosted in a Qt QWindow.
//
// Rendering: libghostty owns a dedicated renderer thread and drives the
// GL context through the gl* callbacks below. We use raw EGL rather than
// QOpenGLContext because eglMakeCurrent is callable from any thread,
// whereas a QOpenGLContext is bound to the QThread it belongs to and
// libghostty's renderer thread is not a QThread.
//
// Scaffold scope (milestone M2): renders, resizes, tracks focus/DPI, and
// accepts text input. Full key translation, mouse, clipboard and action
// handling are marked TODO and belong to later milestones.
class GhosttyWindow : public QWindow {
  Q_OBJECT

public:
  GhosttyWindow();
  ~GhosttyWindow() override;

  // Create the EGL context and the libghostty app + surface. Call once
  // before show(). Returns false on failure.
  bool initialize();

public slots:
  // Pump libghostty's app-level work. Invoked from the wakeup callback
  // (queued onto the GUI thread) and by a periodic timer.
  void tick();

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

  // --- GL context callbacks (run on libghostty's renderer thread) ---
  static void *glGetProcAddress(void *ud, const char *name);
  static void glMakeCurrent(void *ud);
  static void glReleaseCurrent(void *ud);
  static void glPresent(void *ud);

  // --- libghostty runtime callbacks ---
  static void onWakeup(void *ud);
  static bool onAction(ghostty_app_t, ghostty_target_s, ghostty_action_s);
  static bool onReadClipboard(void *ud, ghostty_clipboard_e, void *state);
  static void onConfirmReadClipboard(void *ud, const char *, void *state,
                                     ghostty_clipboard_request_e);
  static void onWriteClipboard(void *ud, ghostty_clipboard_e,
                               const ghostty_clipboard_content_s *, size_t,
                               bool);
  static void onCloseSurface(void *ud, bool process_active);

  // EGL state.
  EGLDisplay m_eglDisplay = EGL_NO_DISPLAY;
  EGLContext m_eglContext = EGL_NO_CONTEXT;
  EGLSurface m_eglSurface = EGL_NO_SURFACE;

  // libghostty handles.
  ghostty_config_t m_config = nullptr;
  ghostty_app_t m_app = nullptr;
  ghostty_surface_t m_surface = nullptr;

  unsigned m_tickCount = 0;
};
