#include <gtk/gtk.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ghostty.h"

typedef struct Host Host;

struct Host {
  GtkApplication *app;
  GtkWindow *window;
  GtkGLArea *gl_area;
  GtkEventController *key_controller;
  GtkEventController *focus_controller;
  GtkEventController *motion_controller;
  GtkEventController *scroll_controller;
  GtkGesture *click_gesture;
  ghostty_config_t config;
  ghostty_app_t ghostty_app;
  ghostty_surface_t surface;
  gboolean tick_pending;
  gboolean injected;
  guint verify_attempts;
  int exit_code;
};

static gboolean host_app_tick(gpointer data);
static gboolean host_request_render(gpointer data);
static gboolean host_inject_text(gpointer data);
static gboolean host_verify_output(gpointer data);

typedef struct {
  Host *host;
  void *request;
} PendingClipboardRead;

static ghostty_input_mods_e translate_mods(GdkModifierType state) {
  ghostty_input_mods_e mods = GHOSTTY_MODS_NONE;

  if ((state & GDK_SHIFT_MASK) != 0) {
    mods |= GHOSTTY_MODS_SHIFT;
  }
  if ((state & GDK_CONTROL_MASK) != 0) {
    mods |= GHOSTTY_MODS_CTRL;
  }
  if ((state & GDK_ALT_MASK) != 0) {
    mods |= GHOSTTY_MODS_ALT;
  }
  if ((state & GDK_SUPER_MASK) != 0 || (state & GDK_META_MASK) != 0) {
    mods |= GHOSTTY_MODS_SUPER;
  }
  if ((state & GDK_LOCK_MASK) != 0) {
    mods |= GHOSTTY_MODS_CAPS;
  }

  return mods;
}

static ghostty_input_mouse_button_e translate_mouse_button(guint button) {
  switch (button) {
    case GDK_BUTTON_PRIMARY:
      return GHOSTTY_MOUSE_LEFT;
    case GDK_BUTTON_MIDDLE:
      return GHOSTTY_MOUSE_MIDDLE;
    case GDK_BUTTON_SECONDARY:
      return GHOSTTY_MOUSE_RIGHT;
    case 8:
      return GHOSTTY_MOUSE_FOUR;
    case 9:
      return GHOSTTY_MOUSE_FIVE;
    default:
      return GHOSTTY_MOUSE_UNKNOWN;
  }
}

static uint32_t unshifted_codepoint_for_keyval(guint keyval) {
  gunichar lower = gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval));
  return lower == 0 ? 0 : (uint32_t)lower;
}

static const char *text_for_keyval(guint keyval,
                                   GdkModifierType state,
                                   char buffer[8]) {
  if ((state & (GDK_CONTROL_MASK | GDK_SUPER_MASK)) != 0) {
    return NULL;
  }

  gunichar codepoint = gdk_keyval_to_unicode(keyval);
  if (codepoint == 0 || g_unichar_iscntrl(codepoint)) {
    return NULL;
  }

  gint len = g_unichar_to_utf8(codepoint, buffer);
  if (len <= 0) {
    return NULL;
  }

  buffer[len] = '\0';
  return buffer;
}

static gboolean host_send_key(Host *host,
                              ghostty_input_action_e action,
                              guint keyval,
                              guint keycode,
                              GdkModifierType state) {
  if (host->surface == NULL) {
    return FALSE;
  }

  char text_buffer[8] = {0};
  const char *text =
      action == GHOSTTY_ACTION_RELEASE ? NULL
                                       : text_for_keyval(keyval, state, text_buffer);

  ghostty_input_key_s event = {
      .action = action,
      .mods = translate_mods(state),
      .consumed_mods = GHOSTTY_MODS_NONE,
      .keycode = keycode,
      .text = text,
      .unshifted_codepoint = unshifted_codepoint_for_keyval(keyval),
      .composing = false,
  };

  return ghostty_surface_key(host->surface, event);
}

static void host_update_pointer(Host *host,
                                double x,
                                double y,
                                GdkModifierType state) {
  if (host->surface == NULL) {
    return;
  }

  ghostty_surface_mouse_pos(host->surface, x, y, translate_mods(state));
}

