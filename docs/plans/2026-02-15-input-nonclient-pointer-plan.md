# InputNonClientPointerSource Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the non-functional drag overlay with WinUI 3's InputNonClientPointerSource API for tab bar drag/resize.

**Architecture:** C++ shim exports two new functions (setup + update drag regions). Zig side removes drag overlay code and calls these instead. The XAML Island handles all hit testing internally via SetRegionRects.

**Tech Stack:** C++/WinRT (WinUI 3 APIs), Zig 0.15.2 (win32 apprt)

**Build:** `zig build -Dapp-runtime=win32 -Dwinui=true` (no output on success)

**Worktree:** `C:\Users\adil\ghostty\ghostty-nonclient` (branch `winui/input-nonclient-pointer`)

---

### Task 1: Add C++ setup and update functions

**Files:**
- Modify: `src/apprt/win32/winui/ghostty_winui.h`
- Modify: `src/apprt/win32/winui/ghostty_winui.cpp`

**Step 1: Add declarations to header**

In `ghostty_winui.h`, replace the `ghostty_tabview_hit_test` declaration (lines 222-228) with:

```c
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
```

**Step 2: Add namespace includes in cpp**

In `ghostty_winui.cpp`, add these to the winrt namespace block (after line 34):

```cpp
    using namespace Microsoft::UI::Input;
    using namespace Microsoft::UI::Windowing;
```

**Step 3: Add implementation in cpp**

Replace the `ghostty_tabview_hit_test` function (lines 1022-1099) with:

```cpp
// ---------------------------------------------------------------
// Drag region management (InputNonClientPointerSource)
// ---------------------------------------------------------------

static void update_drag_regions_impl(GhosttyTabViewImpl* tv, HWND parent_hwnd) {
    if (!tv || !tv->tab_view || !tv->root_grid) {
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: null tv/tab_view/root_grid\n"); fflush(g_log); }
        return;
    }

    try {
        auto xaml_root = tv->root_grid.XamlRoot();
        if (!xaml_root) {
            log_init();
            if (g_log) { fprintf(g_log, "update_drag_regions: no XamlRoot yet\n"); fflush(g_log); }
            return;
        }

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

        // Add the add-tab button. It's inside TabView's template.
        // Walk visual tree to find it.
        auto find_add_button = [](winrt::DependencyObject const& root) -> winrt::FrameworkElement {
            int count = winrt::VisualTreeHelper::GetChildrenCount(root);
            for (int i = 0; i < count; i++) {
                auto child = winrt::VisualTreeHelper::GetChild(root, i);
                auto fe = child.try_as<winrt::FrameworkElement>();
                if (fe) {
                    auto name = fe.Name();
                    if (name == L"AddButton") return fe;
                }
                // Recurse.
                auto result = find_add_button(child);
                if (result) return result;
            }
            return nullptr;
        };

        // Helper lambda needs to be called - use std::function for recursion
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
        }

        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: SetRegionRects called with %d passthrough rects\n",
            (int)passthrough_rects.size()); fflush(g_log); }

    } catch (winrt::hresult_error const& ex) {
        log_init();
        if (g_log) { fprintf(g_log, "update_drag_regions: EXCEPTION 0x%08X\n", (unsigned)ex.code()); fflush(g_log); }
    } catch (...) {
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

        // Set ExtendsContentIntoTitleBar = true via AppWindow.
        auto windowId = winrt::Microsoft::UI::GetWindowIdFromWindow(parent_hwnd);
        auto appWindow = winrt::AppWindow::GetFromWindowId(windowId);
        auto titleBar = appWindow.TitleBar();
        titleBar.ExtendsContentIntoTitleBar(true);
        titleBar.PreferredHeightOption(winrt::TitleBarHeightOption::Tall);

        log_init();
        if (g_log) { fprintf(g_log, "setup_drag_regions: ExtendsContentIntoTitleBar=true, PreferredHeightOption=Tall\n"); fflush(g_log); }

        // Hook SizeChanged on the root grid to auto-update regions.
        tv->root_grid.SizeChanged([tv, parent_hwnd](auto&&, auto&&) {
            log_init();
            if (g_log) { fprintf(g_log, "setup_drag_regions: SizeChanged fired -> updating regions\n"); fflush(g_log); }
            update_drag_regions_impl(tv, parent_hwnd);
        });

        // Hook TabItems vector changed to update on tab add/remove.
        auto items = tv->tab_view.TabItems();
        auto observable = items.try_as<winrt::Windows::Foundation::Collections::IObservableVector<winrt::Windows::Foundation::IInspectable>>();
        if (observable) {
            observable.VectorChanged([tv, parent_hwnd](auto&&, auto&&) {
                log_init();
                if (g_log) { fprintf(g_log, "setup_drag_regions: TabItems VectorChanged -> updating regions\n"); fflush(g_log); }
                update_drag_regions_impl(tv, parent_hwnd);
            });
            log_init();
            if (g_log) { fprintf(g_log, "setup_drag_regions: hooked TabItems VectorChanged\n"); fflush(g_log); }
        }

        // Do initial update.
        update_drag_regions_impl(tv, parent_hwnd);

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
```

