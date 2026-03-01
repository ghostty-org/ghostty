//! OSC 3008: Hierarchical Context Signalling (UAPI spec)
//! Specification: https://uapi-group.org/specifications/specs/osc_context/
//!
//! OSC 3008 allows programs to signal context changes to the terminal emulator.
//! Each context has an identifier and metadata fields. Contexts are hierarchical
//! and form a stack.

const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_context_signal);

/// Maximum length of a context identifier (per spec).
const max_context_id_len = 64;

/// A single OSC 3008 context signal command.
pub const Command = struct {
    action: Action,
    /// The context identifier. Must be 1-64 characters in the 32..126 byte range.
    id: []const u8,
    /// Raw unparsed metadata fields after the context ID.
    /// Fields are semicolon-separated key=value pairs.
    /// Parsed lazily via `readOption`.
    metadata: []const u8,

    pub const Action = enum {
        /// OSC 3008;start=<id> — initiates, updates, or returns to a context.
        start,
        /// OSC 3008;end=<id> — terminates a context.
        end,
    };

    /// Read a metadata field value from the raw fields string.
    /// Returns null if the field is not present or malformed.
    pub fn readOption(
        self: Command,
        comptime option: Field,
    ) option.Type() {
        return option.read(self.metadata);
    }
};

/// Context types defined by the specification.
pub const ContextType = enum {
    boot,
    container,
    vm,
    elevate,
    chpriv,
    subcontext,
    remote,
    shell,
    command,
    app,
    service,
    session,

    pub fn parse(value: []const u8) ?ContextType {
        return std.meta.stringToEnum(ContextType, value);
    }
};

/// Exit status for the `exit` end-sequence field.
pub const ExitStatus = enum {
    success,
    failure,
    crash,
    interrupt,

    pub fn parse(value: []const u8) ?ExitStatus {
        return std.meta.stringToEnum(ExitStatus, value);
    }
};

/// Metadata fields that can appear in OSC 3008 sequences.
/// Fields are read lazily from the raw string using the `read` method.
pub const Field = enum {
    // Start sequence fields
    type,
    user,
    hostname,
    machineid,
    bootid,
    pid,
    pidfdid,
    comm,
    cwd,
    cmdline,
    vm,
    container,
    targetuser,
    targethost,
    sessionid,

    // End sequence fields
    exit,
    status,
    signal,

    pub fn Type(comptime self: Field) type {
        return switch (self) {
            .type => ?ContextType,
            .exit => ?ExitStatus,
            .pid, .pidfdid => ?u64,
            .status => ?u64,
            // All other fields are string values
            .user,
            .hostname,
            .machineid,
            .bootid,
            .comm,
            .cwd,
            .cmdline,
            .vm,
            .container,
            .targetuser,
            .targethost,
            .sessionid,
            .signal,
            => ?[]const u8,
        };
    }

    fn key(comptime self: Field) []const u8 {
        return @tagName(self);
    }

    /// Read the field value from the raw fields string.
    ///
    /// The raw fields string contains semicolon-separated key=value pairs
    /// e.g. "type=container;user=lennart;hostname=zeta".
    ///
    /// Unknown or malformed fields are ignored per the specification.
    pub fn read(
        comptime self: Field,
        raw: []const u8,
    ) self.Type() {
        var it = std.mem.splitScalar(u8, raw, ';');
        while (it.next()) |full| {
            // Parse key=value
            const value = value: {
                if (std.mem.indexOfScalar(
                    u8,
                    full,
                    '=',
                )) |eql_idx| {
                    if (std.mem.eql(
                        u8,
                        full[0..eql_idx],
                        self.key(),
                    )) {
                        break :value full[eql_idx + 1 ..];
                    }
                }

                continue;
            };

            return switch (self) {
                .type => .parse(value),
                .exit => .parse(value),
                .pid, .pidfdid, .status => value: {
                    for (value) |c| {
                        if (c < '0' or c > '9') break :value null;
                    }
                    break :value std.fmt.parseInt(
                        u64,
                        value,
                        10,
                    ) catch null;
                },
                // String fields
                .user,
                .hostname,
                .machineid,
                .bootid,
                .comm,
                .cwd,
                .cmdline,
                .vm,
                .container,
                .targetuser,
                .targethost,
                .sessionid,
                .signal,
                => if (value.len > 0) value else null,
            };
        }

        // Not found
        return null;
    }
};

