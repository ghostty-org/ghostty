const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const terminal_c = @import("terminal.zig");
const grid_ref = @import("grid_ref.zig");
const selection_c = @import("selection.zig");
const ZigTerminal = @import("../Terminal.zig");
const formatterpkg = @import("../formatter.zig");
const Result = @import("result.zig").Result;

/// Wrapper around formatter that tracks the allocator for C API usage.
const FormatterWrapper = struct {
    kind: Kind,
    alloc: std.mem.Allocator,

    const Kind = union(enum) {
        terminal: formatterpkg.TerminalFormatter,
    };
};

/// C: GhosttyFormatter
pub const Formatter = ?*FormatterWrapper;

/// C: GhosttyFormatterFormat
pub const Format = formatterpkg.Format;

const CSelection = selection_c.CSelection;

/// C: GhosttyFormatterScreenOptions
pub const ScreenOptions = extern struct {
    /// C: GhosttyFormatterScreenExtra
    pub const Extra = extern struct {
        size: usize = @sizeOf(Extra),
        cursor: bool,
        style: bool,
        hyperlink: bool,
        protection: bool,
        kitty_keyboard: bool,
        kitty_graphics: bool,
        charsets: bool,

        comptime {
            for (std.meta.fieldNames(formatterpkg.ScreenFormatter.Extra)) |name| {
                if (!@hasField(Extra, name))
                    @compileError("ScreenOptions.Extra missing field: " ++ name);
            }
        }

        fn toZig(self: Extra) formatterpkg.ScreenFormatter.Extra {
            return .{
                .cursor = self.cursor,
                .style = self.style,
                .hyperlink = self.hyperlink,
                .protection = self.protection,
                .kitty_keyboard = self.kitty_keyboard,
                .kitty_graphics = self.kitty_graphics,
                .charsets = self.charsets,
            };
        }
    };
};

/// C: GhosttyFormatterTerminalOptions
pub const TerminalOptions = extern struct {
    size: usize = @sizeOf(TerminalOptions),
    emit: Format,
    unwrap: bool,
    trim: bool,
    extra: Extra,

    /// Optional selection to restrict output to a range.
    /// If null, the entire screen is formatted.
    selection: ?*const CSelection = null,

    /// C: GhosttyFormatterTerminalExtra
    pub const Extra = extern struct {
        size: usize = @sizeOf(Extra),
        palette: bool,
        modes: bool,
        scrolling_region: bool,
        tabstops: bool,
        pwd: bool,
        keyboard: bool,
        screen: ScreenOptions.Extra,

        comptime {
            for (std.meta.fieldNames(formatterpkg.TerminalFormatter.Extra)) |name| {
                if (!@hasField(Extra, name))
                    @compileError("TerminalOptions.Extra missing field: " ++ name);
            }
        }

        fn toZig(self: Extra) formatterpkg.TerminalFormatter.Extra {
            return .{
                .palette = self.palette,
                .modes = self.modes,
                .scrolling_region = self.scrolling_region,
                .tabstops = self.tabstops,
                .pwd = self.pwd,
                .keyboard = self.keyboard,
                .screen = self.screen.toZig(),
            };
        }
    };
};

pub fn terminal_new(
    alloc_: ?*const CAllocator,
    result: *Formatter,
    terminal_: terminal_c.Terminal,
    opts: TerminalOptions,
) callconv(lib.calling_conv) Result {
    result.* = terminal_new_(
        alloc_,
        terminal_,
        opts,
    ) catch |err| {
        result.* = null;
        return switch (err) {
            error.InvalidValue => .invalid_value,
            error.OutOfMemory => .out_of_memory,
        };
    };

    return .success;
}

