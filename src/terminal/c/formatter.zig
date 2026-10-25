const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const io_c = @import("io.zig");
const terminal_c = @import("terminal.zig");
const grid_ref = @import("grid_ref.zig");
const selection_c = @import("selection.zig");
const ZigTerminal = @import("../Terminal.zig");
const Screen = @import("../Screen.zig");
const formatterpkg = @import("../formatter.zig");
const Result = @import("result.zig").Result;

/// Wrapper around formatter that tracks the allocator for C API usage.
const FormatterWrapper = struct {
    kind: Kind,
    alloc: std.mem.Allocator,

    const Kind = union(enum) {
        terminal: formatterpkg.TerminalFormatter,
        screen: ScreenKind,
    };

    /// A formatter for one of the terminal's screens, named by key. The
    /// screen is looked up on every format call rather than at creation:
    /// the alternate screen is initialized lazily and is replaced by a
    /// reset or a failed resize, so a pointer taken earlier could dangle.
    const ScreenKind = struct {
        terminal: *const ZigTerminal,
        key: terminal_c.TerminalScreen,
        opts: formatterpkg.Options,
        content: formatterpkg.ScreenFormatter.Content,
        extra: formatterpkg.ScreenFormatter.Extra,

        /// The screen formatter. NoValue while the screen is not
        /// initialized, InvalidValue if the selection is not in it.
        fn screenFormatter(self: ScreenKind) error{ NoValue, InvalidValue }!formatterpkg.ScreenFormatter {
            const screen = self.terminal.screens.get(self.key) orelse return error.NoValue;
            if (!selectionInScreen(self.content, screen)) return error.InvalidValue;
            var result: formatterpkg.ScreenFormatter = .init(screen, self.opts);
            result.content = self.content;
            result.extra = self.extra;
            return result;
        }
    };
};

/// Returns whether content's selection, if it has one, is in screen. A
/// selection's grid refs are pins into one screen's page list, and the
/// formatter assumes they are pins into the screen it formats: a ref from
/// another screen is a null unwrap there (a panic in safe builds, undefined
/// behavior in others). The refs come from the caller and the active screen
/// can change between calls, so they are checked on every format.
fn selectionInScreen(
    content: formatterpkg.ScreenFormatter.Content,
    screen: *const Screen,
) bool {
    const sel = switch (content) {
        .none => return true,
        .selection => |sel| sel orelse return true,
    };
    return screen.pages.containsPin(sel.start()) and
        screen.pages.containsPin(sel.end());
}

/// The result for an error from ScreenKind.screenFormatter.
fn screenResult(err: error{ NoValue, InvalidValue }) Result {
    return switch (err) {
        error.NoValue => .no_value,
        error.InvalidValue => .invalid_value,
    };
}

/// C: GhosttyFormatter
pub const Formatter = ?*FormatterWrapper;

/// C: GhosttyFormatterFormat
pub const Format = formatterpkg.Format;

const CSelection = selection_c.CSelection;

