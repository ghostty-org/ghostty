// Ghostty embedding API. The documentation for the embedding API is
// only within the Zig source files that define the implementations. This
// isn't meant to be a general purpose embedding API (yet) so there hasn't
// been documentation or example work beyond that.
//
// The only consumer of this API is the macOS app, but the API is built to
// be more general purpose.
#ifndef GHOSTTY_H
#define GHOSTTY_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

//-------------------------------------------------------------------
// Macros

#define GHOSTTY_SUCCESS 0

//-------------------------------------------------------------------
// Types

// Opaque types
typedef void* ghostty_app_t;
typedef void* ghostty_config_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_inspector_t;

// Enums are up top so we can reference them later.
typedef enum {
  GHOSTTY_PLATFORM_INVALID,
  GHOSTTY_PLATFORM_MACOS,
  GHOSTTY_PLATFORM_IOS,
} ghostty_platform_e;

typedef enum {
  GHOSTTY_CLIPBOARD_STANDARD,
  GHOSTTY_CLIPBOARD_SELECTION,
} ghostty_clipboard_e;

typedef enum {
  GHOSTTY_CLIPBOARD_REQUEST_PASTE,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
  GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE,
} ghostty_clipboard_request_e;

typedef enum {
  GHOSTTY_SPLIT_RIGHT,
  GHOSTTY_SPLIT_DOWN
} ghostty_split_direction_e;

typedef enum {
  GHOSTTY_SPLIT_FOCUS_PREVIOUS,
  GHOSTTY_SPLIT_FOCUS_NEXT,
  GHOSTTY_SPLIT_FOCUS_TOP,
  GHOSTTY_SPLIT_FOCUS_LEFT,
  GHOSTTY_SPLIT_FOCUS_BOTTOM,
  GHOSTTY_SPLIT_FOCUS_RIGHT,
} ghostty_split_focus_direction_e;

typedef enum {
  GHOSTTY_SPLIT_RESIZE_UP,
  GHOSTTY_SPLIT_RESIZE_DOWN,
  GHOSTTY_SPLIT_RESIZE_LEFT,
  GHOSTTY_SPLIT_RESIZE_RIGHT,
} ghostty_split_resize_direction_e;

typedef enum {
  GHOSTTY_INSPECTOR_TOGGLE,
  GHOSTTY_INSPECTOR_SHOW,
  GHOSTTY_INSPECTOR_HIDE,
} ghostty_inspector_mode_e;

typedef enum {
  GHOSTTY_MOUSE_RELEASE,
  GHOSTTY_MOUSE_PRESS,
} ghostty_input_mouse_state_e;

typedef enum {
  GHOSTTY_MOUSE_UNKNOWN,
  GHOSTTY_MOUSE_LEFT,
  GHOSTTY_MOUSE_RIGHT,
  GHOSTTY_MOUSE_MIDDLE,
} ghostty_input_mouse_button_e;

typedef enum {
  GHOSTTY_MOUSE_MOMENTUM_NONE,
  GHOSTTY_MOUSE_MOMENTUM_BEGAN,
  GHOSTTY_MOUSE_MOMENTUM_STATIONARY,
  GHOSTTY_MOUSE_MOMENTUM_CHANGED,
  GHOSTTY_MOUSE_MOMENTUM_ENDED,
  GHOSTTY_MOUSE_MOMENTUM_CANCELLED,
  GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN,
} ghostty_input_mouse_momentum_e;

typedef enum {
  GHOSTTY_MOUSE_SHAPE_DEFAULT,
  GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU,
  GHOSTTY_MOUSE_SHAPE_HELP,
  GHOSTTY_MOUSE_SHAPE_POINTER,
  GHOSTTY_MOUSE_SHAPE_PROGRESS,
  GHOSTTY_MOUSE_SHAPE_WAIT,
  GHOSTTY_MOUSE_SHAPE_CELL,
  GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
  GHOSTTY_MOUSE_SHAPE_TEXT,
  GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT,
  GHOSTTY_MOUSE_SHAPE_ALIAS,
  GHOSTTY_MOUSE_SHAPE_COPY,
  GHOSTTY_MOUSE_SHAPE_MOVE,
  GHOSTTY_MOUSE_SHAPE_NO_DROP,
  GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
  GHOSTTY_MOUSE_SHAPE_GRAB,
  GHOSTTY_MOUSE_SHAPE_GRABBING,
  GHOSTTY_MOUSE_SHAPE_ALL_SCROLL,
  GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_N_RESIZE,
  GHOSTTY_MOUSE_SHAPE_E_RESIZE,
  GHOSTTY_MOUSE_SHAPE_S_RESIZE,
  GHOSTTY_MOUSE_SHAPE_W_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_SW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NESW_RESIZE,
  GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE,
  GHOSTTY_MOUSE_SHAPE_ZOOM_IN,
  GHOSTTY_MOUSE_SHAPE_ZOOM_OUT,
} ghostty_mouse_shape_e;

