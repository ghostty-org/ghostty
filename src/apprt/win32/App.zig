//! Win32 application runtime. Manages the Win32 window class, message loop,
//! and surface (window) lifecycle.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// Timer ID for the quit-after-last-window-closed delay.
const QUIT_TIMER_ID: usize = 1;

/// The Win32 window class name (wide string).
const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// The core application.
core_app: *CoreApp,

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atom from RegisterClassExW.
class_atom: u16 = 0,

/// Background brush created from the configured background color.
/// Used by WM_ERASEBKGND to fill exposed areas during resize,
/// matching the terminal background so the flash is invisible.
bg_brush: ?w32.HBRUSH = null,

/// Quit timer state, mirroring GTK's three-state approach:
/// - off: no quit pending
/// - active: timer is running (waiting for delay to expire)
/// - expired: delay has elapsed, quit on next tick
quit_timer_state: enum { off, active, expired } = .off,

/// Whether quit has been requested.
quit_requested: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    // Create a brush matching the configured background color so that
    // any exposed window area during resize matches the terminal
    // background, making the flash invisible.
    const bg = config.background;
    const bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .bg_brush = bg_brush,
    };

    // Register the window class
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_OWNDC,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = bg_brush,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;

    // Store self pointer in msg_hwnd's GWLP_USERDATA for wndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn run(self: *App) !void {
    // Create the initial window (heap-allocated because renderer/IO
    // threads hold references to the surface).
    const alloc = self.core_app.alloc;
    const initial_surface = try alloc.create(Surface);
    errdefer alloc.destroy(initial_surface);
    try initial_surface.init(self);

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    while (!self.quit_requested) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) break; // WM_QUIT
        if (result < 0) return error.Win32Error;

        // Intercept keystrokes destined for the search edit control so
        // Enter/Escape can navigate matches or close the search bar.
        if (msg.message == w32.WM_KEYDOWN and msg.hwnd != null) {
            // Find the parent surface of this edit control
            const parent = w32.GetParent(msg.hwnd.?);
            if (parent) |p| {
                const userdata = w32.GetWindowLongPtrW(p, w32.GWLP_USERDATA);
                if (userdata != 0) {
                    const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                    if (surface.search_active and surface.search_edit == msg.hwnd) {
                        const vk: u16 = @intCast(msg.wParam & 0xFFFF);
                        if (surface.handleSearchKey(vk)) continue;
                    }
                }
            }
        }

        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.stopQuitTimer();

    if (self.msg_hwnd) |hwnd| {
        // Clear GWLP_USERDATA before destroying. The msg_hwnd stores
        // *App in userdata, but wndProc tries to cast non-zero userdata
        // to *Surface for non-WM_APP_WAKEUP messages (like WM_DESTROY).
        // The alignment of *App differs from *Surface, causing a panic
        // in @ptrFromInt. Clearing to 0 makes wndProc fall through to
        // DefWindowProc for any messages during destruction.
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }

    if (self.bg_brush) |brush| {
        _ = w32.DeleteObject(@ptrCast(brush));
        self.bg_brush = null;
    }

    self.config.deinit();
}

/// Wake up the message loop from any thread by posting a message
/// to the message-only window.
pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}

