const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const ZigTerminal = @import("../Terminal.zig");
const Stream = @import("../stream_terminal.zig").Stream;
const ScreenSet = @import("../ScreenSet.zig");
const PageList = @import("../PageList.zig");
const kitty = @import("../kitty/key.zig");
const modes = @import("../modes.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const device_attributes = @import("../device_attributes.zig");
const device_status = @import("../device_status.zig");
const size_report = @import("../size_report.zig");
const cell_c = @import("cell.zig");
const row_c = @import("row.zig");
const grid_ref_c = @import("grid_ref.zig");
const style_c = @import("style.zig");
const color = @import("../color.zig");
const Result = @import("result.zig").Result;

const Handler = @import("../stream_terminal.zig").Handler;

const log = std.log.scoped(.terminal_c);

/// Wrapper around ZigTerminal that tracks additional state for C API usage,
/// such as the persistent VT stream needed to handle escape sequences split
/// across multiple vt_write calls.
const TerminalWrapper = struct {
    terminal: *ZigTerminal,
    stream: Stream,
    effects: Effects = .{},
};

/// C callback state for terminal effects. Trampolines are always
/// installed on the stream handler; they check these fields and
/// no-op when the corresponding callback is null.
const Effects = struct {
    userdata: ?*anyopaque = null,
    write_pty: ?WritePtyFn = null,
    bell: ?BellFn = null,
    color_scheme: ?ColorSchemeFn = null,
    device_attributes_cb: ?DeviceAttributesFn = null,
    enquiry: ?EnquiryFn = null,
    xtversion: ?XtversionFn = null,
    title_changed: ?TitleChangedFn = null,
    size_cb: ?SizeFn = null,

    /// Scratch buffer for DA1 feature codes. The device attributes
    /// trampoline converts C feature codes into this buffer and returns
    /// a slice pointing into it. Storing it here ensures the slice
    /// remains valid after the trampoline returns, since the caller
    /// (`reportDeviceAttributes`) reads it before any re-entrant call.
    da_features_buf: [64]device_attributes.Primary.Feature = undefined,

    /// C function pointer type for the write_pty callback.
    pub const WritePtyFn = *const fn (Terminal, ?*anyopaque, [*]const u8, usize) callconv(lib.calling_conv) void;

    /// C function pointer type for the bell callback.
    pub const BellFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;

    /// C function pointer type for the color_scheme callback.
    /// Returns true and fills out_scheme if a color scheme is available,
    /// or returns false to silently ignore the query.
    pub const ColorSchemeFn = *const fn (Terminal, ?*anyopaque, *device_status.ColorScheme) callconv(lib.calling_conv) bool;

    /// C function pointer type for the enquiry callback.
    /// Returns the response bytes. The memory must remain valid
    /// until the callback returns.
    pub const EnquiryFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;

    /// C function pointer type for the xtversion callback.
    /// Returns the version string (e.g. "ghostty 1.2.3"). The memory
    /// must remain valid until the callback returns. An empty string
    /// (len=0) causes the default "libghostty" to be reported.
    pub const XtversionFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) lib.String;

    /// C function pointer type for the title_changed callback.
    pub const TitleChangedFn = *const fn (Terminal, ?*anyopaque) callconv(lib.calling_conv) void;

    /// C function pointer type for the size callback.
    /// Returns true and fills out_size if size is available,
    /// or returns false to silently ignore the query.
    pub const SizeFn = *const fn (Terminal, ?*anyopaque, *size_report.Size) callconv(lib.calling_conv) bool;

    /// C function pointer type for the device_attributes callback.
    /// Returns true and fills out_attrs if attributes are available,
    /// or returns false to silently ignore the query.
    pub const DeviceAttributesFn = *const fn (Terminal, ?*anyopaque, *CDeviceAttributes) callconv(lib.calling_conv) bool;

    /// C-compatible device attributes struct.
    /// C: GhosttyDeviceAttributes
    pub const CDeviceAttributes = extern struct {
        primary: Primary,
        secondary: Secondary,
        tertiary: Tertiary,

        pub const Primary = extern struct {
            conformance_level: u16,
            features: [64]u16,
            num_features: usize,
        };

        pub const Secondary = extern struct {
            device_type: u16,
            firmware_version: u16,
            rom_cartridge: u16,
        };

        pub const Tertiary = extern struct {
            unit_id: u32,
        };
    };

    fn writePtyTrampoline(handler: *Handler, data: [:0]const u8) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.write_pty orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata, data.ptr, data.len);
    }

    fn bellTrampoline(handler: *Handler) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.bell orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn colorSchemeTrampoline(handler: *Handler) ?device_status.ColorScheme {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.color_scheme orelse return null;
        var scheme: device_status.ColorScheme = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &scheme)) return scheme;
        return null;
    }

    fn deviceAttributesTrampoline(handler: *Handler) device_attributes.Attributes {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.device_attributes_cb orelse return .{};

        // Get our attributes from the callback.
        var c_attrs: CDeviceAttributes = undefined;
        if (!func(@ptrCast(wrapper), wrapper.effects.userdata, &c_attrs)) return .{};

        // Note below we use a lot of enumFromInt but its always safe
        // because all our types are non-exhaustive enums.

        const n: usize = @min(c_attrs.primary.num_features, 64);
        for (0..n) |i| wrapper.effects.da_features_buf[i] = @enumFromInt(c_attrs.primary.features[i]);

        return .{
            .primary = .{
                .conformance_level = @enumFromInt(c_attrs.primary.conformance_level),
                .features = wrapper.effects.da_features_buf[0..n],
            },
            .secondary = .{
                .device_type = @enumFromInt(c_attrs.secondary.device_type),
                .firmware_version = c_attrs.secondary.firmware_version,
                .rom_cartridge = c_attrs.secondary.rom_cartridge,
            },
            .tertiary = .{
                .unit_id = c_attrs.tertiary.unit_id,
            },
        };
    }

    fn enquiryTrampoline(handler: *Handler) []const u8 {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.enquiry orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn xtversionTrampoline(handler: *Handler) []const u8 {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.xtversion orelse return "";
        const result = func(@ptrCast(wrapper), wrapper.effects.userdata);
        if (result.len == 0) return "";
        return result.ptr[0..result.len];
    }

    fn titleChangedTrampoline(handler: *Handler) void {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.title_changed orelse return;
        func(@ptrCast(wrapper), wrapper.effects.userdata);
    }

    fn sizeTrampoline(handler: *Handler) ?size_report.Size {
        const stream_ptr: *Stream = @fieldParentPtr("handler", handler);
        const wrapper: *TerminalWrapper = @fieldParentPtr("stream", stream_ptr);
        const func = wrapper.effects.size_cb orelse return null;
        var s: size_report.Size = undefined;
        if (func(@ptrCast(wrapper), wrapper.effects.userdata, &s)) return s;
        return null;
    }
};

