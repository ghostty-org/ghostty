//! Wire adapter for Ghostty's already-resolved local command configuration.
const std = @import("std");
const renderer = @import("../../renderer.zig");

pub const max_initial_input = 10 * 1024 * 1024;
pub const max_runtime_scrollback_bytes = 4 * 1024 * 1024;

pub const ScrollbackLimits = struct {
    max_bytes: usize,
    max_lines: ?usize,
};

/// Session snapshots must stay within the current bounded snapshot transport.
/// Never raise a stricter Ghostty limit when deriving the runtime limit.
pub fn effectiveScrollbackLimits(configured_bytes: ?usize, configured_lines: ?usize) ScrollbackLimits {
    return .{
        .max_bytes = if (configured_bytes) |value|
            @min(value, max_runtime_scrollback_bytes)
        else
            max_runtime_scrollback_bytes,
        .max_lines = configured_lines,
    };
}

/// A daemon must inherit the caller's directory, not the broker's startup cwd.
pub fn workingDirectory(alloc: std.mem.Allocator, io: std.Io, proposed: ?[]const u8) ![:0]u8 {
    const inherited = try std.process.currentPathAlloc(io, alloc);
    errdefer alloc.free(inherited);
    const value = proposed orelse return inherited;
    const candidate = try std.fs.path.resolve(alloc, &.{ inherited, value });
    defer alloc.free(candidate);
    var directory = std.Io.Dir.cwd().openDir(io, candidate, .{}) catch return inherited;
    directory.close(io);
    const result = try alloc.dupeZ(u8, candidate);
    alloc.free(inherited);
    return result;
}

const OpenRequest = struct {
    id: []const u8,
    policy: std.json.Value,
    create: bool,
    cwd: ?[]const u8 = null,
};

pub fn createsSession(alloc: std.mem.Allocator, request: ?[]const u8) bool {
    const bytes = request orelse return false;
    const parsed = std.json.parseFromSlice(OpenRequest, alloc, bytes, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.create;
}

fn childEnvironmentKey(key: []const u8) bool {
    return !std.mem.startsWith(u8, key, "OMG_RUNTIME_") and
        !std.mem.eql(u8, key, "OMG_SESSION_RUNTIME_DESCRIPTOR") and
        !std.mem.eql(u8, key, "GHOSTTY_SURFACE_ID");
}

const Environment = struct {
    map: *const std.process.Environ.Map,

    pub fn jsonStringify(self: Environment, writer: *std.json.Stringify) std.json.Stringify.Error!void {
        try writer.beginObject();
        var entries = self.map.iterator();
        while (entries.next()) |entry| {
            if (!childEnvironmentKey(entry.key_ptr.*)) continue;
            try writer.objectField(entry.key_ptr.*);
            try writer.write(entry.value_ptr.*);
        }
        try writer.endObject();
    }
};

pub fn prepare(
    alloc: std.mem.Allocator,
    request: []const u8,
    argv: []const [:0]const u8,
    environment: *const std.process.Environ.Map,
    cwd: ?[]const u8,
    grid: renderer.GridSize,
    screen: renderer.ScreenSize,
    configured_scrollback_bytes: ?usize,
    configured_scrollback_lines: ?usize,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(OpenRequest, alloc, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (!parsed.value.create) return attachOnly(alloc, request);
    const scrollback = effectiveScrollbackLimits(configured_scrollback_bytes, configured_scrollback_lines);
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = parsed.value.id,
        .policy = parsed.value.policy,
        .create = true,
        .cwd = cwd orelse parsed.value.cwd,
        .launch = .{
            .argv = argv,
            .env = Environment{ .map = environment },
            .cwd = cwd orelse parsed.value.cwd,
            .cols = grid.columns,
            .rows = grid.rows,
            .pixel_width = @min(screen.width, std.math.maxInt(u16)),
            .pixel_height = @min(screen.height, std.math.maxInt(u16)),
            .scrollback_max_bytes = scrollback.max_bytes,
            .scrollback_max_lines = scrollback.max_lines,
        },
    }, .{ .emit_null_optional_fields = false });
}

/// Startup input is part of creation, never a replayable client input queue.
pub fn withInitialInput(
    alloc: std.mem.Allocator,
    request: []const u8,
    input: []const u8,
    grid: u32,
    pixels: u32,
) ![]u8 {
    if (input.len > max_initial_input) return error.InitialInputTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOpenRequest;
    const launch = parsed.value.object.getPtr("launch") orelse return error.MissingLocalLaunch;
    if (launch.* != .object) return error.InvalidOpenRequest;
    const arena = parsed.arena.allocator();
    try launch.object.put(arena, "cols", .{ .integer = grid >> 16 });
    try launch.object.put(arena, "rows", .{ .integer = grid & 0xffff });
    try launch.object.put(arena, "pixel_width", .{ .integer = pixels >> 16 });
    try launch.object.put(arena, "pixel_height", .{ .integer = pixels & 0xffff });
    const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(input.len));
    defer {
        std.crypto.secureZero(u8, encoded);
        alloc.free(encoded);
    }
    if (input.len > 0) {
        _ = std.base64.standard.Encoder.encode(encoded, input);
        try launch.object.put(arena, "input_base64", .{ .string = encoded });
    }
    return std.json.Stringify.valueAlloc(alloc, parsed.value, .{});
}

