const std = @import("std");
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const io_c = @import("io.zig");
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
const ZigExtra = formatterpkg.TerminalFormatter.Extra;

/// C: GhosttyFormatterExtras
///
/// A bitmask of GHOSTTY_FORMATTER_EXTRA_* values. Each bit is one boolean
/// of `TerminalFormatter.Extra`. The terminal extras come first and the
/// screen extras follow, in the same order as the packed struct, so the
/// bitmask and the struct convert with a plain bit cast. `ExtraBit` checks
/// that at compile time.
pub const Extras = u32;

/// The bit position of each GHOSTTY_FORMATTER_EXTRA_* define in
/// formatter.h. The names match the fields of `TerminalFormatter.Extra`
/// and `ScreenFormatter.Extra`.
///
/// The comptime block fails the build if a field moves or a new one is
/// added without a bit here. When that happens, add the bit here and a
/// matching define to formatter.h.
pub const ExtraBit = enum(u5) {
    palette = 0,
    modes = 1,
    scrolling_region = 2,
    tabstops = 3,
    pwd = 4,
    keyboard = 5,
    cursor = 6,
    style = 7,
    hyperlink = 8,
    protection = 9,
    kitty_keyboard = 10,
    charsets = 11,

    /// The bitmask with only this bit set.
    pub fn mask(self: ExtraBit) Extras {
        return @as(Extras, 1) << @backingInt(self);
    }

    comptime {
        const ZigScreenExtra = formatterpkg.ScreenFormatter.Extra;
        const info = @typeInfo(ExtraBit).@"enum";
        if (@bitSizeOf(ZigExtra) != info.field_names.len)
            @compileError("ExtraBit must have one bit per TerminalFormatter.Extra boolean");
        for (info.field_names, info.field_values) |name, value| {
            const offset = if (@hasField(ZigExtra, name))
                @bitOffsetOf(ZigExtra, name)
            else
                @bitOffsetOf(ZigExtra, "screen") +
                    @bitOffsetOf(ZigScreenExtra, name);
            if (offset != value)
                @compileError("ExtraBit." ++ name ++ " does not match its Extra bit");
        }
    }
};

/// Every bit that has a meaning. `set` rejects a value with any other bit.
const extras_valid: Extras = (@as(Extras, 1) << @bitSizeOf(ZigExtra)) - 1;

fn extrasFromZig(extra: ZigExtra) Extras {
    const Int = @typeInfo(ZigExtra).@"struct".backing_integer.?;
    return @as(Int, @bitCast(extra));
}

/// Returns null if `extras` has a bit with no meaning.
fn extrasToZig(extras: Extras) ?ZigExtra {
    if (extras & ~extras_valid != 0) return null;
    const Int = @typeInfo(ZigExtra).@"struct".backing_integer.?;
    return @bitCast(@as(Int, @intCast(extras)));
}

/// The value each option starts with, and the value a NULL `set` puts back.
/// These are the Zig TerminalFormatter's own defaults. formatter.h lists
/// them, so update the header when one changes.
const defaults = struct {
    const opts: formatterpkg.Options = .plain;
    const extra: ZigExtra = .styles;
};

/// C: GhosttyFormatterOption
pub const Option = enum(c_int) {
    invalid = 0,
    emit = 1,
    unwrap = 2,
    trim = 3,
    selection = 4,
    extras = 5,
    _,

    /// The type that a `set` value or a `get` output points to.
    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .invalid => void,
            .emit => Format,
            .unwrap, .trim => bool,
            .selection => CSelection,
            .extras => Extras,
            _ => void,
        };
    }
};

