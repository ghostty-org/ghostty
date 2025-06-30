const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const diags = @import("diagnostics.zig");
const internal_os = @import("../os/main.zig");
const Diagnostic = diags.Diagnostic;
const DiagnosticList = diags.DiagnosticList;

const log = std.log.scoped(.cli);

// TODO:
//   - Only `--long=value` format is accepted. Do we want to allow
//     `--long value`? Not currently allowed.

// For trimming
pub const whitespace = " \t";

/// The base errors for arg parsing. Additional errors can be returned due
/// to type-specific parsing but these are always possible.
pub const Error = error{
    ValueRequired,
    InvalidField,
    InvalidValue,
};

/// Parse the command line arguments from iter into dst.
///
/// dst must be a struct. The fields and their types will be used to determine
/// the valid CLI flags. See the tests in this file as an example. For field
/// types that are structs, the struct can implement the `parseCLI` function
/// to do custom parsing.
///
/// If the destination type has a field "_arena" of type `?ArenaAllocator`,
/// an arena allocator will be created (or reused if set already) for any
/// allocations. Allocations are necessary for certain types, like `[]const u8`.
///
/// If the destination type has a field "_diagnostics", it must be of type
/// "DiagnosticList" and any diagnostic messages will be added to that list.
/// When diagnostics are present, only allocation errors will be returned.
///
/// If the destination type has a decl "compatibility", it must be of type
/// std.StaticStringMap(CompatibilityHandler(T)), and it will be used to
/// handle backwards compatibility for fields with the given name. The
/// field name doesn't need to exist (so you can setup compatibility for
/// removed fields). The value is a function that will be called when
/// all other parsing fails for that field. If a field changes such that
/// the old values would NOT error, then the caller should handle that
/// downstream after parsing is done, not through this method.
///
/// Note: If the arena is already non-null, then it will be used. In this
/// case, in the case of an error some memory might be leaked into the arena.
pub fn parse(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    iter: anytype,
) !void {
    const info = @typeInfo(T);
    assert(info == .@"struct");

    // Make an arena for all our allocations if we support it. Otherwise,
    // use an allocator that always fails. If the arena is already set on
    // the config, then we reuse that. See memory note in parse docs.
    const arena_available = @hasField(T, "_arena");
    var arena_owned: bool = false;
    const arena_alloc = if (arena_available) arena: {
        // If the arena is unset, we create it. We mark that we own it
        // only so that we can clean it up on error.
        if (dst._arena == null) {
            dst._arena = .init(alloc);
            arena_owned = true;
        }

        break :arena dst._arena.?.allocator();
    } else fail: {
        // Note: this is... not safe...
        var fail = std.testing.FailingAllocator.init(alloc, .{});
        break :fail fail.allocator();
    };
    errdefer if (arena_available and arena_owned) {
        dst._arena.?.deinit();
        dst._arena = null;
    };

    while (iter.next()) |arg| {
        // Do manual parsing if we have a hook for it.
        if (@hasDecl(T, "parseManuallyHook")) {
            if (!try dst.parseManuallyHook(
                arena_alloc,
                arg,
                iter,
            )) return;
        }

        // If the destination supports help then we check for it, call
        // the help function and return.
        if (@hasDecl(T, "help")) {
            if (mem.eql(u8, arg, "--help") or
                mem.eql(u8, arg, "-h"))
            {
                try dst.help();
                return;
            }
        }

        // If this doesn't start with "--" then it isn't a config
        // flag. We don't support positional arguments or configuration
        // values set with spaces so this is an error.
        if (!mem.startsWith(u8, arg, "--")) {
            if (comptime !canTrackDiags(T)) return Error.InvalidField;

            // Add our diagnostic
            try dst._diagnostics.append(arena_alloc, .{
                .key = try arena_alloc.dupeZ(u8, arg),
                .message = "invalid field",
                .location = try diags.Location.fromIter(iter, arena_alloc),
            });

            continue;
        }

        var key: []const u8 = arg[2..];
        const value: ?[]const u8 = value: {
            // If the arg has "=" then the value is after the "=".
            if (mem.indexOf(u8, key, "=")) |idx| {
                defer key = key[0..idx];
                break :value key[idx + 1 ..];
            }

            break :value null;
        };

        parseIntoField(T, arena_alloc, dst, key, value) catch |err| err: {
            // If we get an error parsing a field, then we try to fall
            // back to compatibility handlers if able.
            if (@hasDecl(T, "compatibility")) {
                // If we have a compatibility handler for this key, then
                // we call it and see if it handles the error.
                if (T.compatibility.get(key)) |handler| {
                    if (handler(dst, arena_alloc, key, value)) {
                        log.info(
                            "compatibility handler for {s} handled error, you may be using a deprecated field: {}",
                            .{ key, err },
                        );
                        break :err;
                    }
                }
            }

            if (comptime !canTrackDiags(T)) return err;

            // The error set is dependent on comptime T, so we always add
            // an extra error so we can have the "else" below.
            const ErrSet = @TypeOf(err) || error{ Unknown, OutOfMemory };
            const message: [:0]const u8 = switch (@as(ErrSet, @errorCast(err))) {
                // OOM is not recoverable since we need to allocate to
                // track more error messages.
                error.OutOfMemory => return err,
                error.InvalidField => "unknown field",
                error.ValueRequired => formatValueRequired(T, arena_alloc, key) catch "value required",
                error.InvalidValue => formatInvalidValue(T, arena_alloc, key, value) catch "invalid value",
                else => try std.fmt.allocPrintZ(
                    arena_alloc,
                    "unknown error {}",
                    .{err},
                ),
            };

            // Add our diagnostic
            try dst._diagnostics.append(arena_alloc, .{
                .key = try arena_alloc.dupeZ(u8, key),
                .message = message,
                .location = try diags.Location.fromIter(iter, arena_alloc),
            });
        };
    }
}

