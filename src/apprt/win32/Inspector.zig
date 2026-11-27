//! The terminal inspector: a window that shows what a terminal is doing, such
//! as the bytes it receives and the state it keeps. It is drawn by Dear ImGui
//! with OpenGL into a window of its own, and belongs to one terminal.
const Inspector = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cimgui = @import("dcimgui");
const core_inspector = @import("../../inspector/main.zig");
const wgl = @import("../../renderer/opengl/wgl.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const c = @import("c.zig");
const key = @import("key.zig");

const log = std.log.scoped(.win32);

const class_name = c.utf16Literal("GhosttyInspector");

// The few OpenGL calls made here are from OpenGL 1.1, which opengl32.dll
// provides directly.
extern "opengl32" fn glViewport(x: c_int, y: c_int, w: c_int, h: c_int) callconv(.c) void;
extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.c) void;
extern "opengl32" fn glClear(mask: u32) callconv(.c) void;
const GL_COLOR_BUFFER_BIT = 0x4000;

surface: *Surface,
hwnd: c.Handle,
gl: wgl.Context,
imgui: *cimgui.c.ImGuiContext,
last_frame_ms: u64,
/// Set when the terminal is being destroyed, which already stops the
/// inspector itself.
surface_gone: bool = false,

pub fn registerClass(instance: ?c.Handle) !void {
    if (c.RegisterClassExW(&.{
        .style = c.CS_OWNDC,
        .wnd_proc = wndProc,
        .instance = instance,
        .cursor = c.LoadCursorW(null, c.IDC_ARROW),
        .class_name = class_name,
    }) == 0) return error.RegisterClassFailed;
}

/// Open the inspector for a terminal and start collecting what it shows.
pub fn open(surface: *Surface) !*Inspector {
    const alloc = surface.app.core_app.alloc;

    const self = try alloc.create(Inspector);
    errdefer alloc.destroy(self);
    self.* = .{
        .surface = surface,
        .hwnd = undefined,
        .gl = undefined,
        .imgui = undefined,
        .last_frame_ms = c.GetTickCount64(),
    };

    self.hwnd = c.CreateWindowExW(
        0,
        class_name,
        c.utf16Literal("Ghostty Inspector"),
        c.WS_OVERLAPPEDWINDOW,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        1000,
        750,
        null,
        null,
        c.GetModuleHandleW(null),
        self,
    ) orelse return error.WindowCreateFailed;
    errdefer _ = c.DestroyWindow(self.hwnd);

    self.gl = try wgl.Context.createOn(self.hwnd, false, 3, 3);
    errdefer self.gl.destroy();
    try self.gl.makeCurrent();

    self.imgui = cimgui.c.ImGui_CreateContext(null) orelse return error.ImguiFailed;
    errdefer cimgui.c.ImGui_DestroyContext(self.imgui);
    cimgui.c.ImGui_SetCurrentContext(self.imgui);

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.BackendPlatformName = "ghostty_win32";
    if (!cimgui.ImGui_ImplOpenGL3_Init(null)) return error.ImguiFailed;
    errdefer cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();

    // The inspector's own setup chooses a font sized for twice the usual
    // scale. Sizes are scaled up front, and the font down to match.
    core_inspector.Inspector.setup();
    const scale: f32 = @as(f32, @floatFromInt(c.GetDpiForWindow(self.hwnd))) / 96.0;
    var style: cimgui.c.ImGuiStyle = undefined;
    cimgui.ext.ImGuiStyle_ImGuiStyle(&style);
    cimgui.c.ImGuiStyle_ScaleAllSizes(&style, scale);
    style.FontScaleMain = scale / 2.0;
    cimgui.c.ImGui_GetStyle().* = style;

    try surface.core_surface.activateInspector();
    _ = c.ShowWindow(self.hwnd, c.SW_SHOW);
    self.invalidate();
    return self;
}

/// Close the inspector. When the terminal itself is going away it has
/// already stopped the inspector, so that is not repeated.
pub fn close(self: *Inspector, surface_gone: bool) void {
    self.surface_gone = surface_gone;
    _ = c.DestroyWindow(self.hwnd);
}

pub fn invalidate(self: *Inspector) void {
    _ = c.InvalidateRect(self.hwnd, null, 0);
}

fn useContext(self: *Inspector) bool {
    self.gl.makeCurrent() catch return false;
    cimgui.c.ImGui_SetCurrentContext(self.imgui);
    return true;
}

fn render(self: *Inspector) void {
    if (!self.useContext()) return;
    const core = &self.surface.core_surface;
    const inspector = core.inspector orelse return;

    var client: c.Rect = undefined;
    _ = c.GetClientRect(self.hwnd, &client);
    const width = client.right;
    const height = client.bottom;
    if (width <= 0 or height <= 0) return;

    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();
    io.DisplaySize = .{ .x = @floatFromInt(width), .y = @floatFromInt(height) };
    io.DisplayFramebufferScale = .{ .x = 1, .y = 1 };

    const now = c.GetTickCount64();
    io.DeltaTime = @max(0.00001, @as(f32, @floatFromInt(now - self.last_frame_ms)) / 1000.0);
    self.last_frame_ms = now;

    // Some ImGui behavior takes two frames to settle, so it is drawn twice.
    for (0..2) |_| {
        cimgui.ImGui_ImplOpenGL3_NewFrame();
        cimgui.c.ImGui_NewFrame();
        inspector.render(core);
        cimgui.c.ImGui_Render();
    }

    glViewport(0, 0, width, height);
    glClearColor(0.1, 0.1, 0.1, 1.0);
    glClear(GL_COLOR_BUFFER_BIT);
    cimgui.ImGui_ImplOpenGL3_RenderDrawData(cimgui.c.ImGui_GetDrawData());
    self.gl.swapBuffers();
}