**Step 4: Build to verify C++ compiles**

Run: `zig build -Dapp-runtime=win32 -Dwinui=true`
Expected: no output (success). If there are WinRT namespace issues, fix include paths.

**Step 5: Commit**

```bash
git add src/apprt/win32/winui/ghostty_winui.h src/apprt/win32/winui/ghostty_winui.cpp
git commit -m "winui: add InputNonClientPointerSource setup and update functions"
```

---

### Task 2: Update Zig bindings

**Files:**
- Modify: `src/apprt/win32/WinUI.zig`

**Step 1: Replace hit_test binding with new function bindings**

In `WinUI.zig`:

1. Replace line 84 (`FnTabViewHitTest`) with:
```zig
const FnTabViewSetupDragRegions = *const fn (TabView, c.HWND) callconv(.c) void;
const FnTabViewUpdateDragRegions = *const fn (TabView, c.HWND) callconv(.c) void;
```

2. Replace line 117 (`tabview_hit_test` field) with:
```zig
tabview_setup_drag_regions: ?FnTabViewSetupDragRegions = null,
tabview_update_drag_regions: ?FnTabViewUpdateDragRegions = null,
```

3. Replace line 197 (`self.tabview_hit_test = ...`) with:
```zig
    self.tabview_setup_drag_regions = self.getProc(FnTabViewSetupDragRegions, "ghostty_tabview_setup_drag_regions");
    self.tabview_update_drag_regions = self.getProc(FnTabViewUpdateDragRegions, "ghostty_tabview_update_drag_regions");
```

**Step 2: Build to verify Zig compiles**

Run: `zig build -Dapp-runtime=win32 -Dwinui=true`
Expected: Compile errors for remaining references to `tabview_hit_test` in Window.zig. This is expected -- we fix those in Task 3.

**Step 3: Commit**

```bash
git add src/apprt/win32/WinUI.zig
git commit -m "winui: update Zig bindings for drag region functions"
```

---

### Task 3: Remove drag overlay code and wire up new API

**Files:**
- Modify: `src/apprt/win32/Window.zig`
- Modify: `src/apprt/win32/App.zig`

**Step 1: Remove `drag_overlay_hwnd` field from Window struct**

Delete lines 63-66 (the comment and field):
```zig
/// Drag overlay: transparent child window on top of the XAML Island.
/// Intercepts mouse input for drag/resize/caption hit-testing while
/// returning HTTRANSPARENT for XAML interactive controls (tabs, buttons).
drag_overlay_hwnd: ?HWND = null,
```

**Step 2: Remove `registerDragOverlayClass` from App.zig**

