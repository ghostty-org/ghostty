/// The entry point of the Win32 runtime. It creates the windows, runs the
/// message loop, and turns core actions into window operations.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreApp = @import("../../App.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const Palette = @import("Palette.zig");
const Inspector = @import("Inspector.zig");
const input = @import("../../input.zig");
const keymap = @import("key.zig");
const c = @import("c.zig");
const handoff = @import("handoff.zig");

const log = std.log.scoped(.win32);

/// Posted to the hidden app window from any thread to ask the main thread
/// to drain the core's mailbox.
const wake_message = c.WM_APP;

const app_class_name = c.utf16Literal("GhosttyApp");

core_app: *CoreApp,
config: configpkg.Config,

/// True when Windows started us to receive a console session, in which
/// case there is no window of our own to open at startup.
receiving_handoff: bool,

/// The drop-down terminal, once it has been shown.
quick: ?*Window = null,

/// How many ordinary windows are open.
normal_windows: usize = 0,

/// The shortcuts registered with Windows. A shortcut's number is its
/// position here plus one.
hotkeys: std.ArrayList(Hotkey) = .empty,

/// A message-only window. It has no screen presence and exists so other
/// threads have somewhere to post `wake_message`.
wake_hwnd: c.Handle,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    // Without this Windows scales our windows as bitmaps on high-DPI
    // displays, which blurs all of the terminal text.
    _ = c.SetProcessDpiAwarenessContext(c.DPI_AWARENESS_PER_MONITOR_V2);

    var config = try configpkg.Config.load(core_app.alloc);
    errdefer config.deinit();

    const instance = c.GetModuleHandleW(null);
    if (c.RegisterClassExW(&.{
        .wnd_proc = appWndProc,
        .instance = instance,
        .class_name = app_class_name,
    }) == 0) return error.RegisterClassFailed;
    try Surface.registerClass(instance);
    try Window.registerClass(instance);
    try Palette.registerClass(instance);
    try Inspector.registerClass(instance);

    self.* = .{
        .core_app = core_app,
        .config = config,
        .receiving_handoff = handoff.isEmbedding(),
        .wake_hwnd = undefined,
    };

    self.wake_hwnd = c.CreateWindowExW(
        0,
        app_class_name,
        c.utf16Literal(""),
        0,
        0,
        0,
        0,
        0,
        @ptrFromInt(c.HWND_MESSAGE),
        null,
        instance,
        self,
    ) orelse return error.WindowCreateFailed;

    self.registerGlobalKeybinds();
    if (self.receiving_handoff) try handoff.start(self, onHandoff);
}

/// Windows is offering a console session. Hosting one is not implemented
/// yet, so decline with E_NOTIMPL and let Windows fall back to its console.
fn onHandoff(context: *anyopaque, request: handoff.Request) i32 {
    _ = context;
    _ = request;
    return @bitCast(@as(u32, 0x80004001));
}

pub fn run(self: *App) !void {
    if (!self.receiving_handoff) _ = try Window.create(self);

    var msg: c.Msg = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        // TranslateMessage is skipped on purpose: it would turn key presses
        // into WM_CHAR messages, but the surface builds text itself so the
        // core receives it together with the physical key.
        _ = c.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    if (self.receiving_handoff) handoff.stop();
    self.unregisterGlobalKeybinds();
    self.hotkeys.deinit(self.core_app.alloc);
    _ = c.DestroyWindow(self.wake_hwnd);
    self.config.deinit();
}