/// Turn what the user does in this window into ImGui input.
fn handleMessage(self: *Inspector, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) ?c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PaintStruct = undefined;
            _ = c.BeginPaint(self.hwnd, &ps);
            defer _ = c.EndPaint(self.hwnd, &ps);
            self.render();
            return 0;
        },
        c.WM_ERASEBKGND => return 1,
        c.WM_SIZE => {
            self.invalidate();
            return 0;
        },
        c.WM_CLOSE => {
            _ = c.DestroyWindow(self.hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            self.teardown();
            return 0;
        },
        else => {},
    }

    if (!self.useContext()) return null;
    const io: *cimgui.c.ImGuiIO = cimgui.c.ImGui_GetIO();

    switch (msg) {
        c.WM_MOUSEMOVE => {
            cimgui.c.ImGuiIO_AddMousePosEvent(io, @floatFromInt(c.loword(lparam)), @floatFromInt(c.hiword(lparam)));
        },
        c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_RBUTTONDOWN, c.WM_RBUTTONUP, c.WM_MBUTTONDOWN, c.WM_MBUTTONUP => {
            const button: c_int = switch (msg) {
                c.WM_LBUTTONDOWN, c.WM_LBUTTONUP => cimgui.c.ImGuiMouseButton_Left,
                c.WM_RBUTTONDOWN, c.WM_RBUTTONUP => cimgui.c.ImGuiMouseButton_Right,
                else => cimgui.c.ImGuiMouseButton_Middle,
            };
            const down = msg == c.WM_LBUTTONDOWN or msg == c.WM_RBUTTONDOWN or msg == c.WM_MBUTTONDOWN;
            cimgui.c.ImGuiIO_AddMousePosEvent(io, @floatFromInt(c.loword(lparam)), @floatFromInt(c.hiword(lparam)));
            cimgui.c.ImGuiIO_AddMouseButtonEvent(io, button, down);
            if (down) _ = c.SetCapture(self.hwnd) else _ = c.ReleaseCapture();
        },
        c.WM_MOUSEWHEEL => {
            const notches: f32 = @as(f32, @floatFromInt(c.hiword(@bitCast(wparam)))) / 120.0;
            cimgui.c.ImGuiIO_AddMouseWheelEvent(io, 0, notches);
        },
        c.WM_SETFOCUS => cimgui.c.ImGuiIO_AddFocusEvent(io, true),
        c.WM_KILLFOCUS => cimgui.c.ImGuiIO_AddFocusEvent(io, false),
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP => self.keyEvent(io, msg, wparam, lparam),
        else => return null,
    }

    self.invalidate();
    return 0;
}

fn keyEvent(self: *Inspector, io: *cimgui.c.ImGuiIO, msg: u32, wparam: c.WPARAM, lparam: c.LPARAM) void {
    const down = msg == c.WM_KEYDOWN or msg == c.WM_SYSKEYDOWN;

    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftShift, c.GetKeyState(c.VK_SHIFT) < 0);
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftCtrl, c.GetKeyState(c.VK_CONTROL) < 0);
    cimgui.c.ImGuiIO_AddKeyEvent(io, cimgui.c.ImGuiKey_LeftAlt, c.GetKeyState(c.VK_MENU) < 0);

    const lparam_bits: usize = @bitCast(lparam);
    const extended = (lparam_bits >> 24) & 1 == 1;
    const scan_code: u32 = @truncate((lparam_bits >> 16) & 0xFF);
    const physical = key.fromVirtualKey(@intCast(wparam), extended, scan_code);
    if (physical.imguiKey()) |imgui_key| cimgui.c.ImGuiIO_AddKeyEvent(io, imgui_key, down);

    // Typed text. Windows only makes the characters when asked.
    if (down) {
        const synthetic: c.Msg = .{
            .hwnd = self.hwnd,
            .message = c.WM_KEYDOWN,
            .wparam = wparam,
            .lparam = lparam,
            .time = 0,
            .pt = .{ .x = 0, .y = 0 },
            .private = 0,
        };
        _ = c.TranslateMessage(&synthetic);
        var message: c.Msg = undefined;
        while (c.PeekMessageW(&message, self.hwnd, c.WM_CHAR, c.WM_CHAR, c.PM_REMOVE) != 0) {
            const unit: u16 = @truncate(message.wparam);
            if (unit < 0x20 or unit == 0x7F) continue;
            var text: [8:0]u8 = @splat(0);
            const length = std.unicode.utf16LeToUtf8(&text, &.{unit}) catch continue;
            text[length] = 0;
            cimgui.c.ImGuiIO_AddInputCharactersUTF8(io, &text);
        }
    }
}

/// The window is gone. Let go of what it used, and tell the terminal.
fn teardown(self: *Inspector) void {
    const surface = self.surface;
    const alloc = surface.app.core_app.alloc;
    _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

    if (self.useContext()) {
        cimgui.ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup();
        cimgui.c.ImGui_DestroyContext(self.imgui);
    }
    self.gl.destroy();

    surface.inspector_window = null;
    if (!self.surface_gone) surface.core_surface.deactivateInspector();
    alloc.destroy(self);
}

fn wndProc(
    hwnd: c.Handle,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) callconv(.c) c.LRESULT {
    if (msg == c.WM_NCCREATE) {
        const create: *const c.CreateStructW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(create.create_params)));
        const self: *Inspector = @ptrCast(@alignCast(create.create_params.?));
        self.hwnd = hwnd;
        return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return c.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Inspector = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return self.handleMessage(msg, wparam, lparam) orelse c.DefWindowProcW(hwnd, msg, wparam, lparam);
}
