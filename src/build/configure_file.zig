//! A small build tool that fills in a template the same way CMake's
//! `configure_file(<input> <output> @ONLY)` does. Each `@NAME@` in the
//! template is replaced with the value given for `NAME`, and the result
//! is written to stdout.
//!
//! `zig build` uses it, through `cmake_package_config.zig`, to generate
//! the CMake package config for libghostty-vt from
//! `dist/cmake/ghostty-vt-config.cmake.in`. That is the same template the
//! CMake wrapper uses, so both builds install the same config.
//!
//! Usage:
//!
//!     configure_file <template> [NAME=VALUE]... > <output>
//!
//! For example, given a template `paths.cmake.in` containing:
//!
//!     set(libdir "${PREFIX}/@LIBDIR@")
//!
//! running `configure_file paths.cmake.in LIBDIR=lib` prints:
//!
//!     set(libdir "${PREFIX}/lib")
//!
//! Only the `@NAME@` form is replaced. CMake's own `${VAR}` references
//! are left alone so CMake can evaluate them later.
//!
//! The tool is strict so the template and the build script can't drift
//! apart. It fails if the template uses a name that has no value, or if
//! a value is given for a name the template never uses.
//!
//! Names may contain letters, digits, and the characters `/ _ . + -`.
//! This matches CMake, and it means a template must be careful with
//! text like `@rpath/@NAME@`. Both CMake and this tool read `@rpath/@`
//! there as a name, and this tool reports it as missing rather than
//! silently producing the wrong output. Text between two `@` signs that
//! can't be a name, such as `@ foo@`, is copied through unchanged.
//!
//! Zig's built-in `ConfigHeader` with the `autoconf_at` style follows
//! the same rules, but it always adds a C comment as the first line of
//! the output, and CMake can't parse that.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // The process exits right after writing its output, so allocate
    // everything from the arena and never free.
    const alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2) fail("usage: configure_file <template> [NAME=VALUE]...", .{});

    var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try putArgs(alloc, &values, args[2..]);
    try configure(alloc, init.io, args[1], &values);
}

/// Parses each `NAME=VALUE` argument in `args` and adds it to `values`.
/// A later value for the same name replaces an earlier one. Exits the
/// process with an error if an argument has no `=`.
///
/// Tools that compute some values themselves can call this for the rest
/// of their arguments, then pass the result to `configure`:
///
/// ```zig
/// var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
/// try values.put(alloc, "LIBDIR", computed_libdir);
/// try configure_file.putArgs(alloc, &values, args[2..]);
/// try configure_file.configure(alloc, io, args[1], &values);
/// ```
pub fn putArgs(
    alloc: std.mem.Allocator,
    values: *std.StringArrayHashMapUnmanaged([]const u8),
    args: []const []const u8,
) !void {
    for (args) |arg| {
        const eql = std.mem.findScalar(u8, arg, '=') orelse
            fail("invalid argument, expected NAME=VALUE: {s}", .{arg});
        try values.put(alloc, arg[0..eql], arg[eql + 1 ..]);
    }
}

/// Reads the template at `template_path`, replaces each `@NAME@` in it
/// with its value from `values`, and writes the result to stdout.
///
/// Like the tool itself, this is strict. It exits the process with an
/// error, and writes nothing, if the template uses a name that has no
/// value or if `values` has a name the template never uses.
pub fn configure(
    alloc: std.mem.Allocator,
    io: std.Io,
    template_path: []const u8,
    values: *const std.StringArrayHashMapUnmanaged([]const u8),
) !void {
    const template = try std.Io.Dir.cwd().readFileAlloc(
        io,
        template_path,
        alloc,
        .unlimited,
    );

    const used = try alloc.alloc(bool, values.count());
    @memset(used, false);

    // Expand into memory first so a failed run writes nothing.
    var out: std.Io.Writer.Allocating = .init(alloc);
    var missing: []const u8 = undefined;
    expand(&out.writer, template, values, used, &missing) catch |err| switch (err) {
        error.MissingValue => fail("{s}: no value for @{s}@", .{ template_path, missing }),
        error.WriteFailed => return err,
    };

    for (values.keys(), used) |name, u| {
        if (!u) fail("{s}: value given for unused @{s}@", .{ template_path, name });
    }

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    try stdout_writer.interface.writeAll(out.written());
    try stdout_writer.interface.flush();
}

/// Writes `template` to `out` with every `@NAME@` replaced by its value
/// from `values`. `used` must have one entry per value. Each entry is
/// set to true when its value is used, so the caller can report values
/// the template never asked for.
///
/// If the template uses a name with no value, this returns
/// `error.MissingValue` and sets `missing` to that name, so the caller
/// can include it in the error message. Output written before the error
/// is incomplete and should be discarded.
fn expand(
    out: *std.Io.Writer,
    template: []const u8,
    values: *const std.StringArrayHashMapUnmanaged([]const u8),
    used: []bool,
    missing: *[]const u8,
) (error{MissingValue} || std.Io.Writer.Error)!void {
    // The characters CMake allows in an `@NAME@` reference (see
    // cmCommandArgumentLexer in the CMake source).
    const name_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.+-";

    var start: usize = 0;
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, template, i, '@')) |open| {
        const close = std.mem.findScalarPos(u8, template, open + 1, '@') orelse break;
        const name = template[open + 1 .. close];
        if (name.len == 0 or std.mem.findNone(u8, name, name_chars) != null) {
            // Not a name, so keep the text. The second `@` might start
            // a real reference, so resume the search from it.
            i = open + 1;
            continue;
        }

        const index = values.getIndex(name) orelse {
            missing.* = name;
            return error.MissingValue;
        };
        used[index] = true;
        try out.writeAll(template[start..open]);
        try out.writeAll(values.values()[index]);
        start = close + 1;
        i = close + 1;
    }
    try out.writeAll(template[start..]);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

test "expand" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer values.deinit(alloc);
    try values.put(alloc, "A", "1");
    try values.put(alloc, "LIB_DIR", "lib");

    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "" },
        .{ .in = "no placeholders", .out = "no placeholders" },
        .{ .in = "@A@", .out = "1" },
        .{ .in = "x@A@y@LIB_DIR@z", .out = "x1ylibz" },
        .{ .in = "@@", .out = "@@" },
        .{ .in = "a@b", .out = "a@b" },
        .{ .in = "${PREFIX}/@LIB_DIR@", .out = "${PREFIX}/lib" },
        .{ .in = "@ x@A@", .out = "@ x1" },
        .{ .in = "a@b c@d", .out = "a@b c@d" },
        .{ .in = "@A@@A@", .out = "11" },
    };
    var buf: [64]u8 = undefined;
    var missing: []const u8 = undefined;
    for (cases) |c| {
        var out: std.Io.Writer = .fixed(&buf);
        var used = [_]bool{ false, false };
        try expand(&out, c.in, &values, &used, &missing);
        try testing.expectEqualStrings(c.out, out.buffered());
    }

    var out: std.Io.Writer = .fixed(&buf);
    var used = [_]bool{ false, false };
    try testing.expectError(
        error.MissingValue,
        expand(&out, "ok @A@ then @MISSING@", &values, &used, &missing),
    );
    try testing.expectEqualStrings("MISSING", missing);

    // CMake reads this as a reference to a variable named "rpath/".
    try testing.expectError(
        error.MissingValue,
        expand(&out, "\"@rpath/@A@\"", &values, &used, &missing),
    );
    try testing.expectEqualStrings("rpath/", missing);
}