static GdkClipboard *host_clipboard(Host *host, ghostty_clipboard_e clipboard) {
  if (host->gl_area == NULL) {
    return NULL;
  }

  GdkDisplay *display = gtk_widget_get_display(GTK_WIDGET(host->gl_area));
  if (display == NULL) {
    return NULL;
  }

  switch (clipboard) {
    case GHOSTTY_CLIPBOARD_STANDARD:
      return gdk_display_get_clipboard(display);
    case GHOSTTY_CLIPBOARD_SELECTION:
      return gdk_display_get_primary_clipboard(display);
    default:
      return NULL;
  }
}

static void clipboard_read_done(GObject *source_object,
                                GAsyncResult *result,
                                gpointer user_data) {
  PendingClipboardRead *pending = user_data;
  g_autoptr(GError) error = NULL;
  char *text =
      gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source_object), result, &error);

  if (pending->host->surface != NULL) {
    ghostty_surface_complete_clipboard_request(
        pending->host->surface,
        text != NULL ? text : "",
        pending->request,
        false);
  }

  g_free(text);
  g_free(pending);
}

static bool runtime_action_cb(ghostty_app_t app,
                              ghostty_target_s target,
                              ghostty_action_s action) {
  (void)app;

  if (target.tag != GHOSTTY_TARGET_SURFACE) {
    return false;
  }

  Host *host = ghostty_surface_userdata(target.target.surface);
  if (host == NULL) {
    return false;
  }

  switch (action.tag) {
    case GHOSTTY_ACTION_RENDER:
      if (g_main_context_is_owner(NULL)) {
        gtk_gl_area_queue_render(host->gl_area);
      } else {
        g_main_context_invoke(NULL, host_request_render, host);
      }
      return true;

    case GHOSTTY_ACTION_SET_TITLE:
      if (action.action.set_title.title != NULL) {
        gtk_window_set_title(host->window, action.action.set_title.title);
      }
      return true;

    case GHOSTTY_ACTION_CLOSE_WINDOW:
      g_application_quit(G_APPLICATION(host->app));
      return true;

    case GHOSTTY_ACTION_SIZE_LIMIT:
    case GHOSTTY_ACTION_INITIAL_SIZE:
    case GHOSTTY_ACTION_CELL_SIZE:
    case GHOSTTY_ACTION_RENDERER_HEALTH:
    case GHOSTTY_ACTION_MOUSE_SHAPE:
    case GHOSTTY_ACTION_MOUSE_VISIBILITY:
    case GHOSTTY_ACTION_MOUSE_OVER_LINK:
    case GHOSTTY_ACTION_SCROLLBAR:
    case GHOSTTY_ACTION_PWD:
    case GHOSTTY_ACTION_KEY_SEQUENCE:
    case GHOSTTY_ACTION_KEY_TABLE:
    case GHOSTTY_ACTION_COLOR_CHANGE:
    case GHOSTTY_ACTION_CONFIG_CHANGE:
    case GHOSTTY_ACTION_RELOAD_CONFIG:
    case GHOSTTY_ACTION_QUIT_TIMER:
    case GHOSTTY_ACTION_COMMAND_FINISHED:
    case GHOSTTY_ACTION_START_SEARCH:
    case GHOSTTY_ACTION_END_SEARCH:
    case GHOSTTY_ACTION_SEARCH_TOTAL:
    case GHOSTTY_ACTION_SEARCH_SELECTED:
    case GHOSTTY_ACTION_READONLY:
      return false;

    default:
      return false;
  }
}

static void runtime_wakeup_cb(void *userdata) {
  Host *host = userdata;
  if (host->tick_pending) {
    return;
  }

  host->tick_pending = TRUE;
  g_main_context_invoke(NULL, host_app_tick, host);
}

static bool runtime_read_clipboard_cb(void *userdata,
                                      ghostty_clipboard_e clipboard,
                                      void *request) {
  Host *host = userdata;
  GdkClipboard *gdk_clipboard = host_clipboard(host, clipboard);
  if (gdk_clipboard == NULL || host->surface == NULL) {
    return false;
  }

  PendingClipboardRead *pending = g_new0(PendingClipboardRead, 1);
  pending->host = host;
  pending->request = request;
  gdk_clipboard_read_text_async(gdk_clipboard, NULL, clipboard_read_done, pending);
  return true;
}

