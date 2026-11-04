const std = @import("std");
const testing = std.testing;
const Target = @import("target.zig").Target;

/// Create a struct type that is C ABI compatible from a Zig struct type.
///
/// When the target is `.zig`, the original struct type is returned as-is.
/// When the target is `.c`, the struct is recreated with an `extern` layout,
/// ensuring a stable, C-compatible memory layout.
///
/// This handles packed structs by resolving zero alignments to the natural
/// alignment of each field's type, since extern structs require explicit
/// alignment. This means packed struct fields like `bool` will take up
/// their full size (1 byte) rather than being bit-packed.
pub fn Struct(
    comptime target: Target,
    comptime Zig: type,
) type {
    return switch (target) {
        .zig => Zig,
        .c => c: {
            const info = @typeInfo(Zig).@"struct";
            var names: [info.field_names.len][]const u8 = undefined;
            var types: [info.field_names.len]type = undefined;
            var attrs: [info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;

            inline for (info.field_names, info.field_types, info.field_attrs, &names, &types, &attrs) |field_name, field_type, field_attr, *name, *ty, *attr| {
                name.* = field_name;
                ty.* = field_type;
                attr.* = field_attr;
            }

            break :c @Struct(.@"extern", null, &names, &types, &attrs);
        },
    };
}

/// Which side of the C API fills a sized struct.
pub const SizedDirection = enum {
    /// The caller fills the struct and the library reads it.
    input,

    /// The caller passes the struct and the library fills it.
    output,
};

/// Check the `size` field of a sized struct from C. Call this before
/// reading or writing any other field. Returns false if the struct must
/// be rejected, which callers usually report as `.invalid_value`.
///
/// A sized struct is an `extern struct` whose first field is
/// `size: usize`. C callers set `size` to the `sizeof` of the struct in
/// the header they were compiled against, so the library can tell which
/// fields the caller actually has. The struct declares the last field of
/// its first released layout, called the base layout:
///
/// ```zig
/// pub const Options = extern struct {
///     size: usize = @sizeOf(Options),
///     ref: CGridRef,
///     wrap: bool = false,
///
///     pub const sized_base = "wrap";
/// };
/// ```
///
/// The rule follows the one used by Linux `openat2` and libbpf:
///
///   - A `size` smaller than the base layout is always rejected. Every
///     caller has at least the base fields.
///   - For an input, the caller may be newer and pass more bytes than
///     `@sizeOf(T)`. Those extra bytes are fields this library does not
///     know about. They are accepted only if they are all zero, because
///     zero always means the default behavior. A non-zero byte asks for
///     something this library cannot do, so the struct is rejected.
///   - For an output, any `size` at or above the base layout is
///     accepted. The library writes only the fields that fit and never
///     touches bytes after `@sizeOf(T)`.
///
/// After the check, use `sizedField` to read input fields and `sizedSet`
/// or `sizedWrite` to write output fields. They skip any field that does
/// not fit in the caller's `size`. Never read or assign the whole struct,
/// because the caller's struct may be smaller than ours:
///
/// ```zig
/// const opts = options orelse return .invalid_value;
/// if (!lib.sizedCheck(.input, opts)) return .invalid_value;
/// const wrap = lib.sizedField(opts, "wrap");
/// ```
///
/// New fields go at the end of the struct and must start at or after
/// the previous version's `@sizeOf`, never in its trailing padding. C
/// does not promise to zero padding, so this check cannot tell a field
/// placed there from leftover bytes. The comptime checks enforce this for
/// the base layout. Each later version must follow the same rule against
/// the version before it.
pub fn sizedCheck(
    comptime direction: SizedDirection,
    ptr: anytype,
) bool {
    const T = SizedChild(@TypeOf(ptr));
    const size = ptr.size;
    if (size < sizedBaseEnd(T)) return false;
    switch (direction) {
        .output => {},
        .input => if (size > @sizeOf(T)) {
            const bytes: [*]const u8 = @ptrCast(ptr);
            for (bytes[@sizeOf(T)..size]) |b| if (b != 0) return false;
        },
    }

    return true;
}

/// Read field `name` of an input struct that passed `sizedCheck`. If the
/// caller's struct is too small to have the field, returns zero, which is
/// the field's default.
pub fn sizedField(
    ptr: anytype,
    comptime name: []const u8,
) @FieldType(SizedChild(@TypeOf(ptr)), name) {
    const T = SizedChild(@TypeOf(ptr));
    if (!sizedFieldFits(T, ptr.size, name)) return std.mem.zeroes(@FieldType(T, name));
    return @field(ptr, name);
}

/// Write field `name` of an output struct that passed `sizedCheck`. Does
/// nothing if the caller's struct is too small to have the field.
pub fn sizedSet(
    ptr: anytype,
    comptime name: []const u8,
    value: @FieldType(SizedChild(@TypeOf(ptr)), name),
) void {
    const T = SizedChild(@TypeOf(ptr));
    comptime std.debug.assert(!std.mem.eql(u8, name, "size"));
    if (sizedFieldFits(T, ptr.size, name)) @field(ptr, name) = value;
}

/// Write every field of `value` except `size` into an output struct that
/// passed `sizedCheck`. Fields that do not fit in the caller's struct are
/// skipped, and `size` keeps the caller's value.
pub fn sizedWrite(
    ptr: anytype,
    value: SizedChild(@TypeOf(ptr)),
) void {
    const T = SizedChild(@TypeOf(ptr));
    inline for (@typeInfo(T).@"struct".field_names[1..]) |name| {
        sizedSet(ptr, name, @field(value, name));
    }
}

/// Returns true if a struct of type `T` with size `size` can hold
/// field `field`.
pub fn sizedFieldFits(
    comptime T: type,
    size: usize,
    comptime field: []const u8,
) bool {
    const offset = @offsetOf(T, field);
    const field_size = @sizeOf(@FieldType(T, field));
    return size >= offset + field_size;
}

/// The smallest `size` that `sizedCheck` accepts for `T`: the offset just
/// past its `sized_base` field.
pub fn sizedBaseEnd(comptime T: type) usize {
    comptime validateSized(T);
    return @offsetOf(T, T.sized_base) + @sizeOf(@FieldType(T, T.sized_base));
}

/// The struct type behind a pointer to a sized struct.
fn SizedChild(comptime Ptr: type) type {
    const T = switch (@typeInfo(Ptr)) {
        .pointer => |p| p.child,
        else => @compileError("sized struct helpers take a pointer, got " ++ @typeName(Ptr)),
    };
    comptime validateSized(T);
    return T;
}

/// Fail compilation unless `T` is a well-formed sized struct: extern,
/// starting with `size: usize`, with a `sized_base` that names a field,
/// and with no later field inside the base layout's trailing padding.
fn validateSized(comptime T: type) void {
    const info = @typeInfo(T).@"struct";
    if (info.layout != .@"extern") {
        @compileError(@typeName(T) ++ " is a sized struct and must be extern");
    }
    if (!std.mem.eql(u8, info.field_names[0], "size") or info.field_types[0] != usize) {
        @compileError(@typeName(T) ++ " is a sized struct and must start with size: usize");
    }
    if (!@hasDecl(T, "sized_base")) {
        @compileError(@typeName(T) ++ " must declare its base layout as `pub const sized_base = \"<last field>\";`");
    }

    // Fields after the base must start past the base layout's @sizeOf,
    // which is its end rounded up to the alignment of its fields.
    var base_align: usize = 1;
    var past_base = false;
    for (info.field_names, info.field_types) |name, FieldT| {
        if (past_base) {
            const base_size = std.mem.alignForward(
                usize,
                @offsetOf(T, T.sized_base) + @sizeOf(@FieldType(T, T.sized_base)),
                base_align,
            );
            if (@offsetOf(T, name) < base_size) {
                @compileError(@typeName(T) ++ "." ++ name ++ " is placed in the padding of the base layout");
            }
        } else {
            base_align = @max(base_align, @alignOf(FieldT));
            if (std.mem.eql(u8, name, T.sized_base)) past_base = true;
        }
    }
    if (!past_base) {
        @compileError(@typeName(T) ++ ".sized_base names no field");
    }
}

test "sizedFieldFits boundary checks" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };

    const size_required = @offsetOf(Sized, "size") + @sizeOf(@FieldType(Sized, "size"));
    const a_required = @offsetOf(Sized, "a") + @sizeOf(@FieldType(Sized, "a"));
    const b_required = @offsetOf(Sized, "b") + @sizeOf(@FieldType(Sized, "b"));

    try testing.expect(sizedFieldFits(Sized, size_required, "size"));
    try testing.expect(!sizedFieldFits(Sized, size_required - 1, "size"));

    try testing.expect(sizedFieldFits(Sized, a_required, "a"));
    try testing.expect(!sizedFieldFits(Sized, a_required - 1, "a"));

    try testing.expect(sizedFieldFits(Sized, b_required, "b"));
    try testing.expect(!sizedFieldFits(Sized, b_required - 1, "b"));
}