/// The function type for a compatibility handler. The compatibility
/// handler is documented in the `parse` function documentation.
///
/// The function type should return bool if the compatibility was
/// handled, and false otherwise. If false is returned then the
/// naturally occurring error will continue to be processed as if
/// this compatibility handler was not present.
///
/// Compatibility handlers aren't allowed to return errors because
/// they're generally only called in error cases, so we already have
/// an error message to show users. If there is an error in handling
/// the compatibility, then the handler should return false.
pub fn CompatibilityHandler(comptime T: type) type {
    return *const fn (
        dst: *T,
        alloc: Allocator,
        key: []const u8,
        value: ?[]const u8,
    ) bool;
}

/// Convenience function to create a compatibility handler that
/// renames a field from `from` to `to`.
pub fn compatibilityRenamed(
    comptime T: type,
    comptime to: []const u8,
) CompatibilityHandler(T) {
    comptime assert(@hasField(T, to));

    return (struct {
        fn compat(
            dst: *T,
            alloc: Allocator,
            key: []const u8,
            value: ?[]const u8,
        ) bool {
            _ = key;

            parseIntoField(T, alloc, dst, to, value) catch |err| {
                log.warn("error parsing renamed field {s}: {}", .{
                    to,
                    err,
                });

                return false;
            };

            return true;
        }
    }).compat;
}