/// C: GhosttyFormatterScreenOptions
pub const ScreenOptions = extern struct {
    size: usize = @sizeOf(ScreenOptions),
    emit: Format,
    unwrap: bool,
    trim: bool,
    extra: Extra,

    /// Optional selection to restrict output to a range. Its grid
    /// references must be in the formatted screen (screen_grid_ref).
    /// If null, the entire screen is formatted.
    selection: ?*const CSelection = null,

    /// C: GhosttyFormatterScreenExtra
    pub const Extra = extern struct {
        size: usize = @sizeOf(Extra),
        cursor: bool,
        style: bool,
        hyperlink: bool,
        protection: bool,
        kitty_keyboard: bool,
        charsets: bool,

        comptime {
            for (@typeInfo(formatterpkg.ScreenFormatter.Extra).@"struct".field_names) |name| {
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
            for (@typeInfo(formatterpkg.TerminalFormatter.Extra).@"struct".field_names) |name| {
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

pub fn screen_new(
    alloc_: ?*const CAllocator,
    result: *Formatter,
    terminal_: terminal_c.Terminal,
    screen: terminal_c.TerminalScreen,
    opts: ScreenOptions,
) callconv(lib.calling_conv) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.enums.fromInt(terminal_c.TerminalScreen, @backingInt(screen)) orelse {
            result.* = null;
            return .invalid_value;
        };
    }

    result.* = screen_new_(
        alloc_,
        terminal_,
        screen,
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

fn screen_new_(
    alloc_: ?*const CAllocator,
    terminal_: terminal_c.Terminal,
    screen: terminal_c.TerminalScreen,
    opts: ScreenOptions,
) error{
    InvalidValue,
    OutOfMemory,
}!*FormatterWrapper {
    const t: *ZigTerminal = (terminal_ orelse return error.InvalidValue).terminal;

    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(FormatterWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .kind = .{ .screen = .{
            .terminal = t,
            .key = screen,
            .opts = .{
                .emit = opts.emit,
                .unwrap = opts.unwrap,
                .trim = opts.trim,
            },
            .content = .{ .selection = if (opts.selection) |sel|
                sel.toZig() orelse return error.InvalidValue
            else
                null },
            .extra = opts.extra.toZig(),
        } },
        .alloc = alloc,
    };

    return ptr;
}

/// Format directly to a synchronous C writer callback.
pub fn format(
    formatter_: Formatter,
    writer: io_c.Writer,
) callconv(lib.calling_conv) Result {
    const wrapper = formatter_ orelse return .invalid_value;
    if (!writer.valid()) return .invalid_value;

    // Batch the formatter's many small writes into few callback calls. The
    // trailing flush upholds the API contract that success means the
    // callback has accepted every byte.
    var buffer: [io_c.WriterAdapter.recommended_buffer_len]u8 = undefined;
    var adapter: io_c.WriterAdapter = .initBuffered(writer, &buffer);
    format_: {
        switch (wrapper.kind) {
            .terminal => |*t| {
                if (!selectionInScreen(t.content, t.terminal.screens.active))
                    return .invalid_value;
                t.format(adapter.writer()) catch break :format_;
            },
            .screen => |*s| {
                const f = s.screenFormatter() catch |err| return screenResult(err);
                f.format(adapter.writer()) catch break :format_;
            },
        }
        adapter.writer().flush() catch break :format_;
        return .success;
    }

    if (adapter.invalid_write) return .limit_exceeded;
    if (adapter.callback_failed) return .io_error;
    return .io_error;
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
        .terminal => |*t| {
            if (!selectionInScreen(t.content, t.terminal.screens.active)) {
                out_written.* = 0;
                return .invalid_value;
            }
            return formatIntoBuf(t, &writer, out_written);
        },
        .screen => |*s| {
            const f = s.screenFormatter() catch |err| {
                out_written.* = 0;
                return screenResult(err);
            };
            return formatIntoBuf(&f, &writer, out_written);
        },
    }
}

/// Formats f into a fixed writer, reporting the bytes written. A writer
/// that runs out of space fails the write; the size the whole output
/// needs is then reported instead, with out_of_space.
fn formatIntoBuf(
    f: anytype,
    writer: *std.Io.Writer,
    out_written: *usize,
) Result {
    f.format(writer) catch |err| switch (err) {
        error.WriteFailed => {
            // On write failed we always report how much
            // space we actually needed.
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            f.format(&discarding.writer) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

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
        .terminal => |*t| {
            if (!selectionInScreen(t.content, t.terminal.screens.active)) {
                out_ptr.* = null;
                out_len.* = 0;
                return .invalid_value;
            }
            t.format(&aw.writer) catch return .out_of_memory;
        },
        .screen => |*s| {
            const f = s.screenFormatter() catch |err| {
                out_ptr.* = null;
                out_len.* = 0;
                return screenResult(err);
            };
            f.format(&aw.writer) catch return .out_of_memory;
        },
    }

    const buf = aw.toOwnedSlice() catch return .out_of_memory;
    // Empty Zig slices may contain sentinel pointers that foreign runtimes
    // reject even when the length is zero (for example Go's stack scanner).
    out_ptr.* = if (buf.len == 0) null else buf.ptr;
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
        80,
        24,
    ));
    defer terminal_c.free(t);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    try testing.expect(f == null);
}

test "free null" {
    free(null);
}

test "format_alloc empty output" {
    const failing: CAllocator = .fromZig(&std.mem.Allocator.failing);
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        100,
        40,
    ));
    defer terminal_c.free(t);

    // Match a zero-initialized C options struct, including trim = false.
    const opts: TerminalOptions = std.mem.zeroInit(TerminalOptions, .{});
    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        opts,
    ));
    defer free(f);

    for ([_]?*const CAllocator{ null, &failing }) |allocator| {
        var sentinel: u8 = 0;
        var ptr: ?[*]u8 = @ptrCast(&sentinel);
        var len: usize = 123;
        try testing.expectEqual(Result.success, format_alloc(f, allocator, &ptr, &len));
        defer @import("allocator.zig").free(allocator, ptr, len);
        try testing.expectEqual(@as(usize, 0), len);
        try testing.expectEqual(null, ptr);
    }

    // Reusing the same formatter must still allocate and return real output.
    terminal_c.vt_write(t, "hello", 5);
    var ptr: ?[*]u8 = null;
    var len: usize = 0;
    try testing.expectEqual(Result.success, format_alloc(f, null, &ptr, &len));
    defer @import("allocator.zig").free(null, ptr, len);
    try testing.expectEqualStrings("hello", ptr.?[0..len]);
}