1. Delete line 129: `try registerDragOverlayClass(hinstance);`
2. Delete the entire `registerDragOverlayClass` function (lines 1477-1502)

**Step 3: Remove drag overlay functions from Window.zig**

Delete these functions entirely:
- `createDragOverlay` (lines 1405-1516)
- `dragOverlayProc` (lines 1607-1719) -- also remove the `pub` declaration
- `dragOverlayHitTest` (lines 1722-1777)

**Step 4: Remove drag overlay from `destroyWinUIControls`**

In `destroyWinUIControls`, delete the overlay destruction block (lines 1522-1527):
```zig
    // Destroy the drag overlay window.
    if (self.drag_overlay_hwnd) |overlay| {
        _ = c.DestroyWindow(overlay);
        self.drag_overlay_hwnd = null;
    }
```

**Step 5: Remove drag overlay repositioning from `resizeWinUIHost`**

In `resizeWinUIHost`, delete the overlay repositioning block (lines 1373-1387):
```zig
        // Position the drag overlay on top of the XAML Island, covering
        // just the tab bar area. Use HWND_TOP to ensure it's above the island.
        if (self.drag_overlay_hwnd) |overlay| {
            ...
        }
```

Replace it with a call to update drag regions:
```zig
        // Update drag regions after resize.
        if (self.app.winui.tabview_update_drag_regions) |update_fn| {
            log.info("resizeWinUIHost: updating drag regions", .{});
            update_fn(self.winui_tabview, self.hwnd);
        }
```

**Step 6: Replace `createDragOverlay()` call with `setup_drag_regions`**

In `initWinUITabView` (around line 1339), replace:
```zig
    self.createDragOverlay();
```
with:
```zig
    // Set up InputNonClientPointerSource for tab bar drag regions.
    if (winui.tabview_setup_drag_regions) |setup_fn| {
        log.info("initWinUITabView: setting up drag regions for HWND={?}", .{self.hwnd});
        setup_fn(self.winui_tabview, self.hwnd);
    }
```

**Step 7: Remove references to `tabview_hit_test` in Window.zig**

Search for any remaining `tabview_hit_test` references and remove them. The old `dragOverlayHitTest` contained:
```zig
    if (w.app.winui.tabview_hit_test) |hit_test_fn| {
```
This is already deleted as part of removing `dragOverlayHitTest`.

**Step 8: Clean up the parent WM_NCHITTEST handler**

In the parent window proc's `WM_NCHITTEST` handler, remove the debug log line added earlier (if desired), and verify the WinUI path returns `HTCLIENT` for the tab bar area (this is correct -- the XAML Island + InputNonClientPointerSource handles everything there now).

**Step 9: Build and verify**

Run: `zig build -Dapp-runtime=win32 -Dwinui=true`
Expected: no output (success)

**Step 10: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig
git commit -m "winui: replace drag overlay with InputNonClientPointerSource"
```

---

### Task 4: Manual test

**Step 1: Run the app**

Run the built executable and check:
1. Drag on tab bar background should move the window
2. Clicking tabs should switch tabs (passthrough works)
3. Double-click on tab bar background should maximize/restore
4. Right-click on tab bar background should show system menu
5. Resize borders (left, right, bottom) still work
6. Add-tab button is clickable

**Step 2: Check logs**

1. Console (Zig logs): should show `initWinUITabView: setting up drag regions` and `resizeWinUIHost: updating drag regions`
2. `ghostty_winui_log.txt`: should show `setup_drag_regions`, `update_drag_regions` with passthrough rects for each tab and the add button

**Step 3: Verify no regressions**

- Open multiple tabs, close tabs, move tabs -- drag regions should update each time (check log for `VectorChanged -> updating regions`)
- Resize window -- drag regions should update (check log for `SizeChanged fired -> updating regions`)
- Fullscreen toggle should still work

**Step 4: Final commit if any fixups needed**

```bash
git add -A
git commit -m "winui: fixup InputNonClientPointerSource after testing"
```