test "sizedFieldFits respects alignment padding" {
    const Sized = extern struct {
        size: usize,
        a: u8,
        b: u32,
    };

    const up_to_padding = @offsetOf(Sized, "b");
    try testing.expect(sizedFieldFits(Sized, up_to_padding, "a"));
    try testing.expect(!sizedFieldFits(Sized, up_to_padding, "b"));
}

/// A sized struct as a 1.0 library sees it, and the same struct as a
/// later library that appended `c` sees it.
const SizedV1 = extern struct {
    size: usize = @sizeOf(SizedV1),
    a: u32 = 0,
    b: u8 = 0,

    pub const sized_base = "b";
};

const SizedV2 = extern struct {
    size: usize = @sizeOf(SizedV2),
    a: u32 = 0,
    b: u8 = 0,
    c: u64 = 0,

    pub const sized_base = "b";
};

test "sizedCheck boundaries" {
    const base_end = @offsetOf(SizedV1, "b") + 1;
    try testing.expectEqual(base_end, sizedBaseEnd(SizedV1));
    try testing.expectEqual(base_end, sizedBaseEnd(SizedV2));
    try testing.expect(base_end < @sizeOf(SizedV1));

    // Room for a caller whose struct is larger than ours.
    var buf: [@sizeOf(SizedV2) + 8]u8 align(@alignOf(SizedV2)) = @splat(0);
    const v1: *SizedV1 = @ptrCast(&buf);
    v1.* = .{ .a = 7, .b = 9 };

    // One byte below the base end.
    v1.size = base_end - 1;
    try testing.expect(!sizedCheck(.input, v1));
    try testing.expect(!sizedCheck(.output, v1));

    // Exactly the base end, and our own size.
    inline for (.{ base_end, @sizeOf(SizedV1) }) |size| {
        v1.size = size;
        try testing.expect(sizedCheck(.input, v1));
        try testing.expect(sizedCheck(.output, v1));
    }

    // One byte above @sizeOf with a zero tail.
    v1.size = @sizeOf(SizedV1) + 1;
    try testing.expect(sizedCheck(.input, v1));
    try testing.expect(sizedCheck(.output, v1));

    // One byte above @sizeOf with a non-zero tail: inputs only.
    buf[@sizeOf(SizedV1)] = 1;
    try testing.expect(!sizedCheck(.input, v1));
    try testing.expect(sizedCheck(.output, v1));

    // The same for the last tail byte of a much larger caller.
    buf[@sizeOf(SizedV1)] = 0;
    v1.size = buf.len;
    try testing.expect(sizedCheck(.input, v1));
    buf[buf.len - 1] = 1;
    try testing.expect(!sizedCheck(.input, v1));
    try testing.expect(sizedCheck(.output, v1));
}

