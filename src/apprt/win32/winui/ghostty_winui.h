/// ghostty_winui.h — Flat C ABI for the WinUI 3 shim DLL.
///
/// Ghostty loads this DLL at runtime via LoadLibraryW. All types are
/// plain C so that Zig (or any other language) can call through
/// GetProcAddress without needing C++ name-mangling.
///
/// Opaque handles hide the C++/WinRT implementation details.

#pragma once

#include <stdint.h>
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef GHOSTTY_WINUI_EXPORTS
#define GHOSTTY_WINUI_API __declspec(dllexport)
#else
#define GHOSTTY_WINUI_API __declspec(dllimport)
#endif

// ---------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------

typedef struct GhosttyXamlHostImpl*    GhosttyXamlHost;
typedef struct GhosttyTabViewImpl*     GhosttyTabView;
typedef struct GhosttySearchPanelImpl* GhosttySearchPanel;

// ---------------------------------------------------------------
// Theme enum (matches Windows.UI.Xaml.ElementTheme)
// ---------------------------------------------------------------

enum GhosttyTheme {
    GHOSTTY_THEME_DEFAULT = 0,
    GHOSTTY_THEME_LIGHT   = 1,
    GHOSTTY_THEME_DARK    = 2,
};

// ---------------------------------------------------------------
// Callback signatures
// ---------------------------------------------------------------

/// TabView callbacks (Zig → C++ → Zig round-trip).
typedef struct {
    void* ctx;  // Opaque context pointer (Zig *Window or similar).

    void (*on_tab_selected)(void* ctx, uint32_t index);
    void (*on_tab_close_requested)(void* ctx, uint32_t index);
    void (*on_new_tab_requested)(void* ctx);
    void (*on_tab_reordered)(void* ctx, uint32_t from_index, uint32_t to_index);
    void (*on_minimize)(void* ctx);
    void (*on_maximize)(void* ctx);
    void (*on_close)(void* ctx);
} GhosttyTabViewCallbacks;

/// Search panel callbacks.
typedef struct {
    void* ctx;  // Opaque context pointer (Zig *Surface or similar).

    void (*on_search_changed)(void* ctx, const char* text);
    void (*on_search_next)(void* ctx);
    void (*on_search_prev)(void* ctx);
    void (*on_search_close)(void* ctx);
} GhosttySearchCallbacks;

/// Title dialog result callback.
typedef void (*GhosttyTitleResultCallback)(
    void* ctx,
    int32_t accepted,       // 1 = OK, 0 = Cancel
    const char* new_title   // UTF-8, valid only if accepted == 1
);

// ---------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------

/// Returns the last HRESULT error from a failed WinUI operation.
GHOSTTY_WINUI_API int32_t ghostty_winui_last_error(void);

/// Initialize WinUI 3 / Windows App SDK. Call once at startup.
/// Returns 0 on success, nonzero on failure.
GHOSTTY_WINUI_API int32_t ghostty_winui_init(void);

/// Shut down WinUI 3. Call once at exit.
GHOSTTY_WINUI_API void ghostty_winui_shutdown(void);

/// Returns nonzero if WinUI 3 is available and initialized.
GHOSTTY_WINUI_API int32_t ghostty_winui_available(void);

/// Call from the message loop before TranslateMessage/DispatchMessage.
/// Returns nonzero if the message was consumed by XAML.
GHOSTTY_WINUI_API int32_t ghostty_winui_pre_translate_message(MSG* msg);

// ---------------------------------------------------------------
// XAML Island host
// ---------------------------------------------------------------

/// Create a XAML Island host parented to the given HWND.
/// Returns NULL on failure.
GHOSTTY_WINUI_API GhosttyXamlHost ghostty_xaml_host_create(HWND parent);

/// Destroy a XAML Island host.
GHOSTTY_WINUI_API void ghostty_xaml_host_destroy(GhosttyXamlHost host);

/// Get the HWND of the XAML Island (for SetWindowPos, etc.).
GHOSTTY_WINUI_API HWND ghostty_xaml_host_get_hwnd(GhosttyXamlHost host);

/// Reposition/resize the XAML Island within the parent.
GHOSTTY_WINUI_API void ghostty_xaml_host_resize(
    GhosttyXamlHost host,
    int32_t x, int32_t y,
    int32_t width, int32_t height
);