typedef enum {
  GHOSTTY_NON_NATIVE_FULLSCREEN_FALSE,
  GHOSTTY_NON_NATIVE_FULLSCREEN_TRUE,
  GHOSTTY_NON_NATIVE_FULLSCREEN_VISIBLE_MENU,
} ghostty_non_native_fullscreen_e;

typedef enum {
  GHOSTTY_TAB_PREVIOUS = -1,
  GHOSTTY_TAB_NEXT = -2,
} ghostty_tab_e;

typedef enum {
  GHOSTTY_COLOR_SCHEME_LIGHT = 0,
  GHOSTTY_COLOR_SCHEME_DARK = 1,
} ghostty_color_scheme_e;

// This is a packed struct (see src/input/mouse.zig) but the C standard
// afaik doesn't let us reliably define packed structs so we build it up
// from scratch.
typedef int ghostty_input_scroll_mods_t;

typedef enum {
  GHOSTTY_MODS_NONE = 0,
  GHOSTTY_MODS_SHIFT = 1 << 0,
  GHOSTTY_MODS_CTRL = 1 << 1,
  GHOSTTY_MODS_ALT = 1 << 2,
  GHOSTTY_MODS_SUPER = 1 << 3,
  GHOSTTY_MODS_CAPS = 1 << 4,
  GHOSTTY_MODS_NUM = 1 << 5,
  GHOSTTY_MODS_SHIFT_RIGHT = 1 << 6,
  GHOSTTY_MODS_CTRL_RIGHT = 1 << 7,
  GHOSTTY_MODS_ALT_RIGHT = 1 << 8,
  GHOSTTY_MODS_SUPER_RIGHT = 1 << 9,
} ghostty_input_mods_e;

typedef enum {
  GHOSTTY_ACTION_RELEASE,
  GHOSTTY_ACTION_PRESS,
  GHOSTTY_ACTION_REPEAT,
} ghostty_input_action_e;

