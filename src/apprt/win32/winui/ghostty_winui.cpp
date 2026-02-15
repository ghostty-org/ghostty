/// ghostty_winui.cpp — WinUI 3 shim DLL implementation.
///
/// Provides flat C ABI wrappers around C++/WinRT WinUI 3 controls
/// (TabView, search panel, ContentDialog) hosted via XAML Islands
/// (DesktopWindowXamlSource).
///
/// This DLL is loaded at runtime by Ghostty's Zig code via LoadLibraryW.

#include "pch.h"

#include "ghostty_winui.h"

// Bootstrap API for unpackaged apps
#include <MddBootstrap.h>
#include <WindowsAppSDK-VersionInfo.h>

// ContentPreTranslateMessage — loaded dynamically from the WinAppSDK runtime DLL.
typedef BOOL (__stdcall *PFN_ContentPreTranslateMessage)(const MSG* pmsg);
static PFN_ContentPreTranslateMessage g_pfnContentPreTranslateMessage = nullptr;

#include <string>
#include <vector>
#include <memory>
#include <functional>
#include <cmath>
#include <limits>

namespace winrt {
    using namespace Microsoft::UI::Xaml;
    using namespace Microsoft::UI::Xaml::Controls;
    using namespace Microsoft::UI::Xaml::Hosting;
    using namespace Microsoft::UI::Xaml::Input;
    using namespace Microsoft::UI::Xaml::Markup;
    using namespace Microsoft::UI::Xaml::Media;
    using namespace Microsoft::UI::Content;
    using namespace Microsoft::UI::Input;
    using namespace Microsoft::UI::Windowing;
}

// ---------------------------------------------------------------
// Custom Application with IXamlMetadataProvider
// ---------------------------------------------------------------
// WinUI 3 requires an Application subclass that implements
// IXamlMetadataProvider for XamlControlsResources to work.
// The XAML compiler normally generates this, but we implement
// it manually for our CMake-based build.

struct GhosttyApp : winrt::ApplicationT<GhosttyApp, winrt::IXamlMetadataProvider>
{
    GhosttyApp() = default;

    // IXamlMetadataProvider
    winrt::IXamlType GetXamlType(winrt::Windows::UI::Xaml::Interop::TypeName const& type)
    {
        return m_provider.GetXamlType(type);
    }

    winrt::IXamlType GetXamlType(winrt::hstring const& fullName)
    {
        return m_provider.GetXamlType(fullName);
    }

    winrt::com_array<winrt::XmlnsDefinition> GetXmlnsDefinitions()
    {
        return m_provider.GetXmlnsDefinitions();
    }

private:
    winrt::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider m_provider;
};

// ---------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------

/// Convert a UTF-8 C string to a winrt::hstring.
static winrt::hstring to_hstring(const char* utf8) {
    if (!utf8 || !*utf8) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
    if (len <= 0) return {};
    std::wstring buf(len - 1, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8, -1, buf.data(), len);
    return winrt::hstring(buf);
}

/// Convert a winrt::hstring to a UTF-8 std::string.
static std::string to_utf8(const winrt::hstring& hs) {
    if (hs.empty()) return {};
    auto wstr = std::wstring_view(hs);
    int len = WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(),
                                  nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string buf(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wstr.data(), (int)wstr.size(),
                        buf.data(), len, nullptr, nullptr);
    return buf;
}

// ---------------------------------------------------------------
// Global state
// ---------------------------------------------------------------

static bool g_initialized = false;
static thread_local HRESULT g_last_error = S_OK;
static winrt::Microsoft::UI::Dispatching::DispatcherQueueController g_dispatcher_controller{ nullptr };
static winrt::Microsoft::UI::Xaml::Application g_xaml_app{ nullptr };
static winrt::Microsoft::UI::Xaml::Hosting::WindowsXamlManager g_xaml_manager{ nullptr };
static winrt::Microsoft::UI::Xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider g_metadata_provider{ nullptr };


GHOSTTY_WINUI_API int32_t ghostty_winui_last_error(void) {
    return static_cast<int32_t>(g_last_error);
}

// ---------------------------------------------------------------
// Impl structs (behind opaque handles)
// ---------------------------------------------------------------

struct GhosttyXamlHostImpl {
    HWND parent_hwnd = nullptr;
    winrt::DesktopWindowXamlSource xaml_source{ nullptr };
    HWND island_hwnd = nullptr;
};

struct GhosttyTabViewImpl {
    GhosttyXamlHostImpl* host = nullptr;
    winrt::Grid root_grid{ nullptr };
    winrt::Canvas overlay_canvas{ nullptr };
    winrt::TabView tab_view{ nullptr };
    GhosttyTabViewCallbacks callbacks{};
    HWND drag_region_parent_hwnd = nullptr;  // Set by setup_drag_regions
    bool updating_drag_regions = false;  // Re-entrancy guard

    // Event tokens for cleanup.
    winrt::event_token selection_changed_token{};
    winrt::event_token tab_close_token{};
    winrt::event_token add_tab_token{};
};

struct GhosttySearchPanelImpl {
    GhosttyTabViewImpl* tv = nullptr;
    winrt::Border border{ nullptr };
    winrt::StackPanel panel{ nullptr };
    winrt::TextBox search_box{ nullptr };
    winrt::TextBlock match_count_text{ nullptr };
    GhosttySearchCallbacks callbacks{};
    bool visible = false;
};

// ---------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------

static FILE* g_log = nullptr;
static void log_init() {
    if (!g_log) {
        g_log = fopen("ghostty_winui_log.txt", "w");
    }
}
static void log_msg(const char* msg) {
    log_init();
    if (g_log) { fprintf(g_log, "%s\n", msg); fflush(g_log); }
}
static void log_hr(const char* label, HRESULT hr) {
    log_init();
    if (g_log) { fprintf(g_log, "%s: 0x%08X\n", label, (unsigned)hr); fflush(g_log); }
}