fn terminal_new_(
    alloc_: ?*const CAllocator,
    terminal_: terminal_c.Terminal,
    opts: TerminalOptions,
) error{
    InvalidValue,
    OutOfMemory,
}!*FormatterWrapper {
    const t: *ZigTerminal = (terminal_ orelse return error.InvalidValue).terminal;

    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(FormatterWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(ptr);

    var formatter: formatterpkg.TerminalFormatter = .init(t, .{
        .emit = opts.emit,
        .unwrap = opts.unwrap,
        .trim = opts.trim,
    });
    formatter.extra = opts.extra.toZig();

    // Setup the content that we're formatting
    if (opts.selection) |sel| formatter.content = .{
        .selection = sel.toZig() orelse
            return error.InvalidValue,
    };

    ptr.* = .{
        .kind = .{ .terminal = formatter },
        .alloc = alloc,
    };

    return ptr;
}

pub fn format_buf(
    formatter_: Formatter,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const wrapper = formatter_ orelse return .invalid_value;

    var writer: std.Io.Writer = .fixed(if (out_) |out|
        out[0..out_len]
    else
        &.{});

    switch (wrapper.kind) {
        .terminal => |*t| t.format(&writer) catch |err| switch (err) {
            error.WriteFailed => {
                // On write failed we always report how much
                // space we actually needed.
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                t.format(&discarding.writer) catch unreachable;
                out_written.* = @intCast(discarding.count);
                return .out_of_space;
            },
        },
    }

    out_written.* = writer.end;
    return .success;
}

pub fn format_alloc(
    formatter_: Formatter,
    alloc_: ?*const CAllocator,
    out_ptr: *?[*]u8,
    out_len: *usize,
) callconv(lib.calling_conv) Result {
    const wrapper = formatter_ orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    switch (wrapper.kind) {
        .terminal => |*t| t.format(&aw.writer) catch return .out_of_memory,
    }

    const buf = aw.toOwnedSlice() catch return .out_of_memory;
    out_ptr.* = buf.ptr;
    out_len.* = buf.len;
    return .success;
}

pub fn free(formatter_: Formatter) callconv(lib.calling_conv) void {
    const wrapper = formatter_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

test "terminal_new/free" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    try testing.expect(f != null);
    free(f);
}

test "terminal_new invalid_value on null terminal" {
    var f: Formatter = null;
    try testing.expectEqual(Result.invalid_value, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        null,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    try testing.expect(f == null);
}

test "free null" {
    free(null);
}

test "format plain" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello", buf[0..written]);
}

test "format reflects terminal changes" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello", buf[0..written]);

    // Write more data and re-format
    terminal_c.vt_write(t, "\r\nWorld", 7);

    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello\nWorld", buf[0..written]);
}

test "format null returns required size" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    // Pass null buffer to query required size
    var required: usize = 0;
    try testing.expectEqual(Result.out_of_space, format_buf(f, null, 0, &required));
    try testing.expect(required > 0);

    // Now allocate and format
    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqual(required, written);
}

test "format buffer too small" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    // Buffer too small
    var buf: [2]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.out_of_space, format_buf(f, &buf, buf.len, &written));
    // written contains the required size
    try testing.expectEqual(@as(usize, 5), written);
}

test "format null formatter" {
    var written: usize = 0;
    try testing.expectEqual(Result.invalid_value, format_buf(null, null, 0, &written));
}

test "format vt" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Test", 4);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .vt, .unwrap = false, .trim = true, .extra = .{ .palette = true, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = true, .hyperlink = true, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [65536]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(written > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..written], "Test") != null);
}

test "format plain with selection" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello World", 11);

    // Get grid refs for "World" (columns 6..10 on row 0)
    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 6, .y = 0 } },
    }, &start_ref));

    var end_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 10, .y = 0 } },
    }, &end_ref));

    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .selection = &sel, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("World", buf[0..written]);
}

test "format html" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        .{ .cols = 80, .rows = 24, .max_scrollback = 10_000 },
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Html", 4);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .html, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .kitty_graphics = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [65536]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(written > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..written], "Html") != null);
}