static void runtime_confirm_read_clipboard_cb(
    void *userdata,
    const char *text,
    void *request,
    ghostty_clipboard_request_e request_type) {
  Host *host = userdata;
  (void)request_type;
  if (host->surface == NULL) {
    return;
  }

  ghostty_surface_complete_clipboard_request(
      host->surface,
      text != NULL ? text : "",
      request,
      true);
}

static void runtime_write_clipboard_cb(
    void *userdata,
    ghostty_clipboard_e clipboard,
    const ghostty_clipboard_content_s *contents,
    size_t len,
    bool confirm) {
  Host *host = userdata;
  (void)confirm;
  GdkClipboard *gdk_clipboard = host_clipboard(host, clipboard);
  if (gdk_clipboard == NULL) {
    return;
  }

  for (size_t i = 0; i < len; i++) {
    if (g_strcmp0(contents[i].mime, "text/plain;charset=utf-8") == 0 ||
        g_strcmp0(contents[i].mime, "text/plain") == 0) {
      gdk_clipboard_set_text(gdk_clipboard, contents[i].data);
      return;
    }
  }
}

static void runtime_close_surface_cb(void *userdata, bool process_alive) {
  Host *host = userdata;
  (void)process_alive;
  g_application_quit(G_APPLICATION(host->app));
}

static gboolean host_app_tick(gpointer data) {
  Host *host = data;
  host->tick_pending = FALSE;
  ghostty_app_tick(host->ghostty_app);
  return G_SOURCE_REMOVE;
}

static gboolean host_request_render(gpointer data) {
  Host *host = data;
  gtk_gl_area_queue_render(host->gl_area);
  return G_SOURCE_REMOVE;
}

static void host_create_surface(Host *host) {
  if (host->surface != NULL) {
    return;
  }

  ghostty_surface_config_s surface_config = ghostty_surface_config_new();
  surface_config.platform_tag = GHOSTTY_PLATFORM_LINUX;
  surface_config.platform.linux_.gtk_gl_area = host->gl_area;
  surface_config.userdata = host;
  surface_config.scale_factor =
      gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area));

  host->surface = ghostty_surface_new(host->ghostty_app, &surface_config);
  if (host->surface == NULL) {
    fprintf(stderr, "ghostty_surface_new failed\n");
    host->exit_code = 1;
    g_application_quit(G_APPLICATION(host->app));
    return;
  }

  ghostty_surface_set_focus(host->surface, true);
  ghostty_app_set_focus(host->ghostty_app, true);
  ghostty_surface_set_content_scale(
      host->surface,
      gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area)),
      gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area)));

  const int width = gtk_widget_get_width(GTK_WIDGET(host->gl_area));
  const int height = gtk_widget_get_height(GTK_WIDGET(host->gl_area));
  if (width > 0 && height > 0) {
    ghostty_surface_set_size(host->surface, (uint32_t)width, (uint32_t)height);
  }

  g_timeout_add(400, host_inject_text, host);
}

static void gl_area_realize(GtkGLArea *gl_area, gpointer data) {
  Host *host = data;
  gtk_gl_area_make_current(gl_area);
  if (gtk_gl_area_get_error(gl_area) != NULL) {
    fprintf(stderr, "GtkGLArea failed to become current\n");
    host->exit_code = 1;
    g_application_quit(G_APPLICATION(host->app));
    return;
  }

  if (host->surface == NULL) {
    host_create_surface(host);
  } else {
    ghostty_surface_set_linux_gtk_gl_area(host->surface, gl_area);
    ghostty_surface_display_realized(host->surface);
    ghostty_surface_set_content_scale(
        host->surface,
        gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area)),
        gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area)));

    const int width = gtk_widget_get_width(GTK_WIDGET(host->gl_area));
    const int height = gtk_widget_get_height(GTK_WIDGET(host->gl_area));
    if (width > 0 && height > 0) {
      ghostty_surface_set_size(host->surface, (uint32_t)width, (uint32_t)height);
    }
  }
}

