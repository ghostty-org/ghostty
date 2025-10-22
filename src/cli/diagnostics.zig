const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");

/// A diagnostic message from parsing. This is used to provide additional
/// human-friendly warnings and errors about the parsed data.
///
/// All of the memory for the diagnostic is allocated from the arena
/// associated with the config structure. If an arena isn't available
/// then diagnostics are not supported.
pub const Diagnostic = struct {
    location: Location = .none,
    key: [:0]const u8 = "",
    message: [:0]const u8,

    /// Write the full user-friendly diagnostic message to the writer.
    pub fn format(self: *const Diagnostic, writer: *std.Io.Writer) !void {
        switch (self.location) {
            .none => {},
            .cli => |index| try writer.print("cli:{}:", .{index}),
            .file => |file| try writer.print(
                "{s}:{}:",
                .{ file.path, file.line },
            ),
        }

        if (self.key.len > 0) {
            try writer.print("{s}: ", .{self.key});
        } else if (self.location != .none) {
            try writer.print(" ", .{});
        }

        try writer.print("{s}", .{self.message});
    }

    pub fn clone(self: *const Diagnostic, alloc: Allocator) Allocator.Error!Diagnostic {
        return .{
            .location = try self.location.clone(alloc),
            .key = try alloc.dupeZ(u8, self.key),
            .message = try alloc.dupeZ(u8, self.message),
        };
    }
};

/// The possible locations for a diagnostic message. This is used
/// to provide context for the message.
pub const Location = union(enum) {
    none,
    cli: usize,
    file: struct {
        path: []const u8,
        line: usize,
    },

    pub const Key = @typeInfo(Location).@"union".tag_type.?;

    pub fn fromIter(iter: anytype, alloc: Allocator) Allocator.Error!Location {
        const Iter = t: {
            const T = @TypeOf(iter);
            break :t switch (@typeInfo(T)) {
                .pointer => |v| v.child,
                .@"struct" => T,
                else => return .none,
            };
        };

        if (!@hasDecl(Iter, "location")) return .none;
        return (try iter.location(alloc)) orelse .none;
    }

    pub fn clone(self: *const Location, alloc: Allocator) Allocator.Error!Location {
        return switch (self.*) {
            .none,
            .cli,
            => self.*,

            .file => |v| .{ .file = .{
                .path = try alloc.dupe(u8, v.path),
                .line = v.line,
            } },
        };
    }
};

/// A list of diagnostics. The "_diagnostics" field must be this type
/// for diagnostics to be supported. If this field is an incorrect type
/// a compile-time error will be raised.
///
/// This is implemented as a simple wrapper around an array list
/// so that we can inject some logic around adding diagnostics
/// and potentially in the future structure them differently.
pub const DiagnosticList = struct {
    /// The list of diagnostics.
    list: std.ArrayListUnmanaged(Diagnostic) = .{},

    /// Precomputed data for diagnostics. This is used specifically
    /// when we build libghostty so that we can precompute the messages
    /// and return them via the C API without allocating memory at
    /// call time.
    precompute: Precompute = precompute_init,

    const precompute_enabled = switch (build_config.artifact) {
        // We enable precompute for tests so that the logic is
        // semantically analyzed and run.
        .exe, .wasm_module => builtin.is_test,

        // We specifically want precompute for libghostty.
        .lib => true,
    };

    const Precompute = if (precompute_enabled) struct {
        messages: std.ArrayListUnmanaged([:0]const u8) = .{},

        pub fn clone(
            self: *const Precompute,
            alloc: Allocator,
        ) Allocator.Error!Precompute {
            var result: Precompute = .{};
            try result.messages.ensureTotalCapacity(alloc, self.messages.items.len);
            for (self.messages.items) |msg| {
                result.messages.appendAssumeCapacity(
                    try alloc.dupeZ(u8, msg),
                );
            }
            return result;
        }
    } else void;

    const precompute_init: Precompute = if (precompute_enabled) .{} else {};

    pub fn clone(
        self: *const DiagnosticList,
        alloc: Allocator,
    ) Allocator.Error!DiagnosticList {
        var result: DiagnosticList = .{};

        try result.list.ensureTotalCapacity(alloc, self.list.items.len);
        for (self.list.items) |*diag| result.list.appendAssumeCapacity(
            try diag.clone(alloc),
        );

        if (comptime precompute_enabled) {
            result.precompute = try self.precompute.clone(alloc);
        }

        return result;
    }

    pub fn append(
        self: *DiagnosticList,
        alloc: Allocator,
        diag: Diagnostic,
    ) Allocator.Error!void {
        try self.list.append(alloc, diag);
        errdefer _ = self.list.pop();

        if (comptime precompute_enabled) {
            var stream: std.Io.Writer.Allocating = .init(alloc);
            defer stream.deinit();
            diag.format(&stream.writer) catch |err| switch (err) {
                // WriteFailed in this instance can only mean an OOM
                error.WriteFailed => return error.OutOfMemory,
            };

            const owned: [:0]const u8 = try stream.toOwnedSliceSentinel(0);
            errdefer alloc.free(owned);

            try self.precompute.messages.append(alloc, owned);
            errdefer _ = self.precompute.messages.pop();

            assert(self.precompute.messages.items.len == self.list.items.len);
        }
    }

    pub fn empty(self: *const DiagnosticList) bool {
        return self.list.items.len == 0;
    }

    pub fn items(self: *const DiagnosticList) []const Diagnostic {
        return self.list.items;
    }

    /// Returns true if there are any diagnostics for the given
    /// location type.
    pub fn containsLocation(
        self: *const DiagnosticList,
        location: Location.Key,
    ) bool {
        for (self.list.items) |diag| {
            if (diag.location == location) return true;
        }

        return false;
    }
};
