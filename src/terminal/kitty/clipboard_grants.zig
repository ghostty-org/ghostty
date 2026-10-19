//! Kitty clipboard protocol (OSC 5522) session password grants:
//! requests carrying a granted password skip the permission prompt, and
//! paste events mint one-time passwords.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard_command = @import("clipboard_command.zig");
const sys = @import("../sys.zig");

const max_pw_len = clipboard_command.max_pw_len;

/// Session password grants, used to skip permission prompts for
/// requests carrying a known pw. Callers can choose to scope these
/// however they want, e.g. Kitty does it per window and the spec
/// doesn't demand anything.
pub const Grants = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const max_entries = 32;

    pub const Direction = enum { read, write };

    const Entry = struct {
        /// Owned by the allocator passed to grant.
        pw: []const u8,
        read: bool = false,
        write: bool = false,
        one_time: bool = false,
    };

    pub fn deinit(self: *Grants, alloc: Allocator) void {
        for (self.entries.items) |entry| alloc.free(entry.pw);
        self.entries.deinit(alloc);
    }

    /// Record a grant for pw. An existing grant for the same password
    /// gains the new direction.
    pub fn grant(
        self: *Grants,
        alloc: Allocator,
        pw: []const u8,
        dir: Direction,
        one_time: bool,
    ) Allocator.Error!void {
        if (pw.len == 0 or pw.len > max_pw_len) return;

        const entry: *Entry = entry: {
            if (self.findIndex(pw)) |idx| {
                const entry = &self.entries.items[idx];
                entry.one_time = entry.one_time and one_time;
                break :entry entry;
            }

            // Evict the oldest grant once full.
            if (self.entries.items.len >= max_entries) {
                const oldest = self.entries.orderedRemove(0);
                alloc.free(oldest.pw);
            }

            const owned = try alloc.dupe(u8, pw);
            errdefer alloc.free(owned);
            try self.entries.append(alloc, .{
                .pw = owned,
                .one_time = one_time,
            });
            break :entry &self.entries.items[self.entries.items.len - 1];
        };

        switch (dir) {
            .read => entry.read = true,
            .write => entry.write = true,
        }
    }

    /// Check whether pw grants the given direction. A one-time grant is
    /// consumed by this check even when the direction doesn't match,
    /// matching kitty's pop-on-check behavior.
    pub fn use(
        self: *Grants,
        alloc: Allocator,
        pw: []const u8,
        dir: Direction,
    ) bool {
        if (pw.len == 0) return false;
        const idx = self.findIndex(pw) orelse return false;
        const entry = &self.entries.items[idx];
        const allowed = switch (dir) {
            .read => entry.read,
            .write => entry.write,
        };
        if (entry.one_time) {
            const removed = self.entries.swapRemove(idx);
            alloc.free(removed.pw);
        }
        return allowed;
    }

    fn findIndex(self: *const Grants, pw: []const u8) ?usize {
        for (self.entries.items, 0..) |*entry, idx| {
            if (std.mem.eql(u8, entry.pw, pw)) return idx;
        }
        return null;
    }
};

/// The length of a one-time password generated for paste events.
pub const otp_len = 22;

/// The one-time password alphabet. This matches kitty (alphanumeric
/// without easily-confused characters), but the spec doesn't demand
/// this.
pub const otp_alphabet = "23456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ";

/// Generate a one-time password for a paste event.
///
/// The password is a secret: a program that learns it can read the
/// clipboard without a prompt. Entropy comes from `sys.random_secure`
/// if set, otherwise from the Io; see `sys.randomSecure`.
pub fn generateOtp(io: std.Io) std.Io.RandomSecureError![otp_len]u8 {
    var result: [otp_len]u8 = undefined;
    var len: usize = 0;
    while (len < result.len) {
        var raw: [2 * otp_len]u8 = undefined;
        try sys.randomSecure(io, &raw);
        const limit = (std.math.maxInt(u8) + 1) / otp_alphabet.len * otp_alphabet.len;
        for (raw) |byte| {
            if (byte >= limit) continue;
            result[len] = otp_alphabet[byte % otp_alphabet.len];
            len += 1;
            if (len == result.len) break;
        }
    }

    return result;
}

test "grants: basic grant and use" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var grants: Grants = .{};
    defer grants.deinit(alloc);
    try testing.expect(!grants.use(alloc, "pw1", .read));

    try grants.grant(alloc, "pw1", .read, false);
    try testing.expect(grants.use(alloc, "pw1", .read));
    // Persistent grants survive use.
    try testing.expect(grants.use(alloc, "pw1", .read));
    try testing.expect(!grants.use(alloc, "pw1", .write));
}

test "grants: one-time consumed on check" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var grants: Grants = .{};
    defer grants.deinit(alloc);
    try grants.grant(alloc, "otp", .read, true);
    try testing.expect(grants.use(alloc, "otp", .read));
    try testing.expect(!grants.use(alloc, "otp", .read));
}

test "grants: one-time consumed even on direction mismatch" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var grants: Grants = .{};
    defer grants.deinit(alloc);
    try grants.grant(alloc, "otp", .read, true);
    try testing.expect(!grants.use(alloc, "otp", .write));
    try testing.expect(!grants.use(alloc, "otp", .read));
}

test "grants: directions are independent" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var grants: Grants = .{};
    defer grants.deinit(alloc);
    try grants.grant(alloc, "pw", .read, false);
    try grants.grant(alloc, "pw", .write, false);
    try testing.expect(grants.use(alloc, "pw", .read));
    try testing.expect(grants.use(alloc, "pw", .write));
}

test "grants: capacity evicts the oldest" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var grants: Grants = .{};
    defer grants.deinit(alloc);

    var buf: [8]u8 = undefined;
    for (0..Grants.max_entries + 1) |i| {
        const pw = try std.fmt.bufPrint(&buf, "pw{}", .{i});
        try grants.grant(alloc, pw, .read, false);
    }

    // The oldest grant was evicted; the newest survives.
    try testing.expect(!grants.use(alloc, "pw0", .read));
    const newest = try std.fmt.bufPrint(&buf, "pw{}", .{Grants.max_entries});
    try testing.expect(grants.use(alloc, newest, .read));
}

test "generateOtp: length and alphabet with a real Io" {
    const testing = std.testing;

    const otp = try generateOtp(testing.io);
    try testing.expectEqual(otp_len, otp.len);
    for (otp) |c| try testing.expect(std.mem.indexOfScalar(u8, otp_alphabet, c) != null);

    // Two passwords don't collide (a repeat would mean no entropy).
    const other = try generateOtp(testing.io);
    try testing.expect(!std.mem.eql(u8, &otp, &other));
}

test "generateOtp: no entropy is an error, never a weak password" {
    const testing = std.testing;
    try testing.expectError(error.EntropyUnavailable, generateOtp(std.Io.failing));
}

test "generateOtp: sys override supplies entropy without an Io source" {
    const testing = std.testing;
    const S = struct {
        var counter: u8 = 0;
        fn fill(buffer: []u8) sys.RandomSecureError!void {
            for (buffer) |*b| {
                b.* = counter;
                counter +%= 1;
            }
        }
    };
    sys.random_secure = &S.fill;
    defer sys.random_secure = null;

    const otp = try generateOtp(std.Io.failing);
    for (otp) |c| try testing.expect(std.mem.indexOfScalar(u8, otp_alphabet, c) != null);
}