static void gl_area_unrealize(GtkGLArea *gl_area, gpointer data) {
  Host *host = data;
  if (host->surface == NULL) {
    return;
  }

  gtk_gl_area_make_current(gl_area);
  if (gtk_gl_area_get_error(gl_area) != NULL) {
    return;
  }

  ghostty_surface_display_unrealized(host->surface);
}

static gboolean gl_area_render(GtkGLArea *gl_area,
                               GdkGLContext *context,
                               gpointer data) {
  Host *host = data;
  (void)gl_area;
  (void)context;

  if (host->surface != NULL) {
    ghostty_surface_draw(host->surface);
  }

  return TRUE;
}

static void gl_area_resize(GtkGLArea *gl_area,
                           int width,
                           int height,
                           gpointer data) {
  Host *host = data;
  (void)gl_area;

  if (host->surface == NULL || width <= 0 || height <= 0) {
    return;
  }

  const double scale = gtk_widget_get_scale_factor(GTK_WIDGET(host->gl_area));
  ghostty_surface_set_content_scale(host->surface, scale, scale);
  ghostty_surface_set_size(host->surface, (uint32_t)width, (uint32_t)height);
}

static void focus_enter(GtkEventControllerFocus *controller, gpointer data) {
  Host *host = data;
  (void)controller;
  if (host->surface != NULL) {
    ghostty_app_set_focus(host->ghostty_app, true);
    ghostty_surface_set_focus(host->surface, true);
  }
}

static void focus_leave(GtkEventControllerFocus *controller, gpointer data) {
  Host *host = data;
  (void)controller;
  if (host->surface != NULL) {
    ghostty_app_set_focus(host->ghostty_app, false);
    ghostty_surface_set_focus(host->surface, false);
  }
}

static gboolean key_pressed(GtkEventControllerKey *controller,
                            guint keyval,
                            guint keycode,
                            GdkModifierType state,
                            gpointer data) {
  Host *host = data;
  (void)controller;
  return host_send_key(host, GHOSTTY_ACTION_PRESS, keyval, keycode, state);
}

static void key_released(GtkEventControllerKey *controller,
                         guint keyval,
                         guint keycode,
                         GdkModifierType state,
                         gpointer data) {
  Host *host = data;
  (void)controller;
  (void)host_send_key(host, GHOSTTY_ACTION_RELEASE, keyval, keycode, state);
}

static gboolean key_modifiers(GtkEventControllerKey *controller,
                              GdkModifierType state,
                              gpointer data) {
  Host *host = data;
  (void)controller;
  (void)state;
  if (host->ghostty_app != NULL) {
    ghostty_app_keyboard_changed(host->ghostty_app);
  }
  return FALSE;
}

static void motion_event(GtkEventControllerMotion *controller,
                         double x,
                         double y,
                         gpointer data) {
  Host *host = data;
  host_update_pointer(
      host,
      x,
      y,
      gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(controller)));
}

static void motion_leave(GtkEventControllerMotion *controller, gpointer data) {
  Host *host = data;
  if (host->surface == NULL) {
    return;
  }
  ghostty_surface_mouse_pos(
      host->surface,
      -1,
      -1,
      translate_mods(gtk_event_controller_get_current_event_state(
          GTK_EVENT_CONTROLLER(controller))));
}

static void click_pressed(GtkGestureClick *gesture,
                          int n_press,
                          double x,
                          double y,
                          gpointer data) {
  Host *host = data;
  (void)n_press;
  if (host->surface == NULL) {
    return;
  }

  gtk_widget_grab_focus(GTK_WIDGET(host->gl_area));
  ghostty_app_set_focus(host->ghostty_app, true);
  ghostty_surface_set_focus(host->surface, true);
  host_update_pointer(
      host,
      x,
      y,
      gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)));

  ghostty_input_mouse_button_e button = translate_mouse_button(
      gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)));
  if (button == GHOSTTY_MOUSE_UNKNOWN) {
    return;
  }

  (void)ghostty_surface_mouse_button(
      host->surface,
      GHOSTTY_MOUSE_PRESS,
      button,
      translate_mods(gtk_event_controller_get_current_event_state(
          GTK_EVENT_CONTROLLER(gesture))));
}

