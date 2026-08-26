const std = @import("std");
const Allocator = std.mem.Allocator;

const request = @import("request.zig");
const response = @import("response.zig");
const Glossary = @import("Glossary.zig");
const Request = request.Request;
const Response = response.Response;

const log = std.log.scoped(.glyph);

/// Payload formats we support. Hardcoded because the support is
/// fixed.
pub const supported_formats: response.Response.Support.Formats = .{
    .glyf = true,
};

/// Execute a Glyph protocol request against the given state.
///
/// This will never fail, but the response may indiciate an error and
/// the terminal state may not be updated to reflect the command. This will
/// never put the terminal in a corrupt or non-recoverable state.
///
/// For example, allocation errors can happen, but they're wrapped up in
/// an out of memory response.
///
/// Query responses only report glossary coverage. Callers that can determine
/// system font coverage must update the returned query response before sending
/// it to the client.
pub fn execute(
    alloc: Allocator,
    glossary: *Glossary,
    req: *const Request,
) ?Response {
    log.debug("executing glyph protocol request: {t}", .{req.*});
    return switch (req.*) {
        .support => .{ .support = .{ .fmt = supported_formats } },
        .query => |qry| query(glossary, qry),
        .register => |reg| register(alloc, glossary, reg),
        .clear => |clr| clear(alloc, glossary, clr),
    };
}

fn query(
    glossary: *Glossary,
    qry: Request.Query,
) ?Response {
    const cp = qry.get(.cp) orelse return null;
    return .{ .query = .{
        .cp = cp,
        .status = .{
            .glossary = glossary.contains(cp),
        },
    } };
}

fn register(
    alloc: Allocator,
    glossary: *Glossary,
    reg: Request.Register,
) ?Response {
    const reply = reg.get(.reply) orelse .all;
    const cp = registerFallible(alloc, glossary, reg) catch |err| return switch (reply) {
        .none => null,
        .all, .failures => .{ .register = .{
            .cp = reg.get(.cp) orelse 0,
            .status = .err,
            .reason = switch (err) {
                error.OutOfMemory => .{ .other = "out_of_memory" },
                error.OutOfNamespace => .out_of_namespace,
                error.PayloadTooLarge => .payload_too_large,
                error.MalformedPayload => .malformed_payload,
                error.CompositeUnsupported => .composite_unsupported,
                error.HintingUnsupported => .hinting_unsupported,
                error.InvalidOptions,
                error.UnsupportedFormat,
                => .malformed_payload,
            },
        } },
    };

    return switch (reply) {
        .none, .failures => null,
        .all => .{ .register = .{ .cp = cp } },
    };
}

fn registerFallible(
    alloc: Allocator,
    glossary: *Glossary,
    reg: Request.Register,
) (Glossary.Entry.InitError || Glossary.RegisterError)!u21 {
    const cp = reg.get(.cp) orelse
        return error.MalformedPayload;

    var entry = try Glossary.Entry.init(alloc, reg);
    errdefer entry.deinit(alloc);

    try glossary.register(alloc, cp, entry);
    return cp;
}

fn clear(
    alloc: Allocator,
    glossary: *Glossary,
    clr: Request.Clear,
) ?Response {
    if (clr.get(.cp)) |cp| {
        glossary.delete(alloc, cp) catch |err| return .{ .clear = .{
            .status = .err,
            .reason = switch (err) {
                error.OutOfNamespace => "out_of_namespace",
            },
        } };
    } else if (clr.has(.cp)) {
        return .{ .clear = .{
            .status = .err,
            .reason = "malformed_payload",
        } };
    } else {
        glossary.clearAndFree(alloc);
    }

    return .{ .clear = .{} };
}

fn testParse(alloc: Allocator, data: []const u8) !Request {
    var parser = request.CommandParser.init(alloc, 1024 * 1024);
    defer parser.deinit();
    for (data) |byte| try parser.feed(byte);
    return try parser.complete(alloc);
}