GHOSTTY_WINUI_API int32_t ghostty_winui_init(void) {
    try {
        log_msg("init: start");

        // Initialize COM as STA. Use CoInitializeEx directly instead of
        // winrt::init_apartment because the latter throws if COM is already
        // initialized (e.g. by D3D11, OLE clipboard, or the Zig runtime).
        {
            HRESULT hr = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
            log_hr("CoInitializeEx", hr);
            if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
                return static_cast<int32_t>(hr);
            }
        }

        // Bootstrap the Windows App SDK for unpackaged apps.
        log_msg("step: MddBootstrap");
        PACKAGE_VERSION minVersion{};
        minVersion.Version = 0;
        HRESULT hr = MddBootstrapInitialize(
            WINDOWSAPPSDK_RELEASE_MAJORMINOR,
            WINDOWSAPPSDK_RELEASE_VERSION_TAG_W,
            minVersion
        );
        log_hr("MddBootstrap result", hr);
        if (FAILED(hr)) {
            ::CoUninitialize();
            return static_cast<int32_t>(hr);
        }

        // Create a dispatcher queue for the current thread (required by XAML).
        log_msg("step: DispatcherQueue");
        g_dispatcher_controller = winrt::Microsoft::UI::Dispatching::
            DispatcherQueueController::CreateOnCurrentThread();

        // Resolve ContentPreTranslateMessage from the runtime DLL.
        {
            HMODULE hMod = GetModuleHandleW(L"Microsoft.UI.Xaml.dll");
            if (!hMod) hMod = GetModuleHandleW(L"Microsoft.WindowsAppRuntime.dll");
            if (hMod) {
                g_pfnContentPreTranslateMessage = reinterpret_cast<PFN_ContentPreTranslateMessage>(
                    GetProcAddress(hMod, "ContentPreTranslateMessage"));
            }
        }

        // Create our custom Application with IXamlMetadataProvider BEFORE
        // initializing the XAML manager. The XAML framework needs an
        // Application that provides metadata for control type resolution.
        log_msg("step: Creating GhosttyApp");
        try {
            g_xaml_app = winrt::make<GhosttyApp>();
            log_msg("GhosttyApp created OK");
        } catch (winrt::hresult_error const& ex) {
            log_hr("GhosttyApp creation failed", ex.code());
            // Fall through — WindowsXamlManager will create an internal App
        }

        // Initialize WindowsXamlManager — this sets up the XAML runtime for
        // hosting controls via DesktopWindowXamlSource (XAML Islands).
        log_msg("step: WindowsXamlManager");
        g_xaml_manager = winrt::Microsoft::UI::Xaml::Hosting::
            WindowsXamlManager::InitializeForCurrentThread();

        // Get the Application instance — either our GhosttyApp or the one
        // created by WindowsXamlManager.
        log_msg("step: Application::Current");
        g_xaml_app = winrt::Microsoft::UI::Xaml::Application::Current();
        if (g_xaml_app) {
            log_msg("Got Application::Current OK");
        } else {
            log_msg("Application::Current returned null");
        }

        // Load XamlControlsResources for Fluent styling (theme brushes,
        // control templates, etc.). Without this, controls are invisible.
        log_msg("step: XamlControlsResources");
        {
            auto resources = g_xaml_app.Resources();
            if (!resources) {
                resources = winrt::Microsoft::UI::Xaml::ResourceDictionary();
                g_xaml_app.Resources(resources);
            }

            bool loaded = false;

            // Try loading XamlControlsResources — this provides all Fluent
            // control templates. Requires IXamlMetadataProvider on the
            // Application (provided by our GhosttyApp class).
            try {
                auto xcr = winrt::Microsoft::UI::Xaml::Controls::XamlControlsResources();
                resources.MergedDictionaries().Append(xcr);
                loaded = true;
                log_msg("XamlControlsResources loaded OK");
            } catch (winrt::hresult_error const& ex) {
                log_hr("XamlControlsResources failed", ex.code());
                try {
                    auto msg = to_utf8(ex.message());
                    char buf[512];
                    snprintf(buf, sizeof(buf), "  message: %s", msg.c_str());
                    log_msg(buf);
                } catch (...) {}
            }

            if (!loaded) {
                log_msg("WARNING: No control templates loaded. Controls may be invisible.");
            }
        }

        g_initialized = true;
        return 0;
    } catch (winrt::hresult_error const& ex) {
        g_last_error = ex.code();
        log_hr("EXCEPTION", ex.code());
        return static_cast<int32_t>(ex.code());
    } catch (...) {
        log_msg("UNKNOWN EXCEPTION");
        return -1;
    }
}

GHOSTTY_WINUI_API void ghostty_winui_shutdown(void) {
    g_initialized = false;
    g_metadata_provider = nullptr;
    g_xaml_app = nullptr;
    if (g_xaml_manager) {
        g_xaml_manager.Close();
        g_xaml_manager = nullptr;
    }
    if (g_dispatcher_controller) {
        g_dispatcher_controller.ShutdownQueue();
        g_dispatcher_controller = nullptr;
    }
    ::CoUninitialize();
    MddBootstrapShutdown();
}

GHOSTTY_WINUI_API int32_t ghostty_winui_available(void) {
    return g_initialized ? 1 : 0;
}

GHOSTTY_WINUI_API int32_t ghostty_winui_pre_translate_message(MSG* msg) {
    // Route messages through WinAppSDK's ContentPreTranslateMessage so that
    // the XAML framework can process input and rendering messages.
    if (g_pfnContentPreTranslateMessage) {
        return g_pfnContentPreTranslateMessage(msg) ? 1 : 0;
    }
    return 0;
}