fn formatValueRequired(
    comptime T: type,
    arena_alloc: std.mem.Allocator,
    key: []const u8,
) std.mem.Allocator.Error![:0]const u8 {
    var buf = std.ArrayList(u8).init(arena_alloc);
    errdefer buf.deinit();
    const writer = buf.writer();
    try writer.print("value required", .{});
    try formatValues(T, key, writer);
    try writer.writeByte(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn formatInvalidValue(
    comptime T: type,
    arena_alloc: std.mem.Allocator,
    key: []const u8,
    value: ?[]const u8,
) std.mem.Allocator.Error![:0]const u8 {
    var buf = std.ArrayList(u8).init(arena_alloc);
    errdefer buf.deinit();
    const writer = buf.writer();
    try writer.print("invalid value \"{?s}\"", .{value});
    try formatValues(T, key, writer);
    try writer.writeByte(0);
    return buf.items[0 .. buf.items.len - 1 :0];
}

fn formatValues(comptime T: type, key: []const u8, writer: anytype) std.mem.Allocator.Error!void {
    const typeinfo = @typeInfo(T);
    inline for (typeinfo.@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            switch (@typeInfo(f.type)) {
                .@"enum" => |e| {
                    try writer.print(", valid values are: ", .{});
                    inline for (e.fields, 0..) |field, i| {
                        if (i != 0) try writer.print(", ", .{});
                        try writer.print("{s}", .{field.name});
                    }
                },
                else => {},
            }
            break;
        }
    }
}

/// Returns true if this type can track diagnostics.
fn canTrackDiags(comptime T: type) bool {
    return @hasField(T, "_diagnostics");
}

/// Parse a single key/value pair into the destination type T.
///
/// This may result in allocations. The allocations can only be freed by freeing
/// all the memory associated with alloc. It is expected that alloc points to
/// an arena.
pub fn parseIntoField(
    comptime T: type,
    alloc: Allocator,
    dst: *T,
    key: []const u8,
    value: ?[]const u8,
) !void {
    const info = @typeInfo(T);
    assert(info == .@"struct");

    inline for (info.@"struct".fields) |field| {
        if (field.name[0] != '_' and mem.eql(u8, field.name, key)) {
            // For optional fields, we just treat it as the child type.
            // This lets optional fields default to null but get set by
            // the CLI.
            const Field = switch (@typeInfo(field.type)) {
                .optional => |opt| opt.child,
                else => field.type,
            };
            const fieldInfo = @typeInfo(Field);
            const canHaveDecls = fieldInfo == .@"struct" or
                fieldInfo == .@"union" or
                fieldInfo == .@"enum";

            // If the value is empty string (set but empty string),
            // then we reset the value to the default.
            if (value) |v| default: {
                if (v.len != 0) break :default;
                // Set default value if possible.
                if (canHaveDecls and @hasDecl(Field, "init")) {
                    try @field(dst, field.name).init(alloc);
                    return;
                }
                const raw = field.default_value_ptr orelse break :default;
                const ptr: *const field.type = @alignCast(@ptrCast(raw));
                @field(dst, field.name) = ptr.*;
                return;
            }

            // If we are a type that can have decls and have a parseCLI decl,
            // we call that and use that to set the value.
            if (canHaveDecls) {
                if (@hasDecl(Field, "parseCLI")) {
                    const fnInfo = @typeInfo(@TypeOf(Field.parseCLI)).@"fn";
                    switch (fnInfo.params.len) {
                        // 1 arg = (input) => output
                        1 => @field(dst, field.name) = try Field.parseCLI(value),

                        // 2 arg = (self, input) => void
                        2 => switch (@typeInfo(field.type)) {
                            .@"struct",
                            .@"union",
                            .@"enum",
                            => try @field(dst, field.name).parseCLI(value),

                            // If the field is optional and set, then we use
                            // the pointer value directly into it. If its not
                            // set we need to create a new instance.
                            .optional => if (@field(dst, field.name)) |*v| {
                                try v.parseCLI(value);
                            } else {
                                // Note: you cannot do @field(dst, name) = undefined
                                // because this causes the value to be "null"
                                // in ReleaseFast modes.
                                var tmp: Field = undefined;
                                try tmp.parseCLI(value);
                                @field(dst, field.name) = tmp;
                            },

                            else => @compileError("unexpected field type"),
                        },

                        // 3 arg = (self, alloc, input) => void
                        3 => switch (@typeInfo(field.type)) {
                            .@"struct",
                            .@"union",
                            .@"enum",
                            => try @field(dst, field.name).parseCLI(alloc, value),

                            .optional => if (@field(dst, field.name)) |*v| {
                                try v.parseCLI(alloc, value);
                            } else {
                                var tmp: Field = undefined;
                                try tmp.parseCLI(alloc, value);
                                @field(dst, field.name) = tmp;
                            },

                            else => @compileError("unexpected field type"),
                        },

                        else => @compileError("parseCLI invalid argument count"),
                    }

                    return;
                }
            }

            // No parseCLI, magic the value based on the type
            @field(dst, field.name) = switch (Field) {
                []const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.alloc(u8, slice.len);
                    @memcpy(buf, slice);
                    break :value buf;
                },

                [:0]const u8 => value: {
                    const slice = value orelse return error.ValueRequired;
                    const buf = try alloc.allocSentinel(u8, slice.len, 0);
                    @memcpy(buf, slice);
                    buf[slice.len] = 0;
                    break :value buf;
                },

                bool => try parseBool(value orelse "t"),

                inline u8,
                u16,
                u21,
                u32,
                u64,
                usize,
                i8,
                i16,
                i32,
                i64,
                isize,
                => |Int| std.fmt.parseInt(
                    Int,
                    value orelse return error.ValueRequired,
                    0,
                ) catch return error.InvalidValue,

                f32,
                f64,
                => |Float| std.fmt.parseFloat(
                    Float,
                    value orelse return error.ValueRequired,
                ) catch return error.InvalidValue,

                else => switch (fieldInfo) {
                    .@"enum" => std.meta.stringToEnum(
                        Field,
                        value orelse return error.ValueRequired,
                    ) orelse return error.InvalidValue,

                    .@"struct" => try parseStruct(
                        Field,
                        alloc,
                        value orelse return error.ValueRequired,
                    ),

                    .@"union" => try parseTaggedUnion(
                        Field,
                        alloc,
                        value orelse return error.ValueRequired,
                    ),

                    else => @compileError("unsupported field type"),
                },
            };

            return;
        }
    }

    return error.InvalidField;
}