/// C: GhosttyTerminal
pub const Terminal = ?*TerminalWrapper;

/// C: GhosttyTerminalOptions
pub const Options = extern struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
};

const NewError = error{
    InvalidValue,
    OutOfMemory,
};

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Terminal,
    opts: Options,
) callconv(lib.calling_conv) Result {
    result.* = new_(alloc_, opts) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn new_(
    alloc_: ?*const CAllocator,
    opts: Options,
) NewError!*TerminalWrapper {
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;

    const alloc = lib.alloc.default(alloc_);
    const t = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(t);

    const wrapper = alloc.create(TerminalWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(wrapper);

    // Setup our terminal
    t.* = try .init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer t.deinit(alloc);

    // Setup our stream with trampolines always installed so that
    // setting C callbacks at any time takes effect immediately.
    var handler: Stream.Handler = t.vtHandler();
    handler.effects = .{
        .write_pty = &Effects.writePtyTrampoline,
        .bell = &Effects.bellTrampoline,
        .color_scheme = &Effects.colorSchemeTrampoline,
        .device_attributes = &Effects.deviceAttributesTrampoline,
        .enquiry = &Effects.enquiryTrampoline,
        .kitty_clipboard = null,
        .xtversion = &Effects.xtversionTrampoline,
        .title_changed = &Effects.titleChangedTrampoline,
        .size = &Effects.sizeTrampoline,
    };

    wrapper.* = .{
        .terminal = t,
        .stream = .initAlloc(alloc, handler),
    };

    return wrapper;
}

pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    wrapper.stream.nextSlice(ptr[0..len]);
}

/// C: GhosttyTerminalOption
pub const Option = enum(c_int) {
    userdata = 0,
    write_pty = 1,
    bell = 2,
    enquiry = 3,
    xtversion = 4,
    title_changed = 5,
    size_cb = 6,
    color_scheme = 7,
    device_attributes = 8,
    title = 9,
    pwd = 10,
    color_foreground = 11,
    color_background = 12,
    color_cursor = 13,
    color_palette = 14,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .userdata => ?*const anyopaque,
            .write_pty => ?Effects.WritePtyFn,
            .bell => ?Effects.BellFn,
            .color_scheme => ?Effects.ColorSchemeFn,
            .device_attributes => ?Effects.DeviceAttributesFn,
            .enquiry => ?Effects.EnquiryFn,
            .xtversion => ?Effects.XtversionFn,
            .title_changed => ?Effects.TitleChangedFn,
            .size_cb => ?Effects.SizeFn,
            .title, .pwd => ?*const lib.String,
            .color_foreground, .color_background, .color_cursor => ?*const color.RGB.C,
            .color_palette => ?*const color.PaletteC,
        };
    }
};

pub fn set(
    terminal_: Terminal,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Option, @intFromEnum(option)) catch {
            log.warn("terminal_set invalid option value={d}", .{@intFromEnum(option)});
            return .invalid_value;
        };
    }

    const wrapper = terminal_ orelse return .invalid_value;

    return switch (option) {
        inline else => |comptime_option| setTyped(
            wrapper,
            comptime_option,
            @ptrCast(@alignCast(value)),
        ),
    };
}