static void click_released(GtkGestureClick *gesture,
                           int n_press,
                           double x,
                           double y,
                           gpointer data) {
  Host *host = data;
  (void)n_press;
  if (host->surface == NULL) {
    return;
  }

  host_update_pointer(
      host,
      x,
      y,
      gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(gesture)));

  ghostty_input_mouse_button_e button = translate_mouse_button(
      gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture)));
  if (button == GHOSTTY_MOUSE_UNKNOWN) {
    return;
  }

  (void)ghostty_surface_mouse_button(
      host->surface,
      GHOSTTY_MOUSE_RELEASE,
      button,
      translate_mods(gtk_event_controller_get_current_event_state(
          GTK_EVENT_CONTROLLER(gesture))));
}

static gboolean scroll_event(GtkEventControllerScroll *controller,
                             double dx,
                             double dy,
                             gpointer data) {
  Host *host = data;
  if (host->surface == NULL) {
    return FALSE;
  }

  ghostty_input_scroll_mods_t scroll_mods =
      gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_SURFACE
          ? 1
          : 0;
  const double multiplier = scroll_mods != 0 ? 10.0 : 1.0;

  ghostty_surface_mouse_scroll(
      host->surface,
      -dx * multiplier,
      -dy * multiplier,
      scroll_mods);
  return TRUE;
}

static gboolean host_inject_text(gpointer data) {
  Host *host = data;
  if (host->surface == NULL || host->injected) {
    return G_SOURCE_REMOVE;
  }

  host->injected = TRUE;
  ghostty_surface_text(host->surface, "echo smoke\n", strlen("echo smoke\n"));
  g_timeout_add(250, host_verify_output, host);
  return G_SOURCE_REMOVE;
}

static gboolean host_verify_output(gpointer data) {
  Host *host = data;
  ghostty_text_s text = {0};
  ghostty_selection_s selection = {
      .top_left =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_TOP_LEFT,
              .x = 0,
              .y = 0,
          },
      .bottom_right =
          {
              .tag = GHOSTTY_POINT_VIEWPORT,
              .coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
              .x = 0,
              .y = 0,
          },
      .rectangle = false,
  };

  if (host->surface != NULL &&
      ghostty_surface_read_text(host->surface, selection, &text)) {
    bool success = text.text != NULL && strstr(text.text, "smoke") != NULL;
    ghostty_surface_free_text(host->surface, &text);

    if (success) {
      host->exit_code = 0;
      g_application_quit(G_APPLICATION(host->app));
      return G_SOURCE_REMOVE;
    }
  }

  host->verify_attempts++;
  if (host->verify_attempts >= 20) {
    fprintf(stderr, "timed out waiting for embedded Ghostty output\n");
    host->exit_code = 1;
    g_application_quit(G_APPLICATION(host->app));
    return G_SOURCE_REMOVE;
  }

  return G_SOURCE_CONTINUE;
}

