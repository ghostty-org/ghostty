const std = @import("std");
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const ZigTerminal = @import("../Terminal.zig");
const size = @import("../size.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyTerminal
pub const Terminal = ?*ZigTerminal;

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
) callconv(.c) Result {
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
) NewError!*ZigTerminal {
    if (opts.cols == 0 or opts.rows == 0) return error.InvalidValue;

    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(ZigTerminal) catch
        return error.OutOfMemory;
    errdefer alloc.destroy(ptr);

    ptr.* = try .init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    });

    return ptr;
}

pub fn vt_write(
    terminal_: Terminal,
    ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const t = terminal_ orelse return;
    var stream = t.vtStream();
    stream.nextSlice(ptr[0..len]);
}

/// C: GhosttyTerminalScrollViewport
pub const ScrollViewport = ZigTerminal.ScrollViewport.C;

pub fn scroll_viewport(
    terminal_: Terminal,
    behavior: ScrollViewport,
) callconv(.c) void {
    const t = terminal_ orelse return;
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
) callconv(.c) Result {
    const t = terminal_ orelse return .invalid_value;
    if (cols == 0 or rows == 0) return .invalid_value;
    t.resize(t.gpa(), cols, rows) catch return .out_of_memory;
    return .success;
}

pub fn reset(terminal_: Terminal) callconv(.c) void {
    const t = terminal_ orelse return;
    t.fullReset();
}

pub fn free(terminal_: Terminal) callconv(.c) void {
    const t = terminal_ orelse return;

    const alloc = t.gpa();
    t.deinit(alloc);
    alloc.destroy(t);
}

test "new/free" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
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
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 0,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    try testing.expect(t == null);

    try testing.expectEqual(Result.invalid_value, new(
        &lib_alloc.test_allocator,
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
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 5,
            .rows = 2,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    const zt = t.?;

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
        &lib_alloc.test_allocator,
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

    const str = try t.?.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("", str);
}

test "reset null" {
    reset(null);
}

test "resize" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.success, resize(t, 40, 12));
    try testing.expectEqual(40, t.?.cols);
    try testing.expectEqual(12, t.?.rows);
}

test "resize null" {
    try testing.expectEqual(Result.invalid_value, resize(null, 80, 24));
}

test "resize invalid value" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    try testing.expectEqual(Result.invalid_value, resize(t, 0, 24));
    try testing.expectEqual(Result.invalid_value, resize(t, 80, 0));
}

test "vt_write" {
    var t: Terminal = null;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &t,
        .{
            .cols = 80,
            .rows = 24,
            .max_scrollback = 10_000,
        },
    ));
    defer free(t);

    vt_write(t, "Hello", 5);

    const str = try t.?.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}
