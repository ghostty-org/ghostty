//! Tests that the libghostty-vt C headers and the Zig code that implements
//! them describe the same types.
//!
//! The C headers in `include/ghostty/vt` are written by hand, and so are the
//! Zig `extern` types in `src/terminal/c`. Nothing stops the two from
//! drifting apart, and when they do, C programs read the wrong bytes without
//! any warning. These tests catch that drift at build time.
//!
//! The list of public types comes from `type_decls` in `types.zig`, the same
//! list that produces the `ghostty_type_json()` type manifest. For every
//! type in that list, the test finds the C type with the same name and
//! checks that:
//!
//!   - structs and unions have the same size, alignment, and fields, with
//!     each field at the same position, offset, and size.
//!   - enums have the same values in both directions, plus the `_MAX_VALUE`
//!     sentinel that every C enum ends with.
//!   - packed structs and aliases are the same integer type.
//!   - opaque handles are pointers to an incomplete C struct.
//!
//! A second test runs the other way and checks that every struct, union,
//! enum, and opaque handle in the headers is in `type_decls`. Adding a type
//! to a header without registering it fails the build, so new types are
//! always covered.
//!
//! Each failure is logged on its own line and names both sides, so one run
//! reports every mismatch. For example, changing `GHOSTTY_CELL_WIDE_WIDE`
//! from 1 to 5 in the header logs:
//!
//! ```
//! GHOSTTY_CELL_WIDE_WIDE: the header says 5, Zig says 1
//! ```
//!
//! Run these tests with:
//!
//! ```
//! zig build test-lib-vt -Dtest-filter="C header"
//! ```
//!
//! The headers are translated into Zig by translate-c and imported as
//! `ghostty/vt.h`. Only the C ABI test module has that import (see
//! `GhosttyZig.initVtCTest`), so this file must only be referenced from a
//! `test` block.
const std = @import("std");
const types = @import("types.zig");
const TypeDecl = types.TypeDecl;

const c = @import("ghostty/vt.h");

/// A C enum and the names of its enumerators.
const CEnum = struct {
    name: []const u8,
    enumerators: []const []const u8,
};

/// Every enum in the headers.
///
/// translate-c does not produce Zig enums. The header enums are anonymous
/// typedefs, and translate-c turns each one into a constant per enumerator
/// followed by an integer type for the typedef:
///
/// ```c
/// typedef enum {
///   GHOSTTY_CELL_WIDE_NARROW = 0,
///   GHOSTTY_CELL_WIDE_WIDE = 1,
///   GHOSTTY_CELL_WIDE_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
/// } GhosttyCellWide;
/// ```
///
/// becomes
///
/// ```zig
/// pub const GHOSTTY_CELL_WIDE_NARROW: c_int = 0;
/// pub const GHOSTTY_CELL_WIDE_WIDE: c_int = 1;
/// pub const GHOSTTY_CELL_WIDE_MAX_VALUE: c_int = 2147483647;
/// pub const GhosttyCellWide = c_uint;
/// ```
///
/// Nothing in the output links the constants to the type except their
/// order, so we rebuild each enum from that order: a run of `GHOSTTY_`
/// constants directly followed by a `Ghostty` integer type is one enum.
const c_enums: []const CEnum = enums: {
    @setEvalBranchQuota(1_000_000);
    var result: []const CEnum = &.{};
    var run: []const []const u8 = &.{};
    for (@typeInfo(c).@"struct".decl_names) |name| {
        // Collect names without looking at their values. Some translated
        // macros, such as GHOSTTY_API, are compile errors when used.
        if (std.mem.startsWith(u8, name, "GHOSTTY_")) {
            run = run ++ [_][]const u8{name};
            continue;
        }

        defer run = &.{};
        if (run.len == 0 or !std.mem.startsWith(u8, name, "Ghostty")) continue;
        if (@TypeOf(@field(c, name)) != type) continue;
        const T = @field(c, name);
        if (T != c_uint and T != c_int) continue;
        for (run) |enumerator| {
            if (@TypeOf(@field(c, enumerator)) != c_int) break;
        } else result = result ++ [_]CEnum{.{ .name = name, .enumerators = run }};
    }
    break :enums result;
};