/// Called by the core to wake up the event loop. Safe from any thread.
pub fn wakeup(self: *App) void {
    _ = c.PostMessageW(self.wake_hwnd, wake_message, 0, 0);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .new_window => {
            _ = try Window.create(self);
            return true;
        },

        .quit => {
            c.PostQuitMessage(0);
            return true;
        },

        // The core starts this timer when the last surface closes. We quit
        // right away instead of waiting.
        .quit_timer => {
            switch (value) {
                .start => c.PostQuitMessage(0),
                .stop => {},
            }
            return true;
        },

        // Configuration is read once at startup for now.
        .config_change => return true,

        .render => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.invalidate(),
            }
            return true;
        },

        .set_title => {
            switch (target) {
                .app => return false,
                .surface => |surface| try surface.rt_surface.setTitle(value.title),
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.closeWindow(),
            }
            return true;
        },

        .set_window_title => {
            switch (target) {
                .app => return false,
                .surface => |surface| try surface.rt_surface.setTitle(value.title),
            }
            return true;
        },

        .mouse_shape => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.setCursorShape(value),
            }
            return true;
        },

        .mouse_visibility => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.setMouseHidden(value == .hidden),
            }
            return true;
        },

        .initial_size => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.setInitialSize(value.width, value.height),
            }
            return true;
        },

        .size_limit => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.setMinimumSize(value.min_width, value.min_height),
            }
            return true;
        },

        .toggle_maximize => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.toggleMaximize(),
            }
            return true;
        },

        .toggle_fullscreen => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.toggleFullscreen(),
            }
            return true;
        },

        .toggle_window_decorations => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.toggleDecorations(),
            }
            return true;
        },

        .ring_bell => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.ringBell(),
            }
            return true;
        },

        // Nothing to track or draw for these yet, but returning true keeps
        // the core from treating them as failures.
        .pwd, .cell_size, .mouse_over_link, .selection_changed => return true,

        .progress_report => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.setProgress(value),
            }
            return true;
        },

        .desktop_notification => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.window.notify(value.title, value.body),
            }
            return true;
        },

        .start_search => {
            switch (target) {
                .app => return false,
                .surface => |surface| try surface.rt_surface.startSearch(value.needle),
            }
            return true;
        },

        .end_search => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.endSearch(),
            }
            return true;
        },

        .search_total => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.setSearchTotal(value.total),
            }
            return true;
        },

        .search_selected => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.setSearchSelected(value.selected),
            }
            return true;
        },

        .scrollbar => {
            switch (target) {
                .app => return false,
                .surface => |surface| surface.rt_surface.setScrollbar(value),
            }
            return true;
        },

        .new_tab => {
            const surface = surfaceOf(target) orelse return false;
            _ = try surface.window.newTab();
            return true;
        },

        .close_tab => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.closeTabsOf(surface, value);
            return true;
        },

        .goto_tab => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.gotoTab(value);
            return true;
        },

        .move_tab => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.moveTab(value.amount);
            return true;
        },

        .set_tab_title => {
            const surface = surfaceOf(target) orelse return false;
            try surface.window.setTabTitle(surface, value.title);
            return true;
        },

        .new_split => {
            const surface = surfaceOf(target) orelse return false;
            try surface.window.newSplit(surface, value);
            return true;
        },

        .goto_split => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.gotoSplit(surface, value);
            return true;
        },

        .resize_split => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.resizeSplit(surface, value.amount, value.direction);
            return true;
        },

        .equalize_splits => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.equalizeSplits(surface);
            return true;
        },

        .toggle_split_zoom => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.toggleSplitZoom(surface);
            return true;
        },

        .toggle_quick_terminal => {
            try self.toggleQuickTerminal();
            return true;
        },

        .inspector => {
            const surface = surfaceOf(target) orelse return false;
            surface.controlInspector(value);
            return true;
        },

        .render_inspector => {
            const surface = surfaceOf(target) orelse return false;
            surface.redrawInspector();
            return true;
        },

        .toggle_tab_overview => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.toggleTabOverview();
            return true;
        },

        .toggle_command_palette => {
            const surface = surfaceOf(target) orelse return false;
            surface.window.toggleCommandPalette(surface);
            return true;
        },

        .open_url => return openUrl(self.core_app.alloc, value),

        .open_config => return openConfig(self.core_app.alloc),

        .reload_config => {
            try self.reloadConfig();
            return true;
        },

        // Everything else is a feature this runtime does not have yet. The
        // core falls back to its own behavior when we return false.
        else => return false,
    }
}

// Drop-down terminal and global shortcuts

/// Show the drop-down terminal, creating it the first time.
pub fn toggleQuickTerminal(self: *App) !void {
    if (self.quick) |window| {
        window.toggleQuick();
        return;
    }
    _ = try Window.createQuick(self);
}

/// A normal window has closed. The drop-down terminal does not keep the
/// program running by itself, so it goes when the last one is gone.
pub fn windowClosed(self: *App) void {
    self.normal_windows -|= 1;
    if (self.normal_windows == 0) {
        if (self.quick) |window| _ = c.DestroyWindow(window.hwnd);
    }
}

/// A keyboard shortcut that works while Ghostty is in the background.
const Hotkey = struct {
    action: *const input.Binding.Action,
};

/// Ask Windows to report the key bindings marked `global`, even when another
/// program has the keyboard. Windows allows each shortcut to belong to one
/// program only, so one that is taken elsewhere is skipped.
fn registerGlobalKeybinds(self: *App) void {
    const alloc = self.core_app.alloc;
    var iterator = self.config.keybind.set.bindings.iterator();
    while (iterator.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            .leaf => |leaf| leaf,
            else => continue,
        };
        if (!leaf.flags.global) continue;
        const key = switch (entry.key_ptr.key) {
            .physical => |physical| physical,
            else => continue,
        };
        const vk = keymap.virtualKeyOf(key) orelse continue;

        const mods = entry.key_ptr.mods;
        var flags: u32 = c.MOD_NOREPEAT;
        if (mods.alt) flags |= c.MOD_ALT;
        if (mods.ctrl) flags |= c.MOD_CONTROL;
        if (mods.shift) flags |= c.MOD_SHIFT;
        if (mods.super) flags |= c.MOD_WIN;

        // The number Windows reports back when the shortcut is pressed.
        const id: c_int = @intCast(self.hotkeys.items.len + 1);
        if (c.RegisterHotKey(self.wake_hwnd, id, flags, vk) == 0) {
            log.warn("could not register a global shortcut, another program may use it", .{});
            continue;
        }
        self.hotkeys.append(alloc, .{ .action = &entry.value_ptr.leaf.action }) catch {
            _ = c.UnregisterHotKey(self.wake_hwnd, id);
        };
    }
}