/// Parse OSC 3008: hierarchical context signalling.
///
/// Expected data format (after "3008;" prefix has been consumed by the state machine):
///   start=<id>[;<field>=<value>]*
///   end=<id>[;<field>=<value>]*
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }

    // Determine the action (start= or end=)
    const action: Command.Action = action: {
        if (std.mem.startsWith(u8, data, "start=")) break :action .start;
        if (std.mem.startsWith(u8, data, "end=")) break :action .end;

        log.warn("OSC 3008: expected 'start=' or 'end=' prefix, got: {s}", .{
            data[0..@min(data.len, 10)],
        });
        parser.state = .invalid;
        return null;
    };

    // Skip past the "start=" or "end=" prefix
    const prefix_len: usize = switch (action) {
        .start => "start=".len,
        .end => "end=".len,
    };
    const rest = data[prefix_len..];

    if (rest.len == 0) {
        log.warn("OSC 3008: missing context ID", .{});
        parser.state = .invalid;
        return null;
    }

    // Extract the context ID (up to the first semicolon or end of data)
    const id_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const id = rest[0..id_end];

    // Validate context ID length (1-64 chars per spec)
    if (id.len == 0 or id.len > max_context_id_len) {
        log.warn("OSC 3008: context ID length {d} out of range (1-{d})", .{
            id.len,
            max_context_id_len,
        });
        parser.state = .invalid;
        return null;
    }

    // Validate context ID characters (32..126 byte range per spec)
    for (id) |c| {
        if (c < 0x20 or c > 0x7e) {
            log.warn("OSC 3008: invalid character 0x{x:0>2} in context ID", .{c});
            parser.state = .invalid;
            return null;
        }
    }

    // Extract raw metadata fields (everything after the ID)
    const metadata = if (id_end < rest.len) rest[id_end + 1 ..] else "";

    parser.command = .{
        .context_signal = .{
            .action = action,
            .id = id,
            .metadata = metadata,
        },
    };

    return &parser.command;
}

// ============================================================================
// Tests
// ============================================================================

test "OSC 3008: basic start command" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=abc123";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .start);
    try testing.expectEqualStrings("abc123", cmd.context_signal.id);
    try testing.expectEqualStrings("", cmd.context_signal.metadata);
}

test "OSC 3008: basic end command" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;end=abc123";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .end);
    try testing.expectEqualStrings("abc123", cmd.context_signal.id);
    try testing.expectEqualStrings("", cmd.context_signal.metadata);
}

test "OSC 3008: start with metadata fields" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .start);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.context_signal.id);

    // Read individual fields
    try testing.expect(cmd.context_signal.readOption(.type).? == .container);
    try testing.expectEqualStrings("lennart", cmd.context_signal.readOption(.user).?);
    try testing.expectEqualStrings("zeta", cmd.context_signal.readOption(.hostname).?);
}

test "OSC 3008: start with all common fields" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=shell;user=root;hostname=myhost;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=bash";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.readOption(.type).? == .shell);
    try testing.expectEqualStrings("root", cmd.context_signal.readOption(.user).?);
    try testing.expectEqualStrings("myhost", cmd.context_signal.readOption(.hostname).?);
    try testing.expectEqualStrings("3deb5353d3ba43d08201c136a47ead7b", cmd.context_signal.readOption(.machineid).?);
    try testing.expectEqualStrings("d4a3d0fdf2e24fdea6d971ce73f4fbf2", cmd.context_signal.readOption(.bootid).?);
    try testing.expectEqual(@as(u64, 1062862), cmd.context_signal.readOption(.pid).?);
    try testing.expectEqual(@as(u64, 1063162), cmd.context_signal.readOption(.pidfdid).?);
    try testing.expectEqualStrings("bash", cmd.context_signal.readOption(.comm).?);
}

test "OSC 3008: end with exit metadata" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;end=myctx;exit=success;status=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .end);
    try testing.expectEqualStrings("myctx", cmd.context_signal.id);
    try testing.expect(cmd.context_signal.readOption(.exit).? == .success);
    try testing.expectEqual(@as(u64, 0), cmd.context_signal.readOption(.status).?);
}

test "OSC 3008: end with failure exit" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;end=myctx;exit=failure;status=1;signal=SIGKILL";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.readOption(.exit).? == .failure);
    try testing.expectEqual(@as(u64, 1), cmd.context_signal.readOption(.status).?);
    try testing.expectEqualStrings("SIGKILL", cmd.context_signal.readOption(.signal).?);
}