fn setTyped(
    wrapper: *TerminalWrapper,
    comptime option: Option,
    value: option.InType(),
) Result {
    switch (option) {
        .userdata => wrapper.effects.userdata = @constCast(value),
        .write_pty => wrapper.effects.write_pty = value,
        .bell => wrapper.effects.bell = value,
        .color_scheme => wrapper.effects.color_scheme = value,
        .device_attributes => wrapper.effects.device_attributes_cb = value,
        .enquiry => wrapper.effects.enquiry = value,
        .xtversion => wrapper.effects.xtversion = value,
        .title_changed => wrapper.effects.title_changed = value,
        .size_cb => wrapper.effects.size_cb = value,
        .title => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setTitle(str) catch return .out_of_memory;
        },
        .pwd => {
            const str = if (value) |v| v.ptr[0..v.len] else "";
            wrapper.terminal.setPwd(str) catch return .out_of_memory;
        },
        .color_foreground => {
            wrapper.terminal.colors.foreground.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_background => {
            wrapper.terminal.colors.background.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_cursor => {
            wrapper.terminal.colors.cursor.default = if (value) |v| .fromC(v.*) else null;
            wrapper.terminal.flags.dirty.palette = true;
        },
        .color_palette => {
            wrapper.terminal.colors.palette.changeDefault(
                if (value) |v| color.paletteZval(v) else color.default,
            );
            wrapper.terminal.flags.dirty.palette = true;
        },
    }
    return .success;
}

/// C: GhosttyTerminalScrollViewport
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;

pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(lib.calling_conv) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.scrollViewport(switch (behavior.tag) {
        .top => .top,
        .bottom => .bottom,
        .delta => .{ .delta = behavior.value.delta },
    });
}

pub fn resize(
    terminal_: Terminal,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    cell_width_px: u32,
    cell_height_px: u32,
) callconv(lib.calling_conv) Result {
    const wrapper = terminal_ orelse return .invalid_value;
    const t = wrapper.terminal;
    if (cols == 0 or rows == 0) return .invalid_value;
    t.resize(t.gpa(), cols, rows) catch return .out_of_memory;

    // Update pixel sizes
    t.width_px = std.math.mul(u32, cols, cell_width_px) catch std.math.maxInt(u32);
    t.height_px = std.math.mul(u32, rows, cell_height_px) catch std.math.maxInt(u32);

    // Disable synchronized output mode so that we show changes
    // immediately for a resize. This is allowed by the spec.
    t.modes.set(.synchronized_output, false);

    // If we have in-band size reporting enabled, send a report.
    if (t.modes.get(.in_band_size_reports)) in_band: {
        const func = wrapper.effects.write_pty orelse break :in_band;

        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        size_report.encode(&writer, .mode_2048, .{
            .rows = rows,
            .columns = cols,
            .cell_width = cell_width_px,
            .cell_height = cell_height_px,
        }) catch break :in_band;

        const data = writer.buffered();
        func(@ptrCast(wrapper), wrapper.effects.userdata, data.ptr, data.len);
    }

    return .success;
}

pub fn reset(terminal_: Terminal) callconv(lib.calling_conv) void {
    const t: *ZigTerminal = (terminal_ orelse return).terminal;
    t.fullReset();
}

pub fn mode_get(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    out_value: *bool,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    out_value.* = t.modes.get(mode);
    return .success;
}

pub fn mode_set(
    terminal_: Terminal,
    tag: modes.ModeTag.Backing,
    value: bool,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const mode_tag: modes.ModeTag = @bitCast(tag);
    const mode = modes.modeFromInt(mode_tag.value, mode_tag.ansi) orelse return .invalid_value;
    t.modes.set(mode, value);
    return .success;
}

/// C: GhosttyTerminalScreen
pub const TerminalScreen = ScreenSet.Key;

/// C: GhosttyTerminalScrollbar
pub const TerminalScrollbar = PageList.Scrollbar.C;

/// C: GhosttyTerminalData
pub const TerminalData = enum(c_int) {
    invalid = 0,
    cols = 1,
    rows = 2,
    cursor_x = 3,
    cursor_y = 4,
    cursor_pending_wrap = 5,
    active_screen = 6,
    cursor_visible = 7,
    kitty_keyboard_flags = 8,
    scrollbar = 9,
    cursor_style = 10,
    mouse_tracking = 11,
    title = 12,
    pwd = 13,
    total_rows = 14,
    scrollback_rows = 15,
    width_px = 16,
    height_px = 17,
    color_foreground = 18,
    color_background = 19,
    color_cursor = 20,
    color_palette = 21,
    color_foreground_default = 22,
    color_background_default = 23,
    color_cursor_default = 24,
    color_palette_default = 25,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: TerminalData) type {
        return switch (self) {
            .invalid => void,
            .cols, .rows, .cursor_x, .cursor_y => size.CellCountInt,
            .cursor_pending_wrap, .cursor_visible, .mouse_tracking => bool,
            .active_screen => TerminalScreen,
            .kitty_keyboard_flags => u8,
            .scrollbar => TerminalScrollbar,
            .cursor_style => style_c.Style,
            .title, .pwd => lib.String,
            .total_rows, .scrollback_rows => usize,
            .width_px, .height_px => u32,
            .color_foreground,
            .color_background,
            .color_cursor,
            .color_foreground_default,
            .color_background_default,
            .color_cursor_default,
            => color.RGB.C,
            .color_palette, .color_palette_default => color.PaletteC,
        };
    }
};