pub fn parseTaggedUnion(comptime T: type, alloc: Allocator, v: []const u8) !T {
    const info = @typeInfo(T).@"union";
    assert(@typeInfo(info.tag_type.?) == .@"enum");

    // Get the union tag that is being set. We support values with no colon
    // if the value is void so its not an error to have no colon.
    const colon_idx = mem.indexOf(u8, v, ":") orelse v.len;
    const tag_str = std.mem.trim(u8, v[0..colon_idx], whitespace);
    const value = if (colon_idx < v.len) v[colon_idx + 1 ..] else "";

    // Find the field in the union that matches the tag.
    inline for (info.fields) |field| {
        if (mem.eql(u8, field.name, tag_str)) {
            // Special case void types where we don't need a value.
            if (field.type == void) {
                if (value.len > 0) return error.InvalidValue;
                return @unionInit(T, field.name, {});
            }

            // We need to create a struct that looks like this union field.
            // This lets us use parseIntoField as if its a dedicated struct.
            const Target = @Type(.{ .@"struct" = .{
                .layout = .auto,
                .fields = &.{.{
                    .name = field.name,
                    .type = field.type,
                    .default_value_ptr = null,
                    .is_comptime = false,
                    .alignment = @alignOf(field.type),
                }},
                .decls = &.{},
                .is_tuple = false,
            } });

            // Parse the value into the struct
            var t: Target = undefined;
            try parseIntoField(Target, alloc, &t, field.name, value);

            // Build our union
            return @unionInit(T, field.name, @field(t, field.name));
        }
    }

    return error.InvalidValue;
}

fn parseStruct(comptime T: type, alloc: Allocator, v: []const u8) !T {
    return switch (@typeInfo(T).@"struct".layout) {
        .auto => parseAutoStruct(T, alloc, v),
        .@"packed" => parsePackedStruct(T, v),
        else => @compileError("unsupported struct layout"),
    };
}

pub fn parseAutoStruct(comptime T: type, alloc: Allocator, v: []const u8) !T {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .auto);

    // We start our result as undefined so we don't get an error for required
    // fields. We track required fields below and we validate that we set them
    // all at the bottom of this function (in addition to setting defaults for
    // optionals).
    var result: T = undefined;

    // Keep track of which fields were set so we can error if a required
    // field was not set.
    const FieldSet = std.StaticBitSet(info.fields.len);
    var fields_set: FieldSet = .initEmpty();

    // We split each value by ","
    var iter = std.mem.splitSequence(u8, v, ",");
    loop: while (iter.next()) |entry| {
        // Find the key/value, trimming whitespace. The value may be quoted
        // which we strip the quotes from.
        const idx = mem.indexOf(u8, entry, ":") orelse return error.InvalidValue;
        const key = std.mem.trim(u8, entry[0..idx], whitespace);
        const value = value: {
            var value = std.mem.trim(u8, entry[idx + 1 ..], whitespace);

            // Detect a quoted string.
            if (value.len >= 2 and
                value[0] == '"' and
                value[value.len - 1] == '"')
            {
                // Trim quotes since our CLI args processor expects
                // quotes to already be gone.
                value = value[1 .. value.len - 1];
            }

            break :value value;
        };

        inline for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, key)) {
                try parseIntoField(T, alloc, &result, key, value);
                fields_set.set(i);
                continue :loop;
            }
        }

        // No field matched
        return error.InvalidValue;
    }

    // Ensure all required fields are set
    inline for (info.fields, 0..) |field, i| {
        if (!fields_set.isSet(i)) {
            const default_ptr = field.default_value_ptr orelse return error.InvalidValue;
            const typed_ptr: *const field.type = @alignCast(@ptrCast(default_ptr));
            @field(result, field.name) = typed_ptr.*;
        }
    }

    return result;
}