fn findCEnum(comptime name: []const u8) ?CEnum {
    for (c_enums) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

fn findDecl(comptime name: []const u8) ?TypeDecl {
    for (types.type_decls) |decl| if (std.mem.eql(u8, decl.name, name)) return decl;
    return null;
}

test "C headers match Zig ABI types" {
    @setEvalBranchQuota(1_000_000);
    var failures: usize = 0;

    inline for (types.type_decls) |decl| {
        if (comptime !@hasDecl(c, decl.name)) {
            std.log.err("{s}: registered in types.zig but not declared in any header", .{
                decl.name,
            });
            failures += 1;
            continue;
        }

        failures += switch (decl.kind) {
            .@"struct", .@"union" => checkContainer(decl),
            .@"enum" => checkEnum(decl),
            .@"packed" => checkInteger(decl.name, decl.T.Backing, decl.T.Zig),
            .alias => checkInteger(decl.name, decl.T, decl.T),
            .@"opaque" => checkOpaque(decl.name),
        };
    }

    try std.testing.expectEqual(0, failures);
}

test "C header types are all in the type registry" {
    @setEvalBranchQuota(1_000_000);
    var failures: usize = 0;

    inline for (comptime @typeInfo(c).@"struct".decl_names) |name| {
        if (comptime !std.mem.startsWith(u8, name, "Ghostty")) continue;
        if (comptime @TypeOf(@field(c, name)) != type) continue;

        // Callback typedefs and integer typedefs are skipped here. The
        // registry has no kind for callbacks, and an integer typedef cannot
        // be told apart from an enum without the enumerators before it.
        const expected = comptime headerKind(name);
        if (comptime expected) |kind| {
            const found = comptime findDecl(name);
            if (found == null) {
                std.log.err("{s}: a C {t} that is not registered in types.zig", .{
                    name,
                    kind,
                });
                failures += 1;
            } else if (found.?.kind != kind) {
                std.log.err("{s}: a C {t}, but types.zig registers it as {t}", .{
                    name,
                    kind,
                    found.?.kind,
                });
                failures += 1;
            }
        }
    }

    try std.testing.expectEqual(0, failures);
}

/// The kind of a translated header type, or null if it is not a kind that
/// must be registered.
fn headerKind(comptime name: []const u8) ?TypeDecl.Kind {
    if (findCEnum(name) != null) return .@"enum";
    return switch (@typeInfo(@field(c, name))) {
        .@"struct" => |info| if (info.layout == .@"extern") .@"struct" else null,
        .@"union" => |info| if (info.layout == .@"extern") .@"union" else null,
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => |ptr| if (@typeInfo(ptr.child) == .@"opaque") .@"opaque" else null,
            else => null,
        },
        else => null,
    };
}

/// Check a struct or union. Fields are compared by position as well as
/// name, because C code that initializes a struct without designators
/// depends on the field order.
fn checkContainer(comptime decl: TypeDecl) usize {
    const C = @field(c, decl.name);
    const c_names = comptime cFieldNames(decl.kind, C);
    if (c_names == null) {
        std.log.err("{s}: types.zig registers a {t}, but the header declares {s}", .{
            decl.name,
            decl.kind,
            @typeName(C),
        });
        return 1;
    }
    const c_fields = comptime c_names.?;

    var failures: usize = checkSizeAlign(decl.name, C, decl.T);
    const zig_fields = comptime decl.fields();
    if (zig_fields.len != c_fields.len) {
        std.log.err("{s}: the header has {d} fields, Zig has {d}", .{
            decl.name,
            c_fields.len,
            zig_fields.len,
        });
        failures += 1;
    }

    inline for (zig_fields, 0..) |field, i| {
        if (comptime i >= c_fields.len) break;
        const c_name = c_fields[i];
        if (comptime !std.mem.eql(u8, field.name, c_name)) {
            std.log.err("{s}: field {d} is {s} in the header, {s} in Zig", .{
                decl.name,
                i,
                c_name,
                field.name,
            });
            failures += 1;
            continue;
        }

        const c_offset = if (decl.kind == .@"union") 0 else @offsetOf(C, c_name);
        const c_size = @sizeOf(@FieldType(C, c_name));
        if (field.offset != c_offset or @sizeOf(field.T) != c_size) {
            std.log.err(
                "{s}.{s}: the header has offset {d} and size {d}, Zig has offset {d} and size {d}",
                .{ decl.name, field.name, c_offset, c_size, field.offset, @sizeOf(field.T) },
            );
            failures += 1;
        }
    }

    return failures;
}

fn cFieldNames(comptime kind: TypeDecl.Kind, comptime C: type) ?[]const [:0]const u8 {
    return switch (@typeInfo(C)) {
        .@"struct" => |info| if (kind == .@"struct") info.field_names else null,
        .@"union" => |info| if (kind == .@"union") info.field_names else null,
        else => null,
    };
}