pub fn get(
    terminal_: Terminal,
    data: TerminalData,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(TerminalData, @intFromEnum(data)) catch {
            log.warn("terminal_get invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    return switch (data) {
        .invalid => .invalid_value,
        inline else => |comptime_data| getTyped(
            terminal_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    terminal_: Terminal,
    comptime data: TerminalData,
    out: *data.OutType(),
) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    switch (data) {
        .invalid => return .invalid_value,
        .cols => out.* = t.cols,
        .rows => out.* = t.rows,
        .cursor_x => out.* = t.screens.active.cursor.x,
        .cursor_y => out.* = t.screens.active.cursor.y,
        .cursor_pending_wrap => out.* = t.screens.active.cursor.pending_wrap,
        .active_screen => out.* = t.screens.active_key,
        .cursor_visible => out.* = t.modes.get(.cursor_visible),
        .kitty_keyboard_flags => out.* = @as(u8, t.screens.active.kitty_keyboard.current().int()),
        .scrollbar => out.* = t.screens.active.pages.scrollbar().cval(),
        .cursor_style => out.* = .fromStyle(t.screens.active.cursor.style),
        .mouse_tracking => out.* = t.modes.get(.mouse_event_x10) or
            t.modes.get(.mouse_event_normal) or
            t.modes.get(.mouse_event_button) or
            t.modes.get(.mouse_event_any),
        .title => {
            const title = t.getTitle() orelse "";
            out.* = .{ .ptr = title.ptr, .len = title.len };
        },
        .pwd => {
            const pwd = t.getPwd() orelse "";
            out.* = .{ .ptr = pwd.ptr, .len = pwd.len };
        },
        .total_rows => out.* = t.screens.active.pages.total_rows,
        .scrollback_rows => out.* = t.screens.active.pages.total_rows - t.rows,
        .width_px => out.* = t.width_px,
        .height_px => out.* = t.height_px,
        .color_foreground => out.* = (t.colors.foreground.get() orelse return .no_value).cval(),
        .color_background => out.* = (t.colors.background.get() orelse return .no_value).cval(),
        .color_cursor => out.* = (t.colors.cursor.get() orelse return .no_value).cval(),
        .color_foreground_default => out.* = (t.colors.foreground.default orelse return .no_value).cval(),
        .color_background_default => out.* = (t.colors.background.default orelse return .no_value).cval(),
        .color_cursor_default => out.* = (t.colors.cursor.default orelse return .no_value).cval(),
        .color_palette => out.* = color.paletteCval(&t.colors.palette.current),
        .color_palette_default => out.* = color.paletteCval(&t.colors.palette.original),
    }

    return .success;
}

pub fn grid_ref(
    terminal_: Terminal,
    pt: point.Point.C,
    out_ref: ?*grid_ref_c.CGridRef,
) callconv(lib.calling_conv) Result {
    const t: *ZigTerminal = (terminal_ orelse return .invalid_value).terminal;
    const zig_pt: point.Point = switch (pt.tag) {
        .active => .{ .active = pt.value.active },
        .viewport => .{ .viewport = pt.value.viewport },
        .screen => .{ .screen = pt.value.screen },
        .history => .{ .history = pt.value.history },
    };
    const p = t.screens.active.pages.pin(zig_pt) orelse
        return .invalid_value;
    if (out_ref) |out| out.* = grid_ref_c.CGridRef.fromPin(p);
    return .success;
}

pub fn free(terminal_: Terminal) callconv(lib.calling_conv) void {
    const wrapper = terminal_ orelse return;
    const t = wrapper.terminal;

    wrapper.stream.deinit();
    const alloc = t.gpa();
    t.deinit(alloc);
    alloc.destroy(t);
    alloc.destroy(wrapper);
}

test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));

    try testing.expect(t != null);
    free(t);
}

test "new invalid value" {
    var t: Terminal = null;

    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 0,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);

    try testing.expectEqual(Result.invalid_value, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 0,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);
}

test "free null" {
    free(null);
}