// ---------------------------------------------------------------
// XAML Island host
// ---------------------------------------------------------------

GHOSTTY_WINUI_API GhosttyXamlHost ghostty_xaml_host_create(HWND parent) {
    if (!g_initialized) return nullptr;

    try {
        auto impl = new GhosttyXamlHostImpl();
        impl->parent_hwnd = parent;

        // Create the DesktopWindowXamlSource.
        impl->xaml_source = winrt::DesktopWindowXamlSource();

        // Initialize with the parent HWND using WinUI 3 API.
        auto windowId = winrt::Microsoft::UI::GetWindowIdFromWindow(parent);
        impl->xaml_source.Initialize(windowId);

        // Get the island HWND from the SiteBridge and configure window style.
        auto site_bridge = impl->xaml_source.SiteBridge();
        if (site_bridge) {
            auto bridgeWindowId = site_bridge.WindowId();
            impl->island_hwnd = winrt::Microsoft::UI::GetWindowFromWindowId(bridgeWindowId);

            // Must set WS_CHILD | WS_VISIBLE on the island HWND for content to render.
            if (impl->island_hwnd) {
                ::SetWindowLong(impl->island_hwnd, GWL_STYLE,
                    WS_TABSTOP | WS_CHILD | WS_VISIBLE);
            }
        }

        return impl;
    } catch (winrt::hresult_error const& ex) {
        g_last_error = ex.code();
        return nullptr;
    } catch (...) {
        g_last_error = E_FAIL;
        return nullptr;
    }
}

GHOSTTY_WINUI_API void ghostty_xaml_host_destroy(GhosttyXamlHost host) {
    if (!host) return;
    try {
        if (host->xaml_source) {
            host->xaml_source.Close();
            host->xaml_source = nullptr;
        }
    } catch (...) {}
    delete host;
}

GHOSTTY_WINUI_API HWND ghostty_xaml_host_get_hwnd(GhosttyXamlHost host) {
    return host ? host->island_hwnd : nullptr;
}

GHOSTTY_WINUI_API void ghostty_xaml_host_resize(
    GhosttyXamlHost host,
    int32_t x, int32_t y,
    int32_t width, int32_t height
) {
    if (!host || !host->xaml_source) return;
    try {
        char buf[256];
        snprintf(buf, sizeof(buf), "xaml_host_resize: %dx%d at (%d,%d)", width, height, x, y);
        log_msg(buf);

        auto site_bridge = host->xaml_source.SiteBridge();
        if (site_bridge) {
            winrt::Windows::Graphics::RectInt32 rect{ x, y, width, height };
            site_bridge.MoveAndResize(rect);
            site_bridge.Show();
        }
    } catch (...) {}
}

// ---------------------------------------------------------------
// TabView
// ---------------------------------------------------------------

GHOSTTY_WINUI_API GhosttyTabView ghostty_tabview_create(
    GhosttyXamlHost host,
    GhosttyTabViewCallbacks callbacks
) {
    if (!host) return nullptr;

    try {
        auto impl = new GhosttyTabViewImpl();
        impl->host = host;
        impl->callbacks = callbacks;

        // Create TabView control.
        impl->tab_view = winrt::TabView();
        impl->tab_view.IsAddTabButtonVisible(true);
        impl->tab_view.TabWidthMode(winrt::TabViewWidthMode::Equal);
        impl->tab_view.CanReorderTabs(true);
        impl->tab_view.CanDragTabs(true);

        // Wire up events.
        impl->selection_changed_token = impl->tab_view.SelectionChanged(
            [impl](auto const&, auto const&) {
                if (impl->callbacks.on_tab_selected) {
                    auto idx = impl->tab_view.SelectedIndex();
                    if (idx >= 0) {
                        impl->callbacks.on_tab_selected(
                            impl->callbacks.ctx,
                            static_cast<uint32_t>(idx)
                        );
                    }
                }
            }
        );

        impl->tab_close_token = impl->tab_view.TabCloseRequested(
            [impl](auto const&, winrt::TabViewTabCloseRequestedEventArgs const& args) {
                if (impl->callbacks.on_tab_close_requested) {
                    // Find the index of the tab being closed.
                    auto items = impl->tab_view.TabItems();
                    for (uint32_t i = 0; i < items.Size(); ++i) {
                        if (items.GetAt(i) == args.Tab()) {
                            impl->callbacks.on_tab_close_requested(
                                impl->callbacks.ctx, i
                            );
                            break;
                        }
                    }
                }
            }
        );

        impl->add_tab_token = impl->tab_view.AddTabButtonClick(
            [impl](auto const&, auto const&) {
                if (impl->callbacks.on_new_tab_requested) {
                    impl->callbacks.on_new_tab_requested(impl->callbacks.ctx);
                }
            }
        );

        // System caption buttons (min/max/close) are provided by DWM when
        // ExtendsContentIntoTitleBar is true. No need for custom XAML buttons.

        // Wrap TabView in a Grid with an overlay Canvas for search panel.
        impl->root_grid = winrt::Grid();
        // Default to dark theme for the grid and all children.
        impl->root_grid.RequestedTheme(winrt::ElementTheme::Dark);
        // Opaque background so the DWM glass/frame doesn't show through.
        // Use the WinUI theme's standard tab background color.
        {
            winrt::Windows::UI::Color bg;
            bg.A = 255; bg.R = 32; bg.G = 32; bg.B = 32;
            impl->root_grid.Background(winrt::SolidColorBrush(bg));
        }

        // Row 0: TabView (Auto height)
        winrt::RowDefinition row0;
        row0.Height(winrt::GridLengthHelper::FromValueAndType(0, winrt::GridUnitType::Auto));
        impl->root_grid.RowDefinitions().Append(row0);

        // Row 1: Overlay canvas (Star, fills remaining space)
        winrt::RowDefinition row1;
        row1.Height(winrt::GridLengthHelper::FromValueAndType(1, winrt::GridUnitType::Star));
        impl->root_grid.RowDefinitions().Append(row1);

        winrt::Grid::SetRow(impl->tab_view, 0);
        impl->root_grid.Children().Append(impl->tab_view);

        impl->overlay_canvas = winrt::Canvas();
        impl->overlay_canvas.IsHitTestVisible(true);
        impl->overlay_canvas.Background(nullptr);  // Transparent, doesn't block input
        winrt::Grid::SetRow(impl->overlay_canvas, 1);
        impl->root_grid.Children().Append(impl->overlay_canvas);

        // Set the root Grid as the XAML content.
        host->xaml_source.Content(impl->root_grid);

        // Show the island via the SiteBridge API.
        auto site_bridge = host->xaml_source.SiteBridge();
        if (site_bridge) {
            site_bridge.Show();
        }

        // Debug: log TabView state after creation.
        log_msg("TabView created");
        {
            auto tab_items = impl->tab_view.TabItems();
            char buf[256];
            snprintf(buf, sizeof(buf), "  TabView: items=%u, visible=%d, width=%.0f, height=%.0f",
                     tab_items.Size(),
                     (int)(impl->tab_view.Visibility() == winrt::Visibility::Visible),
                     impl->tab_view.ActualWidth(),
                     impl->tab_view.ActualHeight());
            log_msg(buf);
            snprintf(buf, sizeof(buf), "  Grid: width=%.0f, height=%.0f",
                     impl->root_grid.ActualWidth(),
                     impl->root_grid.ActualHeight());
            log_msg(buf);
            if (host->island_hwnd) {
                RECT rc;
                GetWindowRect(host->island_hwnd, &rc);
                snprintf(buf, sizeof(buf), "  Island HWND: %dx%d at (%d,%d)",
                         rc.right - rc.left, rc.bottom - rc.top, rc.left, rc.top);
                log_msg(buf);
            }
        }

        // Log size changes on root grid for debugging.
        impl->root_grid.SizeChanged(
            [impl](auto const&, winrt::SizeChangedEventArgs const& args) {
                char buf[256];
                auto ns = args.NewSize();
                snprintf(buf, sizeof(buf), "Grid SizeChanged: %.0fx%.0f, TabView: %.0fx%.0f",
                         ns.Width, ns.Height,
                         impl->tab_view.ActualWidth(), impl->tab_view.ActualHeight());
                log_msg(buf);
            }
        );

        return impl;
    } catch (...) {
        return nullptr;
    }
}

