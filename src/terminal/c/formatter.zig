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

    /// The options and content that both kinds have.
    fn optsAndContent(self: *FormatterWrapper) struct {
        *formatterpkg.Options,
        *formatterpkg.ScreenFormatter.Content,
    } {
        return switch (self.kind) {
            .terminal => |*t| .{ &t.opts, &t.content },
            .screen => |*s| .{ &s.opts, &s.content },
        };
    }
};

/// C: GhosttyFormatter
pub const Formatter = ?*FormatterWrapper;

/// C: GhosttyFormatterFormat
pub const Format = formatterpkg.Format;

const CSelection = selection_c.CSelection;
const ZigExtra = formatterpkg.TerminalFormatter.Extra;
const ZigScreenExtra = formatterpkg.ScreenFormatter.Extra;

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

/// The bits a screen formatter accepts: the extras of `ScreenFormatter.Extra`.
/// The others are terminal state, which only a terminal formatter writes.
const extras_screen: Extras = mask: {
    var result: Extras = 0;
    for (@typeInfo(ZigScreenExtra).@"struct".field_names) |name| {
        result |= @field(ExtraBit, name).mask();
    }
    break :mask result;
};

fn screenExtrasFromZig(extra: ZigScreenExtra) Extras {
    var result: ZigExtra = .none;
    result.screen = extra;
    return extrasFromZig(result);
}

/// Returns null if `extras` has a bit that isn't a screen extra.
fn screenExtrasToZig(extras: Extras) ?ZigScreenExtra {
    if (extras & ~extras_screen != 0) return null;
    return (extrasToZig(extras) orelse unreachable).screen;
}

/// The value each option starts with, and the value a NULL `set` puts back.
/// These are the Zig TerminalFormatter's own defaults. formatter.h lists
/// them, so update the header when one changes. A screen formatter starts
/// with the screen extras of the same default.
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
    pub fn InType(comptime self: Option) type {
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
    result_: ?*Formatter,
    terminal_: terminal_c.Terminal,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) {
        if (result_) |o| o.* = null;
        return .unsupported;
    }
    const result = result_ orelse return .invalid_value;
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

pub fn screen_new(
    alloc_: ?*const CAllocator,
    result_: ?*Formatter,
    terminal_: terminal_c.Terminal,
    screen_: lib.CEnum(terminal_c.TerminalScreen),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) {
        if (result_) |o| o.* = null;
        return .unsupported;
    }
    const result = result_ orelse return .invalid_value;
    const screen = lib.enumFromC(terminal_c.TerminalScreen, screen_) orelse {
        result.* = null;
        return .invalid_value;
    };
    result.* = screen_new_(
        alloc_,
        terminal_,
        screen,
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
            .opts = defaults.opts,
            .content = .{ .selection = null },
            .extra = defaults.extra.screen,
        } },
        .alloc = alloc,
    };

    return ptr;
}

pub fn set(
    formatter_: Formatter,
    option: Option,
    value: ?*const anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) return .unsupported;
    return switch (option) {
        _ => .unsupported,
        .invalid => .invalid_value,
        inline else => |comptime_option| {
            const wrapper = formatter_ orelse return .invalid_value;
            return setTyped(
                wrapper,
                comptime_option,
                @ptrCast(@alignCast(value)),
            );
        },
    };
}

/// Set one option. A null value puts it back to its default.
fn setTyped(
    wrapper: *FormatterWrapper,
    comptime option: Option,
    value: ?*const option.InType(),
) Result {
    const opts, const content = wrapper.optsAndContent();
    switch (option) {
        .invalid => comptime unreachable,
        .emit => opts.emit = if (value) |v|
            lib.enumFromPtr(Format, v) orelse return .invalid_value
        else
            defaults.opts.emit,
        .unwrap => opts.unwrap = if (value) |v| v.* else defaults.opts.unwrap,
        .trim => opts.trim = if (value) |v| v.* else defaults.opts.trim,
        // The refs are checked against the formatted screen on each format
        // call (selectionInScreen), not here: the screen they must be in
        // can change before then.
        .selection => content.* = .{
            .selection = if (value) |v|
                v.toZig() orelse return .invalid_value
            else
                null,
        },
        .extras => switch (wrapper.kind) {
            .terminal => |*t| t.extra = if (value) |v|
                extrasToZig(v.*) orelse return .invalid_value
            else
                defaults.extra,
            .screen => |*sk| sk.extra = if (value) |v|
                screenExtrasToZig(v.*) orelse return .invalid_value
            else
                defaults.extra.screen,
        },
        _ => comptime unreachable,
    }

    return .success;
}

pub fn get(
    formatter_: Formatter,
    option: Option,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) return .unsupported;
    return switch (option) {
        _ => .unsupported,
        .invalid => .invalid_value,
        inline else => |comptime_option| {
            const wrapper = formatter_ orelse return .invalid_value;
            const out_ptr = out orelse return .invalid_value;
            return getTyped(
                wrapper,
                comptime_option,
                @ptrCast(@alignCast(out_ptr)),
            );
        },
    };
}