pub fn terminal_new(
    alloc_: ?*const CAllocator,
    result: *Formatter,
    terminal_: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    result.* = terminal_new_(
        alloc_,
        terminal_,
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
) error{
    InvalidValue,
    OutOfMemory,
}!*FormatterWrapper {
    const t: *ZigTerminal = (terminal_ orelse return error.InvalidValue).terminal;

    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(FormatterWrapper) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(ptr);

    var formatter: formatterpkg.TerminalFormatter = .init(t, defaults.opts);
    formatter.extra = defaults.extra;

    ptr.* = .{
        .kind = .{ .terminal = formatter },
        .alloc = alloc,
    };

    return ptr;
}

pub fn set(
    formatter_: Formatter,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    return switch (option) {
        _ => .unsupported,
        .invalid => .invalid_value,
        inline else => |comptime_option| {
            const wrapper = formatter_ orelse return .invalid_value;
            return setTyped(
                terminalFormatter(wrapper),
                comptime_option,
                @ptrCast(@alignCast(value)),
            );
        },
    };
}

/// Set one option. A null value puts it back to its default.
fn setTyped(
    f: *formatterpkg.TerminalFormatter,
    comptime option: Option,
    value: ?*const option.Type(),
) Result {
    switch (option) {
        .invalid => comptime unreachable,
        .emit => f.opts.emit = if (value) |v|
            lib.enumFromPtr(Format, v) orelse return .invalid_value
        else
            defaults.opts.emit,
        .unwrap => f.opts.unwrap = if (value) |v| v.* else defaults.opts.unwrap,
        .trim => f.opts.trim = if (value) |v| v.* else defaults.opts.trim,
        .selection => f.content = .{
            .selection = if (value) |v|
                v.toZig() orelse return .invalid_value
            else
                null,
        },
        .extras => f.extra = if (value) |v|
            extrasToZig(v.*) orelse return .invalid_value
        else
            defaults.extra,
        _ => comptime unreachable,
    }

    return .success;
}

pub fn get(
    formatter_: Formatter,
    option: Option,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    return switch (option) {
        _ => .unsupported,
        .invalid => .invalid_value,
        inline else => |comptime_option| {
            const wrapper = formatter_ orelse return .invalid_value;
            const out_ptr = out orelse return .invalid_value;
            return getTyped(
                terminalFormatter(wrapper),
                comptime_option,
                @ptrCast(@alignCast(out_ptr)),
            );
        },
    };
}

fn getTyped(
    f: *const formatterpkg.TerminalFormatter,
    comptime option: Option,
    out: *option.Type(),
) Result {
    switch (option) {
        .invalid => comptime unreachable,
        .emit => out.* = f.opts.emit,
        .unwrap => out.* = f.opts.unwrap,
        .trim => out.* = f.opts.trim,
        .selection => out.* = CSelection.fromZig(switch (f.content) {
            .none => return .no_value,
            .selection => |sel| sel orelse return .no_value,
        }),
        .extras => out.* = extrasFromZig(f.extra),
        _ => comptime unreachable,
    }

    return .success;
}

fn terminalFormatter(wrapper: *FormatterWrapper) *formatterpkg.TerminalFormatter {
    return switch (wrapper.kind) {
        .terminal => |*t| t,
    };
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
            .terminal => |*t| t.format(adapter.writer()) catch break :format_,
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

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
    ));
    defer free(f);

    // Output is still empty with trimming turned off.
    const trim = false;
    try testing.expectEqual(Result.success, set(f, .trim, &trim));

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
    ));
    defer free(f);

    const emit: Format = .vt;
    try testing.expectEqual(Result.success, set(f, .emit, &emit));

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
    ));
    defer free(f);

    try testing.expectEqual(Result.success, set(f, .selection, &sel));

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
    ));
    defer free(f);

    const emit: Format = .html;
    try testing.expectEqual(Result.success, set(f, .emit, &emit));

    var buf: [65536]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(written > 0);
    try testing.expect(std.mem.indexOf(u8, buf[0..written], "Html") != null);
}