/// Check an enum in both directions: every Zig value must be in the header
/// with the same number, and every header enumerator must be a Zig value.
/// Exhaustive and non-exhaustive Zig enums are both accepted.
fn checkEnum(comptime decl: TypeDecl) usize {
    const c_enum = comptime findCEnum(decl.name) orelse {
        std.log.err("{s}: types.zig registers an enum, but the header has no such enum", .{
            decl.name,
        });
        return 1;
    };

    // Some Zig enums are narrower than a C int to save space in Zig
    // structs, such as `sgr.Attribute.Underline`, which is a u3. Those
    // enums declare the type they cross the C ABI as, `pub const C = c_int`,
    // and that is the type whose layout must match the header.
    const info = @typeInfo(decl.T).@"enum";
    const Abi = if (@hasDecl(decl.T, "C")) decl.T.C else decl.T;
    var failures: usize = checkSizeAlign(decl.name, @field(c, decl.name), Abi);

    inline for (info.field_names, info.field_values) |zig_name, value| {
        const c_name = comptime decl.prefix ++ TypeDecl.enumValueName(decl.name, zig_name);
        if (comptime !hasEnumerator(c_enum, c_name)) {
            std.log.err("{s}: the header has no enumerator for Zig value .{s}", .{
                c_name,
                zig_name,
            });
            failures += 1;
        } else if (@field(c, c_name) != value) {
            std.log.err("{s}: the header says {d}, Zig says {d}", .{
                c_name,
                @field(c, c_name),
                value,
            });
            failures += 1;
        }
    }

    const sentinel = comptime decl.prefix ++ decl.sentinel_suffix;
    inline for (c_enum.enumerators) |c_name| {
        if (comptime std.mem.eql(u8, c_name, sentinel)) {
            if (@field(c, c_name) != std.math.maxInt(c_int)) {
                std.log.err("{s}: must be GHOSTTY_ENUM_MAX_VALUE, but is {d}", .{
                    c_name,
                    @field(c, c_name),
                });
                failures += 1;
            }
        } else if (comptime !hasZigValue(decl, c_name)) {
            std.log.err("{s}: in the header, but {s} has no matching value", .{
                c_name,
                @typeName(decl.T),
            });
            failures += 1;
        }
    }

    if (comptime !hasEnumerator(c_enum, sentinel)) {
        std.log.err("{s}: the header is missing the {s} sentinel", .{ decl.name, sentinel });
        failures += 1;
    }

    return failures;
}

fn hasEnumerator(comptime c_enum: CEnum, comptime name: []const u8) bool {
    for (c_enum.enumerators) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

fn hasZigValue(comptime decl: TypeDecl, comptime c_name: []const u8) bool {
    for (@typeInfo(decl.T).@"enum".field_names) |zig_name| {
        const expected = decl.prefix ++ TypeDecl.enumValueName(decl.name, zig_name);
        if (std.mem.eql(u8, expected, c_name)) return true;
    }
    return false;
}

/// Check a type that the header declares as a plain integer typedef, such
/// as `typedef uint16_t GhosttyMode;`. `Int` is the integer the header must
/// use and `Zig` is the Zig type stored in that integer.
fn checkInteger(comptime name: []const u8, comptime Int: type, comptime Zig: type) usize {
    const C = @field(c, name);
    if (C != Int) {
        std.log.err("{s}: the header uses {s}, Zig uses {s}", .{
            name,
            @typeName(C),
            @typeName(Int),
        });
        return 1;
    }
    return checkSizeAlign(name, C, Zig);
}

/// Check an opaque handle, which the header declares as a pointer to a
/// struct it never defines, such as
/// `typedef struct GhosttyTerminalImpl* GhosttyTerminal;`.
fn checkOpaque(comptime name: []const u8) usize {
    const C = @field(c, name);
    const ok = switch (@typeInfo(C)) {
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => |ptr| @typeInfo(ptr.child) == .@"opaque",
            else => false,
        },
        else => false,
    };
    if (!ok) {
        std.log.err("{s}: must be a pointer to an undefined struct, but is {s}", .{
            name,
            @typeName(C),
        });
        return 1;
    }
    return 0;
}

fn checkSizeAlign(comptime name: []const u8, comptime C: type, comptime Zig: type) usize {
    if (@sizeOf(C) == @sizeOf(Zig) and @alignOf(C) == @alignOf(Zig)) return 0;
    std.log.err(
        "{s}: the header has size {d} and alignment {d}, Zig has size {d} and alignment {d}",
        .{ name, @sizeOf(C), @alignOf(C), @sizeOf(Zig), @alignOf(Zig) },
    );
    return 1;
}