// ---------------------------------------------------------------
// TabView
// ---------------------------------------------------------------

/// Create a TabView control inside the given XAML host.
/// The callbacks struct is copied; the ctx pointer must remain valid.
GHOSTTY_WINUI_API GhosttyTabView ghostty_tabview_create(
    GhosttyXamlHost host,
    GhosttyTabViewCallbacks callbacks
);

/// Destroy the TabView.
GHOSTTY_WINUI_API void ghostty_tabview_destroy(GhosttyTabView tv);

/// Add a new tab with the given UTF-8 title. Returns the tab index.
GHOSTTY_WINUI_API uint32_t ghostty_tabview_add_tab(
    GhosttyTabView tv,
    const char* title
);

/// Remove the tab at the given index.
GHOSTTY_WINUI_API void ghostty_tabview_remove_tab(
    GhosttyTabView tv,
    uint32_t index
);

/// Select (activate) the tab at the given index.
GHOSTTY_WINUI_API void ghostty_tabview_select_tab(
    GhosttyTabView tv,
    uint32_t index
);

/// Set the title of an existing tab.
GHOSTTY_WINUI_API void ghostty_tabview_set_tab_title(
    GhosttyTabView tv,
    uint32_t index,
    const char* title
);

/// Move a tab from one index to another.
GHOSTTY_WINUI_API void ghostty_tabview_move_tab(
    GhosttyTabView tv,
    uint32_t from_index,
    uint32_t to_index
);

/// Get the pixel height of the TabView header area.
GHOSTTY_WINUI_API int32_t ghostty_tabview_get_height(GhosttyTabView tv);

/// Set the TabView theme (light/dark/default).
GHOSTTY_WINUI_API void ghostty_tabview_set_theme(
    GhosttyTabView tv,
    int32_t theme
);

/// Set the active tab's background color (RGB). Inactive tabs use the tab bar default.
GHOSTTY_WINUI_API void ghostty_tabview_set_background_color(
    GhosttyTabView tv,
    uint8_t r, uint8_t g, uint8_t b
);

// ---------------------------------------------------------------
// Search panel
// ---------------------------------------------------------------

/// Create a search panel overlay inside the TabView's shared XAML Island.
GHOSTTY_WINUI_API GhosttySearchPanel ghostty_search_create(
    GhosttyTabView tv,
    GhosttySearchCallbacks callbacks
);

/// Destroy the search panel.
GHOSTTY_WINUI_API void ghostty_search_destroy(GhosttySearchPanel panel);

/// Show the search panel with optional initial text (UTF-8, may be NULL).
GHOSTTY_WINUI_API void ghostty_search_show(
    GhosttySearchPanel panel,
    const char* initial_text
);

/// Hide the search panel.
GHOSTTY_WINUI_API void ghostty_search_hide(GhosttySearchPanel panel);

/// Update the match count display ("selected / total").
GHOSTTY_WINUI_API void ghostty_search_set_match_count(
    GhosttySearchPanel panel,
    int32_t total,
    int32_t selected
);

/// Reposition the search panel within its parent.
GHOSTTY_WINUI_API void ghostty_search_reposition(
    GhosttySearchPanel panel,
    int32_t x, int32_t y, int32_t width
);

// ---------------------------------------------------------------
// Title dialog
// ---------------------------------------------------------------

/// Show a title prompt dialog. The callback is invoked when the user
/// clicks OK or Cancel. The dialog is modeless (non-blocking).
GHOSTTY_WINUI_API void ghostty_title_dialog_show(
    GhosttyTabView tv,
    const char* label,          // UTF-8 prompt label
    const char* current_title,  // UTF-8 current title (pre-filled)
    void* ctx,
    GhosttyTitleResultCallback callback
);

/// Set up drag regions for the tab bar using InputNonClientPointerSource.
/// Call once after TabView creation. Sets ExtendsContentIntoTitleBar = true
/// and hooks SizeChanged for automatic region updates.
GHOSTTY_WINUI_API void ghostty_tabview_setup_drag_regions(
    GhosttyTabView tv,
    HWND parent_hwnd
);

/// Manually trigger a drag region update (e.g. on window resize).
GHOSTTY_WINUI_API void ghostty_tabview_update_drag_regions(
    GhosttyTabView tv,
    HWND parent_hwnd
);

#ifdef __cplusplus
}  // extern "C"
#endif