test "set and get each option" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        10,
        5,
    ));
    defer terminal_c.free(t);

    // Row 0 soft-wraps into row 1, row 2 has trailing spaces, and the
    // cursor ends bold so VT output carries an SGR for its style.
    const input = "0123456789abc\r\nhi   \x1b[1m";
    terminal_c.vt_write(t, input, input.len);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
    ));
    defer free(f);

    var buf: [65536]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("0123456789\nabc\nhi", buf[0..written]);

    // Emit
    for ([_]Format{ .vt, .html, .plain }) |emit| {
        try testing.expectEqual(Result.success, set(f, .emit, &emit));
        var out: Format = .plain;
        try testing.expectEqual(Result.success, get(f, .emit, &out));
        try testing.expectEqual(emit, out);

        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        const output = buf[0..written];
        switch (emit) {
            .plain => try testing.expectEqualStrings("0123456789\nabc\nhi", output),
            .vt => try testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null),
            .html => try testing.expect(std.mem.indexOf(u8, output, "<div") != null),
        }
    }

    // Unwrap
    {
        const v = true;
        try testing.expectEqual(Result.success, set(f, .unwrap, &v));
        var out = false;
        try testing.expectEqual(Result.success, get(f, .unwrap, &out));
        try testing.expect(out);
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings("0123456789abc\nhi", buf[0..written]);
    }

    // Trim
    {
        const v = false;
        try testing.expectEqual(Result.success, set(f, .trim, &v));
        var out = true;
        try testing.expectEqual(Result.success, get(f, .trim, &out));
        try testing.expect(!out);
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings("0123456789abc\nhi   ", buf[0..written]);
    }

    // Extras only change VT output, so compare VT with the defaults and
    // with nothing.
    {
        const vt: Format = .vt;
        try testing.expectEqual(Result.success, set(f, .emit, &vt));

        var out: Extras = 0;
        try testing.expectEqual(Result.success, get(f, .extras, &out));
        try testing.expectEqual(
            ExtraBit.palette.mask() | ExtraBit.style.mask() | ExtraBit.hyperlink.mask(),
            out,
        );
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        const styles_len = written;
        try testing.expect(std.mem.indexOf(u8, buf[0..written], "\x1b]4;") != null);

        const none: Extras = 0;
        try testing.expectEqual(Result.success, set(f, .extras, &none));
        try testing.expectEqual(Result.success, get(f, .extras, &out));
        try testing.expectEqual(none, out);
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expect(written < styles_len);
        try testing.expect(std.mem.indexOf(u8, buf[0..written], "\x1b]4;") == null);

        const all: Extras = extras_valid;
        try testing.expectEqual(Result.success, set(f, .extras, &all));
        try testing.expectEqual(Result.success, get(f, .extras, &out));
        try testing.expectEqual(all, out);
        try testing.expectEqual(@as(Extras, 0xFFF), out);

        // Bits without a meaning are rejected and leave the value alone.
        const unknown: Extras = 1 << 12;
        try testing.expectEqual(Result.invalid_value, set(f, .extras, &unknown));
        try testing.expectEqual(Result.success, get(f, .extras, &out));
        try testing.expectEqual(all, out);

        const plain: Format = .plain;
        try testing.expectEqual(Result.success, set(f, .emit, &plain));
    }

    // Selection: "hi" on row 2, columns 0..1.
    {
        var out: CSelection = .{ .start = .{}, .end = .{} };
        try testing.expectEqual(Result.no_value, get(f, .selection, &out));

        var start_ref: grid_ref.CGridRef = .{};
        try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
            .tag = .active,
            .value = .{ .active = .{ .x = 0, .y = 2 } },
        }, &start_ref));
        var end_ref: grid_ref.CGridRef = .{};
        try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
            .tag = .active,
            .value = .{ .active = .{ .x = 1, .y = 2 } },
        }, &end_ref));
        var sel: CSelection = .{ .start = start_ref, .end = end_ref };
        try testing.expectEqual(Result.success, set(f, .selection, &sel));

        // The formatter copied the selection.
        sel.start = .{};
        try testing.expectEqual(Result.success, get(f, .selection, &out));
        try testing.expectEqual(start_ref, out.start);
        try testing.expectEqual(end_ref, out.end);
        try testing.expect(!out.rectangle);

        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings("hi", buf[0..written]);

        // A selection with a zeroed grid reference is rejected and the
        // old selection stays.
        try testing.expectEqual(Result.invalid_value, set(f, .selection, &sel));
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings("hi", buf[0..written]);
    }

    // Invalid values for typed options are rejected.
    {
        const bad_emit: c_int = 99;
        try testing.expectEqual(Result.invalid_value, set(f, .emit, &bad_emit));
        var out: Format = .vt;
        try testing.expectEqual(Result.success, get(f, .emit, &out));
        try testing.expectEqual(Format.plain, out);
    }
}