test "sizedField reads fields past the caller's size as zero" {
    // An older caller hands a newer library a struct without c.
    var buf: [@sizeOf(SizedV2)]u8 align(@alignOf(SizedV2)) = @splat(0xaa);
    const v2: *SizedV2 = @ptrCast(&buf);
    v2.size = @sizeOf(SizedV1);
    v2.a = 7;
    v2.b = 9;
    try testing.expect(sizedCheck(.input, v2));
    try testing.expectEqual(@as(u32, 7), sizedField(v2, "a"));
    try testing.expectEqual(@as(u8, 9), sizedField(v2, "b"));
    try testing.expectEqual(@as(u64, 0), sizedField(v2, "c"));

    v2.size = @sizeOf(SizedV2);
    v2.c = 3;
    try testing.expectEqual(@as(u64, 3), sizedField(v2, "c"));
}

test "sizedWrite skips fields past the caller's size" {
    // An older caller hands a newer library a struct without c. The
    // bytes past the caller's size must stay as they were.
    var buf: [@sizeOf(SizedV2)]u8 align(@alignOf(SizedV2)) = @splat(0xaa);
    const v2: *SizedV2 = @ptrCast(&buf);
    v2.size = @sizeOf(SizedV1);
    try testing.expect(sizedCheck(.output, v2));
    sizedWrite(v2, .{ .size = 0, .a = 7, .b = 9, .c = 3 });
    try testing.expectEqual(@as(usize, @sizeOf(SizedV1)), v2.size);
    try testing.expectEqual(@as(u32, 7), v2.a);
    try testing.expectEqual(@as(u8, 9), v2.b);
    for (buf[@sizeOf(SizedV1)..]) |b| try testing.expectEqual(@as(u8, 0xaa), b);

    // A newer caller hands an older library a larger struct. The
    // library writes its own fields and leaves the tail alone.
    var big: [@sizeOf(SizedV1) + 8]u8 align(@alignOf(SizedV1)) = @splat(0xaa);
    const v1: *SizedV1 = @ptrCast(&big);
    v1.size = big.len;
    try testing.expect(sizedCheck(.output, v1));
    sizedWrite(v1, .{ .a = 7, .b = 9 });
    try testing.expectEqual(@as(usize, big.len), v1.size);
    try testing.expectEqual(@as(u32, 7), v1.a);
    try testing.expectEqual(@as(u8, 9), v1.b);
    for (big[@sizeOf(SizedV1)..]) |b| try testing.expectEqual(@as(u8, 0xaa), b);
}

test "packed struct converts to extern with full-size bools" {
    const Packed = packed struct {
        flag1: bool,
        flag2: bool,
        value: u8,
    };

    const C = Struct(.c, Packed);
    const info = @typeInfo(C).@"struct";

    try testing.expectEqual(.@"extern", info.layout);
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag1")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag2")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "value")));
    try testing.expectEqual(@as(usize, 3), @sizeOf(C));
}