GHOSTTY_WINUI_API void ghostty_tabview_destroy(GhosttyTabView tv) {
    if (!tv) return;
    try {
        if (tv->tab_view) {
            tv->tab_view.SelectionChanged(tv->selection_changed_token);
            tv->tab_view.TabCloseRequested(tv->tab_close_token);
            tv->tab_view.AddTabButtonClick(tv->add_tab_token);
        }
    } catch (...) {}
    delete tv;
}

GHOSTTY_WINUI_API uint32_t ghostty_tabview_add_tab(
    GhosttyTabView tv,
    const char* title
) {
    if (!tv || !tv->tab_view) return UINT32_MAX;

    try {
        winrt::TabViewItem item;
        item.Header(winrt::box_value(to_hstring(title)));
        item.IsClosable(true);

        auto items = tv->tab_view.TabItems();
        items.Append(item);
        return items.Size() - 1;
    } catch (...) {
        return UINT32_MAX;
    }
}

GHOSTTY_WINUI_API void ghostty_tabview_remove_tab(
    GhosttyTabView tv,
    uint32_t index
) {
    if (!tv || !tv->tab_view) return;
    try {
        auto items = tv->tab_view.TabItems();
        if (index < items.Size()) {
            items.RemoveAt(index);
        }
    } catch (...) {}
}

GHOSTTY_WINUI_API void ghostty_tabview_select_tab(
    GhosttyTabView tv,
    uint32_t index
) {
    if (!tv || !tv->tab_view) return;
    try {
        auto items = tv->tab_view.TabItems();
        if (index < items.Size()) {
            tv->tab_view.SelectedIndex(static_cast<int32_t>(index));
        }
    } catch (...) {}
}

// Forward declarations — defined in the drag region section below.
static void update_drag_regions_impl(GhosttyTabViewImpl* tv, HWND parent_hwnd);
static void schedule_drag_region_update_round(GhosttyTabViewImpl* tv, HWND hwnd, int round);

GHOSTTY_WINUI_API void ghostty_tabview_set_tab_title(
    GhosttyTabView tv,
    uint32_t index,
    const char* title
) {
    if (!tv || !tv->tab_view) return;
    try {
        auto items = tv->tab_view.TabItems();
        if (index < items.Size()) {
            auto item = items.GetAt(index).as<winrt::TabViewItem>();
            item.Header(winrt::box_value(to_hstring(title)));

            // Title change causes tab width to change — update drag
            // regions immediately. UpdateLayout() inside the impl
            // forces XAML to recalculate before reading dimensions.
            if (tv->drag_region_parent_hwnd) {
                update_drag_regions_impl(tv, tv->drag_region_parent_hwnd);
            }
        }
    } catch (...) {}
}

GHOSTTY_WINUI_API void ghostty_tabview_move_tab(
    GhosttyTabView tv,
    uint32_t from_index,
    uint32_t to_index
) {
    if (!tv || !tv->tab_view) return;
    try {
        auto items = tv->tab_view.TabItems();
        if (from_index >= items.Size() || to_index >= items.Size()) return;
        if (from_index == to_index) return;

        auto item = items.GetAt(from_index);
        items.RemoveAt(from_index);
        items.InsertAt(to_index, item);
        tv->tab_view.SelectedIndex(static_cast<int32_t>(to_index));
    } catch (...) {}
}