test "format plain" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello", buf[0..written]);
}

test "format streams to writer" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello\r\nWorld", 12);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    const Context = struct {
        destination: []u8,
        offset: usize = 0,
        calls: usize = 0,

        fn write(
            userdata: ?*anyopaque,
            data: [*]const u8,
            len: usize,
        ) callconv(lib.calling_conv) bool {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (len > self.destination.len - self.offset) return false;
            @memcpy(self.destination[self.offset..][0..len], data[0..len]);
            self.offset += len;
            self.calls += 1;
            return true;
        }
    };

    var buf: [1024]u8 = undefined;
    var context: Context = .{ .destination = &buf };
    try testing.expectEqual(Result.success, format(f, .{
        .write = &Context.write,
        .userdata = &context,
    }));
    try testing.expect(context.calls > 0);
    try testing.expectEqualStrings("Hello\nWorld", buf[0..context.offset]);
}

test "format writer errors" {
    const FailWriter = struct {
        fn write(
            _: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            return false;
        }
    };

    try testing.expectEqual(Result.invalid_value, format(null, .{
        .write = &FailWriter.write,
    }));

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);
    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    try testing.expectEqual(Result.invalid_value, format(f, .{}));
    try testing.expectEqual(Result.io_error, format(f, .{
        .write = &FailWriter.write,
    }));
}

test "format reflects terminal changes" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Test", 4);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .vt, .unwrap = false, .trim = true, .extra = .{ .palette = true, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = true, .hyperlink = true, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        80,
        24,
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
        .{ .emit = .plain, .unwrap = false, .trim = true, .selection = &sel, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
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
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Html", 4);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .html, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [65536]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(written > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..written], "Html") != null);
}

test "screen_new/free" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .primary,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
    ));
    try testing.expect(f != null);
    free(f);
}

test "screen_new invalid_value on null terminal" {
    var f: Formatter = null;
    try testing.expectEqual(Result.invalid_value, screen_new(
        &lib.alloc.test_allocator,
        &f,
        null,
        .primary,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
    ));
    try testing.expect(f == null);
}

test "format screen primary beneath the alternate screen" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "primary", 7);
    terminal_c.vt_write(t, "\x1b[?1049h\x1b[Halternate", 20);

    var screen: terminal_c.TerminalScreen = undefined;
    try testing.expectEqual(Result.success, terminal_c.get(t, .active_screen, @ptrCast(&screen)));
    try testing.expectEqual(terminal_c.TerminalScreen.alternate, screen);

    // The terminal formatter formats the active screen; a screen
    // formatter formats the screen it was given, active or not.
    for ([_]struct { screen: terminal_c.TerminalScreen, want: []const u8 }{
        .{ .screen = .primary, .want = "primary" },
        .{ .screen = .alternate, .want = "alternate" },
    }) |tc| {
        var f: Formatter = null;
        try testing.expectEqual(Result.success, screen_new(
            &lib.alloc.test_allocator,
            &f,
            t,
            tc.screen,
            .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
        ));
        defer free(f);

        var buf: [1024]u8 = undefined;
        var written: usize = 0;
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings(tc.want, buf[0..written]);
    }

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("alternate", buf[0..written]);
}

test "format screen no_value until the alternate screen exists" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    // The alternate screen is initialized when a program first switches
    // to it, and can be discarded by a reset, so the formatter is created
    // regardless and the screen is looked up when formatting.
    var f: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .alternate,
        .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 123;
    try testing.expectEqual(Result.no_value, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqual(@as(usize, 0), written);

    var ptr: ?[*]u8 = null;
    var len: usize = 123;
    try testing.expectEqual(Result.no_value, format_alloc(f, null, &ptr, &len));
    try testing.expectEqual(null, ptr);
    try testing.expectEqual(@as(usize, 0), len);

    const Context = struct {
        fn write(
            _: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            unreachable;
        }
    };
    try testing.expectEqual(Result.no_value, format(f, .{
        .write = &Context.write,
    }));

    terminal_c.vt_write(t, "\x1b[?1049halt", 11);
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("alt", buf[0..written]);

    // A full reset discards the alternate screen again.
    terminal_c.vt_write(t, "\x1bc", 2);
    try testing.expectEqual(Result.no_value, format_buf(f, &buf, buf.len, &written));
}