typedef enum {
  GHOSTTY_KEY_INVALID,

  // a-z
  GHOSTTY_KEY_A,
  GHOSTTY_KEY_B,
  GHOSTTY_KEY_C,
  GHOSTTY_KEY_D,
  GHOSTTY_KEY_E,
  GHOSTTY_KEY_F,
  GHOSTTY_KEY_G,
  GHOSTTY_KEY_H,
  GHOSTTY_KEY_I,
  GHOSTTY_KEY_J,
  GHOSTTY_KEY_K,
  GHOSTTY_KEY_L,
  GHOSTTY_KEY_M,
  GHOSTTY_KEY_N,
  GHOSTTY_KEY_O,
  GHOSTTY_KEY_P,
  GHOSTTY_KEY_Q,
  GHOSTTY_KEY_R,
  GHOSTTY_KEY_S,
  GHOSTTY_KEY_T,
  GHOSTTY_KEY_U,
  GHOSTTY_KEY_V,
  GHOSTTY_KEY_W,
  GHOSTTY_KEY_X,
  GHOSTTY_KEY_Y,
  GHOSTTY_KEY_Z,

  // numbers
  GHOSTTY_KEY_ZERO,
  GHOSTTY_KEY_ONE,
  GHOSTTY_KEY_TWO,
  GHOSTTY_KEY_THREE,
  GHOSTTY_KEY_FOUR,
  GHOSTTY_KEY_FIVE,
  GHOSTTY_KEY_SIX,
  GHOSTTY_KEY_SEVEN,
  GHOSTTY_KEY_EIGHT,
  GHOSTTY_KEY_NINE,

  // puncuation
  GHOSTTY_KEY_SEMICOLON,
  GHOSTTY_KEY_SPACE,
  GHOSTTY_KEY_APOSTROPHE,
  GHOSTTY_KEY_COMMA,
  GHOSTTY_KEY_GRAVE_ACCENT,  // `
  GHOSTTY_KEY_PERIOD,
  GHOSTTY_KEY_SLASH,
  GHOSTTY_KEY_MINUS,
  GHOSTTY_KEY_PLUS,
  GHOSTTY_KEY_EQUAL,
  GHOSTTY_KEY_LEFT_BRACKET,   // [
  GHOSTTY_KEY_RIGHT_BRACKET,  // ]
  GHOSTTY_KEY_BACKSLASH,      // /

  // control
  GHOSTTY_KEY_UP,
  GHOSTTY_KEY_DOWN,
  GHOSTTY_KEY_RIGHT,
  GHOSTTY_KEY_LEFT,
  GHOSTTY_KEY_HOME,
  GHOSTTY_KEY_END,
  GHOSTTY_KEY_INSERT,
  GHOSTTY_KEY_DELETE,
  GHOSTTY_KEY_CAPS_LOCK,
  GHOSTTY_KEY_SCROLL_LOCK,
  GHOSTTY_KEY_NUM_LOCK,
  GHOSTTY_KEY_PAGE_UP,
  GHOSTTY_KEY_PAGE_DOWN,
  GHOSTTY_KEY_ESCAPE,
  GHOSTTY_KEY_ENTER,
  GHOSTTY_KEY_TAB,
  GHOSTTY_KEY_BACKSPACE,
  GHOSTTY_KEY_PRINT_SCREEN,
  GHOSTTY_KEY_PAUSE,
  GHOSTTY_KEY_UNDO,
  GHOSTTY_KEY_CUT,
  GHOSTTY_KEY_COPY,
  GHOSTTY_KEY_PASTE,

  // function keys
  GHOSTTY_KEY_F1,
  GHOSTTY_KEY_F2,
  GHOSTTY_KEY_F3,
  GHOSTTY_KEY_F4,
  GHOSTTY_KEY_F5,
  GHOSTTY_KEY_F6,
  GHOSTTY_KEY_F7,
  GHOSTTY_KEY_F8,
  GHOSTTY_KEY_F9,
  GHOSTTY_KEY_F10,
  GHOSTTY_KEY_F11,
  GHOSTTY_KEY_F12,
  GHOSTTY_KEY_F13,
  GHOSTTY_KEY_F14,
  GHOSTTY_KEY_F15,
  GHOSTTY_KEY_F16,
  GHOSTTY_KEY_F17,
  GHOSTTY_KEY_F18,
  GHOSTTY_KEY_F19,
  GHOSTTY_KEY_F20,
  GHOSTTY_KEY_F21,
  GHOSTTY_KEY_F22,
  GHOSTTY_KEY_F23,
  GHOSTTY_KEY_F24,
  GHOSTTY_KEY_F25,

  // keypad
  GHOSTTY_KEY_KP_0,
  GHOSTTY_KEY_KP_1,
  GHOSTTY_KEY_KP_2,
  GHOSTTY_KEY_KP_3,
  GHOSTTY_KEY_KP_4,
  GHOSTTY_KEY_KP_5,
  GHOSTTY_KEY_KP_6,
  GHOSTTY_KEY_KP_7,
  GHOSTTY_KEY_KP_8,
  GHOSTTY_KEY_KP_9,
  GHOSTTY_KEY_KP_DECIMAL,
  GHOSTTY_KEY_KP_DIVIDE,
  GHOSTTY_KEY_KP_MULTIPLY,
  GHOSTTY_KEY_KP_SUBTRACT,
  GHOSTTY_KEY_KP_ADD,
  GHOSTTY_KEY_KP_ENTER,
  GHOSTTY_KEY_KP_EQUAL,
  GHOSTTY_KEY_KP_SEPARATOR,
  GHOSTTY_KEY_KP_LEFT,
  GHOSTTY_KEY_KP_RIGHT,
  GHOSTTY_KEY_KP_UP,
  GHOSTTY_KEY_KP_DOWN,
  GHOSTTY_KEY_KP_PAGE_UP,
  GHOSTTY_KEY_KP_PAGE_DOWN,
  GHOSTTY_KEY_KP_HOME,
  GHOSTTY_KEY_KP_END,
  GHOSTTY_KEY_KP_INSERT,
  GHOSTTY_KEY_KP_DELETE,
  GHOSTTY_KEY_KP_BEGIN,

  // modifiers
  GHOSTTY_KEY_LEFT_SHIFT,
  GHOSTTY_KEY_LEFT_CONTROL,
  GHOSTTY_KEY_LEFT_ALT,
  GHOSTTY_KEY_LEFT_SUPER,
  GHOSTTY_KEY_RIGHT_SHIFT,
  GHOSTTY_KEY_RIGHT_CONTROL,
  GHOSTTY_KEY_RIGHT_ALT,
  GHOSTTY_KEY_RIGHT_SUPER,
} ghostty_input_key_e;