GHOSTTY_WINUI_API int32_t ghostty_tabview_get_height(GhosttyTabView tv) {
    if (!tv || !tv->tab_view) return 40;
    try {
        // Measure the TabView to get its desired height.
        tv->tab_view.Measure({ std::numeric_limits<float>::infinity(),
                               std::numeric_limits<float>::infinity() });
        auto height = tv->tab_view.DesiredSize().Height;
        // Fluent TabView with content is ~40px. Use minimum to ensure
        // the tab bar is always visible even before first layout.
        if (height < 36) height = 40;
        return static_cast<int32_t>(std::ceil(height));
    } catch (...) {
        return 40;
    }
}

GHOSTTY_WINUI_API void ghostty_tabview_set_theme(
    GhosttyTabView tv,
    int32_t theme
) {
    if (!tv || !tv->root_grid) return;
    try {
        winrt::ElementTheme xaml_theme;
        switch (theme) {
            case GHOSTTY_THEME_LIGHT: xaml_theme = winrt::ElementTheme::Light; break;
            case GHOSTTY_THEME_DARK:  xaml_theme = winrt::ElementTheme::Dark; break;
            default:                  xaml_theme = winrt::ElementTheme::Default; break;
        }
        // Apply theme to root grid — this cascades to all children
        // including TabView, search panel, and any dialogs.
        tv->root_grid.RequestedTheme(xaml_theme);
    } catch (...) {}
}

// ---------------------------------------------------------------
// Search panel
// ---------------------------------------------------------------

GHOSTTY_WINUI_API GhosttySearchPanel ghostty_search_create(
    GhosttyTabView tv,
    GhosttySearchCallbacks callbacks
) {
    if (!g_initialized || !tv) return nullptr;

    try {
        auto impl = new GhosttySearchPanelImpl();
        impl->tv = tv;
        impl->callbacks = callbacks;

        // Helper: create a compact icon-only button (Windows Terminal style).
        auto make_icon_button = [](const wchar_t* glyph, double font_size = 12.0) {
            winrt::Button btn;
            winrt::FontIcon icon;
            icon.Glyph(glyph);
            icon.FontFamily(winrt::FontFamily(L"Segoe Fluent Icons"));
            icon.FontSize(font_size);
            btn.Content(icon);
            btn.Padding(winrt::ThicknessHelper::FromLengths(6, 4, 6, 4));
            btn.MinWidth(30);
            btn.MinHeight(30);
            btn.VerticalAlignment(winrt::VerticalAlignment::Center);
            return btn;
        };

        // Build the search UI as a Border with rounded corners.
        impl->border = winrt::Border();
        impl->border.CornerRadius(winrt::CornerRadiusHelper::FromUniformRadius(4));
        impl->border.Padding(winrt::ThicknessHelper::FromLengths(4, 4, 4, 4));

        // Use a theme-aware background via AcrylicBrush for a modern look.
        // Falls back to solid color if Acrylic is unavailable.
        try {
            winrt::Microsoft::UI::Xaml::Media::AcrylicBrush acrylic_brush;
            acrylic_brush.TintOpacity(0.85);
            winrt::Windows::UI::Color tint_color;
            tint_color.A = 255;
            tint_color.R = 32;
            tint_color.G = 32;
            tint_color.B = 32;
            acrylic_brush.TintColor(tint_color);
            acrylic_brush.FallbackColor(tint_color);
            impl->border.Background(acrylic_brush);
        } catch (...) {
            // Fallback: solid dark background.
            auto bg_brush = winrt::SolidColorBrush();
            winrt::Windows::UI::Color bg_color;
            bg_color.A = 240;
            bg_color.R = 32;
            bg_color.G = 32;
            bg_color.B = 32;
            bg_brush.Color(bg_color);
            impl->border.Background(bg_brush);
        }

        // Subtle border stroke for definition (like Windows Terminal).
        auto border_brush = winrt::SolidColorBrush();
        winrt::Windows::UI::Color border_color;
        border_color.A = 60;
        border_color.R = 255;
        border_color.G = 255;
        border_color.B = 255;
        border_brush.Color(border_color);
        impl->border.BorderBrush(border_brush);
        impl->border.BorderThickness(winrt::ThicknessHelper::FromUniformLength(1));

        // Drop shadow effect via Translation for depth.
        impl->border.Translation({ 0.0f, 0.0f, 16.0f });
        auto shadow = winrt::Microsoft::UI::Xaml::Media::ThemeShadow();
        impl->border.Shadow(shadow);

        // Horizontal StackPanel inside the border.
        impl->panel = winrt::StackPanel();
        impl->panel.Orientation(winrt::Controls::Orientation::Horizontal);
        impl->panel.Spacing(2);
        impl->panel.VerticalAlignment(winrt::VerticalAlignment::Center);

        // Search TextBox — styled to blend into the search bar.
        impl->search_box = winrt::TextBox();
        impl->search_box.PlaceholderText(L"Find");
        impl->search_box.Width(220);
        impl->search_box.MinHeight(0);
        impl->search_box.VerticalAlignment(winrt::VerticalAlignment::Center);
        impl->search_box.Padding(winrt::ThicknessHelper::FromLengths(8, 4, 8, 4));
        impl->search_box.TextChanged([impl](auto const&, auto const&) {
            if (impl->callbacks.on_search_changed) {
                auto text = to_utf8(impl->search_box.Text());
                impl->callbacks.on_search_changed(
                    impl->callbacks.ctx, text.c_str()
                );
            }
        });
        // Handle Enter/Shift+Enter for next/prev, Escape for close.
        impl->search_box.KeyDown([impl](auto const&, winrt::KeyRoutedEventArgs const& e) {
            if (e.Key() == winrt::Windows::System::VirtualKey::Enter) {
                bool shift = (::GetKeyState(VK_SHIFT) & 0x8000) != 0;
                if (shift) {
                    if (impl->callbacks.on_search_prev)
                        impl->callbacks.on_search_prev(impl->callbacks.ctx);
                } else {
                    if (impl->callbacks.on_search_next)
                        impl->callbacks.on_search_next(impl->callbacks.ctx);
                }
                e.Handled(true);
            } else if (e.Key() == winrt::Windows::System::VirtualKey::Escape) {
                if (impl->callbacks.on_search_close)
                    impl->callbacks.on_search_close(impl->callbacks.ctx);
                e.Handled(true);
            }
        });
        impl->panel.Children().Append(impl->search_box);

        // Match count text — subtle, smaller font.
        impl->match_count_text = winrt::TextBlock();
        impl->match_count_text.VerticalAlignment(winrt::VerticalAlignment::Center);
        impl->match_count_text.Text(L"");
        impl->match_count_text.FontSize(12);
        impl->match_count_text.Opacity(0.6);
        impl->match_count_text.Margin(winrt::ThicknessHelper::FromLengths(4, 0, 2, 0));
        impl->panel.Children().Append(impl->match_count_text);

        // Separator — thin vertical line between text area and buttons.
        auto separator = winrt::Border();
        separator.Width(1);
        separator.Height(16);
        separator.VerticalAlignment(winrt::VerticalAlignment::Center);
        separator.Margin(winrt::ThicknessHelper::FromLengths(2, 0, 2, 0));
        auto sep_brush = winrt::SolidColorBrush();
        winrt::Windows::UI::Color sep_color;
        sep_color.A = 40;
        sep_color.R = 255;
        sep_color.G = 255;
        sep_color.B = 255;
        sep_brush.Color(sep_color);
        separator.Background(sep_brush);
        impl->panel.Children().Append(separator);

        // Previous button (ChevronUp) — compact icon button.
        auto prev_btn = make_icon_button(L"\xE74A");
        prev_btn.Click([impl](auto const&, auto const&) {
            if (impl->callbacks.on_search_prev)
                impl->callbacks.on_search_prev(impl->callbacks.ctx);
        });
        impl->panel.Children().Append(prev_btn);

        // Next button (ChevronDown) — compact icon button.
        auto next_btn = make_icon_button(L"\xE74B");
        next_btn.Click([impl](auto const&, auto const&) {
            if (impl->callbacks.on_search_next)
                impl->callbacks.on_search_next(impl->callbacks.ctx);
        });
        impl->panel.Children().Append(next_btn);

        // Another separator before close.
        auto separator2 = winrt::Border();
        separator2.Width(1);
        separator2.Height(16);
        separator2.VerticalAlignment(winrt::VerticalAlignment::Center);
        separator2.Margin(winrt::ThicknessHelper::FromLengths(2, 0, 2, 0));
        separator2.Background(sep_brush);
        impl->panel.Children().Append(separator2);

        // Close button (X) — compact icon button.
        auto close_btn = make_icon_button(L"\xE711", 10.0);
        close_btn.Click([impl](auto const&, auto const&) {
            if (impl->callbacks.on_search_close)
                impl->callbacks.on_search_close(impl->callbacks.ctx);
        });
        impl->panel.Children().Append(close_btn);

        impl->border.Child(impl->panel);

        // Start collapsed (hidden).
        impl->border.Visibility(winrt::Visibility::Collapsed);

        // Add to the TabView's overlay canvas.
        tv->overlay_canvas.Children().Append(impl->border);

        return impl;
    } catch (...) {
        return nullptr;
    }
}