fn parsePackedStruct(comptime T: type, v: []const u8) !T {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .@"packed");

    var result: T = .{};

    // Allow standalone boolean values like "true" and "false" to
    // turn on or off all of the struct's fields.
    bools: {
        const b = parseBool(v) catch break :bools;
        inline for (info.fields) |field| {
            assert(field.type == bool);
            @field(result, field.name) = b;
        }
        return result;
    }

    // We split each value by ","
    var iter = std.mem.splitSequence(u8, v, ",");
    loop: while (iter.next()) |part_raw| {
        // Determine the field we're looking for and the value. If the
        // field is prefixed with "no-" then we set the value to false.
        const part, const value = part: {
            const negation_prefix = "no-";
            const trimmed = std.mem.trim(u8, part_raw, whitespace);
            if (std.mem.startsWith(u8, trimmed, negation_prefix)) {
                break :part .{ trimmed[negation_prefix.len..], false };
            } else {
                break :part .{ trimmed, true };
            }
        };

        inline for (info.fields) |field| {
            assert(field.type == bool);
            if (std.mem.eql(u8, field.name, part)) {
                @field(result, field.name) = value;
                continue :loop;
            }
        }

        // No field matched
        return error.InvalidValue;
    }

    return result;
}

pub fn parseBool(v: []const u8) !bool {
    const t = &[_][]const u8{ "1", "t", "T", "true" };
    const f = &[_][]const u8{ "0", "f", "F", "false" };

    inline for (t) |str| {
        if (mem.eql(u8, v, str)) return true;
    }
    inline for (f) |str| {
        if (mem.eql(u8, v, str)) return false;
    }

    return error.InvalidValue;
}

test "parse: simple" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: bool = false,
        @"b-f": bool = true,

        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");

    // Reparsing works
    var iter2 = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84",
    );
    defer iter2.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter2);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("84", data.a);
    try testing.expect(data.b);
    try testing.expect(!data.@"b-f");
}

test "parse: quoted value" {
    const testing = std.testing;

    var data: struct {
        a: u8 = 0,
        b: []const u8 = "",
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=\"42\" --b=\"hello!\"",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expectEqualStrings("hello!", data.b);
}

test "parse: empty value resets to default" {
    const testing = std.testing;

    var data: struct {
        a: u8 = 42,
        b: bool = false,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a= --b=",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expectEqual(@as(u8, 42), data.a);
    try testing.expect(!data.b);
}

test "parse: positional arguments are invalid" {
    const testing = std.testing;

    var data: struct {
        a: u8 = 42,
        _arena: ?ArenaAllocator = null,
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=84 what",
    );
    defer iter.deinit();
    try testing.expectError(
        error.InvalidField,
        parse(@TypeOf(data), testing.allocator, &data, &iter),
    );
    try testing.expectEqual(@as(u8, 84), data.a);
}

test "parse: diagnostic tracking" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: enum { one } = .one,

        _arena: ?ArenaAllocator = null,
        _diagnostics: DiagnosticList = .{},
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--what --a=42",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data._diagnostics.items().len == 1);
    {
        const diag = data._diagnostics.items()[0];
        try testing.expectEqual(diags.Location.none, diag.location);
        try testing.expectEqualStrings("what", diag.key);
        try testing.expectEqualStrings("unknown field", diag.message);
    }
}

test "parse: diagnostic location" {
    const testing = std.testing;

    var data: struct {
        a: []const u8 = "",
        b: enum { one, two } = .one,

        _arena: ?ArenaAllocator = null,
        _diagnostics: DiagnosticList = .{},
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var fbs = std.io.fixedBufferStream(
        \\a=42
        \\what
        \\b=two
    );
    const r = fbs.reader();

    const Iter = LineIterator(@TypeOf(r));
    var iter: Iter = .{ .r = r, .filepath = "test" };
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expectEqualStrings("42", data.a);
    try testing.expect(data.b == .two);
    try testing.expect(data._diagnostics.items().len == 1);
    {
        const diag = data._diagnostics.items()[0];
        try testing.expectEqualStrings("what", diag.key);
        try testing.expectEqualStrings("unknown field", diag.message);
        try testing.expectEqualStrings("test", diag.location.file.path);
        try testing.expectEqual(2, diag.location.file.line);
    }
}

test "parse: compatibility handler" {
    const testing = std.testing;

    var data: struct {
        a: bool = false,
        _arena: ?ArenaAllocator = null,

        pub const compatibility: std.StaticStringMap(
            CompatibilityHandler(@This()),
        ) = .initComptime(&.{
            .{ "a", compat },
        });

        fn compat(
            self: *@This(),
            alloc: Allocator,
            key: []const u8,
            value: ?[]const u8,
        ) bool {
            _ = alloc;
            if (std.mem.eql(u8, key, "a")) {
                if (value) |v| {
                    if (mem.eql(u8, v, "yuh")) {
                        self.a = true;
                        return true;
                    }
                }
            }

            return false;
        }
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--a=yuh",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expect(data.a);
}

test "parse: compatibility renamed" {
    const testing = std.testing;

    var data: struct {
        a: bool = false,
        b: bool = false,
        _arena: ?ArenaAllocator = null,

        pub const compatibility: std.StaticStringMap(
            CompatibilityHandler(@This()),
        ) = .initComptime(&.{
            .{ "old", compatibilityRenamed(@This(), "a") },
        });
    } = .{};
    defer if (data._arena) |arena| arena.deinit();

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--old=true --b=true",
    );
    defer iter.deinit();
    try parse(@TypeOf(data), testing.allocator, &data, &iter);
    try testing.expect(data._arena != null);
    try testing.expect(data.a);
    try testing.expect(data.b);
}

test "parseIntoField: ignore underscore-prefixed fields" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        _a: []const u8 = "12",
    } = .{};

    try testing.expectError(
        error.InvalidField,
        parseIntoField(@TypeOf(data), alloc, &data, "_a", "42"),
    );
    try testing.expectEqualStrings("12", data._a);
}