typedef struct {
  ghostty_input_action_e action;
  ghostty_input_mods_e mods;
  uint32_t keycode;
  const char* text;
  bool composing;
} ghostty_input_key_s;

typedef struct {
  ghostty_input_key_e key;
  ghostty_input_mods_e mods;
  bool physical;
} ghostty_input_trigger_s;

typedef enum {
  GHOSTTY_BUILD_MODE_DEBUG,
  GHOSTTY_BUILD_MODE_RELEASE_SAFE,
  GHOSTTY_BUILD_MODE_RELEASE_FAST,
  GHOSTTY_BUILD_MODE_RELEASE_SMALL,
} ghostty_build_mode_e;

typedef enum {
  GHOSTTY_RENDERER_HEALTH_OK,
  GHOSTTY_RENDERER_HEALTH_UNHEALTHY,
} ghostty_renderer_health_e;

// Fully defined types. This MUST be kept in sync with equivalent Zig
// structs. To find the Zig struct, grep for this type name. The documentation
// for all of these types is available in the Zig source.
typedef struct {
  ghostty_build_mode_e build_mode;
  const char* version;
  uintptr_t version_len;
} ghostty_info_s;

typedef struct {
  const char* message;
} ghostty_error_s;

typedef struct {
  void* nsview;
} ghostty_platform_macos_s;

typedef struct {
  void* uiview;
} ghostty_platform_ios_s;

typedef union {
  ghostty_platform_macos_s macos;
  ghostty_platform_ios_s ios;
} ghostty_platform_u;

typedef struct {
  ghostty_platform_e platform_tag;
  ghostty_platform_u platform;
  void* userdata;
  double scale_factor;
  float font_size;
  const char* working_directory;
  const char* command;
} ghostty_surface_config_s;

typedef void (*ghostty_runtime_wakeup_cb)(void*);
typedef const ghostty_config_t (*ghostty_runtime_reload_config_cb)(void*);
typedef void (*ghostty_runtime_open_config_cb)(void*);
typedef void (*ghostty_runtime_set_title_cb)(void*, const char*);
typedef void (*ghostty_runtime_set_mouse_shape_cb)(void*,
                                                   ghostty_mouse_shape_e);
typedef void (*ghostty_runtime_set_mouse_visibility_cb)(void*, bool);
typedef void (*ghostty_runtime_read_clipboard_cb)(void*,
                                                  ghostty_clipboard_e,
                                                  void*);
typedef void (*ghostty_runtime_confirm_read_clipboard_cb)(
    void*,
    const char*,
    void*,
    ghostty_clipboard_request_e);
typedef void (*ghostty_runtime_write_clipboard_cb)(void*,
                                                   const char*,
                                                   ghostty_clipboard_e,
                                                   bool);
typedef void (*ghostty_runtime_new_split_cb)(void*,
                                             ghostty_split_direction_e,
                                             ghostty_surface_config_s);
typedef void (*ghostty_runtime_new_tab_cb)(void*, ghostty_surface_config_s);
typedef void (*ghostty_runtime_new_window_cb)(void*, ghostty_surface_config_s);
typedef void (*ghostty_runtime_control_inspector_cb)(void*,
                                                     ghostty_inspector_mode_e);
typedef void (*ghostty_runtime_close_surface_cb)(void*, bool);
typedef void (*ghostty_runtime_focus_split_cb)(void*,
                                               ghostty_split_focus_direction_e);