GHOSTTY_WINUI_API void ghostty_search_destroy(GhosttySearchPanel panel) {
    if (!panel) return;
    try {
        // Remove the border from the overlay canvas.
        if (panel->tv && panel->tv->overlay_canvas && panel->border) {
            auto children = panel->tv->overlay_canvas.Children();
            uint32_t idx = 0;
            if (children.IndexOf(panel->border, idx)) {
                children.RemoveAt(idx);
            }
        }
    } catch (...) {}
    delete panel;
}

GHOSTTY_WINUI_API void ghostty_search_show(
    GhosttySearchPanel panel,
    const char* initial_text
) {
    if (!panel || !panel->border) return;
    try {
        if (initial_text && *initial_text) {
            panel->search_box.Text(to_hstring(initial_text));
        }
        panel->border.Visibility(winrt::Visibility::Visible);
        panel->visible = true;
        panel->search_box.Focus(winrt::FocusState::Programmatic);
    } catch (...) {}
}

GHOSTTY_WINUI_API void ghostty_search_hide(GhosttySearchPanel panel) {
    if (!panel || !panel->border) return;
    try {
        panel->border.Visibility(winrt::Visibility::Collapsed);
        panel->visible = false;
    } catch (...) {}
}

GHOSTTY_WINUI_API void ghostty_search_set_match_count(
    GhosttySearchPanel panel,
    int32_t total,
    int32_t selected
) {
    if (!panel || !panel->match_count_text) return;
    try {
        if (total <= 0) {
            panel->match_count_text.Text(L"No matches");
        } else {
            auto text = std::to_wstring(selected + 1) + L" / " +
                        std::to_wstring(total);
            panel->match_count_text.Text(winrt::hstring(text));
        }
    } catch (...) {}
}

GHOSTTY_WINUI_API void ghostty_search_reposition(
    GhosttySearchPanel panel,
    int32_t x, int32_t y, int32_t width
) {
    if (!panel || !panel->border) return;
    try {
        // Position the border within the overlay canvas.
        winrt::Canvas::SetLeft(panel->border, static_cast<double>(x));
        winrt::Canvas::SetTop(panel->border, static_cast<double>(y));
        // Width is optional — the border sizes to content, but we can set max width.
        panel->border.MaxWidth(static_cast<double>(width));
    } catch (...) {}
}