test "scroll_viewport" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 5,
            .rows = 2,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Write "hello" on the first line
    vt_write(t, "hello", 5);

    // Push "hello" into scrollback with 3 newlines (index = ESC D)
    vt_write(t, "\x1bD\x1bD\x1bD", 6);
    {
        // Viewport should be empty now since hello scrolled off
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll to top: "hello" should be visible again
    scroll_viewport(t, .{ .tag = .top, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }

    // Scroll to bottom: viewport should be empty again
    scroll_viewport(t, .{ .tag = .bottom, .value = undefined });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("", str);
    }

    // Scroll up by delta to bring "hello" back into view
    scroll_viewport(t, .{ .tag = .delta, .value = .{ .delta = -3 } });
    {
        const str = try zt.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("hello", str);
    }
}

test "scroll_viewport null" {
    scroll_viewport(null, .{ .tag = .top, .value = undefined });
}

test "reset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);
    reset(t);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}

test "reset null" {
    reset(null);
}

test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 40, 12, 9, 18));
    try testing.expectEqual(40, t.?.terminal.cols);
    try testing.expectEqual(12, t.?.terminal.rows);
}

test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24, 9, 18));
}

test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24, 9, 18));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0, 9, 18));
}

test "mode_get and mode_set" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;

    // DEC mode 25 (cursor_visible) defaults to true
    const cursor_visible: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(value);

    // Set it to false
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible, false));
    try testing.expectEqual(Result.success, mode_get(t, cursor_visible, &value));
    try testing.expect(!value);

    // ANSI mode 4 (insert) defaults to false
    const insert: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 4, .ansi = true });
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(!value);

    try testing.expectEqual(Result.success, mode_set(t, insert, true));
    try testing.expectEqual(Result.success, mode_get(t, insert, &value));
    try testing.expect(value);
}

test "mode_get null" {
    var value: bool = undefined;
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(null, tag, &value));
}

test "mode_set null" {
    const tag: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(null, tag, true));
}

test "mode_get unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var value: bool = undefined;
    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_get(t, unknown, &value));
}

test "mode_set unknown mode" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const unknown: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9999, .ansi = false });
    try testing.expectEqual(Result.invalid_value, mode_set(t, unknown, true));
}

test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "vt_write split escape sequence" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    // Write "Hello" in bold by splitting the CSI bold sequence across two writes.
    // ESC [ 1 m  = bold on, ESC [ 0 m = reset
    // Split ESC from the rest of the CSI sequence.
    vt_write(t, "Hello \x1b", 7);
    vt_write(t, "[1mBold\x1b[0m", 10);

    const str = try t.?.terminal.plainString(testing.allocator);
    defer testing.allocator.free(str);
    // If the escape sequence leaked, we'd see "[1mBold" as literal text.
    try testing.expectEqualStrings("Hello Bold", str);
}

test "get cols and rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var cols: size.CellCountInt = undefined;
    var rows: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cols, @ptrCast(&cols)));
    try testing.expectEqual(Result.success, get(t, .rows, @ptrCast(&rows)));
    try testing.expectEqual(80, cols);
    try testing.expectEqual(24, rows);
}

test "get cursor position" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var x: size.CellCountInt = undefined;
    var y: size.CellCountInt = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_x, @ptrCast(&x)));
    try testing.expectEqual(Result.success, get(t, .cursor_y, @ptrCast(&y)));
    try testing.expectEqual(5, x);
    try testing.expectEqual(0, y);
}

test "get null" {
    var cols: size.CellCountInt = undefined;
    try testing.expectEqual(Result.invalid_value, get(null, .cols, @ptrCast(&cols)));
}

test "get cursor_visible" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var visible: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(visible);

    // DEC mode 25 controls cursor visibility
    const cursor_visible_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 25, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, cursor_visible_mode, false));
    try testing.expectEqual(Result.success, get(t, .cursor_visible, @ptrCast(&visible)));
    try testing.expect(!visible);
}

test "get active_screen" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var screen: TerminalScreen = undefined;
    try testing.expectEqual(Result.success, get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(.primary, screen);
}

test "get kitty_keyboard_flags" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var flags: u8 = undefined;
    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(0, flags);

    // Push kitty flags via VT sequence: CSI > 3 u (push disambiguate | report_events)
    vt_write(t, "\x1b[>3u", 5);

    try testing.expectEqual(Result.success, get(t, .kitty_keyboard_flags, @ptrCast(&flags)));
    try testing.expectEqual(3, flags);
}

test "get mouse_tracking" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var tracking: bool = undefined;
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);

    // Enable X10 mouse (DEC mode 9)
    const x10_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 9, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable X10, enable normal mouse (DEC mode 1000)
    try testing.expectEqual(Result.success, mode_set(t, x10_mode, false));
    const normal_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1000, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable normal, enable button mouse (DEC mode 1002)
    try testing.expectEqual(Result.success, mode_set(t, normal_mode, false));
    const button_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1002, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, button_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable button, enable any mouse (DEC mode 1003)
    try testing.expectEqual(Result.success, mode_set(t, button_mode, false));
    const any_mode: modes.ModeTag.Backing = @bitCast(modes.ModeTag{ .value = 1003, .ansi = false });
    try testing.expectEqual(Result.success, mode_set(t, any_mode, true));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(tracking);

    // Disable all - should be false again
    try testing.expectEqual(Result.success, mode_set(t, any_mode, false));
    try testing.expectEqual(Result.success, get(t, .mouse_tracking, @ptrCast(&tracking)));
    try testing.expect(!tracking);
}