pub fn attachOnly(alloc: std.mem.Allocator, request: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(OpenRequest, alloc, request, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return std.json.Stringify.valueAlloc(alloc, .{
        .id = parsed.value.id,
        .policy = parsed.value.policy,
        .create = false,
    }, .{});
}

test "local session launch preserves prepared shell environment without app routing" {
    const alloc = std.testing.allocator;
    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("TERM", "xterm-ghostty");
    try env.put("GHOSTTY_RESOURCES_DIR", "/bundle/resources");
    try env.put("ZDOTDIR", "/bundle/shell-integration/zsh");
    try env.put("MY_SETTING", "space and Unicode \xe7\x95\x8c");
    try env.put("OMG_SSH_HANDOFF_TOKEN", "stable-session-capability");
    try env.put("OMG_QUICK_INPUT_BRIDGE", "/stable/editor");
    try env.put("OMG_RUNTIME_SOCKET", "/old-app/socket");
    try env.put("OMG_RUNTIME_LOCAL", "1");
    try env.put("OMG_SESSION_RUNTIME_DESCRIPTOR", "private-routing");
    try env.put("GHOSTTY_SURFACE_ID", "old-process-pointer");
    const request = try prepare(
        alloc,
        "{\"id\":\"pane\",\"policy\":{},\"create\":true}",
        &.{ "/usr/bin/login", "-flp", "user", "/bin/zsh", "-l" },
        &env,
        "/tmp/project",
        .{ .columns = 91, .rows = 35 },
        .{ .width = 728, .height = 560 },
        50_000_000,
        100,
    );
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    const launch = parsed.value.object.get("launch").?.object;
    const child = launch.get("env").?.object;
    try std.testing.expectEqualStrings("/usr/bin/login", launch.get("argv").?.array.items[0].string);
    try std.testing.expectEqualStrings("/tmp/project", launch.get("cwd").?.string);
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024), launch.get("scrollback_max_bytes").?.integer);
    try std.testing.expectEqual(@as(i64, 100), launch.get("scrollback_max_lines").?.integer);
    try std.testing.expectEqualStrings("xterm-ghostty", child.get("TERM").?.string);
    try std.testing.expectEqualStrings("/bundle/shell-integration/zsh", child.get("ZDOTDIR").?.string);
    try std.testing.expectEqualStrings("space and Unicode \xe7\x95\x8c", child.get("MY_SETTING").?.string);
    try std.testing.expect(child.contains("OMG_SSH_HANDOFF_TOKEN"));
    try std.testing.expect(child.contains("OMG_QUICK_INPUT_BRIDGE"));
    try std.testing.expect(!child.contains("OMG_RUNTIME_SOCKET"));
    try std.testing.expect(!child.contains("OMG_RUNTIME_LOCAL"));
    try std.testing.expect(!child.contains("OMG_SESSION_RUNTIME_DESCRIPTOR"));
    try std.testing.expect(!child.contains("GHOSTTY_SURFACE_ID"));
}

test "local session startup input belongs only to the original creation" {
    const alloc = std.testing.allocator;
    const initial = "{\"id\":\"pane\",\"policy\":{},\"create\":true,\"launch\":{\"argv\":[\"sh\"],\"env\":{\"SECRET\":\"value\"}}}";
    const request = try withInitialInput(alloc, initial, "echo once\n\x00", (100 << 16) | 30, (800 << 16) | 480);
    defer alloc.free(request);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, request, .{});
    defer parsed.deinit();
    const launch = parsed.value.object.get("launch").?.object;
    try std.testing.expectEqual(@as(i64, 100), launch.get("cols").?.integer);
    try std.testing.expectEqual(@as(i64, 30), launch.get("rows").?.integer);
    const encoded = launch.get("input_base64").?.string;
    const decoded = try alloc.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    defer alloc.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, encoded);
    try std.testing.expectEqualStrings("echo once\n\x00", decoded);
    const attached = try attachOnly(alloc, request);
    defer alloc.free(attached);
    try std.testing.expect(std.mem.indexOf(u8, attached, "launch") == null);
    try std.testing.expect(std.mem.indexOf(u8, attached, "SECRET") == null);
    try std.testing.expect(!createsSession(alloc, attached));
}

test "local session cwd fallback matches the launching process" {
    const alloc = std.testing.allocator;
    const inherited = try std.process.currentPathAlloc(std.testing.io, alloc);
    defer alloc.free(inherited);
    const fallback = try workingDirectory(alloc, std.testing.io, "/nonexistent/omg-local-session-fixture");
    defer alloc.free(fallback);
    try std.testing.expectEqualStrings(inherited, fallback);
    const relative = try workingDirectory(alloc, std.testing.io, ".");
    defer alloc.free(relative);
    try std.testing.expectEqualStrings(inherited, relative);
}

test "runtime scrollback preserves stricter Ghostty limits and clamps wider ones" {
    const unlimited = effectiveScrollbackLimits(null, null);
    try std.testing.expectEqual(@as(usize, max_runtime_scrollback_bytes), unlimited.max_bytes);
    try std.testing.expect(unlimited.max_lines == null);

    const disabled = effectiveScrollbackLimits(0, 0);
    try std.testing.expectEqual(@as(usize, 0), disabled.max_bytes);
    try std.testing.expectEqual(@as(?usize, 0), disabled.max_lines);

    const strict = effectiveScrollbackLimits(1024, 32);
    try std.testing.expectEqual(@as(usize, 1024), strict.max_bytes);
    try std.testing.expectEqual(@as(?usize, 32), strict.max_lines);

    const wider = effectiveScrollbackLimits(50_000_000, null);
    try std.testing.expectEqual(@as(usize, max_runtime_scrollback_bytes), wider.max_bytes);
    try std.testing.expect(wider.max_lines == null);
}