test "format screen with a selection in the primary screen's scrollback" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        3,
    ));
    defer terminal_c.free(t);

    // Two rows of scrollback, three on screen, then the alternate screen.
    terminal_c.vt_write(t, "l0\r\nl1\r\nl2\r\nl3\r\nl4", 18);
    terminal_c.vt_write(t, "\x1b[?1049halt", 11);

    // The primary screen's grid refs select the last row of its
    // scrollback and the first row of its screen.
    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.screen_grid_ref(t, .primary, .{
        .tag = .history,
        .value = .{ .history = .{ .x = 0, .y = 1 } },
    }, &start_ref));
    var end_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.screen_grid_ref(t, .primary, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 1, .y = 0 } },
    }, &end_ref));
    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };

    var f: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .primary,
        .{ .emit = .plain, .unwrap = false, .trim = true, .selection = &sel, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("l1\nl2", buf[0..written]);
}

test "format invalid_value for a selection in another screen" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello World", 11);

    // A selection of "Hello" in the primary screen.
    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    var end_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 4, .y = 0 } },
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
        .{ .emit = .plain, .unwrap = false, .trim = true, .selection = &sel, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello", buf[0..written]);

    // The terminal formatter formats the active screen, and the
    // selection's refs are not in the alternate one.
    terminal_c.vt_write(t, "\x1b[?1049halt", 11);
    written = 1;
    try testing.expectEqual(Result.invalid_value, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqual(@as(usize, 0), written);

    var out_ptr: ?[*]u8 = undefined;
    var out_len: usize = 1;
    try testing.expectEqual(Result.invalid_value, format_alloc(
        f,
        &lib.alloc.test_allocator,
        &out_ptr,
        &out_len,
    ));
    try testing.expect(out_ptr == null);
    try testing.expectEqual(@as(usize, 0), out_len);

    const Context = struct {
        fn write(
            _: ?*anyopaque,
            _: [*]const u8,
            _: usize,
        ) callconv(lib.calling_conv) bool {
            unreachable;
        }
    };
    try testing.expectEqual(Result.invalid_value, format(f, .{
        .write = &Context.write,
    }));

    // Back on the primary screen the selection is valid again.
    terminal_c.vt_write(t, "\x1b[?1049l", 8);
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("Hello", buf[0..written]);
}

test "format screen invalid_value for a selection in another screen" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "primary", 7);
    terminal_c.vt_write(t, "\x1b[?1049h\x1b[Halt", 14);

    const opts: ScreenOptions = .{ .emit = .plain, .unwrap = false, .trim = true, .extra = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } };
    const screens = [_]terminal_c.TerminalScreen{ .primary, .alternate };
    for (screens, 0..) |from, i| {
        const other = screens[1 - i];

        var start_ref: grid_ref.CGridRef = .{};
        try testing.expectEqual(Result.success, terminal_c.screen_grid_ref(t, from, .{
            .tag = .active,
            .value = .{ .active = .{ .x = 0, .y = 0 } },
        }, &start_ref));
        var end_ref: grid_ref.CGridRef = .{};
        try testing.expectEqual(Result.success, terminal_c.screen_grid_ref(t, from, .{
            .tag = .active,
            .value = .{ .active = .{ .x = 2, .y = 0 } },
        }, &end_ref));
        const sel: selection_c.CSelection = .{
            .start = start_ref,
            .end = end_ref,
        };
        var screen_opts = opts;
        screen_opts.selection = &sel;

        var buf: [1024]u8 = undefined;
        var written: usize = 0;

        var f: Formatter = null;
        try testing.expectEqual(Result.success, screen_new(
            &lib.alloc.test_allocator,
            &f,
            t,
            from,
            screen_opts,
        ));
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expect(written == 3);
        free(f);

        try testing.expectEqual(Result.success, screen_new(
            &lib.alloc.test_allocator,
            &f,
            t,
            other,
            screen_opts,
        ));
        defer free(f);
        try testing.expectEqual(Result.invalid_value, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqual(@as(usize, 0), written);
    }
}

test "format invalid_value for a selection outside its page" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "Hello", 5);

    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    var end_ref = start_ref;
    end_ref.x = 200;
    const sel: selection_c.CSelection = .{
        .start = start_ref,
        .end = end_ref,
    };

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .{ .emit = .plain, .unwrap = false, .trim = true, .selection = &sel, .extra = .{ .palette = false, .modes = false, .scrolling_region = false, .tabstops = false, .pwd = false, .keyboard = false, .screen = .{ .cursor = false, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } } },
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.invalid_value, format_buf(f, &buf, buf.len, &written));
}