// ---------------------------------------------------------------
// Title dialog
// ---------------------------------------------------------------

GHOSTTY_WINUI_API void ghostty_title_dialog_show(
    GhosttyTabView tv,
    const char* label,
    const char* current_title,
    void* ctx,
    GhosttyTitleResultCallback callback
) {
    if (!g_initialized || !callback || !tv || !tv->root_grid) return;

    try {
        // Create ContentDialog.
        winrt::ContentDialog dialog;
        dialog.Title(winrt::box_value(to_hstring(label)));
        dialog.PrimaryButtonText(L"OK");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(winrt::ContentDialogButton::Primary);

        // Create a TextBox for the title input.
        winrt::TextBox title_box;
        title_box.Text(to_hstring(current_title));
        title_box.SelectAll();
        dialog.Content(title_box);

        // Use the TabView's existing XamlRoot (shared island).
        dialog.XamlRoot(tv->root_grid.XamlRoot());

        // Show the dialog asynchronously.
        auto async_op = dialog.ShowAsync();
        async_op.Completed([callback, ctx, title_box]
                          (auto const& op, auto status) {
            if (status == winrt::Windows::Foundation::AsyncStatus::Completed) {
                auto result = op.GetResults();
                if (result == winrt::ContentDialogResult::Primary) {
                    auto text = to_utf8(title_box.Text());
                    callback(ctx, 1, text.c_str());
                } else {
                    callback(ctx, 0, nullptr);
                }
            } else {
                callback(ctx, 0, nullptr);
            }
        });
    } catch (...) {
        callback(ctx, 0, nullptr);
    }
}

// ---------------------------------------------------------------
// Drag region management (InputNonClientPointerSource)
// ---------------------------------------------------------------

/// Maximum rounds of deferred drag-region updates.
/// Each round goes through the XAML DispatcherQueue, giving XAML
/// a chance to process layout between rounds. By round 3, tab
/// dimensions should be fully up to date after a title change.
static constexpr int DRAG_REGION_MAX_ROUNDS = 4;

/// Schedule a multi-round drag region update via DispatcherQueue.
/// Each round calls update_drag_regions_impl then enqueues the next
/// round. XAML processes layout between rounds (unlike PostMessage
/// which gets drained in the same PeekMessageW loop).
static void schedule_drag_region_update_round(GhosttyTabViewImpl* tv, HWND hwnd, int round) {
    if (round >= DRAG_REGION_MAX_ROUNDS) return;
    if (!g_dispatcher_controller) return;

    auto dq = g_dispatcher_controller.DispatcherQueue();
    if (!dq) return;

    dq.TryEnqueue([tv, hwnd, round]() {
        update_drag_regions_impl(tv, hwnd);
        // Enqueue next round — XAML will process layout before it runs.
        schedule_drag_region_update_round(tv, hwnd, round + 1);
    });
}

static void update_drag_regions_impl(GhosttyTabViewImpl* tv, HWND parent_hwnd) {
    if (!tv || !tv->tab_view || !tv->root_grid) {
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: null tv/tab_view/root_grid\n"); fflush(g_log); }
        return;
    }

    // Guard against re-entrancy (SetRegionRects can trigger LayoutUpdated).
    if (tv->updating_drag_regions) return;
    tv->updating_drag_regions = true;

    try {
        auto xaml_root = tv->root_grid.XamlRoot();
        if (!xaml_root) {
            log_init();
            if (g_log) { fprintf(g_log, "update_drag_regions: no XamlRoot yet\n"); fflush(g_log); }
            tv->updating_drag_regions = false;
            return;
        }

        // Force XAML to synchronously recalculate layout so that
        // ActualWidth/ActualHeight reflect any pending changes
        // (e.g. tab title text changes that resize TabViewItems).
        tv->tab_view.UpdateLayout();

        double scale = xaml_root.RasterizationScale();
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: scale=%.2f parent_hwnd=%p\n", scale, (void*)parent_hwnd); fflush(g_log); }

        // Get the AppWindow for this HWND.
        auto windowId = winrt::Microsoft::UI::GetWindowIdFromWindow(parent_hwnd);
        auto appWindow = winrt::AppWindow::GetFromWindowId(windowId);
        auto nonClientSrc = winrt::InputNonClientPointerSource::GetForWindowId(windowId);

        // Collect passthrough rects for interactive elements.
        std::vector<winrt::Windows::Graphics::RectInt32> passthrough_rects;

        // Helper to add a rect for a FrameworkElement.
        auto add_element_rect = [&](winrt::FrameworkElement const& elem, const char* label) {
            if (!elem) return;
            try {
                auto transform = elem.TransformToVisual(nullptr);
                auto logical = transform.TransformBounds(winrt::Windows::Foundation::Rect{
                    0, 0,
                    static_cast<float>(elem.ActualWidth()),
                    static_cast<float>(elem.ActualHeight())
                });

                winrt::Windows::Graphics::RectInt32 physical{
                    static_cast<int32_t>(std::round(logical.X * scale)),
                    static_cast<int32_t>(std::round(logical.Y * scale)),
                    static_cast<int32_t>(std::round(logical.Width * scale)),
                    static_cast<int32_t>(std::round(logical.Height * scale))
                };

                log_init();
                if (g_log) {
                    auto name = elem.Name();
                    fprintf(g_log, "  passthrough[%d] %s [%ls]: logical=(%.0f,%.0f,%.0f,%.0f) physical=(%d,%d,%d,%d)\n",
                        (int)passthrough_rects.size(), label, name.c_str(),
                        logical.X, logical.Y, logical.Width, logical.Height,
                        physical.X, physical.Y, physical.Width, physical.Height);
                    fflush(g_log);
                }

                passthrough_rects.push_back(physical);
            } catch (winrt::hresult_error const& ex) {
                log_init();
                if (g_log) { fprintf(g_log, "  passthrough %s: EXCEPTION 0x%08X\n", label, (unsigned)ex.code()); fflush(g_log); }
            }
        };

        // Add each TabViewItem as a passthrough rect.
        auto items = tv->tab_view.TabItems();
        for (uint32_t i = 0; i < items.Size(); i++) {
            auto item = items.GetAt(i);
            auto tvi = item.try_as<winrt::TabViewItem>();
            if (tvi) {
                char label[32];
                snprintf(label, sizeof(label), "tab[%u]", i);
                add_element_rect(tvi, label);
            }
        }

        // Add the add-tab button. It's inside TabView's template — walk visual tree to find it.
        std::function<winrt::FrameworkElement(winrt::DependencyObject const&)> find_button;
        find_button = [&find_button](winrt::DependencyObject const& root) -> winrt::FrameworkElement {
            int count = winrt::VisualTreeHelper::GetChildrenCount(root);
            for (int i = 0; i < count; i++) {
                auto child = winrt::VisualTreeHelper::GetChild(root, i);
                auto fe = child.try_as<winrt::FrameworkElement>();
                if (fe) {
                    auto name = fe.Name();
                    if (name == L"AddButton") return fe;
                }
                auto result = find_button(child);
                if (result) return result;
            }
            return nullptr;
        };

        auto add_btn = find_button(tv->tab_view);
        if (add_btn) {
            add_element_rect(add_btn, "add-button");
        } else {
            log_init();
            if (g_log) { fprintf(g_log, "  add-button: NOT FOUND in visual tree\n"); fflush(g_log); }
        }

        // Set the passthrough regions.
        if (!passthrough_rects.empty()) {
            auto arr = winrt::array_view<winrt::Windows::Graphics::RectInt32>(
                passthrough_rects.data(),
                static_cast<uint32_t>(passthrough_rects.size()));
            nonClientSrc.SetRegionRects(winrt::NonClientRegionKind::Passthrough, arr);
        } else {
            // Clear passthrough if empty.
            nonClientSrc.ClearRegionRects(winrt::NonClientRegionKind::Passthrough);
        }

        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: SetRegionRects called with %d passthrough rects\n",
            (int)passthrough_rects.size()); fflush(g_log); }

        tv->updating_drag_regions = false;
    } catch (winrt::hresult_error const& ex) {
        tv->updating_drag_regions = false;
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: EXCEPTION 0x%08X\n", (unsigned)ex.code()); fflush(g_log); }
    } catch (...) {
        tv->updating_drag_regions = false;
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: UNKNOWN EXCEPTION\n"); fflush(g_log); }
    }
}

