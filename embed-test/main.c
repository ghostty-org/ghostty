// libghostty OpenGL embedding harness (Workstream A4).
//
// A minimal GLFW host that drives libghostty through the
// GHOSTTY_PLATFORM_OPENGL embedded API. Its only purpose is to verify
// that the OpenGL embedded render path (A1 + A2) actually produces a
// rendered terminal. This is throwaway verification scaffolding, not a
// real terminal frontend.
//
// Build: see build.sh in this directory.

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <GLFW/glfw3.h>

#include "ghostty.h"

// State shared with the libghostty callbacks.
typedef struct {
  GLFWwindow *window;
} host_t;

// The single surface, so GLFW input callbacks can reach it.
static ghostty_surface_t g_surface = NULL;

// Set when libghostty asks for a redraw; the main loop then draws.
// libghostty action callbacks may run on a worker thread, so this
// must be atomic to pair the write in on_action with the read in
// the main loop.
static atomic_int g_needs_draw = 1;

// Count of presented frames. A nonzero value confirms the OpenGL
// embedded render path is producing frames.
static atomic_int g_frames = 0;

// --- ghostty_platform_opengl_s callbacks -----------------------------
//
// libghostty draws on the app thread (must_draw_from_app_thread), so
// these run on the main thread.

static void *gl_get_proc_address(void *userdata, const char *name) {
  (void)userdata;
  return (void *)glfwGetProcAddress(name);
}

static void gl_make_current(void *userdata) {
  host_t *h = userdata;
  glfwMakeContextCurrent(h->window);
}

static void gl_release_current(void *userdata) {
  (void)userdata;
  glfwMakeContextCurrent(NULL);
}

static void gl_present(void *userdata) {
  host_t *h = userdata;
  glfwSwapBuffers(h->window);
  atomic_fetch_add(&g_frames, 1);
}

// --- ghostty_runtime_config_s callbacks ------------------------------

static void on_wakeup(void *userdata) {
  (void)userdata;
  // Called from another thread; nudge the main loop so it ticks.
  glfwPostEmptyEvent();
}

static bool on_action(ghostty_app_t app, ghostty_target_s target,
                      ghostty_action_s action) {
  (void)app;
  (void)target;
  // libghostty requests a redraw via the render action; the main loop
  // services it. Other actions are ignored by this harness.
  if (action.tag == GHOSTTY_ACTION_RENDER) {
    atomic_store(&g_needs_draw, 1);
    return true;
  }
  return false;
}

static bool on_read_clipboard(void *userdata, ghostty_clipboard_e loc,
                              void *state) {
  (void)userdata;
  (void)loc;
  (void)state;
  return false;
}

static void on_confirm_read_clipboard(void *userdata, const char *str,
                                      void *state,
                                      ghostty_clipboard_request_e req) {
  (void)userdata;
  (void)str;
  (void)state;
  (void)req;
}

static void on_write_clipboard(void *userdata, ghostty_clipboard_e loc,
                               const ghostty_clipboard_content_s *content,
                               size_t n, bool confirm) {
  (void)userdata;
  (void)loc;
  (void)content;
  (void)n;
  (void)confirm;
}

static void on_close_surface(void *userdata, bool process_active) {
  (void)userdata;
  (void)process_active;
}

// --- GLFW input -> libghostty ----------------------------------------