test "parseIntoField: struct with init func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            v: []const u8,

            pub fn init(self: *Self, _alloc: Allocator) !void {
                _ = _alloc;
                self.* = .{ .v = "HELLO!" };
            }
        },
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}

test "parseIntoField: string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: []const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
}

test "parseIntoField: sentinel string" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: [:0]const u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqualStrings("42", data.a);
    try testing.expectEqual(@as(u8, 0), data.a[data.a.len]);
}

test "parseIntoField: bool" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: bool,
    } = undefined;

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "t");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "T");
    try testing.expectEqual(true, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "true");
    try testing.expectEqual(true, data.a);

    // False
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "0");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "f");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "F");
    try testing.expectEqual(false, data.a);
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "false");
    try testing.expectEqual(false, data.a);
}

test "parseIntoField: unsigned numbers" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        u8: u8,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "u8", "1");
    try testing.expectEqual(@as(u8, 1), data.u8);
}

test "parseIntoField: floats" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        f64: f64,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "f64", "1");
    try testing.expectEqual(@as(f64, 1.0), data.f64);
}

test "parseIntoField: enums" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Enum = enum { one, two, three };
    var data: struct {
        v: Enum,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "two");
    try testing.expectEqual(Enum.two, data.v);
}

test "parseIntoField: packed struct" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "b");
    try testing.expect(!data.v.a);
    try testing.expect(data.v.b);
}

test "parseIntoField: packed struct negation" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "a,no-b");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}

test "parseIntoField: packed struct true/false" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "true");
    try testing.expect(data.v.a);
    try testing.expect(data.v.b);

    try parseIntoField(@TypeOf(data), alloc, &data, "v", "false");
    try testing.expect(!data.v.a);
    try testing.expect(!data.v.b);

    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "v", "true,a"),
    );
}

test "parseIntoField: packed struct whitespace" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Field = packed struct {
        a: bool = false,
        b: bool = true,
    };
    var data: struct {
        v: Field,
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "v", " a, no-b ");
    try testing.expect(data.v.a);
    try testing.expect(!data.v.b);
}

test "parseIntoField: optional field" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: ?bool = null,
    } = .{};

    // True
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "1");
    try testing.expectEqual(true, data.a.?);

    // Unset
    try parseIntoField(@TypeOf(data), alloc, &data, "a", "");
    try testing.expect(data.a == null);
}

test "parseIntoField: struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: struct {
            const Self = @This();

            v: []const u8,

            pub fn parseCLI(value: ?[]const u8) !Self {
                _ = value;
                return Self{ .v = "HELLO!" };
            }
        },
    } = undefined;

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.v);
}

test "parseIntoField: optional struct with parse func" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        a: ?struct {
            const Self = @This();

            v: []const u8,

            pub fn parseCLI(self: *Self, _: Allocator, value: ?[]const u8) !void {
                _ = value;
                self.* = .{ .v = "HELLO!" };
            }
        } = null,
    } = .{};

    try parseIntoField(@TypeOf(data), alloc, &data, "a", "42");
    try testing.expectEqual(@as([]const u8, "HELLO!"), data.a.?.v);
}