typedef void (*ghostty_runtime_resize_split_cb)(
    void*,
    ghostty_split_resize_direction_e,
    uint16_t);
typedef void (*ghostty_runtime_equalize_splits_cb)(void*);
typedef void (*ghostty_runtime_toggle_split_zoom_cb)(void*);
typedef void (*ghostty_runtime_goto_tab_cb)(void*, int32_t);
typedef void (*ghostty_runtime_toggle_fullscreen_cb)(
    void*,
    ghostty_non_native_fullscreen_e);
typedef void (*ghostty_runtime_set_initial_window_size_cb)(void*,
                                                           uint32_t,
                                                           uint32_t);
typedef void (*ghostty_runtime_render_inspector_cb)(void*);
typedef void (*ghostty_runtime_set_cell_size_cb)(void*, uint32_t, uint32_t);
typedef void (*ghostty_runtime_show_desktop_notification_cb)(void*,
                                                             const char*,
                                                             const char*);
typedef void (
    *ghostty_runtime_update_renderer_health)(void*, ghostty_renderer_health_e);

typedef struct {
  void* userdata;
  bool supports_selection_clipboard;
  ghostty_runtime_wakeup_cb wakeup_cb;
  ghostty_runtime_reload_config_cb reload_config_cb;
  ghostty_runtime_open_config_cb open_config_cb;
  ghostty_runtime_set_title_cb set_title_cb;
  ghostty_runtime_set_mouse_shape_cb set_mouse_shape_cb;
  ghostty_runtime_set_mouse_visibility_cb set_mouse_visibility_cb;
  ghostty_runtime_read_clipboard_cb read_clipboard_cb;
  ghostty_runtime_confirm_read_clipboard_cb confirm_read_clipboard_cb;
  ghostty_runtime_write_clipboard_cb write_clipboard_cb;
  ghostty_runtime_new_split_cb new_split_cb;
  ghostty_runtime_new_tab_cb new_tab_cb;
  ghostty_runtime_new_window_cb new_window_cb;
  ghostty_runtime_control_inspector_cb control_inspector_cb;
  ghostty_runtime_close_surface_cb close_surface_cb;
  ghostty_runtime_focus_split_cb focus_split_cb;
  ghostty_runtime_resize_split_cb resize_split_cb;
  ghostty_runtime_equalize_splits_cb equalize_splits_cb;
  ghostty_runtime_toggle_split_zoom_cb toggle_split_zoom_cb;
  ghostty_runtime_goto_tab_cb goto_tab_cb;
  ghostty_runtime_toggle_fullscreen_cb toggle_fullscreen_cb;
  ghostty_runtime_set_initial_window_size_cb set_initial_window_size_cb;
  ghostty_runtime_render_inspector_cb render_inspector_cb;
  ghostty_runtime_set_cell_size_cb set_cell_size_cb;
  ghostty_runtime_show_desktop_notification_cb show_desktop_notification_cb;
  ghostty_runtime_update_renderer_health update_renderer_health_cb;
} ghostty_runtime_config_s;

//-------------------------------------------------------------------
// Published API

int ghostty_init(void);
void ghostty_cli_main(uintptr_t, char**);
ghostty_info_s ghostty_info(void);

ghostty_config_t ghostty_config_new();
void ghostty_config_free(ghostty_config_t);
void ghostty_config_load_cli_args(ghostty_config_t);
void ghostty_config_load_string(ghostty_config_t, const char*, uintptr_t);
void ghostty_config_load_default_files(ghostty_config_t);
void ghostty_config_load_recursive_files(ghostty_config_t);
void ghostty_config_finalize(ghostty_config_t);
bool ghostty_config_get(ghostty_config_t, void*, const char*, uintptr_t);
ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t,
                                               const char*,
                                               uintptr_t);
uint32_t ghostty_config_errors_count(ghostty_config_t);
ghostty_error_s ghostty_config_get_error(ghostty_config_t, uint32_t);
void ghostty_config_open();

ghostty_app_t ghostty_app_new(const ghostty_runtime_config_s*,
                              ghostty_config_t);
void ghostty_app_free(ghostty_app_t);
bool ghostty_app_tick(ghostty_app_t);
void* ghostty_app_userdata(ghostty_app_t);
void ghostty_app_keyboard_changed(ghostty_app_t);
void ghostty_app_open_config(ghostty_app_t);
void ghostty_app_reload_config(ghostty_app_t);
bool ghostty_app_needs_confirm_quit(ghostty_app_t);

