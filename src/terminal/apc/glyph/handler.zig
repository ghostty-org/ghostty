//! Glyph Protocol request dispatcher.
//!
//! Turns a parsed `request.Request` into an optional `response.Response`
//! and mutates the session glossary as required. The caller is
//! responsible for formatting the returned response to the wire and
//! writing it back over the PTY.
//!
//! `reply=0` registrations and `reply=2` successful registrations
//! return `null` so the caller emits nothing at all (spec §6.2).

const std = @import("std");
const Allocator = std.mem.Allocator;

const request = @import("request.zig");
const response = @import("response.zig");
const glyf = @import("glyf.zig");
const Glossary = @import("glossary.zig").Glossary;

const log = std.log.scoped(.glyph_protocol);

/// Payload formats this build advertises in the `s` reply.
pub const supported_formats: response.Response.Support.Formats = .{
    .glyf = true,
};

/// Dispatch a parsed request. Returns the response the caller should
/// format and emit, or `null` when the request dictates silence.
///
/// The glossary is mutated on register/clear.
pub fn handle(
    alloc: Allocator,
    glossary: *Glossary,
    req: request.Request,
) Allocator.Error!?response.Response {
    return switch (req) {
        .support => .{ .support = .{ .fmt = supported_formats } },
        .query => |q| handleQuery(glossary, q),
        .register => |r| try handleRegister(alloc, glossary, r),
        .clear => |c| try handleClear(alloc, glossary, c),
    };
}

fn handleQuery(glossary: *const Glossary, q: request.Request.Query) ?response.Response {
    // A query with no or malformed `cp` is silently dropped — the
    // client gets no reply and times out.
    const cp = q.get(.cp) orelse return null;

    // Without a font-coverage oracle wired in yet, the best we can
    // truthfully advertise is "glossary covers it" vs "free". A
    // future pass can upgrade `.free` to `.system` by consulting the
    // terminal's font fallback chain.
    const status: response.Coverage = if (glossary.contains(cp)) .glossary else .free;
    return .{ .query = .{ .cp = cp, .status = status } };
}

fn handleRegister(
    alloc: Allocator,
    glossary: *Glossary,
    r: request.Request.Register,
) Allocator.Error!?response.Response {
    // A missing `cp` is a malformed request — no reply (client will
    // time out).
    const cp = r.get(.cp) orelse return null;
    const reply = r.get(.reply) orelse .all;

    if (!isPUA(cp)) return registerError(reply, cp, "out_of_namespace");

    var decoded = r.decodePayload(alloc) catch |err| switch (err) {
        error.OutOfMemory => |oom| return oom,
        else => |e| {
            const fmt_name = @tagName(r.get(.fmt) orelse .glyf);
            log.warn("register decode failed cp={x} fmt={s} err={}", .{ cp, fmt_name, e });
            return registerError(reply, cp, request.reasonString(e) orelse "malformed_payload");
        },
    };

    const upm_raw: u32 = r.get(.upm) orelse 1000;
    if (upm_raw == 0 or upm_raw > std.math.maxInt(u16)) {
        decoded.deinit(alloc);
        return registerError(reply, cp, "malformed_payload");
    }
    const upm: u16 = @intCast(upm_raw);
    const width = r.get(.width) orelse .narrow;

    // Ownership transfers to the glossary on success; only free on
    // failure. The glossary handles every payload variant uniformly.
    _ = glossary.register(alloc, cp, decoded, upm, width) catch |err| {
        decoded.deinit(alloc);
        return err;
    };

    return switch (reply) {
        .all => .{ .register = .{ .cp = cp } },
        .none, .failures => null,
    };
}

fn handleClear(
    alloc: Allocator,
    glossary: *Glossary,
    c: request.Request.Clear,
) Allocator.Error!?response.Response {
    if (c.get(.cp)) |cp| {
        if (!isPUA(cp)) return .{ .clear = .{
            .status = .err,
            .reason = "out_of_namespace",
        } };
        glossary.clearOne(alloc, cp);
    } else {
        glossary.clearAll(alloc);
    }
    return .{ .clear = .{} };
}

fn registerError(
    reply: request.Reply,
    cp: u21,
    reason: []const u8,
) ?response.Response {
    return switch (reply) {
        .none => null,
        .all, .failures => .{ .register = .{
            .cp = cp,
            .status = .err,
            .reason = reason,
        } },
    };
}

/// Unicode Private Use Areas per spec §4: basic PUA, supplementary
/// PUA-A, supplementary PUA-B. Endpoints follow the spec (e.g.
/// 0xFFFFD, not 0xFFFFF) because codepoints above them are
/// noncharacters.
fn isPUA(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF_0000 and cp <= 0xF_FFFD) or
        (cp >= 0x10_0000 and cp <= 0x10_FFFD);
}

// tests

const testing = std.testing;
const CommandParser = request.CommandParser;