fn testExecute(alloc: Allocator, glossary: *Glossary, req: *const Request) ?Response {
    return execute(alloc, glossary, req);
}

test "execute register stores glyph and returns success" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{ .cp = 0xE0A0 },
    }, testExecute(alloc, &glossary, &req).?);
    try testing.expect(glossary.contains(0xE0A0));
}

test "execute register reply failures suppresses success" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;reply=2;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expect(testExecute(alloc, &glossary, &req) == null);
    try testing.expect(glossary.contains(0xE0A0));
}

test "execute register reply none suppresses failure" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=41;reply=0;%%%not-base64%%%");
    defer req.deinit(alloc);

    try testing.expect(testExecute(alloc, &glossary, &req) == null);
    try testing.expect(!glossary.contains('A'));
}

test "execute register rejects non-PUA" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=41;AAAAAAAAAAAAAA==");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{
            .cp = 'A',
            .status = .err,
            .reason = .out_of_namespace,
        },
    }, testExecute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains('A'));
}

test "execute register reports malformed payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "r;cp=e0a0;%%%not-base64%%%");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .register = .{
            .cp = 0xE0A0,
            .status = .err,
            .reason = .malformed_payload,
        },
    }, testExecute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains(0xE0A0));
}

test "execute clear removes all glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var reg1 = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer reg1.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg1);

    var reg2 = try testParse(alloc, "r;cp=e0a1;AAAAAAAAAAAAAA==");
    defer reg2.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg2);

    var req = try testParse(alloc, "c");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{ .clear = .{} }, testExecute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains(0xE0A0));
    try testing.expect(!glossary.contains(0xE0A1));
}

test "execute clear removes one glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var reg1 = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer reg1.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg1);

    var reg2 = try testParse(alloc, "r;cp=e0a1;AAAAAAAAAAAAAA==");
    defer reg2.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg2);

    var req = try testParse(alloc, "c;cp=e0a0");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{ .clear = .{} }, testExecute(alloc, &glossary, &req).?);
    try testing.expect(!glossary.contains(0xE0A0));
    try testing.expect(glossary.contains(0xE0A1));
}

test "execute clear rejects non-PUA" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "c;cp=41");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .clear = .{
            .status = .err,
            .reason = "out_of_namespace",
        },
    }, testExecute(alloc, &glossary, &req).?);
}

test "execute clear rejects malformed cp without clearing glossary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var reg1 = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer reg1.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg1);

    var reg2 = try testParse(alloc, "r;cp=e0a1;AAAAAAAAAAAAAA==");
    defer reg2.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg2);

    for ([_][]const u8{ "c;cp=zz", "c;cp=", "c;cp=200000" }) |data| {
        var req = try testParse(alloc, data);
        defer req.deinit(alloc);

        try testing.expectEqual(Response{
            .clear = .{
                .status = .err,
                .reason = "malformed_payload",
            },
        }, testExecute(alloc, &glossary, &req).?);
        try testing.expect(glossary.contains(0xE0A0));
        try testing.expect(glossary.contains(0xE0A1));
    }
}

test "execute query reports no coverage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "q;cp=e0a0");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .query = .{
            .cp = 0xE0A0,
            .status = .{},
        },
    }, testExecute(alloc, &glossary, &req).?);
}

test "execute query reports glossary coverage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var reg = try testParse(alloc, "r;cp=e0a0;AAAAAAAAAAAAAA==");
    defer reg.deinit(alloc);
    _ = testExecute(alloc, &glossary, &reg);

    var req = try testParse(alloc, "q;cp=e0a0");
    defer req.deinit(alloc);

    try testing.expectEqual(Response{
        .query = .{
            .cp = 0xE0A0,
            .status = .{ .glossary = true },
        },
    }, testExecute(alloc, &glossary, &req).?);
}

test "execute query without cp returns no response" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var req = try testParse(alloc, "q;foo=bar");
    defer req.deinit(alloc);

    try testing.expect(testExecute(alloc, &glossary, &req) == null);
}