ghostty_surface_config_s ghostty_surface_config_new();

ghostty_surface_t ghostty_surface_new(ghostty_app_t, ghostty_surface_config_s*);
void ghostty_surface_free(ghostty_surface_t);
ghostty_app_t ghostty_surface_app(ghostty_surface_t);
bool ghostty_surface_transparent(ghostty_surface_t);
bool ghostty_surface_needs_confirm_quit(ghostty_surface_t);
void ghostty_surface_refresh(ghostty_surface_t);
void ghostty_surface_draw(ghostty_surface_t);
void ghostty_surface_set_content_scale(ghostty_surface_t, double, double);
void ghostty_surface_set_focus(ghostty_surface_t, bool);
void ghostty_surface_set_occlusion(ghostty_surface_t, bool);
void ghostty_surface_set_size(ghostty_surface_t, uint32_t, uint32_t);
void ghostty_surface_set_color_scheme(ghostty_surface_t,
                                      ghostty_color_scheme_e);
ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t,
                                                          ghostty_input_mods_e);
void ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s);
void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_mouse_button(ghostty_surface_t,
                                  ghostty_input_mouse_state_e,
                                  ghostty_input_mouse_button_e,
                                  ghostty_input_mods_e);
void ghostty_surface_mouse_pos(ghostty_surface_t, double, double);
void ghostty_surface_mouse_scroll(ghostty_surface_t,
                                  double,
                                  double,
                                  ghostty_input_scroll_mods_t);
void ghostty_surface_ime_point(ghostty_surface_t, double*, double*);
void ghostty_surface_request_close(ghostty_surface_t);
void ghostty_surface_split(ghostty_surface_t, ghostty_split_direction_e);
void ghostty_surface_split_focus(ghostty_surface_t,
                                 ghostty_split_focus_direction_e);
void ghostty_surface_split_resize(ghostty_surface_t,
                                  ghostty_split_resize_direction_e,
                                  uint16_t);
void ghostty_surface_split_equalize(ghostty_surface_t);
bool ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t);
void ghostty_surface_complete_clipboard_request(ghostty_surface_t,
                                                const char*,
                                                void*,
                                                bool);
uintptr_t ghostty_surface_pwd(ghostty_surface_t, char*, uintptr_t);
bool ghostty_surface_has_selection(ghostty_surface_t);
uintptr_t ghostty_surface_selection(ghostty_surface_t, char*, uintptr_t);

#ifdef __APPLE__
void ghostty_surface_set_display_id(ghostty_surface_t, uint32_t);
#endif

ghostty_inspector_t ghostty_surface_inspector(ghostty_surface_t);
void ghostty_inspector_free(ghostty_surface_t);
void ghostty_inspector_set_focus(ghostty_inspector_t, bool);
void ghostty_inspector_set_content_scale(ghostty_inspector_t, double, double);
void ghostty_inspector_set_size(ghostty_inspector_t, uint32_t, uint32_t);
void ghostty_inspector_mouse_button(ghostty_inspector_t,
                                    ghostty_input_mouse_state_e,
                                    ghostty_input_mouse_button_e,
                                    ghostty_input_mods_e);
void ghostty_inspector_mouse_pos(ghostty_inspector_t, double, double);
void ghostty_inspector_mouse_scroll(ghostty_inspector_t,
                                    double,
                                    double,
                                    ghostty_input_scroll_mods_t);
void ghostty_inspector_key(ghostty_inspector_t,
                           ghostty_input_action_e,
                           ghostty_input_key_e,
                           ghostty_input_mods_e);
void ghostty_inspector_text(ghostty_inspector_t, const char*);

#ifdef __APPLE__
bool ghostty_inspector_metal_init(ghostty_inspector_t, void*);
void ghostty_inspector_metal_render(ghostty_inspector_t, void*, void*);
bool ghostty_inspector_metal_shutdown(ghostty_inspector_t);
#endif

// APIs I'd like to get rid of eventually but are still needed for now.
// Don't use these unless you know what you're doing.
void ghostty_set_window_background_blur(ghostty_surface_t, void*);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_H */
