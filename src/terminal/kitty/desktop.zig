/// Kitty desktop notifications (OSC 99)
/// https://sw.kovidgoyal.net/kitty/desktop-notifications/
pub const KittyDesktopNotification = @This();

const std = @import("std");
const Terminator = @import("../osc.zig").Terminator;
const Parser = @import("../osc.zig").Parser;
const simd = @import("../../simd/main.zig");
const Duration = @import("../../config/Config.zig").Duration;

const log = std.log.scoped(.kitty_desktop);

/// metadata keys
metadata: Metadata = .{},

/// payload
payload: ?[]const u8 = null,

/// terminator
terminator: Terminator = .st,

/// we use an arena to make cleaning up allocations simpler
arena: std.heap.ArenaAllocator,

const Metadata = struct {
    /// What action to perform when the notification is clicked
    a: Action = .{},

    /// When non-zero an escape
    /// code is sent to the application when the notification is closed.
    c: bool = false,

    /// Indicates if the notification is complete or not. A non-zero value
    /// means it is complete.
    d: bool = true,

    /// If set to 1 means the payload is Base64 encoded UTF-8, otherwise it
    /// is plain UTF-8 text with no C0 control codes in it
    e: bool = false,

    /// The name of the application sending the notification. Can be used to
    /// filter out notifications.
    f: ?[]const u8 = null,

    /// Identifier for icon data. Make these globally unqiue, like an UUID.
    g: ?[]const u8 = null,

    /// Identifier for the notification. Make these globally unqiue, like
    /// an UUID, so that terminal multiplexers can direct responses to the
    /// correct window. Note that for backwards compatibility reasons i=0 is
    /// special and should not be used.
    i: ?[]const u8 = null,

    /// Icon name. Can be specified multiple times.
    n: std.ArrayListUnmanaged(Icon) = .{},

    /// When to honor the notification request. `unfocused` means when the
    /// window the notification is sent on does not have keyboard focus.
    /// `invisible` means the window both is unfocused and not visible to the
    /// user, for example, because it is in an inactive tab or its OS window
    /// is not currently active. `always` is the default and always honors
    /// the request.
    o: When = .always,

    /// Type of the payload. If a notification has no title, the body will
    /// be used as title. A notification with not title and no body is
    /// ignored. Terminal emulators should ignore payloads of unknown type
    /// to allow for future expansion of this protocol.
    p: Type = .title,

    /// The sound name to play with the notification. `silent` means no
    /// sound. `system` means to play the default sound, if any, of the
    /// platform notification service. Other names are implementation
    /// dependent.
    s: Sound = .{ .standard = .system },

    /// The type of the notification. Used to filter out notifications. Can
    /// be specified multiple times.
    t: std.ArrayListUnmanaged([]const u8) = .{},

    /// The urgency of the notification. 0 is low, 1 is normal and 2 is critical.
    /// If not specified normal is used.
    u: Urgency = .normal,

    /// The number of milliseconds to auto-close the notification after. Kitty uses `-1`
    /// to indicate never auto-closing the notification. We use `null`.
    w: ?Duration = null,
};

const Action = struct {
    focus: bool = true,
    report: bool = false,
};

const Icon = union(enum) {
    const Standard = enum {
        /// An error symbol
        @"error",

        /// A warning symbol
        warning,

        /// A symbol denoting an informational message
        info,

        /// A symbol denoting asking the user a question
        question,

        /// A symbol denoting a help message
        help,

        /// A symbol denoting a generic file manager application
        @"file-manager",

        /// A symbol denoting a generic system monitoring/information
        /// application
        @"system-monitor",

        /// A symbol denoting a generic text editor application
        @"text-editor",
    };

    /// one of the standard icon types
    standard: Standard,

    /// Application/system dependent icon name
    other: []const u8,
};

/// When to honor the notification request.
const When = enum {
    /// the default and always honors the request.
    always,

    /// the notification is sent if the surface does not have keyboard focus
    unfocused,

    /// the window is both unfocused and not visible to the user, for example,
    /// because it is in an inactive tab or its OS window is not currently
    /// active
    invisible,
};