test "get total_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    var total: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .total_rows, @ptrCast(&total)));
    try testing.expect(total >= 24);
}

test "get scrollback_rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 3,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    var scrollback: usize = undefined;
    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 0), scrollback);

    // Write enough lines to push content into scrollback
    vt_write(t, "line1\r\nline2\r\nline3\r\nline4\r\nline5\r\n", 34);

    try testing.expectEqual(Result.success, get(t, .scrollback_rows, @ptrCast(&scrollback)));
    try testing.expectEqual(@as(usize, 2), scrollback);
}

test "get invalid" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, get(t, .invalid, null));
}

test "grid_ref" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.success, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));

    // Extract cell from grid ref and verify it contains 'H'
    var out_cell: cell_c.CCell = undefined;
    try testing.expectEqual(Result.success, grid_ref_c.grid_ref_cell(&out_ref, &out_cell));

    var cp: u32 = 0;
    try testing.expectEqual(Result.success, cell_c.get(out_cell, .codepoint, @ptrCast(&cp)));
    try testing.expectEqual(@as(u32, 'H'), cp);
}

test "grid_ref null terminal" {
    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(null, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &out_ref));
}

test "set write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;
        var last_userdata: ?*anyopaque = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
            last_userdata = null;
        }

        fn writePty(_: Terminal, ud: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
            last_userdata = ud;
        }
    };
    defer S.deinit();

    // Set userdata and write_pty callback
    var sentinel: u8 = 42;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // DECRQM for wraparound mode (mode 7, set by default) should trigger write_pty
    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[?7;1$y", S.last_data.?);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);
}

test "set write_pty without callback ignores queries" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Without setting a callback, DECRQM should be silently ignored (no crash)
    vt_write(t, "\x1B[?7$p", 6);
}

test "set write_pty null clears callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;

    // Set then clear the callback
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .write_pty, null));

    vt_write(t, "\x1B[?7$p", 6);
    try testing.expect(!S.called);
}

test "set bell callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var bell_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn bell(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            bell_count += 1;
            last_userdata = ud;
        }
    };
    S.bell_count = 0;
    S.last_userdata = null;

    // Set userdata and bell callback
    var sentinel: u8 = 99;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .bell, @ptrCast(&S.bell)));

    // Single BEL
    vt_write(t, "\x07", 1);
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Multiple BELs
    vt_write(t, "\x07\x07", 2);
    try testing.expectEqual(@as(usize, 3), S.bell_count);
}

test "bell without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // BEL without a callback should not crash
    vt_write(t, "\x07", 1);
}

test "set enquiry callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const response = "OK";
        fn enquiry(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = response, .len = response.len };
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .enquiry, @ptrCast(&S.enquiry)));

    // ENQ (0x05) should trigger the enquiry callback and write response via write_pty
    vt_write(t, "\x05", 1);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("OK", S.last_data.?);
}

test "enquiry without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // ENQ without a callback should not crash
    vt_write(t, "\x05", 1);
}

test "set xtversion callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        const version = "myterm 1.0";
        fn xtversion(_: Terminal, _: ?*anyopaque) callconv(lib.calling_conv) lib.String {
            return .{ .ptr = version, .len = version.len };
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .xtversion, @ptrCast(&S.xtversion)));

    // XTVERSION: CSI > q
    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    // Response should be DCS >| version ST
    try testing.expectEqualStrings("\x1BP>|myterm 1.0\x1B\\", S.last_data.?);
}

test "xtversion without callback reports default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    // Set write_pty but not xtversion — should get default "libghostty"
    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    vt_write(t, "\x1B[>q", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1BP>|libghostty\x1B\\", S.last_data.?);
}

test "set title_changed callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var title_count: usize = 0;
        var last_userdata: ?*anyopaque = null;

        fn titleChanged(_: Terminal, ud: ?*anyopaque) callconv(lib.calling_conv) void {
            title_count += 1;
            last_userdata = ud;
        }
    };
    S.title_count = 0;
    S.last_userdata = null;

    var sentinel: u8 = 77;
    try testing.expectEqual(Result.success, set(t, .userdata, @ptrCast(&sentinel)));
    try testing.expectEqual(Result.success, set(t, .title_changed, @ptrCast(&S.titleChanged)));

    // OSC 2 ; title ST — set window title
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&sentinel)), S.last_userdata);

    // Another title change
    vt_write(t, "\x1B]2;World\x1B\\", 10);
    try testing.expectEqual(@as(usize, 2), S.title_count);
}

test "title_changed without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // OSC 2 without a callback should not crash
    vt_write(t, "\x1B]2;Hello\x1B\\", 10);
}