test "OSC 3008: unknown fields are ignored" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=shell;unknownfield=value;user=root";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.readOption(.type).? == .shell);
    try testing.expectEqualStrings("root", cmd.context_signal.readOption(.user).?);
}

test "OSC 3008: missing field returns null" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=myctx;user=lennart";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.readOption(.type) == null);
    try testing.expect(cmd.context_signal.readOption(.hostname) == null);
    try testing.expect(cmd.context_signal.readOption(.pid) == null);
}

test "OSC 3008: invalid prefix" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;bogus=abc123";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 3008: empty data" {
    const testing = std.testing;

    // Can't really produce empty data after "3008;" because the state machine
    // won't write a writer for that case, but we test the edge case where
    // only "start=" is present with no ID.
    var p: Parser = .init(null);
    const input = "3008;start=";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 3008: max length context ID" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const id = "a" ** 64;
    const input = "3008;start=" ++ id;
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expectEqualStrings(id, cmd.context_signal.id);
}

test "OSC 3008: over-length context ID" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const id = "a" ** 65;
    const input = "3008;start=" ++ id;
    for (input) |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 3008: context type enum coverage" {
    const testing = std.testing;

    const types = [_]struct { str: []const u8, expected: ContextType }{
        .{ .str = "boot", .expected = .boot },
        .{ .str = "container", .expected = .container },
        .{ .str = "vm", .expected = .vm },
        .{ .str = "elevate", .expected = .elevate },
        .{ .str = "chpriv", .expected = .chpriv },
        .{ .str = "subcontext", .expected = .subcontext },
        .{ .str = "remote", .expected = .remote },
        .{ .str = "shell", .expected = .shell },
        .{ .str = "command", .expected = .command },
        .{ .str = "app", .expected = .app },
        .{ .str = "service", .expected = .service },
        .{ .str = "session", .expected = .session },
    };

    for (types) |t| {
        try testing.expectEqual(t.expected, ContextType.parse(t.str).?);
    }

    try testing.expect(ContextType.parse("invalid") == null);
}

test "OSC 3008: exit status enum coverage" {
    const testing = std.testing;

    try testing.expect(ExitStatus.parse("success").? == .success);
    try testing.expect(ExitStatus.parse("failure").? == .failure);
    try testing.expect(ExitStatus.parse("crash").? == .crash);
    try testing.expect(ExitStatus.parse("interrupt").? == .interrupt);
    try testing.expect(ExitStatus.parse("invalid") == null);
}

test "OSC 3008: spec example - container start" {
    const testing = std.testing;

    // From the spec: a new container "foobar" invoked by user "lennart" on host "zeta"
    var p: Parser = .init(null);
    const input = "3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=systemd-nspawn;container=foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .start);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.context_signal.id);
    try testing.expect(cmd.context_signal.readOption(.type).? == .container);
    try testing.expectEqualStrings("lennart", cmd.context_signal.readOption(.user).?);
    try testing.expectEqualStrings("zeta", cmd.context_signal.readOption(.hostname).?);
    try testing.expectEqualStrings("systemd-nspawn", cmd.context_signal.readOption(.comm).?);
    try testing.expectEqualStrings("foobar", cmd.context_signal.readOption(.container).?);
    try testing.expectEqual(@as(u64, 1062862), cmd.context_signal.readOption(.pid).?);
}

test "OSC 3008: spec example - context end" {
    const testing = std.testing;

    // From the spec: context end
    var p: Parser = .init(null);
    const input = "3008;end=bed86fab93af4328bbed0a1224af6d40";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .end);
    try testing.expectEqualStrings("bed86fab93af4328bbed0a1224af6d40", cmd.context_signal.id);
}

test "OSC 3008: cwd and cmdline fields" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=myctx;type=command;cwd=/home/user;cmdline=ls -la";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expectEqualStrings("/home/user", cmd.context_signal.readOption(.cwd).?);
    try testing.expectEqualStrings("ls -la", cmd.context_signal.readOption(.cmdline).?);
}

test "OSC 3008: start command with no fields" {
    const testing = std.testing;

    var p: Parser = .init(null);
    const input = "3008;start=simpleid";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .context_signal);
    try testing.expect(cmd.context_signal.action == .start);
    try testing.expectEqualStrings("simpleid", cmd.context_signal.id);
    try testing.expect(cmd.context_signal.readOption(.type) == null);
    try testing.expect(cmd.context_signal.readOption(.user) == null);
    try testing.expect(cmd.context_signal.readOption(.exit) == null);
}