fn parseRequest(alloc: Allocator, body: []const u8) !request.Request {
    var parser: CommandParser = .init(alloc, 1024 * 1024);
    defer parser.deinit();
    for (body) |b| try parser.feed(b);
    return parser.complete(alloc);
}

test "support reply advertises glyf" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    var req = try parseRequest(testing.allocator, "s");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp == .support);
    try testing.expect(resp.support.fmt.glyf);
}

test "query returns free when unregistered" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    var req = try parseRequest(testing.allocator, "q;cp=e0a0");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expectEqual(@as(u21, 0xE0A0), resp.query.cp);
    try testing.expect(resp.query.status == .free);
}

test "query returns glossary when registered" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    _ = try g.register(testing.allocator, 0xE0A0, .{ .glyf = .{
        .contours = &.{},
        .points = &.{},
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    } }, 1000, .narrow);

    var req = try parseRequest(testing.allocator, "q;cp=e0a0");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp.query.status == .glossary);
}

test "register out of namespace is rejected" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    // 'a' is not in any PUA range.
    var req = try parseRequest(testing.allocator, "r;cp=61;fmt=glyf;AA==");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp == .register);
    try testing.expectEqual(@as(u21, 0x61), resp.register.cp);
    try testing.expectEqualStrings("out_of_namespace", resp.register.reason.?);
    try testing.expect(g.len() == 0);
}

test "register with reply=0 is silent" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    // Out-of-namespace, but reply=0 suppresses even the error.
    var req = try parseRequest(testing.allocator, "r;cp=61;fmt=glyf;reply=0;AA==");
    defer req.deinit(testing.allocator);

    try testing.expect(try handle(testing.allocator, &g, req) == null);
}

fn makeEmptyGlyfB64(buf: *std.ArrayList(u8)) !void {
    // numberOfContours = 0 + 8 bytes bbox → valid empty glyph.
    var raw: [10]u8 = undefined;
    std.mem.writeInt(i16, raw[0..2], 0, .big);
    @memset(raw[2..], 0);
    const enc = std.base64.standard.Encoder;
    const size = enc.calcSize(raw.len);
    try buf.resize(testing.allocator, size);
    _ = enc.encode(buf.items, &raw);
}

test "register glyf success stores entry and acks" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(testing.allocator);
    try makeEmptyGlyfB64(&b64);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "r;cp=e0a0;fmt=glyf;");
    try body.appendSlice(testing.allocator, b64.items);

    var req = try parseRequest(testing.allocator, body.items);
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expectEqual(@as(u21, 0xE0A0), resp.register.cp);
    try testing.expect(resp.register.status == .ok);
    try testing.expect(resp.register.reason == null);
    try testing.expect(g.contains(0xE0A0));
    // No `width=` was sent, so the registration defaults to narrow.
    try testing.expectEqual(request.Width.narrow, g.widthFor(0xE0A0).?);
}

test "register glyf with width=2 stores wide width" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(testing.allocator);
    try makeEmptyGlyfB64(&b64);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "r;cp=e0a0;fmt=glyf;width=2;");
    try body.appendSlice(testing.allocator, b64.items);

    var req = try parseRequest(testing.allocator, body.items);
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp.register.status == .ok);
    try testing.expectEqual(request.Width.wide, g.widthFor(0xE0A0).?);
}

test "register glyf with reply=2 is silent on success" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(testing.allocator);
    try makeEmptyGlyfB64(&b64);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "r;cp=e0a0;fmt=glyf;reply=2;");
    try body.appendSlice(testing.allocator, b64.items);

    var req = try parseRequest(testing.allocator, body.items);
    defer req.deinit(testing.allocator);

    try testing.expect(try handle(testing.allocator, &g, req) == null);
    try testing.expect(g.contains(0xE0A0));
}

test "register malformed glyf emits error reason" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var req = try parseRequest(
        testing.allocator,
        "r;cp=e0a0;fmt=glyf;%%%not-base64%%%",
    );
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expectEqualStrings("malformed_payload", resp.register.reason.?);
    try testing.expect(g.len() == 0);
}

test "clear all acks" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var req = try parseRequest(testing.allocator, "c;");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp == .clear);
    try testing.expect(resp.clear.status == .ok);
}

test "clear specific cp acks and drops" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    _ = try g.register(testing.allocator, 0xE0A0, .{ .glyf = .{
        .contours = &.{},
        .points = &.{},
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    } }, 1000, .narrow);

    var req = try parseRequest(testing.allocator, "c;cp=e0a0");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp.clear.status == .ok);
    try testing.expect(!g.contains(0xE0A0));
}

test "clear non-PUA rejected with reason" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var req = try parseRequest(testing.allocator, "c;cp=61");
    defer req.deinit(testing.allocator);

    const resp = (try handle(testing.allocator, &g, req)).?;
    try testing.expect(resp.clear.status == .err);
    try testing.expectEqualStrings("out_of_namespace", resp.clear.reason.?);
}
