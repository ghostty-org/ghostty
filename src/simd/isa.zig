const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const x86_64 = @import("x86_64.zig");

/// Raw comptime entry of poissible ISA. The arch is the arch that the
/// ISA is even possible on (e.g. neon is only possible on aarch64) but
/// the actual ISA may not be available at runtime.
const Entry = struct {
    name: [:0]const u8,
    arch: []const std.Target.Cpu.Arch = &.{},
};

const entries: []const Entry = &.{
    .{ .name = "scalar" },
    .{ .name = "neon", .arch = &.{.aarch64} },
    .{ .name = "avx2", .arch = &.{ .x86, .x86_64 } },
};

/// Enum of possible ISAs for our SIMD operations. Note that these are
/// coarse-grained because they match possible implementations rather than
/// a fine-grained packed struct of available CPU features.
pub const ISA = isa: {
    const EnumField = std.builtin.Type.EnumField;
    var fields: [entries.len]EnumField = undefined;
    for (entries, 0..) |entry, i| {
        fields[i] = .{ .name = entry.name, .value = i };
    }

    break :isa @Type(.{ .Enum = .{
        .tag_type = std.math.IntFittingRange(0, entries.len - 1),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// A set of ISAs.
pub const Set = std.EnumSet(ISA);

/// Check if the given ISA is possible on the current target. This is
/// available at comptime to help prevent invalid architectures from
/// being used.
pub fn possible(comptime isa: ISA) bool {
    inline for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, @tagName(isa))) {
            for (entry.arch) |arch| {
                if (arch == builtin.cpu.arch) return true;
            }

            // If we have no valid archs then its always valid.
            return entry.arch.len == 0;
        }
    }

    unreachable;
}

/// Detect all possible ISAs at runtime.
pub fn detect() Set {
    var set: Set = .{};
    set.insert(.scalar);
    switch (builtin.cpu.arch) {
        // Neon is mandatory on aarch64. No runtime checks necessary.
        .aarch64 => set.insert(.neon),
        .x86_64 => detectX86(&set),
        else => {},
    }

    return set;
}

/// Returns the preferred ISA to use that is available.
pub fn preferred(set: Set) ISA {
    const order: []const ISA = &.{ .avx2, .neon, .scalar };

    // We should have all of our ISAs present in order
    comptime {
        for (@typeInfo(ISA).Enum.fields) |field| {
            const v = @field(ISA, field.name);
            assert(std.mem.indexOfScalar(ISA, order, v) != null);
        }
    }

    inline for (order) |isa| {
        if (comptime possible(isa)) {
            if (set.contains(isa)) return isa;
        }
    }

    return .scalar;
}

fn detectX86(set: *Set) void {
    // NOTE: this is just some boilerplate to detect AVX2. We
    // can probably support earlier forms of SIMD such as plain
    // SSE, and we can definitely take advtange of later forms. This
    // is just some boilerplate to ONLY detect AVX2 right now.

    // If we support less than 7 for the maximum leaf level then we
    // don't support any AVX instructions.
    var leaf = x86_64.cpuid(0, 0);
    if (leaf.eax < 7) return;

    // If we don't have xsave or avx, then we don't support anything.
    leaf = x86_64.cpuid(1, 0);
    const has_xsave = hasBit(leaf.ecx, 27);
    const has_avx = hasBit(leaf.ecx, 28);
    if (!has_xsave or !has_avx) return;

    // We require AVX save state in order to use AVX instructions.
    const xcr0_eax = x86_64.getXCR0(); // requires xsave+avx
    const has_avx_save = hasMask(xcr0_eax, x86_64.XCR0_XMM | x86_64.XCR0_YMM);
    if (!has_avx_save) return;

    // Check for AVX2.
    leaf = x86_64.cpuid(7, 0);
    const has_avx2 = hasBit(leaf.ebx, 5);
    if (has_avx2) set.insert(.avx2);
}

/// Check if a bit is set at the given offset
inline fn hasBit(input: u32, offset: u5) bool {
    return (input >> offset) & 1 != 0;
}

/// Checks if a mask exactly matches the input
inline fn hasMask(input: u32, mask: u32) bool {
    return (input & mask) == mask;
}

/// This is a helper to provide a runtime lookup map for the ISA to
/// the proper function implementation. Func is the function type,
/// and map is an array of tuples of the form (ISA, Struct) where
/// Struct has a decl named `name` that is a Func.
///
/// The slightly awkward parameters are to ensure that functions
/// are only analyzed for possible ISAs for the target.
///
/// This will ensure that impossible ISAs for the build target are
/// not included so they're not analyzed. For example, a NEON implementation
/// will not be included on x86_64.
pub fn funcMap(
    comptime Func: type,
    comptime name: []const u8,
    v: ISA,
    comptime map: anytype,
) *const Func {
    switch (v) {
        inline else => |tag| {
            // If this tag isn't possible, compile no code for this case.
            if (comptime !possible(tag)) unreachable;

            // Find the entry for this tag and return the function.
            inline for (map) |entry| {
                if (entry[0] == tag) return @field(entry[1], name);
            } else unreachable;
        },
    }
}

test "detect" {
    const testing = std.testing;
    const set = detect();
    try testing.expect(set.contains(.scalar));

    switch (builtin.cpu.arch) {
        .aarch64 => {
            // Neon is always available on aarch64
            try testing.expect(set.contains(.neon));
            try testing.expect(!set.contains(.avx2));
        },

        else => {},
    }
}

test "preferred" {
    _ = preferred(detect());
}

test "possible" {
    const testing = std.testing;
    try testing.expect(possible(.scalar)); // always possible

    // hardcode some other common realities
    switch (builtin.cpu.arch) {
        .aarch64 => {
            try testing.expect(possible(.neon));
            try testing.expect(!possible(.avx2));
        },

        .x86, .x86_64 => {
            try testing.expect(!possible(.neon));
            try testing.expect(possible(.avx2));
        },

        else => {},
    }
}