static void on_char(GLFWwindow *win, unsigned int cp) {
  (void)win;
  if (!g_surface) return;

  // Encode the UTF-32 codepoint to UTF-8 and feed it as text.
  char buf[4];
  int len = 0;
  if (cp < 0x80) {
    buf[len++] = (char)cp;
  } else if (cp < 0x800) {
    buf[len++] = (char)(0xC0 | (cp >> 6));
    buf[len++] = (char)(0x80 | (cp & 0x3F));
  } else if (cp < 0x10000) {
    buf[len++] = (char)(0xE0 | (cp >> 12));
    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[len++] = (char)(0x80 | (cp & 0x3F));
  } else {
    buf[len++] = (char)(0xF0 | (cp >> 18));
    buf[len++] = (char)(0x80 | ((cp >> 12) & 0x3F));
    buf[len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
    buf[len++] = (char)(0x80 | (cp & 0x3F));
  }
  ghostty_surface_text(g_surface, buf, (uintptr_t)len);
}

static void on_framebuffer_size(GLFWwindow *win, int w, int h) {
  (void)win;
  if (g_surface && w > 0 && h > 0) {
    ghostty_surface_set_size(g_surface, (uint32_t)w, (uint32_t)h);
    atomic_store(&g_needs_draw, 1);
  }
}

int main(int argc, char **argv) {
  if (ghostty_init((uintptr_t)argc, argv) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "ghostty_init failed\n");
    return 1;
  }

  if (!glfwInit()) {
    fprintf(stderr, "glfwInit failed (no display?)\n");
    return 1;
  }

  // Ghostty's OpenGL renderer requires at least OpenGL 4.3 core.
  glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
  glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);
  glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
  glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GLFW_TRUE);

  GLFWwindow *window =
      glfwCreateWindow(800, 600, "libghostty OpenGL harness", NULL, NULL);
  if (!window) {
    fprintf(stderr, "glfwCreateWindow failed\n");
    glfwTerminate();
    return 1;
  }

  // libghostty draws on the app thread, so the GL context stays current
  // on this (the main) thread, where glfwCreateWindow left it.

  host_t host = {.window = window};

  // App-level runtime config.
  ghostty_runtime_config_s rt = {0};
  rt.userdata = &host;
  rt.supports_selection_clipboard = false;
  rt.wakeup_cb = on_wakeup;
  rt.action_cb = on_action;
  rt.read_clipboard_cb = on_read_clipboard;
  rt.confirm_read_clipboard_cb = on_confirm_read_clipboard;
  rt.write_clipboard_cb = on_write_clipboard;
  rt.close_surface_cb = on_close_surface;

  ghostty_config_t cfg = ghostty_config_new();
  ghostty_config_finalize(cfg);

  ghostty_app_t app = ghostty_app_new(&rt, cfg);
  if (!app) {
    fprintf(stderr, "ghostty_app_new failed\n");
    return 1;
  }

  float xscale = 1.0f, yscale = 1.0f;
  glfwGetWindowContentScale(window, &xscale, &yscale);

  // Force a widely-available TERM since the libghostty built with
  // -Dapp-runtime=none does not install Ghostty's terminfo.
  ghostty_env_var_s env[] = {
      {"TERM", "xterm-256color"},
  };

  // Surface config: hand libghostty our OpenGL context callbacks.
  ghostty_surface_config_s sc = ghostty_surface_config_new();
  sc.platform_tag = GHOSTTY_PLATFORM_OPENGL;
  sc.platform.opengl = (ghostty_platform_opengl_s){
      .userdata = &host,
      .get_proc_address = gl_get_proc_address,
      .make_current = gl_make_current,
      .release_current = gl_release_current,
      .present = gl_present,
  };
  sc.userdata = &host;
  sc.scale_factor = xscale;
  sc.env_vars = env;
  sc.env_var_count = sizeof(env) / sizeof(env[0]);

  ghostty_surface_t surface = ghostty_surface_new(app, &sc);
  if (!surface) {
    fprintf(stderr, "ghostty_surface_new failed\n");
    return 1;
  }
  g_surface = surface;

  int fbw, fbh;
  glfwGetFramebufferSize(window, &fbw, &fbh);
  ghostty_surface_set_content_scale(surface, xscale, yscale);
  ghostty_surface_set_size(surface, (uint32_t)fbw, (uint32_t)fbh);
  ghostty_surface_set_focus(surface, true);

  glfwSetCharCallback(window, on_char);
  glfwSetFramebufferSizeCallback(window, on_framebuffer_size);

  printf("harness running — a terminal should render. "
         "Close the window to exit.\n");
  fflush(stdout);

  // Main loop: pump GLFW events, tick libghostty, and draw when asked.
  double next_report = glfwGetTime() + 1.0;
  while (!glfwWindowShouldClose(window)) {
    glfwWaitEventsTimeout(0.1);
    ghostty_app_tick(app);
    if (ghostty_surface_process_exited(surface)) {
      glfwSetWindowShouldClose(window, GLFW_TRUE);
      break;
    }

    // libghostty requested a draw (via the render action); service it
    // on this thread. atomic_exchange clears the flag and reads it in
    // one step, so a wakeup setting it again between the read and
    // the draw is preserved for the next iteration.
    if (atomic_exchange(&g_needs_draw, 0)) {
      ghostty_surface_draw(surface);
    }

    // Report presented-frame count once per second.
    double now = glfwGetTime();
    if (now >= next_report) {
      printf("frames presented: %d\n", atomic_load(&g_frames));
      fflush(stdout);
      next_report = now + 1.0;
    }
  }

  printf("exiting — total frames presented: %d\n", atomic_load(&g_frames));

  ghostty_surface_free(surface);
  ghostty_app_free(app);
  ghostty_config_free(cfg);
  glfwDestroyWindow(window);
  glfwTerminate();
  return 0;
}
