//! Benchmark for bidirectional text processing.

const BiDiText = @This();

const std = @import("std");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const terminalpkg = @import("../terminal/main.zig");
const BiDi = @import("../text/BiDi.zig");

mode: Mode,
alloc: Allocator,
terminal: terminalpkg.Terminal,

pub const Mode = enum {
    latin,
    arabic,
    mixed,
};

pub const Options = struct {
    mode: Mode = .latin,
};

pub fn create(alloc: Allocator, opts: Options) !*BiDiText {
    const ptr = try alloc.create(BiDiText);
    errdefer alloc.destroy(ptr);

    ptr.* = .{
        .mode = opts.mode,
        .alloc = alloc,
        .terminal = try terminalpkg.Terminal.init(alloc, .{
            .cols = 80,
            .rows = 24,
        }),
    };

    return ptr;
}

pub fn destroy(self: *BiDiText, alloc: Allocator) void {
    self.terminal.deinit(alloc);
    alloc.destroy(self);
}

pub fn benchmark(self: *BiDiText) Benchmark {
    return Benchmark.init(self, .{
        .setupFn = setup,
        .teardownFn = teardown,
        .stepFn = step,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *BiDiText = @ptrCast(@alignCast(ptr));
    self.terminal.fullReset();

    const text = switch (self.mode) {
        .latin => "The quick brown fox jumps over the lazy dog. Hello World!",
        .arabic => "مرحبا بك في تطبيق غوستي البرمجة بلغة زيج سريعة وآمنة",
        .mixed => "Hello مرحبا World العالم Testing الاختبار",
    };

    self.terminal.printString(text) catch return error.BenchmarkFailed;
}

fn teardown(ptr: *anyopaque) void {
    _ = ptr;
}

fn step(ptr: *anyopaque) Benchmark.Error!void {
    if (comptime !build_options.fribidi) return;

    const self: *BiDiText = @ptrCast(@alignCast(ptr));
    const screen = self.terminal.screens.active;
    const pin = screen.pages.pin(.{ .viewport = .{} }) orelse return;

    const rac = pin.rowAndCell();
    const page = pin.node.data;
    const row = rac.row.*;
    const base: [*]u8 = @ptrCast(page.memory.ptr);
    const cells = row.cells.ptr(base)[0..page.size.cols];
    if (cells.len == 0) return;

    var has_complex = false;
    for (cells) |cell| {
        if (!cell.hasText()) continue;
        if (BiDi.isComplexScript(BiDi.detectScript(cell.codepoint()))) {
            has_complex = true;
            break;
        }
    }
    if (!has_complex) return;

    var codepoints = std.ArrayList(u32).initCapacity(self.alloc, cells.len) catch {
        return error.BenchmarkFailed;
    };
    defer codepoints.deinit(self.alloc);

    for (cells) |cell| {
        const cp = if (cell.hasText()) cell.codepoint() else ' ';
        codepoints.appendAssumeCapacity(cp);
    }

    var analysis = BiDi.analyzeBidiCodepoints(self.alloc, codepoints.items) catch {
        return error.BenchmarkFailed;
    };
    defer analysis.deinit();

    const logical_to_visual = BiDi.reorderVisualCodepoints(
        self.alloc,
        codepoints.items,
        &analysis,
    ) catch return error.BenchmarkFailed;
    defer self.alloc.free(logical_to_visual);
}