test "set size callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn sizeCb(_: Terminal, _: ?*anyopaque, out_size: *size_report.Size) callconv(lib.calling_conv) bool {
            out_size.* = .{
                .rows = 24,
                .columns = 80,
                .cell_width = 8,
                .cell_height = 16,
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .size_cb, @ptrCast(&S.sizeCb)));

    // CSI 18 t — report text area size in characters
    vt_write(t, "\x1B[18t", 5);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.last_data.?);
}

test "size without callback is silent" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // CSI 18 t without a size callback should not crash
    vt_write(t, "\x1B[18t", 5);
}

test "set device_attributes callback primary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 64,
                    .features = .{ 22, 52 } ++ .{0} ** 62,
                    .num_features = 2,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI c — primary DA
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.last_data.?);
}

test "set device_attributes callback secondary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{22} ++ .{0} ** 63,
                    .num_features = 1,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 10,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0 },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI > c — secondary DA
    vt_write(t, "\x1B[>c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[>1;10;0c", S.last_data.?);
}

test "set device_attributes callback tertiary" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, out: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            out.* = .{
                .primary = .{
                    .conformance_level = 62,
                    .features = .{0} ** 64,
                    .num_features = 0,
                },
                .secondary = .{
                    .device_type = 1,
                    .firmware_version = 0,
                    .rom_cartridge = 0,
                },
                .tertiary = .{ .unit_id = 0xAABBCCDD },
            };
            return true;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // CSI = c — tertiary DA
    vt_write(t, "\x1B[=c", 4);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1bP!|AABBCCDD\x1b\\", S.last_data.?);
}

test "device_attributes without callback uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // Without setting a device_attributes callback, DA1 should return the default
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}

test "device_attributes callback returns false uses default" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }

        fn da(_: Terminal, _: ?*anyopaque, _: *Effects.CDeviceAttributes) callconv(lib.calling_conv) bool {
            return false;
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));
    try testing.expectEqual(Result.success, set(t, .device_attributes, @ptrCast(&S.da)));

    // Callback returns false, should use default response
    vt_write(t, "\x1B[c", 3);
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1b[?62;22c", S.last_data.?);
}

test "set and get title" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // No title set yet — should return empty string
    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);

    // Set title via option
    const hello: lib.String = .{ .ptr = "Hello", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&hello)));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("Hello", title.ptr[0..title.len]);

    // Overwrite title
    const world: lib.String = .{ .ptr = "World", .len = 5 };
    try testing.expectEqual(Result.success, set(t, .title, @ptrCast(&world)));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("World", title.ptr[0..title.len]);

    // Clear title with NULL
    try testing.expectEqual(Result.success, set(t, .title, null));

    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqual(@as(usize, 0), title.len);
}

test "set and get pwd" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // No pwd set yet — should return empty string
    var pwd: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);

    // Set pwd via option
    const home: lib.String = .{ .ptr = "/home/user", .len = 10 };
    try testing.expectEqual(Result.success, set(t, .pwd, @ptrCast(&home)));

    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqualStrings("/home/user", pwd.ptr[0..pwd.len]);

    // Clear pwd with NULL
    try testing.expectEqual(Result.success, set(t, .pwd, null));

    try testing.expectEqual(Result.success, get(t, .pwd, @ptrCast(&pwd)));
    try testing.expectEqual(@as(usize, 0), pwd.len);
}

test "get title set via vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Set title via OSC 2
    vt_write(t, "\x1B]2;VT Title\x1B\\", 14);

    var title: lib.String = undefined;
    try testing.expectEqual(Result.success, get(t, .title, @ptrCast(&title)));
    try testing.expectEqualStrings("VT Title", title.ptr[0..title.len]);
}

test "resize updates pixel dimensions" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));

    const zt = t.?.terminal;
    try testing.expectEqual(@as(u32, 100 * 9), zt.width_px);
    try testing.expectEqual(@as(u32, 40 * 18), zt.height_px);
}

test "resize pixel overflow saturates" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 100, 40, std.math.maxInt(u32), std.math.maxInt(u32)));

    const zt = t.?.terminal;
    try testing.expectEqual(std.math.maxInt(u32), zt.width_px);
    try testing.expectEqual(std.math.maxInt(u32), zt.height_px);
}

test "resize disables synchronized output" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;
    zt.modes.set(.synchronized_output, true);

    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
    try testing.expect(!zt.modes.get(.synchronized_output));
}

test "resize sends in-band size report" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var last_data: ?[]u8 = null;

        fn deinit() void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = null;
        }

        fn writePty(_: Terminal, _: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(lib.calling_conv) void {
            if (last_data) |d| testing.allocator.free(d);
            last_data = testing.allocator.dupe(u8, ptr[0..len]) catch @panic("OOM");
        }
    };
    defer S.deinit();

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // Enable in-band size reports (mode 2048)
    t.?.terminal.modes.set(.in_band_size_reports, true);

    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));

    // Expected: \x1B[48;rows;cols;height_px;width_pxt
    // height_px = 40*18 = 720, width_px = 100*9 = 900
    try testing.expect(S.last_data != null);
    try testing.expectEqualStrings("\x1B[48;40;100;720;900t", S.last_data.?);
}