GHOSTTY_WINUI_API void ghostty_tabview_setup_drag_regions(
    GhosttyTabView tv,
    HWND parent_hwnd
) {
    if (!tv || !parent_hwnd) {
        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: null tv or parent_hwnd\n"); fflush(g_log); }
        return;
    }

    try {
        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: parent_hwnd=%p\n", (void*)parent_hwnd); fflush(g_log); }

        // Store parent HWND so we can auto-update regions on title change.
        tv->drag_region_parent_hwnd = parent_hwnd;

        // Set ExtendsContentIntoTitleBar = true via AppWindow.
        auto windowId = winrt::Microsoft::UI::GetWindowIdFromWindow(parent_hwnd);
        auto appWindow = winrt::AppWindow::GetFromWindowId(windowId);
        auto titleBar = appWindow.TitleBar();
        titleBar.ExtendsContentIntoTitleBar(true);
        titleBar.PreferredHeightOption(winrt::TitleBarHeightOption::Tall);

        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: ExtendsContentIntoTitleBar=true, PreferredHeightOption=Tall\n"); fflush(g_log); }

        // Hook SizeChanged on the root grid to auto-update regions.
        // Deferred via timer so TabViewItems have correct layout.
        tv->root_grid.SizeChanged([tv, parent_hwnd](auto&&, auto&&) {
            log_init();
            if (g_log) { fprintf(g_log, "setup_drag_regions: SizeChanged fired -> scheduling deferred update\n"); fflush(g_log); }
            schedule_drag_region_update_round(tv, parent_hwnd, 0);
        });

        // Hook TabItems vector changed to update on tab add/remove.
        // Deferred via timer since new items won't have layout yet.
        auto items = tv->tab_view.TabItems();
        auto observable = items.try_as<winrt::Windows::Foundation::Collections::IObservableVector<winrt::Windows::Foundation::IInspectable>>();
        if (observable) {
            observable.VectorChanged([tv, parent_hwnd](auto&&, auto&&) {
                log_init();
                if (g_log) { fprintf(g_log, "setup_drag_regions: TabItems VectorChanged -> scheduling deferred update\n"); fflush(g_log); }
                schedule_drag_region_update_round(tv, parent_hwnd, 0);
            });
            log_init();
            if (g_log) { fprintf(g_log, "setup_drag_regions: hooked TabItems VectorChanged\n"); fflush(g_log); }
        }

        // Defer initial update — TabViewItems won't have layout yet.
        schedule_drag_region_update_round(tv, parent_hwnd, 0);

        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: setup complete\n"); fflush(g_log); }

    } catch (winrt::hresult_error const& ex) {
        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: EXCEPTION 0x%08X\n", (unsigned)ex.code()); fflush(g_log); }
    } catch (...) {
        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: UNKNOWN EXCEPTION\n"); fflush(g_log); }
    }
}

GHOSTTY_WINUI_API void ghostty_tabview_update_drag_regions(
    GhosttyTabView tv,
    HWND parent_hwnd
) {
    update_drag_regions_impl(tv, parent_hwnd);
}