test "parseIntoField: struct with basic fields" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        value: struct {
            a: []const u8,
            b: u32,
            c: u8 = 12,
        } = undefined,
    } = .{};

    // Set required fields
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello,b:42");
    try testing.expectEqualStrings("hello", data.value.a);
    try testing.expectEqual(42, data.value.b);
    try testing.expectEqual(12, data.value.c);

    // Set all fields
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:world,b:84,c:24");
    try testing.expectEqualStrings("world", data.value.a);
    try testing.expectEqual(84, data.value.b);
    try testing.expectEqual(24, data.value.c);

    // Missing require dfield
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello"),
    );
}

test "parseIntoField: tagged union" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
            c: void,
            d: []const u8,
            e: [:0]const u8,
        } = undefined,
    } = .{};

    // Set one field
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "a:1");
    try testing.expectEqual(1, data.value.a);

    // Set another
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "b:2");
    try testing.expectEqual(2, data.value.b);

    // Set void field
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "c");
    try testing.expectEqual({}, data.value.c);

    // Set string field
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "d:hello");
    try testing.expectEqualStrings("hello", data.value.d);

    // Set sentinel string field
    try parseIntoField(@TypeOf(data), alloc, &data, "value", "e:hello");
    try testing.expectEqualStrings("hello", data.value.e);
}

test "parseIntoField: tagged union unknown filed" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};

    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "c:1"),
    );
}

test "parseIntoField: tagged union invalid field value" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};

    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a:hello"),
    );
}

test "parseIntoField: tagged union missing tag" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var data: struct {
        value: union(enum) {
            a: u8,
            b: u8,
        } = undefined,
    } = .{};

    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", "a"),
    );
    try testing.expectError(
        error.InvalidValue,
        parseIntoField(@TypeOf(data), alloc, &data, "value", ":a"),
    );
}

/// An iterator that considers its location to be CLI args. It
/// iterates through an underlying iterator and increments a counter
/// to track the current CLI arg index.
///
/// This also ignores any argument that starts with `+`. It assumes that
/// actions were parsed out before this iterator was created.
pub fn ArgsIterator(comptime Iterator: type) type {
    return struct {
        const Self = @This();

        /// The underlying args iterator.
        iterator: Iterator,

        /// Our current index into the iterator. This is 1-indexed.
        /// The 0 value is used to indicate that we haven't read any
        /// values yet.
        index: usize = 0,

        pub fn deinit(self: *Self) void {
            if (@hasDecl(Iterator, "deinit")) {
                self.iterator.deinit();
            }
        }

        pub fn next(self: *Self) ?[]const u8 {
            const value = self.iterator.next() orelse return null;
            self.index += 1;

            // We ignore any argument that starts with "+". This is used
            // to indicate actions and are expected to be parsed out before
            // this iterator is created.
            if (value.len > 0 and value[0] == '+') return self.next();

            return value;
        }

        /// Returns a location for a diagnostic message.
        pub fn location(self: *const Self, _: Allocator) error{}!?diags.Location {
            return .{ .cli = self.index };
        }
    };
}

/// Create an args iterator for the process args. This will skip argv0.
pub fn argsIterator(alloc_gpa: Allocator) internal_os.args.ArgIterator.InitError!ArgsIterator(internal_os.args.ArgIterator) {
    var iter = try internal_os.args.iterator(alloc_gpa);
    errdefer iter.deinit();
    _ = iter.next(); // skip argv0
    return .{ .iterator = iter };
}