/// IPC from external processes. Not yet implemented for Win32.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            const alloc = self.core_app.alloc;
            const surface = alloc.create(Surface) catch |err| {
                log.err("failed to allocate new surface err={}", .{err});
                return true;
            };
            surface.init(self) catch |err| {
                log.err("failed to create new window err={}", .{err});
                alloc.destroy(surface);
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            _ = w32.MessageBeep(0xFFFFFFFF);
            return true;
        },

        .quit_timer => {
            switch (value) {
                .start => self.startQuitTimer(),
                .stop => self.stopQuitTimer(),
            }
            return true;
        },

        .config_change => {
            // Update our stored config with the new one.
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;

                // Recreate the background brush from the new config.
                if (self.bg_brush) |old_brush| {
                    _ = w32.DeleteObject(@ptrCast(old_brush));
                }
                const bg = new_config.background;
                self.bg_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
            } else |err| {
                log.err("error updating app config err={}", .{err});
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.toggleFullscreen();
                },
            }
            return true;
        },

        .toggle_maximize => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    if (core_surface.rt_surface.hwnd) |hwnd| {
                        if (w32.IsZoomed(hwnd) != 0) {
                            _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                        } else {
                            _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                        }
                    }
                },
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.close(false);
                },
            }
            return true;
        },

        .open_config => {
            // Open the config file in the default editor.
            const config_path = configpkg.preferredDefaultFilePath(
                self.core_app.alloc,
            ) catch |err| {
                log.err("failed to get config path: {}", .{err});
                return true;
            };
            defer self.core_app.alloc.free(config_path);

            // Convert to wide string for ShellExecuteW.
            var wbuf: [512]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, config_path) catch return true;
            if (wlen < wbuf.len) {
                wbuf[wlen] = 0;
                _ = w32.ShellExecuteW(
                    null,
                    std.unicode.utf8ToUtf16LeStringLiteral("open"),
                    @ptrCast(&wbuf),
                    null,
                    null,
                    w32.SW_SHOW,
                );
            }
            return true;
        },

        .scrollbar => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setScrollbar(value);
                },
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setMouseShape(value);
                },
            }
            return true;
        },

        .open_url => {
            // Open a URL using ShellExecuteW — the native Windows way.
            // internal_os.open() uses std.process.Child which can hit
            // unreachable on Windows, so we use ShellExecuteW directly.
            var wbuf: [2048]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, value.url) catch return true;
            if (wlen < wbuf.len) {
                wbuf[wlen] = 0;
                _ = w32.ShellExecuteW(
                    null,
                    std.unicode.utf8ToUtf16LeStringLiteral("open"),
                    @ptrCast(&wbuf),
                    null,
                    null,
                    w32.SW_SHOW,
                );
            }
            return true;
        },

        .mouse_over_link => {
            // Acknowledge the action. The cursor shape change is handled
            // separately by mouse_shape → IDC_HAND. We could show the
            // URL in a status bar or tooltip here in the future.
            return true;
        },

        .start_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(true, value.needle);
                },
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    core_surface.rt_surface.setSearchActive(false, "");
                },
            }
            return true;
        },

        .search_total, .search_selected => {
            // Acknowledge — we could display match count in the search
            // bar in the future.
            return true;
        },

        .desktop_notification => {
            self.showDesktopNotification(target, value);
            return true;
        },

        // Return false for unhandled actions
        else => return false,
    }
}

/// Start the quit timer. Called when the last surface closes.
fn startQuitTimer(self: *App) void {
    // Cancel any existing timer first.
    self.stopQuitTimer();

    // Check if we should quit at all.
    if (!self.config.@"quit-after-last-window-closed") return;

    // If a delay is configured, start a Win32 timer.
    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        const ms = v.asMilliseconds();
        if (self.msg_hwnd) |hwnd| {
            _ = w32.SetTimer(hwnd, QUIT_TIMER_ID, ms, null);
            self.quit_timer_state = .active;
        }
    } else {
        // No delay — quit immediately.
        self.quit_timer_state = .expired;
        self.quit_requested = true;
        w32.PostQuitMessage(0);
    }
}

/// Cancel the quit timer. Called when a new surface opens.
fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer_state) {
        .off => {},
        .expired => self.quit_timer_state = .off,
        .active => {
            if (self.msg_hwnd) |hwnd| {
                _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            }
            self.quit_timer_state = .off;
        },
    }
}

/// Show a Windows balloon notification via Shell_NotifyIconW.
/// Creates a temporary tray icon, shows the balloon, then removes
/// the icon after a short delay.
fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    value: apprt.Action.Value(.desktop_notification),
) void {
    _ = target;
    const hwnd = self.msg_hwnd orelse return;

    var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = w32.NIF_INFO | w32.NIF_ICON | w32.NIF_TIP;
    nid.hIcon = w32.LoadIconW(null, w32.IDI_APPLICATION);
    nid.dwInfoFlags = w32.NIIF_INFO;
    nid.uVersion_or_uTimeout = 5000; // 5 second timeout

    // Copy title (UTF-8 → UTF-16LE)
    const title_z = value.title;
    var title_len = std.unicode.utf8ToUtf16Le(&nid.szInfoTitle, title_z) catch 0;
    if (title_len >= nid.szInfoTitle.len) title_len = nid.szInfoTitle.len - 1;
    nid.szInfoTitle[title_len] = 0;

    // Copy body (UTF-8 → UTF-16LE)
    const body_z = value.body;
    var body_len = std.unicode.utf8ToUtf16Le(&nid.szInfo, body_z) catch 0;
    if (body_len >= nid.szInfo.len) body_len = nid.szInfo.len - 1;
    nid.szInfo[body_len] = 0;

    // Tooltip
    const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(nid.szTip[0..tip.len], tip);
    nid.szTip[tip.len] = 0;

    // Add the icon, show notification, then remove the icon.
    _ = w32.Shell_NotifyIconW(w32.NIM_ADD, &nid);
    _ = w32.Shell_NotifyIconW(w32.NIM_MODIFY, &nid);

    // Schedule icon removal after 6 seconds via a timer.
    // Timer ID 2 (separate from quit timer).
    _ = w32.SetTimer(hwnd, 2, 6000, null);
}