static void app_activate(GApplication *app, gpointer data) {
  Host *host = data;
  GtkWidget *window = gtk_application_window_new(GTK_APPLICATION(app));
  GtkWidget *gl_area = gtk_gl_area_new();

  host->window = GTK_WINDOW(window);
  host->gl_area = GTK_GL_AREA(gl_area);

  gtk_window_set_default_size(host->window, 960, 540);
  gtk_window_set_title(host->window, "Ghostty Embedded GTK Smoke Test");
  gtk_gl_area_set_required_version(host->gl_area, 4, 3);
  gtk_gl_area_set_auto_render(host->gl_area, FALSE);
  gtk_gl_area_set_has_depth_buffer(host->gl_area, FALSE);
  gtk_gl_area_set_has_stencil_buffer(host->gl_area, FALSE);
  gtk_widget_set_focusable(gl_area, TRUE);

  host->key_controller = gtk_event_controller_key_new();
  host->focus_controller = gtk_event_controller_focus_new();
  host->motion_controller = gtk_event_controller_motion_new();
  host->scroll_controller = gtk_event_controller_scroll_new(
      GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
  host->click_gesture = gtk_gesture_click_new();

  g_signal_connect(host->key_controller,
                   "key-pressed",
                   G_CALLBACK(key_pressed),
                   host);
  g_signal_connect(host->key_controller,
                   "key-released",
                   G_CALLBACK(key_released),
                   host);
  g_signal_connect(host->key_controller,
                   "modifiers",
                   G_CALLBACK(key_modifiers),
                   host);
  g_signal_connect(host->focus_controller, "enter", G_CALLBACK(focus_enter), host);
  g_signal_connect(host->focus_controller, "leave", G_CALLBACK(focus_leave), host);
  g_signal_connect(host->motion_controller,
                   "motion",
                   G_CALLBACK(motion_event),
                   host);
  g_signal_connect(host->motion_controller,
                   "leave",
                   G_CALLBACK(motion_leave),
                   host);
  g_signal_connect(host->scroll_controller,
                   "scroll",
                   G_CALLBACK(scroll_event),
                   host);
  g_signal_connect(host->click_gesture,
                   "pressed",
                   G_CALLBACK(click_pressed),
                   host);
  g_signal_connect(host->click_gesture,
                   "released",
                   G_CALLBACK(click_released),
                   host);

  gtk_widget_add_controller(gl_area, host->key_controller);
  gtk_widget_add_controller(gl_area, host->focus_controller);
  gtk_widget_add_controller(gl_area, host->motion_controller);
  gtk_widget_add_controller(gl_area, host->scroll_controller);
  gtk_widget_add_controller(gl_area, GTK_EVENT_CONTROLLER(host->click_gesture));

  g_signal_connect(gl_area, "realize", G_CALLBACK(gl_area_realize), host);
  g_signal_connect(gl_area, "unrealize", G_CALLBACK(gl_area_unrealize), host);
  g_signal_connect(gl_area, "render", G_CALLBACK(gl_area_render), host);
  g_signal_connect(gl_area, "resize", G_CALLBACK(gl_area_resize), host);

  gtk_window_set_child(host->window, gl_area);
  gtk_window_present(host->window);
}

int main(int argc, char **argv) {
  Host host = {0};
  host.exit_code = 1;

  if (ghostty_init((size_t)argc, argv) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "ghostty_init failed\n");
    return 1;
  }

  host.config = ghostty_config_new();
  if (host.config == NULL) {
    fprintf(stderr, "ghostty_config_new failed\n");
    return 1;
  }
  ghostty_config_finalize(host.config);

  ghostty_runtime_config_s runtime = {
      .userdata = &host,
      .supports_selection_clipboard = false,
      .wakeup_cb = runtime_wakeup_cb,
      .action_cb = runtime_action_cb,
      .read_clipboard_cb = runtime_read_clipboard_cb,
      .confirm_read_clipboard_cb = runtime_confirm_read_clipboard_cb,
      .write_clipboard_cb = runtime_write_clipboard_cb,
      .close_surface_cb = runtime_close_surface_cb,
  };

  host.ghostty_app = ghostty_app_new(&runtime, host.config);
  if (host.ghostty_app == NULL) {
    fprintf(stderr, "ghostty_app_new failed\n");
    ghostty_config_free(host.config);
    return 1;
  }

  host.app = gtk_application_new("com.mitchellh.ghostty.embedded-smoke",
                                 G_APPLICATION_NON_UNIQUE);
  g_signal_connect(host.app, "activate", G_CALLBACK(app_activate), &host);

  const int rc = g_application_run(G_APPLICATION(host.app), argc, argv);
  if (rc != 0 && host.exit_code == 1) {
    host.exit_code = rc;
  }

  if (host.surface != NULL) {
    ghostty_surface_free(host.surface);
  }
  if (host.ghostty_app != NULL) {
    ghostty_app_free(host.ghostty_app);
  }
  if (host.config != NULL) {
    ghostty_config_free(host.config);
  }
  if (host.app != NULL) {
    g_object_unref(host.app);
  }

  return host.exit_code;
}