test "format screen vt emits the screen's own cursor" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "\x1b[5;10Hprimary", 14);
    terminal_c.vt_write(t, "\x1b[?1049h\x1b[2;3Halt", 17);

    for ([_]struct { screen: terminal_c.TerminalScreen, want: []const u8 }{
        .{ .screen = .primary, .want = "primary\x1b[5;17H" },
        .{ .screen = .alternate, .want = "alt\x1b[2;6H" },
    }) |tc| {
        var f: Formatter = null;
        try testing.expectEqual(Result.success, screen_new(
            &lib.alloc.test_allocator,
            &f,
            t,
            tc.screen,
            .{ .emit = .vt, .unwrap = false, .trim = true, .extra = .{ .cursor = true, .style = false, .hyperlink = false, .protection = false, .kitty_keyboard = false, .charsets = false } },
        ));
        defer free(f);

        var buf: [4096]u8 = undefined;
        var written: usize = 0;
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expect(std.mem.endsWith(u8, buf[0..written], tc.want));
    }
}

test "format screen restores the primary screen beneath the alternate" {
    // A terminal with scrollback on the primary screen and a program on
    // the alternate screen, as an editor leaves it.
    var source: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &source,
        20,
        4,
    ));
    defer terminal_c.free(source);
    const primary_vt = "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\n$ vim";
    terminal_c.vt_write(source, primary_vt, primary_vt.len);
    const alternate_vt = "\x1b[?1049h\x1b[H\x1b[2Jedited text\x1b[3;4H";
    terminal_c.vt_write(source, alternate_vt, alternate_vt.len);

    // The primary screen is formatted first, with its cursor. The
    // terminal formatter then formats the active (alternate) screen with
    // the terminal's modes: mode 1049 switches the target over and saves
    // the primary screen's cursor, as the program's own switch did.
    var primary_fmt: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &primary_fmt,
        source,
        .primary,
        .{ .emit = .vt, .unwrap = false, .trim = false, .extra = .{ .cursor = true, .style = true, .hyperlink = true, .protection = true, .kitty_keyboard = true, .charsets = true } },
    ));
    defer free(primary_fmt);
    var terminal_fmt: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &terminal_fmt,
        source,
        .{ .emit = .vt, .unwrap = false, .trim = false, .extra = .{ .palette = false, .modes = true, .scrolling_region = true, .tabstops = true, .pwd = false, .keyboard = true, .screen = .{ .cursor = true, .style = true, .hyperlink = true, .protection = true, .kitty_keyboard = true, .charsets = true } } },
    ));
    defer free(terminal_fmt);

    var target: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &target,
        20,
        4,
    ));
    defer terminal_c.free(target);
    var buf: [4096]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(primary_fmt, &buf, buf.len, &written));
    terminal_c.vt_write(target, &buf, written);
    try testing.expectEqual(Result.success, format_buf(terminal_fmt, &buf, buf.len, &written));
    terminal_c.vt_write(target, &buf, written);

    // The alternate screen is active in both, with the same contents and
    // cursor.
    const source_t: *ZigTerminal = source.?.terminal;
    const target_t: *ZigTerminal = target.?.terminal;
    try testing.expectEqual(terminal_c.TerminalScreen.alternate, target_t.screens.active_key);
    try expectSameScreen(source_t, target_t);

    // Leaving the alternate screen brings back the primary screen, its
    // scrollback and its cursor in both.
    terminal_c.vt_write(source, "\x1b[?1049l", 8);
    terminal_c.vt_write(target, "\x1b[?1049l", 8);
    try testing.expectEqual(terminal_c.TerminalScreen.primary, target_t.screens.active_key);
    try expectSameScreen(source_t, target_t);
    try testing.expectEqual(@as(usize, 2), target_t.screens.active.pages.total_rows - target_t.rows);
}

/// Expects the active screens of two terminals to hold the same text,
/// scrollback included, with the cursor at the same place.
fn expectSameScreen(want: *ZigTerminal, got: *ZigTerminal) !void {
    const want_str = try want.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(want_str);
    const got_str = try got.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(got_str);
    try testing.expectEqualStrings(want_str, got_str);
    try testing.expectEqual(want.screens.active.cursor.x, got.screens.active.cursor.x);
    try testing.expectEqual(want.screens.active.cursor.y, got.screens.active.cursor.y);
}