test "set null resets to defaults" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        10,
        5,
    ));
    defer terminal_c.free(t);
    terminal_c.vt_write(t, "0123456789abc\r\nhi   ", 20);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &f,
        t,
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    const expected = "0123456789\nabc\nhi";
    try testing.expectEqualStrings(expected, buf[0..written]);

    var start_ref: grid_ref.CGridRef = .{};
    try testing.expectEqual(Result.success, terminal_c.grid_ref(t, .{
        .tag = .active,
        .value = .{ .active = .{ .x = 0, .y = 0 } },
    }, &start_ref));
    const sel: CSelection = .{ .start = start_ref, .end = start_ref };
    const html: Format = .html;
    const yes = true;
    const no = false;
    const none: Extras = 0;
    try testing.expectEqual(Result.success, set(f, .emit, &html));
    try testing.expectEqual(Result.success, set(f, .unwrap, &yes));
    try testing.expectEqual(Result.success, set(f, .trim, &no));
    try testing.expectEqual(Result.success, set(f, .selection, &sel));
    try testing.expectEqual(Result.success, set(f, .extras, &none));

    for ([_]Option{ .emit, .unwrap, .trim, .selection, .extras }) |option| {
        try testing.expectEqual(Result.success, set(f, option, null));
    }

    var emit: Format = .vt;
    try testing.expectEqual(Result.success, get(f, .emit, &emit));
    try testing.expectEqual(Format.plain, emit);
    var unwrap = true;
    try testing.expectEqual(Result.success, get(f, .unwrap, &unwrap));
    try testing.expect(!unwrap);
    var trim = false;
    try testing.expectEqual(Result.success, get(f, .trim, &trim));
    try testing.expect(trim);
    var out_sel: CSelection = .{ .start = .{}, .end = .{} };
    try testing.expectEqual(Result.no_value, get(f, .selection, &out_sel));
    var extras: Extras = 0;
    try testing.expectEqual(Result.success, get(f, .extras, &extras));
    try testing.expectEqual(extrasFromZig(.styles), extras);

    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings(expected, buf[0..written]);
}

test "set and get reject unknown and invalid options" {
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
    ));
    defer free(f);

    const yes = true;
    var out = false;
    try testing.expectEqual(Result.invalid_value, set(f, .invalid, &yes));
    try testing.expectEqual(Result.invalid_value, get(f, .invalid, &out));
    try testing.expectEqual(Result.invalid_value, set(null, .trim, &yes));
    try testing.expectEqual(Result.invalid_value, get(null, .trim, &out));
    try testing.expectEqual(Result.invalid_value, get(f, .trim, null));

    // Keys newer than this library are unsupported, with or without a
    // formatter, so a caller can check for a key before creating one.
    const unknown: Option = @fromBackingInt(@intCast(99));
    try testing.expectEqual(Result.unsupported, set(f, unknown, &yes));
    try testing.expectEqual(Result.unsupported, get(f, unknown, &out));
    try testing.expectEqual(Result.unsupported, set(null, unknown, &yes));
    try testing.expectEqual(Result.unsupported, get(null, unknown, null));
}
