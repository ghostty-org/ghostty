const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const js = @import("main.zig");

// This is the API that must be provided by the host environment. For
// testing we mock it out so that we can test a well-behaved system.
pub usingnamespace if (!builtin.is_test) struct {
    pub extern "zig-js" fn valueGet(out: *u64, id: u32, addr: [*]const u8, len: usize) void;
    pub extern "zig-js" fn valueSet(id: u32, addr: [*]const u8, len: usize, refPtr: *const u64) void;
    pub extern "zig-js" fn valueObjectCreate(out: *u64) void;
    pub extern "zig-js" fn valueStringCreate(out: *u64, addr: [*]const u8, len: usize) void;
    pub extern "zig-js" fn valueStringLen(id: u32) u32;
    pub extern "zig-js" fn valueStringCopy(id: u32, addr: [*]u8, max: usize) void;
    pub extern "zig-js" fn valueDeinit(id: u32) void;
    pub extern "zig-js" fn valueNew(out: *u64, id: u32, argsPtr: [*]const u64, argsLen: usize) void;
    pub extern "zig-js" fn funcApply(
        out: *u64,
        func: u32,
        thisPtr: *const u64,
        argsPtr: [*]const u64,
        argsLen: usize,
    ) void;
} else struct {
    const alloc = std.testing.allocator;

    /// This is what we store in our array list so that we can manage
    /// memory correctly even in tests.
    const StoredValue = union(enum) {
        string: []const u8,
        object: std.StringHashMapUnmanaged(u64),

        pub fn deinit(self: StoredValue) void {
            switch (self) {
                .string => |v| alloc.free(v),
                .object => |v| {
                    var it = v.iterator();
                    while (it.next()) |entry| {
                        alloc.free(entry.key_ptr.*);
                    }

                    // It doesn't matter that we copy this becaus we
                    // should never reuse values.
                    var copy = v;
                    copy.deinit(alloc);
                },
            }
        }
    };

    /// Mimics the JS style values array except we never reuse IDs
    /// since we're testing and don't plan on overflowing 32-bits.
    var values: std.ArrayListUnmanaged(StoredValue) = .{};

    pub fn deinit() void {
        // Note: we don't deinit the value items here so we can test
        // that we deinit properly in our tests.

        values.deinit(alloc);
        values = .{};
    }

    pub fn valueGet(out: *u64, id: u32, addr: [*]const u8, len: usize) void {
        const obj = &values.items[id].object;
        const key = addr[0..len];
        out.* = obj.get(key) orelse @bitCast(js.Ref.null);
    }

    pub fn valueSet(id: u32, addr: [*]const u8, len: usize, ref_ptr: *const u64) void {
        const obj = &values.items[id].object;
        const key = alloc.dupe(u8, addr[0..len]) catch unreachable;
        obj.put(alloc, key, ref_ptr.*) catch unreachable;
    }

    pub fn valueObjectCreate(out: *u64) void {
        values.append(alloc, .{ .object = .{} }) catch unreachable;
        const ref: js.Ref = .{ .type_id = .object, .id = @intCast(values.items.len - 1) };
        out.* = @bitCast(ref);
    }

    pub fn valueStringCreate(out: *u64, addr: [*]const u8, len: usize) void {
        // Copy the value
        const copy = alloc.dupe(u8, addr[0..len]) catch unreachable;

        // Write it
        values.append(alloc, .{ .string = copy }) catch unreachable;

        // Create the ref
        const ref: js.Ref = .{ .type_id = .string, .id = @intCast(values.items.len - 1) };
        out.* = @bitCast(ref);
    }

    pub fn valueStringLen(id: u32) u32 {
        return @intCast(values.items[id].string.len);
    }

    pub fn valueStringCopy(id: u32, addr: [*]u8, max: usize) void {
        @memcpy(addr[0..max], values.items[id].string);
    }

    pub fn valueDeinit(id: u32) void {
        values.items[id].deinit();
    }

    pub fn valueNew(
        out: *u64,
        id: u32,
        argsPtr: [*]const u64,
        argsLen: usize,
    ) void {
        _ = out;
        _ = id;
        _ = argsPtr;
        _ = argsLen;
    }

    pub fn funcApply(
        out: *u64,
        func: u32,
        thisPtr: *const u64,
        argsPtr: [*]const u64,
        argsLen: usize,
    ) void {
        _ = out;
        _ = func;
        _ = thisPtr;
        _ = argsPtr;
        _ = argsLen;
    }
};