/// Type of the payload. If a notification has no title, the body will be used
/// as title. A notification with not title and no body is ignored. Terminal
/// emulators should ignore payloads of unknown type to allow for future
/// expansion of this protocol.
const Type = enum {
    /// The payload contains the title of the notification.
    title,

    /// The payload contains the body of the notification.
    body,

    /// Close a previous notification.
    close,

    /// The payload is the icon image in any of the PNG, JPEG or GIF image
    /// formats. It is recommended to use an image size of 256x256 for icons.
    /// Since icons are binary data, they must be transmitted encoded, with
    /// `e=1`.
    icon,

    /// Query the terminal for the supported features.
    @"?",

    /// Query to see which notifications are still alive.
    alive,

    /// Add buttons to the notification. Buttons are a list of UTF-8 text
    /// separated by the Unicode Line Separator character (U+2028) which is
    /// the UTF-8 bytes 0xe2 0x80 0xa8. They can be sent either as Escape code
    /// safe UTF-8 or Base64. When the user clicks on one of the buttons, and
    /// reporting is enabled with a=report, the terminal will send an escape
    /// code to the command.
    buttons,
};

const Sound = union(enum) {
    const Standard = enum {
        /// The default system sound for a notification, which may be some
        /// kind of beep or just silence
        system,

        /// No sound must accompany the notification
        silent,

        /// A sound associated with error messages
        @"error",

        /// A sound associated with warning messages
        warning,

        /// A sound associated with information messages
        info,

        /// A sound associated with questions
        question,
    };

    /// one of the standard sound names
    standard: Standard,

    /// Application/system dependent sound name
    other: []const u8,
};

const Urgency = enum(u2) {
    low = 0,
    normal = 1,
    critical = 2,
};

/// Kitty desktop notification identifiers are restrited to the characters
/// `a-zA-Z0-9_-+.```
fn isLegalIdentifierCharacter(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+', '.' => true,
        else => false,
    };
}

const illegal_identifier_characters = i: {
    @setEvalBranchQuota(2000);
    var count: usize = 0;
    for (0..std.math.maxInt(u8)) |c| {
        if (!isLegalIdentifierCharacter(c)) count += 1;
    }
    var index: usize = 0;
    var array: [count]u8 = undefined;
    for (0..std.math.maxInt(u8)) |c| {
        if (!isLegalIdentifierCharacter(c)) {
            array[index] = c;
            index += 1;
        }
    }
    break :i array;
};

fn isIllegalIdentifier(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, &illegal_identifier_characters) != null;
}

pub fn init(self: *KittyDesktopNotification, gpa_alloc: std.mem.Allocator, parser: *Parser) !void {
    self.arena = std.heap.ArenaAllocator.init(gpa_alloc);
    self.metadata = .{};
    self.payload = null;
    self.terminator = .st;
    try self.parse(parser);
}

pub fn deinit(self: *KittyDesktopNotification) void {
    self.arena.deinit();
}

pub fn parse(self: *KittyDesktopNotification, parser: *Parser) !void {
    const metadata_str = parser.temp_state.key;
    const payload_str = parser.buf[parser.buf_start..parser.buf_idx];

    try self.parseMetadata(parser, metadata_str);

    if (payload_str.len > 0) {
        const alloc = self.arena.allocator();

        if (self.metadata.e) {
            const size = simd.base64.maxLen(payload_str);
            const buf = alloc.alloc(u8, size) catch {
                log.warn("unable to allocate memory to decode payload", .{});
                parser.state = .invalid;
                parser.complete = false;
                return error.InvalidPayload;
            };
            self.payload = simd.base64.decode(payload_str, buf) catch |err| {
                log.warn("unable to decode payload: {}", .{err});
                parser.state = .invalid;
                parser.complete = false;
                return error.InvalidPayload;
            };
            // mark e as false because we've decoded it
            self.metadata.e = false;
        } else {
            self.payload = alloc.dupe(u8, payload_str) catch {
                log.warn("unable to allocate memory for the payload", .{});
                parser.state = .invalid;
                parser.complete = false;
                return error.InvaidPayload;
            };
        }
    }
    parser.complete = true;
}