fn getTyped(
    wrapper: *FormatterWrapper,
    comptime option: Option,
    out: *option.InType(),
) Result {
    const opts, const content = wrapper.optsAndContent();
    switch (option) {
        .invalid => comptime unreachable,
        .emit => out.* = opts.emit,
        .unwrap => out.* = opts.unwrap,
        .trim => out.* = opts.trim,
        .selection => out.* = CSelection.fromZig(switch (content.*) {
            .none => return .no_value,
            .selection => |sel| sel orelse return .no_value,
        }),
        .extras => out.* = switch (wrapper.kind) {
            .terminal => |*t| extrasFromZig(t.extra),
            .screen => |*sk| screenExtrasFromZig(sk.extra),
        },
        _ => comptime unreachable,
    }

    return .success;
}

/// Returns whether content's selection, if it has one, is in screen. A
/// selection's grid refs are pins into one screen's page list, and the
/// formatter assumes they are pins into the screen it formats: a ref from
/// another screen is a null unwrap there (a panic in safe builds, undefined
/// behavior in others). The refs come from the caller and the active screen
/// can change between calls, so they are checked on every format. A stale
/// ref into a page that still exists is not detected (the header documents
/// that refs must be taken after the terminal's last update).
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

/// Format directly to a synchronous C writer callback.
pub fn format(
    formatter_: Formatter,
    writer: io_c.Writer,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) return .unsupported;
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
            .screen => |*sk| {
                const f = sk.screenFormatter() catch |err| return screenResult(err);
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
    out_written_: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) return .unsupported;
    const wrapper = formatter_ orelse return .invalid_value;
    const out_written = out_written_ orelse return .invalid_value;

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
        .screen => |*sk| {
            const f = sk.screenFormatter() catch |err| {
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
    out_ptr_: ?*?[*]u8,
    out_len_: ?*usize,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.formatter)) return .unsupported;
    const wrapper = formatter_ orelse return .invalid_value;
    const out_ptr = out_ptr_ orelse return .invalid_value;
    const out_len = out_len_ orelse return .invalid_value;
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
        .screen => |*sk| {
            const f = sk.screenFormatter() catch |err| {
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
    if (comptime !lib.feature(.formatter)) return;
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
    ));
    defer free(f);
    try testing.expectEqual(Result.success, set(f, .selection, &sel));

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
    ));
    defer free(f);
    try testing.expectEqual(Result.success, set(f, .selection, &sel));

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.invalid_value, format_buf(f, &buf, buf.len, &written));
}

/// A screen as the C API takes it.
const CScreen = lib.CEnum(terminal_c.TerminalScreen);

/// screen_new, then emit and extras set for a test.
fn testScreenNew(
    result: *Formatter,
    terminal_: terminal_c.Terminal,
    screen: CScreen,
    emit: Format,
    extras: Extras,
) !void {
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        result,
        terminal_,
        screen,
    ));
    try testing.expectEqual(Result.success, set(result.*, .emit, &emit));
    try testing.expectEqual(Result.success, set(result.*, .extras, &extras));
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
    ));
    try testing.expect(f != null);
    free(f);
}