test "ArgsIterator" {
    const testing = std.testing;

    const child = try std.process.ArgIteratorGeneral(.{}).init(
        testing.allocator,
        "--what +list-things --a=42",
    );
    const Iter = ArgsIterator(@TypeOf(child));
    var iter: Iter = .{ .iterator = child };
    defer iter.deinit();

    try testing.expectEqualStrings("--what", iter.next().?);
    try testing.expectEqualStrings("--a=42", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

/// Returns an iterator (implements "next") that reads CLI args by line.
/// Each CLI arg is expected to be a single line. This is used to implement
/// configuration files.
pub fn LineIterator(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        /// The maximum size a single line can be. We don't expect any
        /// CLI arg to exceed this size. Can't wait to git blame this in
        /// like 4 years and be wrong about this.
        pub const MAX_LINE_SIZE = 4096;

        /// Our stateful reader.
        r: ReaderType,

        /// Filepath that is used for diagnostics. This is only used for
        /// diagnostic messages so it can be formatted however you want.
        /// It is prefixed to the messages followed by the line number.
        filepath: []const u8 = "",

        /// The current line that we're on. This is 1-indexed because
        /// lines are generally 1-indexed in the real world. The value
        /// can be zero if we haven't read any lines yet.
        line: usize = 0,

        /// This is the buffer where we store the current entry that
        /// is formatted to be compatible with the parse function.
        entry: [MAX_LINE_SIZE]u8 = [_]u8{ '-', '-' } ++ ([_]u8{0} ** (MAX_LINE_SIZE - 2)),

        pub fn next(self: *Self) ?[]const u8 {
            // TODO: detect "--" prefixed lines and give a friendlier error
            const buf = buf: {
                while (true) {
                    // Read the full line
                    var entry = self.r.readUntilDelimiterOrEof(self.entry[2..], '\n') catch |err| switch (err) {
                        inline else => |e| {
                            log.warn("cannot read from \"{s}\": {}", .{ self.filepath, e });
                            return null;
                        },
                    } orelse return null;

                    // Increment our line counter
                    self.line += 1;

                    // Trim any whitespace (including CR) around it
                    const trim = std.mem.trim(u8, entry, whitespace ++ "\r");
                    if (trim.len != entry.len) {
                        std.mem.copyForwards(u8, entry, trim);
                        entry = entry[0..trim.len];
                    }

                    // Ignore blank lines and comments
                    if (entry.len == 0 or entry[0] == '#') continue;

                    // Trim spaces around '='
                    if (mem.indexOf(u8, entry, "=")) |idx| {
                        const key = std.mem.trim(u8, entry[0..idx], whitespace);
                        const value = value: {
                            var value = std.mem.trim(u8, entry[idx + 1 ..], whitespace);

                            // Detect a quoted string.
                            if (value.len >= 2 and
                                value[0] == '"' and
                                value[value.len - 1] == '"')
                            {
                                // Trim quotes since our CLI args processor expects
                                // quotes to already be gone.
                                value = value[1 .. value.len - 1];
                            }

                            break :value value;
                        };

                        const len = key.len + value.len + 1;
                        if (entry.len != len) {
                            std.mem.copyForwards(u8, entry, key);
                            entry[key.len] = '=';
                            std.mem.copyForwards(u8, entry[key.len + 1 ..], value);
                            entry = entry[0..len];
                        }
                    }

                    break :buf entry;
                }
            };

            // We need to reslice so that we include our '--' at the beginning
            // of our buffer so that we can trick the CLI parser to treat it
            // as CLI args.
            return self.entry[0 .. buf.len + 2];
        }

        /// Returns a location for a diagnostic message.
        pub fn location(
            self: *const Self,
            alloc: Allocator,
        ) Allocator.Error!?diags.Location {
            // If we have no filepath then we have no location.
            if (self.filepath.len == 0) return null;

            return .{ .file = .{
                .path = try alloc.dupe(u8, self.filepath),
                .line = self.line,
            } };
        }
    };
}

// Constructs a LineIterator (see docs for that).
fn lineIterator(reader: anytype) LineIterator(@TypeOf(reader)) {
    return .{ .r = reader };
}

/// An iterator valid for arg parsing from a slice.
pub const SliceIterator = struct {
    const Self = @This();

    slice: []const []const u8,
    idx: usize = 0,

    pub fn next(self: *Self) ?[]const u8 {
        if (self.idx >= self.slice.len) return null;
        defer self.idx += 1;
        return self.slice[self.idx];
    }
};

/// Construct a SliceIterator from a slice.
pub fn sliceIterator(slice: []const []const u8) SliceIterator {
    return .{ .slice = slice };
}

test "LineIterator" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream(
        \\A
        \\B=42
        \\C
        \\
        \\# A comment
        \\D
        \\
        \\  # An indented comment
        \\  E
        \\
        \\# A quoted string with whitespace
        \\F=  "value "
    );

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=42", iter.next().?);
    try testing.expectEqualStrings("--C", iter.next().?);
    try testing.expectEqualStrings("--D", iter.next().?);
    try testing.expectEqualStrings("--E", iter.next().?);
    try testing.expectEqualStrings("--F=value ", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator end in newline" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A\n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator spaces around '='" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A = B\n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A=B", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator no value" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A = \n\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A=", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "LineIterator with CRLF line endings" {
    const testing = std.testing;
    var fbs = std.io.fixedBufferStream("A\r\nB = C\r\n");

    var iter = lineIterator(fbs.reader());
    try testing.expectEqualStrings("--A", iter.next().?);
    try testing.expectEqualStrings("--B=C", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