/// Create a new visible window. This is called by Surface.init and
/// by performAction(.new_window).
pub fn createWindow(self: *App) !w32.HWND {
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        self.hinstance,
        null,
    ) orelse return error.Win32Error;

    // Enable dark mode window chrome so the title bar and frame match
    // the terminal's dark background. This also prevents the bright
    // white resize border that would otherwise flash during resize.
    // Supported on Windows 10 build 18985+ and Windows 11.
    const dark_mode: u32 = 1; // TRUE
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    // Apply dark theme to common controls (scrollbar, etc.) so they
    // match the dark title bar instead of being bright white.
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window
    // transparent using the layered window API. This applies uniform
    // alpha to the entire window (including text), but is the only
    // reliable approach with legacy OpenGL/WGL contexts.
    if (self.config.@"background-opacity" < 1.0) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(self.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    return hwnd;
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// The Win32 window procedure. Routes messages to the appropriate Surface
/// or handles app-level messages.
fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.c) isize {
    // GWLP_USERDATA stores either an *App (message-only window) or
    // *Surface (visible windows). We disambiguate by checking the message:
    // WM_APP_WAKEUP only goes to the message-only window.
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);

    // Handle app-level messages (message-only window, userdata is *App).
    if (msg == WM_APP_WAKEUP) {
        if (userdata != 0) {
            const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
            app.tick();
        }
        return 0;
    }

    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        if (userdata != 0) {
            const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
            _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
            app.quit_timer_state = .expired;
            app.quit_requested = true;
            w32.PostQuitMessage(0);
        }
        return 0;
    }

    // Timer ID 2: remove the notification tray icon after balloon timeout.
    if (msg == w32.WM_TIMER and wparam == 2) {
        _ = w32.KillTimer(hwnd, 2);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }

    // All other messages are for visible (surface) windows.
    // If userdata is 0 (during creation) or this is a non-surface window,
    // fall through to DefWindowProc.
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Guard: verify this is a surface window or its search popup.
    // The msg-only window can receive WM_DESTROY during shutdown.
    const is_surface_window = surface.hwnd != null and surface.hwnd.? == hwnd;
    const is_search_popup = surface.search_hwnd != null and surface.search_hwnd.? == hwnd;
    if (!is_surface_window and !is_search_popup)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_ENTERSIZEMOVE => {
            surface.in_live_resize = true;
            return 0;
        },

        w32.WM_EXITSIZEMOVE => {
            surface.in_live_resize = false;
            return 0;
        },

        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_CLOSE => {
            // If wparam=1 (set by Surface.close when process_active=true),
            // show a confirmation dialog. For the X button (wparam=0), we
            // don't call needsConfirmQuit() because without shell integration
            // (common on Windows with cmd.exe), it always returns true since
            // cursorIsAtPrompt() can't detect prompt state without OSC 133.
            const needs_confirm = wparam == 1;

            if (needs_confirm) {
                const result = w32.MessageBoxW(
                    hwnd,
                    std.unicode.utf8ToUtf16LeStringLiteral(
                        "A process is still running in this terminal.\r\nClose anyway?",
                    ),
                    std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
                    w32.MB_YESNO | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2,
                );
                if (result != w32.IDYES) return 0;
            }

            // Destroy the window. This is safe here because WM_CLOSE is
            // dispatched from the message loop (not from inside a
            // core_surface callback), so no code holds a reference to
            // the surface that would be invalidated.
            if (surface.hwnd) |h| {
                _ = w32.DestroyWindow(h);
            }
            return 0;
        },

        w32.WM_DESTROY => {
            surface.handleDestroy();
            return 0;
        },

        w32.WM_ERASEBKGND => {
            // Fill with the configured background color to prevent
            // a visible flash during resize. The OpenGL renderer will
            // overwrite the entire client area on the next frame.
            if (surface.app.bg_brush) |brush| {
                const hdc_erase: w32.HDC = @ptrFromInt(wparam);
                var rect: w32.RECT = undefined;
                if (w32.GetClientRect(hwnd, &rect) != 0) {
                    _ = w32.FillRect(hdc_erase, &rect, brush);
                }
            }
            return 1;
        },

        w32.WM_PAINT => {
            // Validate the paint region to stop Windows from
            // sending more WM_PAINT messages, then wake the
            // renderer thread to redraw.
            _ = w32.ValidateRect(hwnd, null);
            if (surface.core_surface_ready) {
                surface.core_surface.renderer_thread.wakeup.notify() catch {};
            }
            return 0;
        },

        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },

        w32.WM_CHAR => {
            // In Win32 Input Mode, the Unicode character is already
            // included in the WM_KEYDOWN event (Uc parameter). WM_CHAR
            // from TranslateMessage would duplicate it. IME text arrives
            // via WM_IME_COMPOSITION (handled separately), so suppress
            // all WM_CHAR in this mode.
            if (surface.isWin32InputMode()) return 0;

            // If handleKeyEvent already produced text via ToUnicode for
            // the preceding WM_KEYDOWN, suppress this WM_CHAR to avoid
            // double input. Otherwise, process it — the character came
            // from IME, SendInput Unicode (VK_PACKET), PostMessage, or
            // another source that didn't go through handleKeyEvent.
            if (surface.key_event_produced_text) {
                surface.key_event_produced_text = false;
                return 0;
            }
            surface.handleCharEvent(wparam);
            return 0;
        },

        w32.WM_IME_STARTCOMPOSITION => {
            surface.handleImeStartComposition();
            // Let DefWindowProc show the default composition window.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_COMPOSITION => {
            if (surface.handleImeComposition(lparam)) {
                // We extracted the result string — suppress further
                // processing so WM_IME_CHAR/WM_CHAR are not generated.
                return 0;
            }
            // No result string yet (intermediate composition) — let
            // DefWindowProc update the default composition window.
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_IME_ENDCOMPOSITION => {
            surface.handleImeEndComposition();
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_LBUTTONDOWN => { surface.handleMouseButton(.left, .press, lparam); return 0; },
        w32.WM_LBUTTONUP => { surface.handleMouseButton(.left, .release, lparam); return 0; },
        w32.WM_RBUTTONDOWN => { surface.handleMouseButton(.right, .press, lparam); return 0; },
        w32.WM_RBUTTONUP => { surface.handleMouseButton(.right, .release, lparam); return 0; },
        w32.WM_MBUTTONDOWN => { surface.handleMouseButton(.middle, .press, lparam); return 0; },
        w32.WM_MBUTTONUP => { surface.handleMouseButton(.middle, .release, lparam); return 0; },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam);
            return 0;
        },

        w32.WM_VSCROLL => {
            surface.handleVScroll(wparam);
            return 0;
        },

        w32.WM_SETCURSOR => {
            // Only override the cursor in the client area. For non-client
            // areas (resize borders, title bar), let DefWindowProc handle it.
            const hit_test: u16 = @intCast(lparam & 0xFFFF);
            if (hit_test == w32.HTCLIENT and surface.handleSetCursor()) {
                return 1; // TRUE = we set the cursor
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_COMMAND => {
            const notification: u16 = @intCast((wparam >> 16) & 0xFFFF);
            const control_id: u16 = @intCast(wparam & 0xFFFF);
            if (control_id == Surface.SEARCH_EDIT_ID and notification == w32.EN_CHANGE) {
                surface.handleSearchChange();
                return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_CTLCOLOREDIT => {
            // Dark mode colors for the search edit control
            const hdc_edit: w32.HDC = @ptrFromInt(wparam);
            _ = w32.SetTextColor(hdc_edit, w32.RGB(220, 220, 220));
            _ = w32.SetBkColor(hdc_edit, w32.RGB(45, 45, 45));
            if (surface.app.bg_brush) |brush| {
                return @bitCast(@intFromPtr(@as(*const anyopaque, @ptrCast(brush))));
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_SETFOCUS => { surface.handleFocus(true); return 0; },
        w32.WM_KILLFOCUS => { surface.handleFocus(false); return 0; },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