test "resize no size report without mode 2048" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const S = struct {
        var called: bool = false;
        fn writePty(_: Terminal, _: ?*anyopaque, _: [*]const u8, _: usize) callconv(lib.calling_conv) void {
            called = true;
        }
    };
    S.called = false;

    try testing.expectEqual(Result.success, set(t, .write_pty, @ptrCast(&S.writePty)));

    // in_band_size_reports is off by default
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
    try testing.expect(!S.called);
}

test "resize in-band report without write_pty callback" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Enable mode 2048 but don't set a write_pty callback — should not crash
    t.?.terminal.modes.set(.in_band_size_reports, true);
    try testing.expectEqual(Result.success, resize(t, 100, 40, 9, 18));
}

test "resize null terminal" {
    try testing.expectEqual(Result.invalid_value, resize(null, 100, 40, 9, 18));
}

test "resize zero cols" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 40, 9, 18));
}

test "resize zero rows" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 100, 0, 9, 18));
}

test "grid_ref out of bounds" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var out_ref: grid_ref_c.CGridRef = .{};
    try testing.expectEqual(Result.invalid_value, grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 100, .y = 0 } },
    }, &out_ref));
}

test "set and get color_foreground" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Initially unset
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));

    // Set a value
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);

    // Clear with null
    try testing.expectEqual(Result.success, set(t, .color_foreground, null));
    try testing.expectEqual(Result.no_value, get(t, .color_foreground, @ptrCast(&rgb)));
}

test "set and get color_background" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));

    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);

    try testing.expectEqual(Result.success, set(t, .color_background, null));
    try testing.expectEqual(Result.no_value, get(t, .color_background, @ptrCast(&rgb)));
}

test "set and get color_cursor" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));

    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);

    try testing.expectEqual(Result.success, set(t, .color_cursor, null));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor, @ptrCast(&rgb)));
}

test "set and get color_palette" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    // Get default palette
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);

    // Set custom palette
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);

    // Reset with null restores default
    try testing.expectEqual(Result.success, set(t, .color_palette, null));
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.default[0].cval(), palette[0]);
}

test "get color default vs effective with override" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;
    var rgb: color.RGB.C = undefined;

    // Set defaults
    const fg: color.RGB.C = .{ .r = 0xAA, .g = 0xBB, .b = 0xCC };
    const bg: color.RGB.C = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    const cur: color.RGB.C = .{ .r = 0xFF, .g = 0x00, .b = 0x88 };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expectEqual(Result.success, set(t, .color_background, @ptrCast(&bg)));
    try testing.expectEqual(Result.success, set(t, .color_cursor, @ptrCast(&cur)));

    // Simulate OSC overrides
    const override: color.RGB = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
    zt.colors.foreground.override = override;
    zt.colors.background.override = override;
    zt.colors.cursor.override = override;

    // Effective returns override
    try testing.expectEqual(Result.success, get(t, .color_foreground, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_background, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor, @ptrCast(&rgb)));
    try testing.expectEqual(override.cval(), rgb);

    // Default returns original
    try testing.expectEqual(Result.success, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(fg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(bg, rgb);
    try testing.expectEqual(Result.success, get(t, .color_cursor_default, @ptrCast(&rgb)));
    try testing.expectEqual(cur, rgb);
}

test "get color default returns no_value when unset" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(Result.no_value, get(t, .color_foreground_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_background_default, @ptrCast(&rgb)));
    try testing.expectEqual(Result.no_value, get(t, .color_cursor_default, @ptrCast(&rgb)));
}

test "get color_palette_default vs current" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;

    // Set a custom default palette
    var custom: color.PaletteC = color.paletteCval(&color.default);
    custom[0] = .{ .r = 0x12, .g = 0x34, .b = 0x56 };
    try testing.expectEqual(Result.success, set(t, .color_palette, @ptrCast(&custom)));

    // Simulate OSC override on index 0
    zt.colors.palette.set(0, .{ .r = 0xFF, .g = 0xFF, .b = 0xFF });

    // Current palette returns the override
    var palette: color.PaletteC = undefined;
    try testing.expectEqual(Result.success, get(t, .color_palette, @ptrCast(&palette)));
    try testing.expectEqual(color.RGB.C{ .r = 0xFF, .g = 0xFF, .b = 0xFF }, palette[0]);

    // Default palette returns the original
    try testing.expectEqual(Result.success, get(t, .color_palette_default, @ptrCast(&palette)));
    try testing.expectEqual(custom[0], palette[0]);
}

test "set color sets dirty flag" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 0,
        },
    ));
    defer free(t);

    const zt = t.?.terminal;
    zt.flags.dirty.palette = false;

    const fg: color.RGB.C = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    try testing.expectEqual(Result.success, set(t, .color_foreground, @ptrCast(&fg)));
    try testing.expect(zt.flags.dirty.palette);
}