pub fn parseMetadata(self: *KittyDesktopNotification, parser: *Parser, metadata_str: []const u8) !void {
    const alloc = self.arena.allocator();

    // bail if metadata string is empty
    if (std.mem.trim(u8, metadata_str, " ").len == 0) return;

    var kvs = std.mem.splitScalar(u8, metadata_str, ':');

    while (kvs.next()) |kv| {
        const key_str = kv[0..(std.mem.indexOfScalar(u8, kv, '=') orelse kv.len)];

        const key = key: {
            const k = std.mem.trim(u8, key_str, " ");
            break :key std.meta.stringToEnum(
                std.meta.FieldEnum(KittyDesktopNotification.Metadata),
                k,
            ) orelse {
                log.warn("unknown metadata key \"{s}\"", .{k});
                parser.state = .invalid;
                parser.complete = false;
                return error.InvaldKey;
            };
        };

        if (key_str.len == kv.len) {
            log.warn("value for metadata key \"{s}\" is empty", .{@tagName(key)});
            parser.state = .invalid;
            parser.complete = false;
            return error.InvalidValue;
        }

        const value = std.mem.trim(u8, kv[key_str.len + 1 ..], " ");

        if (value.len == 0) {
            log.warn("value for metadata key \"{s}\" is empty", .{@tagName(key)});
            parser.state = .invalid;
            parser.complete = false;
            return error.InvalidValue;
        }

        switch (key) {
            // action
            .a => {
                var it = std.mem.splitScalar(u8, value, ',');
                while (it.next()) |name| {
                    const tmp = std.mem.trim(u8, name, " ");
                    if (tmp.len == 0) {
                        log.warn("metadata key \"s\" has an empty element in its value", .{});
                        parser.state = .invalid;
                        parser.complete = false;
                        return error.InvalidValue;
                    }
                    const action = std.meta.stringToEnum(
                        std.meta.FieldEnum(Action),
                        if (tmp[0] == '-')
                            tmp[1..]
                        else
                            tmp,
                    ) orelse {
                        log.warn("metadata key \"s\" has an invalid element in its value: \"{s}\"", .{tmp});
                        parser.state = .invalid;
                        parser.complete = false;
                        return error.InvalidValue;
                    };
                    switch (action) {
                        .focus => self.metadata.a.focus = tmp[0] != '-',
                        .report => self.metadata.a.report = tmp[0] != '-',
                    }
                }
            },

            // close
            .c => {
                self.metadata.c = !std.mem.eql(u8, value, "0");
            },

            // done
            .d => {
                self.metadata.d = !std.mem.eql(u8, value, "0");
            },

            // payload encoded
            .e => {
                self.metadata.e = !std.mem.eql(u8, value, "0");
            },

            // name of the application
            .f => {
                const buf = alloc.alloc(u8, simd.base64.maxLen(value)) catch {
                    log.warn("unable to allocate a buffer to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                self.metadata.f = simd.base64.decode(value, buf) catch {
                    log.warn("unable to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // identification for the icon
            .g => {
                if (isIllegalIdentifier(value)) {
                    log.warn("value of metadata key \"g\" is an illegal identifier", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                }
                self.metadata.g = alloc.dupe(u8, value) catch {
                    log.warn("unable to allocate a buffer for value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // identifier for the notification
            .i => {
                if (isIllegalIdentifier(value)) {
                    log.warn("value of metadata key \"i\" is an illegal identifier", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                }
                self.metadata.i = alloc.dupe(u8, value) catch {
                    log.warn("unable to allocate buffer for value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // icon
            .n => {
                const buf = alloc.alloc(u8, simd.base64.maxLen(value)) catch {
                    log.warn("unable to allocate buffer to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                var tmp = simd.base64.decode(value, buf) catch {
                    log.warn("unable to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                if (std.mem.eql(u8, tmp, "warn")) tmp = "warning";
                const n = std.meta.stringToEnum(Icon.Standard, tmp) orelse {
                    self.metadata.n.append(alloc, .{ .other = tmp }) catch {
                        log.warn("unable to append value", .{});
                        parser.state = .invalid;
                        parser.complete = false;
                        return error.InvalidValue;
                    };
                    return;
                };
                self.metadata.n.append(alloc, .{ .standard = n }) catch {
                    log.warn("unable to append value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // when
            .o => {
                self.metadata.o = std.meta.stringToEnum(When, value) orelse {
                    log.warn("invalid value for key \"o\": \"{s}\"", .{value});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // type of paylod
            .p => {
                self.metadata.p = std.meta.stringToEnum(Type, value) orelse {
                    log.warn("invalid value for key \"p\": \"{s}\"", .{value});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // sound
            .s => {
                const buf = alloc.alloc(u8, simd.base64.maxLen(value)) catch {
                    log.warn("unable to allocate buffer to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                var tmp = simd.base64.decode(value, buf) catch {
                    log.warn("unable to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                if (std.mem.eql(u8, tmp, "warn")) tmp = "warning";
                self.metadata.s = .{
                    .standard = std.meta.stringToEnum(Sound.Standard, tmp) orelse {
                        self.metadata.s = .{ .other = tmp };
                        return;
                    },
                };
            },

            // type of notification
            .t => {
                const buf = try alloc.alloc(u8, simd.base64.maxLen(value));
                self.metadata.t.append(alloc, simd.base64.decode(value, buf) catch {
                    log.warn("unable to decode value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                }) catch {
                    log.warn("unable to append value", .{});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // urgency
            .u => {
                const u = std.fmt.parseUnsigned(std.meta.Tag(Urgency), value, 10) catch {
                    log.warn("invalid value for key \"u\": \"{s}\"", .{value});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
                self.metadata.u = std.meta.intToEnum(Urgency, u) catch {
                    log.warn("invalid value for key \"u\": \"{s}\"", .{value});
                    parser.state = .invalid;
                    parser.complete = false;
                    return error.InvalidValue;
                };
            },

            // when
            .w => {
                if (std.mem.eql(u8, value, "-1")) {
                    self.metadata.w = null;
                    continue;
                }
                self.metadata.w = .{
                    .duration = (std.fmt.parseUnsigned(u64, value, 10) catch {
                        log.warn("invalid value for key \"w\": \"{s}\"", .{value});
                        parser.state = .invalid;
                        parser.complete = false;
                        return error.InvalidValue;
                    }) * std.time.ns_per_ms,
                };
            },
        }
    }
}

pub fn encodeForInspector(self: *const KittyDesktopNotification, alloc: std.mem.Allocator, md: *std.StringHashMap([:0]const u8)) !void {
    var l = std.ArrayList(u8).init(alloc);
    errdefer l.deinit();

    const writer = l.writer();
    try writer.writeAll("a=");
    try writer.writeAll(if (self.metadata.a.focus) "" else "no-");
    try writer.writeAll("focus,");
    try writer.writeAll(if (self.metadata.a.report) "" else "no-");
    try writer.writeAll("report\nc=");
    try writer.writeAll(if (self.metadata.c) "1" else "0");
    try writer.writeAll("\nd=");
    try writer.writeAll(if (self.metadata.d) "1" else "0");
    try writer.writeAll("\ne=");
    try writer.writeAll(if (self.metadata.d) "1" else "0");
    if (self.metadata.f) |f| {
        try writer.writeAll("\nf=");
        try writer.writeAll(f);
    }
    if (self.metadata.g) |g| {
        try writer.writeAll("\ng=");
        try writer.writeAll(g);
    }
    if (self.metadata.i) |i| {
        try writer.writeAll("\ni=");
        try writer.writeAll(i);
    }
    for (self.metadata.n.items) |i| {
        try writer.writeAll("\nn=");
        switch (i) {
            .standard => |s| try writer.writeAll(@tagName(s)),
            .other => |o| try writer.writeAll(o),
        }
    }
    try writer.writeAll("\no=");
    try writer.writeAll(@tagName(self.metadata.o));
    try writer.writeAll("\np=");
    try writer.writeAll(@tagName(self.metadata.p));
    try writer.writeAll("\ns=");
    switch (self.metadata.s) {
        .standard => |s| try writer.writeAll(@tagName(s)),
        .other => |o| try writer.writeAll(o),
    }
    for (self.metadata.t.items) |i| {
        try writer.writeAll("\nt=");
        try writer.writeAll(i);
    }
    try writer.writeAll("\nu=");
    try writer.writeAll(@tagName(self.metadata.u));
    if (self.metadata.w) |w| try writer.print("\nw={}", .{w});

    try md.put("metadata", try l.toOwnedSliceSentinel(0));
    try md.put("payload", try alloc.dupeZ(u8, if (self.payload) |p| p else "(null)"));
}

test "OSC: kitty desktop notification 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;;Hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("Hello world", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;e=1;SGVsbG8gd29ybGQ=";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("Hello world", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 3" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=1:d=0;Hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("Hello world", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i != null);
    try testing.expectEqualStrings(d.metadata.i.?, "1");
    try testing.expectEqual(false, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 4" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=1:p=body;This is cool";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("This is cool", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i != null);
    try testing.expectEqualStrings(d.metadata.i.?, "1");
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.body, d.metadata.p);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 5" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=1:p=close;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);

    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i != null);
    try testing.expectEqualStrings(d.metadata.i.?, "1");
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.close, d.metadata.p);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 6" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;s=c3lzdGVt;bell";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("bell", d.payload.?);

    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i == null);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 7" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;s=c29tZSBvdGhlciBzb3VuZA==;bell";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings("bell", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i == null);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expect(d.metadata.s == .other);
    try testing.expectEqualStrings(d.metadata.s.other, "some other sound");
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 8" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;g=4d3995d1-faf7-4f23-bba0-148548ecfefc;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i == null);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expect(d.metadata.g != null);
    try testing.expectEqualStrings("4d3995d1-faf7-4f23-bba0-148548ecfefc", d.metadata.g.?);
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 9" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;n=ZmlsZS1tYW5hZ2Vy;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i == null);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expect(d.metadata.g == null);
    try testing.expectEqual(@as(usize, 1), d.metadata.n.items.len);
    try testing.expect(d.metadata.n.items[0] == .standard);
    try testing.expect(d.metadata.n.items[0].standard == .@"file-manager");
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 10" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;t=YW5ub3lpbmcgcG9wdXA=:t=YW5vdGhlciBhbm5veWluZyBwb3B1cA==;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i == null);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.title, d.metadata.p);
    try testing.expect(d.metadata.g == null);
    try testing.expectEqual(@as(usize, 0), d.metadata.n.items.len);
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 2), d.metadata.t.items.len);
    try testing.expectEqualStrings(d.metadata.t.items[0], "annoying popup");
    try testing.expectEqualStrings(d.metadata.t.items[1], "another annoying popup");
}

test "OSC: kitty desktop notification 11" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=f6b48921-c9c2-4913-b697-ab12ef8431e3:p=?;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);

    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(true, d.metadata.a.focus);
    try testing.expectEqual(false, d.metadata.a.report);
    try testing.expect(d.metadata.i != null);
    try testing.expectEqualStrings("f6b48921-c9c2-4913-b697-ab12ef8431e3", d.metadata.i.?);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.@"?", d.metadata.p);
    try testing.expect(d.metadata.g == null);
    try testing.expectEqual(@as(usize, 0), d.metadata.n.items.len);
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 12 - bad urgency" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;u=3;";
    for (input) |ch| p.next(ch);

    try testing.expectEqual(null, p.end('\x1b'));
}

test "OSC: kitty desktop notification 13 - bad urgency with an alloc" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=f6b48921-c9c2-4913-b697-ab12ef8431e3:u=3;";
    for (input) |ch| p.next(ch);

    try testing.expectEqual(null, p.end('\x1b'));
}

test "OSC: kitty desktop notification 14 - no allocator" {
    const testing = std.testing;

    var p: Parser = .{};
    defer p.deinit();

    const input = "99;i=f6b48921-c9c2-4913-b697-ab12ef8431e3:u=3;";
    for (input) |ch| p.next(ch);

    try testing.expectEqual(null, p.end('\x1b'));
}

test "OSC: kitty desktop notification 15 - illegal notification identifier" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;i=0!9;";
    for (input) |ch| p.next(ch);

    try testing.expectEqual(null, p.end('\x1b'));
}

test "OSC: kitty desktop notification 16 - illegal icon data identifier" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;g=a&Z;";
    for (input) |ch| p.next(ch);

    try testing.expectEqual(null, p.end('\x1b'));
}

test "OSC: kitty desktop notification 17 - whitespace" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99; a = report , -focus : i = f6b48921-c9c2-4913-b697-ab12ef8431e3 : p = buttons ; ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload != null);
    try testing.expectEqualStrings(" ", d.payload.?);
    try testing.expectEqual(.st, d.terminator);
    try testing.expectEqual(false, d.metadata.a.focus);
    try testing.expectEqual(true, d.metadata.a.report);
    try testing.expect(d.metadata.i != null);
    try testing.expectEqualStrings("f6b48921-c9c2-4913-b697-ab12ef8431e3", d.metadata.i.?);
    try testing.expectEqual(true, d.metadata.d);
    try testing.expectEqual(Type.buttons, d.metadata.p);
    try testing.expect(d.metadata.g == null);
    try testing.expectEqual(@as(usize, 0), d.metadata.n.items.len);
    try testing.expect(d.metadata.s == .standard);
    try testing.expect(d.metadata.s.standard == .system);
    try testing.expectEqual(@as(usize, 0), d.metadata.t.items.len);
}

test "OSC: kitty desktop notification 18 - w" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;w=42;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);
    try testing.expectEqual(.st, d.terminator);
    try testing.expect(d.metadata.w != null);
    try testing.expectEqual(42 * std.time.ns_per_ms, d.metadata.w.?.duration);
}

test "OSC: kitty desktop notification 19 - w" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "99;w=-1;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expect(cmd.kitty_desktop_notification != null);
    const d = cmd.kitty_desktop_notification.?;

    try testing.expect(d.payload == null);
    try testing.expectEqual(.st, d.terminator);
    try testing.expect(d.metadata.w == null);
}