fn unregisterGlobalKeybinds(self: *App) void {
    for (0..self.hotkeys.items.len) |i| {
        _ = c.UnregisterHotKey(self.wake_hwnd, @intCast(i + 1));
    }
    self.hotkeys.clearRetainingCapacity();
}

/// A global shortcut was pressed.
fn runGlobalShortcut(self: *App, id: usize) void {
    if (id == 0 or id > self.hotkeys.items.len) return;
    const action = self.hotkeys.items[id - 1].action;
    switch (action.*) {
        .toggle_quick_terminal => self.toggleQuickTerminal() catch |err| {
            log.warn("could not toggle the quick terminal err={}", .{err});
        },
        else => {
            const surface = self.core_app.focusedSurface() orelse return;
            _ = surface.performBindingAction(action.*) catch |err| {
                log.warn("global shortcut failed err={}", .{err});
            };
        },
    }
}

fn surfaceOf(target: apprt.Target) ?*Surface {
    return switch (target) {
        .app => null,
        .surface => |core_surface| core_surface.rt_surface,
    };
}

/// Read the configuration again and give it to every surface.
fn reloadConfig(self: *App) !void {
    var new_config = try configpkg.Config.load(self.core_app.alloc);
    errdefer new_config.deinit();

    // The core copies what it needs, so the old config can go afterward.
    try self.core_app.updateConfig(self, &new_config);
    // The shortcuts point into the old config, so they are registered again.
    self.unregisterGlobalKeybinds();
    self.config.deinit();
    self.config = new_config;
    self.registerGlobalKeybinds();
}

/// Open a link in the user's default handler.
///
/// Links that come from terminal output can be anything a program printed,
/// so for those only web and mail addresses are opened. Opening an arbitrary
/// path or protocol could run a program the user never meant to start.
fn openUrl(alloc: Allocator, value: apprt.action.OpenUrl) !bool {
    const untrusted = switch (value.kind) {
        .unknown, .osc8 => true,
        else => false,
    };
    if (untrusted and !hasSafeScheme(value.url)) return false;

    const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, value.url);
    defer alloc.free(wide);

    // ShellExecute reports success with a value greater than 32.
    const result = c.ShellExecuteW(null, c.utf16Literal("open"), wide, null, null, c.SW_SHOW);
    return @intFromPtr(result) > 32;
}

/// Open the config file in a text editor, creating it first if there is
/// none yet. The file has no extension Windows knows, so Notepad is used
/// rather than whatever the system would pick for it.
fn openConfig(alloc: Allocator) !bool {
    const path = configpkg.edit.openPath(alloc) catch |err| {
        log.warn("could not prepare the config file err={}", .{err});
        return false;
    };
    defer alloc.free(path);

    const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(wide_path);

    // The path goes to Notepad in quotes, since folders can have spaces.
    const quoted = try std.mem.concat(alloc, u16, &.{ &[_]u16{'"'}, wide_path, &[_]u16{'"'} });
    defer alloc.free(quoted);
    const parameters = try alloc.dupeSentinel(u16, quoted, 0);
    defer alloc.free(parameters);

    const result = c.ShellExecuteW(null, c.utf16Literal("open"), c.utf16Literal("notepad.exe"), parameters, null, c.SW_SHOW);
    return @intFromPtr(result) > 32;
}

fn hasSafeScheme(url: []const u8) bool {
    const schemes = [_][]const u8{ "http://", "https://", "mailto:" };
    for (schemes) |scheme| {
        if (std.ascii.startsWithIgnoreCase(url, scheme)) return true;
    }
    return false;
}

test "only web and mail links count as safe" {
    try std.testing.expect(hasSafeScheme("https://example.com"));
    try std.testing.expect(hasSafeScheme("HTTP://example.com"));
    try std.testing.expect(hasSafeScheme("mailto:someone@example.com"));
    try std.testing.expect(!hasSafeScheme("file:///c:/windows/system32/calc.exe"));
    try std.testing.expect(!hasSafeScheme("calc.exe"));
    try std.testing.expect(!hasSafeScheme("ms-msdt:/id"));
}

/// Send the given IPC to a running Ghostty. There is no single-instance
/// support on Windows yet, so nothing can be delivered.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

fn appWndProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const create: *const c.CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(
            hwnd,
            c.GWLP_USERDATA,
            @bitCast(@intFromPtr(create.create_params)),
        );
    } else if (msg == wake_message) {
        const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
        if (ptr != 0) {
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            self.core_app.tick(self) catch |err| {
                log.warn("error ticking the app err={}", .{err});
            };
        }
        return 0;
    } else if (msg == c.WM_HOTKEY) {
        const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
        if (ptr != 0) {
            const self: *App = @ptrFromInt(@as(usize, @bitCast(ptr)));
            self.runGlobalShortcut(wparam);
        }
        return 0;
    }

    return c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