test "screen_new invalid_value" {
    var f: Formatter = null;
    try testing.expectEqual(Result.invalid_value, screen_new(
        &lib.alloc.test_allocator,
        &f,
        null,
        .primary,
    ));
    try testing.expect(f == null);

    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    try testing.expectEqual(Result.invalid_value, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        @fromBackingInt(99),
    ));
    try testing.expect(f == null);
    try testing.expectEqual(Result.invalid_value, screen_new(
        &lib.alloc.test_allocator,
        null,
        t,
        .primary,
    ));
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

    // A screen formatter formats the screen it was given, active or not.
    for ([_]struct { screen: CScreen, want: []const u8 }{
        .{ .screen = .primary, .want = "primary" },
        .{ .screen = .alternate, .want = "alternate" },
    }) |tc| {
        var f: Formatter = null;
        try testing.expectEqual(Result.success, screen_new(
            &lib.alloc.test_allocator,
            &f,
            t,
            tc.screen,
        ));
        defer free(f);

        var buf: [1024]u8 = undefined;
        var written: usize = 0;
        try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
        try testing.expectEqualStrings(tc.want, buf[0..written]);
    }

    // The terminal formatter formats the active screen.
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

    // The alternate screen is created when a program first switches to it,
    // and a full reset discards it, so the formatter is created regardless
    // and the screen is looked up when formatting.
    var f: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .alternate,
    ));
    defer free(f);

    var buf: [1024]u8 = undefined;
    var written: usize = 123;
    try testing.expectEqual(Result.no_value, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqual(@as(usize, 0), written);

    var ptr: ?[*]u8 = undefined;
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

    // Select from the last row of the primary screen's scrollback to the
    // first row of its screen.
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
    ));
    defer free(f);
    try testing.expectEqual(Result.success, set(f, .selection, &sel));

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("l1\nl2", buf[0..written]);
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

    const screens = [_]CScreen{ .primary, .alternate };
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

        var buf: [1024]u8 = undefined;
        var written: usize = 0;

        // The refs' own screen formats them, the other screen refuses them.
        for ([_]struct { screen: CScreen, want: Result }{
            .{ .screen = from, .want = .success },
            .{ .screen = other, .want = .invalid_value },
        }) |tc| {
            var f: Formatter = null;
            try testing.expectEqual(Result.success, screen_new(
                &lib.alloc.test_allocator,
                &f,
                t,
                tc.screen,
            ));
            defer free(f);
            try testing.expectEqual(Result.success, set(f, .selection, &sel));
            try testing.expectEqual(tc.want, format_buf(f, &buf, buf.len, &written));
            try testing.expectEqual(@as(usize, if (tc.want == .success) 3 else 0), written);
        }
    }
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

    for ([_]struct { screen: CScreen, want: []const u8 }{
        .{ .screen = .primary, .want = "primary\x1b[5;17H" },
        .{ .screen = .alternate, .want = "alt\x1b[2;6H" },
    }) |tc| {
        var f: Formatter = null;
        try testScreenNew(&f, t, tc.screen, .vt, ExtraBit.cursor.mask());
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
    const trim = false;
    var primary_fmt: Formatter = null;
    try testScreenNew(&primary_fmt, source, .primary, .vt, extras_screen);
    defer free(primary_fmt);
    try testing.expectEqual(Result.success, set(primary_fmt, .trim, &trim));

    var terminal_fmt: Formatter = null;
    try testing.expectEqual(Result.success, terminal_new(
        &lib.alloc.test_allocator,
        &terminal_fmt,
        source,
    ));
    defer free(terminal_fmt);
    const vt: Format = .vt;
    const extras: Extras = extras_screen | ExtraBit.modes.mask() |
        ExtraBit.scrolling_region.mask() | ExtraBit.tabstops.mask() |
        ExtraBit.keyboard.mask();
    try testing.expectEqual(Result.success, set(terminal_fmt, .emit, &vt));
    try testing.expectEqual(Result.success, set(terminal_fmt, .extras, &extras));
    try testing.expectEqual(Result.success, set(terminal_fmt, .trim, &trim));

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

test "screen formatter options" {
    var t: terminal_c.Terminal = null;
    try testing.expectEqual(Result.success, terminal_c.new(
        &lib.alloc.test_allocator,
        &t,
        80,
        24,
    ));
    defer terminal_c.free(t);

    terminal_c.vt_write(t, "\x1b[31mred\x1b[0m   \r\nline2", 22);

    var f: Formatter = null;
    try testing.expectEqual(Result.success, screen_new(
        &lib.alloc.test_allocator,
        &f,
        t,
        .primary,
    ));
    defer free(f);

    // The defaults are a terminal formatter's, with only the screen part
    // of its extras: the whole screen as trimmed plain text.
    var emit: Format = undefined;
    try testing.expectEqual(Result.success, get(f, .emit, &emit));
    try testing.expectEqual(defaults.opts.emit, emit);
    var extras: Extras = undefined;
    try testing.expectEqual(Result.success, get(f, .extras, &extras));
    try testing.expectEqual(ExtraBit.style.mask() | ExtraBit.hyperlink.mask(), extras);
    var sel_out: CSelection = undefined;
    try testing.expectEqual(Result.no_value, get(f, .selection, &sel_out));

    var buf: [1024]u8 = undefined;
    var written: usize = 0;
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expectEqualStrings("red\nline2", buf[0..written]);

    // A screen formatter takes the screen extras and no others. A refused
    // value leaves the option as it was.
    try testing.expectEqual(Result.success, set(f, .extras, &extras_screen));
    try testing.expectEqual(Result.success, get(f, .extras, &extras));
    try testing.expectEqual(extras_screen, extras);
    for ([_]Extras{
        ExtraBit.palette.mask(),
        ExtraBit.modes.mask() | ExtraBit.cursor.mask(),
        extras_valid,
        extras_valid + 1,
    }) |bad| {
        try testing.expectEqual(Result.invalid_value, set(f, .extras, &bad));
        try testing.expectEqual(Result.success, get(f, .extras, &extras));
        try testing.expectEqual(extras_screen, extras);
    }

    // NULL puts the default back.
    try testing.expectEqual(Result.success, set(f, .extras, null));
    try testing.expectEqual(Result.success, get(f, .extras, &extras));
    try testing.expectEqual(ExtraBit.style.mask() | ExtraBit.hyperlink.mask(), extras);

    // The other options work as on a terminal formatter.
    const trim = false;
    try testing.expectEqual(Result.success, set(f, .trim, &trim));
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(std.mem.startsWith(u8, buf[0..written], "red   \n"));
    try testing.expectEqual(Result.success, set(f, .trim, null));

    const vt: Format = .vt;
    try testing.expectEqual(Result.success, set(f, .emit, &vt));
    try testing.expectEqual(Result.success, format_buf(f, &buf, buf.len, &written));
    try testing.expect(std.mem.indexOf(u8, buf[0..written], "\x1b[") != null);
}
