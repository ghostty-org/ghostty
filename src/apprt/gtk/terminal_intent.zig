//! The freedesktop Terminal Intent, `org.freedesktop.Terminal1`: a D-Bus
//! interface that lets the desktop run a program (a `Terminal=true` app,
//! say) in a new Ghostty window. It is exported beside
//! `org.freedesktop.Application`, on the same object path.
//!
//! https://specifications.freedesktop.org/terminal-intent/latest/
const TerminalIntent = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");

const Application = @import("class/application.zig").Application;
const Overrides = @import("class/Overrides.zig");

const log = std.log.scoped(.gtk_terminal_intent);

/// The interface we implement.
const interface_name = "org.freedesktop.Terminal1";

const interface_xml =
    \\<node>
    \\  <interface name="org.freedesktop.Terminal1">
    \\    <method name="LaunchCommand">
    \\      <arg type="aa{sv}" name="commands" direction="in"/>
    \\      <arg type="ay" name="desktop_entry" direction="in"/>
    \\      <arg type="a{sv}" name="options" direction="in"/>
    \\      <arg type="a{sv}" name="platform_data" direction="in"/>
    \\    </method>
    \\  </interface>
    \\</node>
;

const vtable: gio.DBusInterfaceVTable = .{
    .f_method_call = &methodCall,
    .f_get_property = null,
    .f_set_property = null,

    // Reserved by GDBus for future expansion, it is never read.
    .f_padding = undefined,
};

/// The registration ID returned by `registerObject`. Zero is never a valid
/// registration ID so we use it to mean "not registered".
registration_id: c_uint = 0,

pub const Error = error{
    InvalidInterface,
    RegistrationFailed,
};

/// Export the interface on `object_path`, the path GApplication exports
/// `org.freedesktop.Application` on, as the spec requires.
pub fn register(
    self: *TerminalIntent,
    app: *Application,
    connection: *gio.DBusConnection,
    object_path: [*:0]const u8,
) Error!void {
    assert(self.registration_id == 0);

    var err_: ?*glib.Error = null;
    defer if (err_) |err| err.free();

    const node_info = gio.DBusNodeInfo.newForXml(interface_xml, &err_) orelse {
        log.warn(
            "unable to parse interface definition err={s}",
            .{errorMessage(err_)},
        );
        return error.InvalidInterface;
    };
    // GDBus keeps its own reference to the interface info.
    defer node_info.unref();

    const interface_info = node_info.lookupInterface(interface_name) orelse
        return error.InvalidInterface;

    // The application outlives its registration, so there is nothing to
    // free, but the bindings require a non-null destroy notify.
    const registration_id = connection.registerObject(
        object_path,
        interface_info,
        &vtable,
        app,
        &noopDestroy,
        &err_,
    );
    if (registration_id == 0) {
        log.warn(
            "unable to export terminal intent err={s}",
            .{errorMessage(err_)},
        );
        return error.RegistrationFailed;
    }

    self.registration_id = registration_id;
    log.debug("terminal intent exported path={s}", .{object_path});
}

/// Unexport the interface. Safe to call if we were never registered.
pub fn unregister(
    self: *TerminalIntent,
    connection: *gio.DBusConnection,
) void {
    if (self.registration_id != 0) {
        _ = connection.unregisterObject(self.registration_id);
        self.registration_id = 0;
    }
}

fn noopDestroy(_: ?*anyopaque) callconv(.c) void {}

fn errorMessage(err_: ?*glib.Error) [:0]const u8 {
    const err = err_ orelse return "(unknown)";
    const message = err.f_message orelse return "(unknown)";
    return std.mem.sliceTo(message, 0);
}

//---------------------------------------------------------------
// D-Bus method handling

fn methodCall(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: *glib.Variant,
    invocation: *gio.DBusMethodInvocation,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const app: *Application = @ptrCast(@alignCast(user_data orelse return));

    // GDBus has already checked the method and its signature against
    // the introspection data.
    if (!std.mem.eql(u8, std.mem.span(method_name), "LaunchCommand")) {
        invocation.returnDbusError(
            "org.freedesktop.DBus.Error.UnknownMethod",
            "Unknown method",
        );
        return;
    }

    var arena: std.heap.ArenaAllocator = .init(app.allocator());
    defer arena.deinit();

    const request = parse(arena.allocator(), parameters) catch |err| {
        log.warn("rejecting LaunchCommand: {t}", .{err});
        switch (err) {
            error.InvalidArgs => invocation.returnDbusError(
                "org.freedesktop.DBus.Error.InvalidArgs",
                "Invalid exec, env or working_directory",
            ),
            error.OutOfMemory => invocation.returnDbusError(
                "org.freedesktop.DBus.Error.NoMemory",
                "Out of memory",
            ),
        }
        return;
    };

    app.launchCommands(request.tabs, request.startup_id);
    invocation.returnValue(null);
}

/// A `LaunchCommand` call, as one window with a tab per command.
pub const Request = struct {
    tabs: []const Overrides,
    startup_id: ?[:0]const u8,
};

pub const ParseError = Allocator.Error || error{InvalidArgs};

/// Parse the `(aa{sv}aya{sv}a{sv})` parameters of `LaunchCommand`.
/// Every key is optional and keys of the wrong type count as absent,
/// since the spec asks for unknown keys to be ignored. Everything
/// returned is allocated from `alloc`.
pub fn parse(alloc: Allocator, parameters: *glib.Variant) ParseError!Request {
    if (!isType(parameters, "(aa{sv}aya{sv}a{sv})")) return error.InvalidArgs;

    const commands = parameters.getChildValue(0);
    defer commands.unref();
    const options = parameters.getChildValue(2);
    defer options.unref();
    const platform_data = parameters.getChildValue(3);
    defer platform_data.unref();

    const keep_open = keep_open: {
        const value = lookup(options, "keep-terminal-open", "b") orelse
            break :keep_open false;
        defer value.unref();
        break :keep_open value.getBoolean() != 0;
    };

    const startup_id: ?[:0]const u8 = startup_id: {
        for ([_][:0]const u8{ "activation-token", "desktop-startup-id" }) |key| {
            const value = lookup(platform_data, key, "s") orelse continue;
            defer value.unref();
            var len: usize = 0;
            const str = value.getString(&len)[0..len];
            if (str.len == 0) continue;
            break :startup_id try alloc.dupeZ(u8, str);
        }
        break :startup_id null;
    };

    // An empty list still means a window with a shell in it.
    const n = commands.nChildren();
    const tabs = try alloc.alloc(Overrides, @max(n, 1));
    tabs[0] = .{ .working_directory = home };
    for (0..n) |i| {
        const command = commands.getChildValue(i);
        defer command.unref();
        tabs[i] = try parseCommand(alloc, command, keep_open);
    }

    return .{ .tabs = tabs, .startup_id = startup_id };
}

/// `$HOME`, where a command with no working directory runs. The
/// surface expands it when it finalizes the working directory.
const home = "~/";

fn parseCommand(
    alloc: Allocator,
    command: *glib.Variant,
    keep_open: bool,
) ParseError!Overrides {
    var result: Overrides = .{ .working_directory = home };

    if (lookup(command, "exec", "aay")) |value| {
        defer value.unref();
        const argv = try byteStrings(alloc, value);

        // An empty argv, or an empty program, means a regular shell.
        if (argv.len > 0 and argv[0].len > 0) {
            result.command = .{ .direct = argv };
            result.wait_after_command = keep_open;
        }
    }

    if (lookup(command, "env", "aay")) |value| {
        defer value.unref();
        const env = try byteStrings(alloc, value);
        for (env) |entry| {
            const key, _ = std.mem.cutScalar(u8, entry, '=') orelse
                return error.InvalidArgs;
            if (key.len == 0) return error.InvalidArgs;
        }
        result.env = env;
    }

    if (lookup(command, "working_directory", "ay")) |value| {
        defer value.unref();
        const dir = try byteString(alloc, value);
        if (dir.len > 0) result.working_directory = if (dir[0] == '/')
            dir
        else
            try std.mem.concatWithSentinel(alloc, u8, &.{ home, dir }, 0);
    }

    return result;
}

fn isType(value: *glib.Variant, comptime type_string: [:0]const u8) bool {
    return std.mem.eql(u8, std.mem.span(value.getTypeString()), type_string);
}

/// Look `key` up in an `a{sv}`, returning a new reference to its value
/// if it is there and of type `type_string`. This walks the dictionary
/// rather than using `g_variant_lookup_value`, whose binding cannot
/// return null.
fn lookup(
    dict: *glib.Variant,
    key: []const u8,
    comptime type_string: [:0]const u8,
) ?*glib.Variant {
    for (0..dict.nChildren()) |i| {
        const entry = dict.getChildValue(i);
        defer entry.unref();

        const name = entry.getChildValue(0);
        defer name.unref();
        var len: usize = 0;
        if (!std.mem.eql(u8, name.getString(&len)[0..len], key)) continue;

        const boxed = entry.getChildValue(1);
        defer boxed.unref();
        const value = boxed.getVariant();
        if (isType(value, type_string)) return value;
        value.unref();
        return null;
    }

    return null;
}

/// An `ay` as a string. GLib writes bytestrings with a trailing NUL,
/// which is dropped. A NUL anywhere else could not be passed on to a
/// program, so it is an error.
fn byteString(alloc: Allocator, value: *glib.Variant) ParseError![:0]const u8 {
    // `g_variant_get_fixed_array` returns NULL for an empty array.
    if (value.nChildren() == 0) return "";

    var len: usize = 0;
    const ptr: [*]const u8 = @ptrCast(value.getFixedArray(&len, 1));
    var bytes = ptr[0..len];
    if (bytes[bytes.len - 1] == 0) bytes = bytes[0 .. bytes.len - 1];
    if (std.mem.findScalar(u8, bytes, 0) != null) return error.InvalidArgs;
    return try alloc.dupeZ(u8, bytes);
}

/// An `aay` as a list of strings, as `byteString` reads each one.
fn byteStrings(alloc: Allocator, value: *glib.Variant) ParseError![]const [:0]const u8 {
    const result = try alloc.alloc([:0]const u8, value.nChildren());
    for (result, 0..) |*str, i| {
        const child = value.getChildValue(i);
        defer child.unref();
        str.* = try byteString(alloc, child);
    }
    return result;
}

/// Parse GVariant text the way a call arrives: serialized into a D-Bus
/// message and read back out, rather than as an in-memory value.
fn testParse(alloc: Allocator, text: [:0]const u8) ParseError!Request {
    const value = glib.Variant.parse(null, text, null, null, null) orelse
        return error.InvalidArgs;
    // `g_variant_parse` returns a full reference, not a floating one, so
    // the message's `ref_sink` takes a second reference rather than ours.
    defer value.unref();

    const message = gio.DBusMessage.newMethodCall(
        "com.mitchellh.ghostty",
        "/com/mitchellh/ghostty",
        interface_name,
        "LaunchCommand",
    );
    defer message.unref();
    message.setBody(value);

    var len: usize = 0;
    const blob = message.toBlob(&len, .{}, null) orelse return error.InvalidArgs;
    defer glib.free(blob);

    const received = gio.DBusMessage.newFromBlob(blob, len, .{}, null) orelse
        return error.InvalidArgs;
    defer received.unref();

    return parse(alloc, received.getBody() orelse return error.InvalidArgs);
}

test "empty commands opens a shell" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(arena.allocator(), "(@aa{sv} [], b'', @a{sv} {}, @a{sv} {})");
    try testing.expectEqual(1, request.tabs.len);
    try testing.expect(request.tabs[0].command == null);
    try testing.expectEqualStrings(home, request.tabs[0].working_directory.?);
    try testing.expect(request.startup_id == null);
}

test "empty command opens a shell" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(
        arena.allocator(),
        "([@a{sv} {}, {'exec': <@aay []>}, {'exec': <[b'', b'x']>}], b'', @a{sv} {'keep-terminal-open': <true>}, @a{sv} {})",
    );
    try testing.expectEqual(3, request.tabs.len);
    for (request.tabs) |tab| {
        try testing.expect(tab.command == null);
        try testing.expect(!tab.wait_after_command);
        try testing.expectEqualStrings(home, tab.working_directory.?);
    }
}

test "exec as GLib sends it" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // A GVariant b'' literal carries a trailing NUL, as GLib's do.
    const request = try testParse(
        arena.allocator(),
        "([{'exec': <[b'vim', b'/tmp/a file']>, 'working_directory': <b'/opt/editor'>}], b'/usr/share/applications/vim.desktop', @a{sv} {}, {'desktop-startup-id': <'id'>})",
    );
    try testing.expectEqual(1, request.tabs.len);
    const tab = request.tabs[0];
    const argv = tab.command.?.direct;
    try testing.expectEqual(2, argv.len);
    try testing.expectEqualStrings("vim", argv[0]);
    try testing.expectEqualStrings("/tmp/a file", argv[1]);
    try testing.expectEqualStrings("/opt/editor", tab.working_directory.?);
    try testing.expectEqual(0, tab.env.len);
    try testing.expect(!tab.wait_after_command);
    try testing.expectEqualStrings("id", request.startup_id.?);
}

test "bytestrings without a trailing NUL" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(
        arena.allocator(),
        "([{'exec': <[[byte 0x6c, 0x73]]>}], b'', @a{sv} {}, @a{sv} {})",
    );
    try testing.expectEqualStrings("ls", request.tabs[0].command.?.direct[0]);
}

test "keys of the wrong type are ignored" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(
        arena.allocator(),
        "([{'exec': <'vim'>, 'env': <'FOO=bar'>, 'working_directory': <'/tmp'>, 'other': <1>}], b'', {'keep-terminal-open': <'yes'>}, {'activation-token': <1>})",
    );
    try testing.expectEqual(1, request.tabs.len);
    try testing.expect(request.tabs[0].command == null);
    try testing.expectEqual(0, request.tabs[0].env.len);
    try testing.expectEqualStrings(home, request.tabs[0].working_directory.?);
    try testing.expect(request.startup_id == null);
}

test "relative working directory is under home" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(
        arena.allocator(),
        "([{'working_directory': <b'src/ghostty'>}], b'', @a{sv} {}, @a{sv} {})",
    );
    try testing.expectEqualStrings("~/src/ghostty", request.tabs[0].working_directory.?);
}

test "env and keep-terminal-open" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const request = try testParse(
        arena.allocator(),
        "([{'exec': <[b'make']>, 'env': <[b'FOO=a=b', b'EMPTY=']>}], b'', {'keep-terminal-open': <true>}, {'activation-token': <'token'>, 'desktop-startup-id': <'id'>})",
    );
    const tab = request.tabs[0];
    try testing.expect(tab.wait_after_command);
    try testing.expectEqual(2, tab.env.len);
    try testing.expectEqualStrings("FOO=a=b", tab.env[0]);
    try testing.expectEqualStrings("EMPTY=", tab.env[1]);
    try testing.expectEqualStrings("token", request.startup_id.?);
}

test "invalid arguments" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // No `=` in an env entry.
    try testing.expectError(error.InvalidArgs, testParse(
        alloc,
        "([{'env': <[b'FOO']>}], b'', @a{sv} {}, @a{sv} {})",
    ));

    // An empty name.
    try testing.expectError(error.InvalidArgs, testParse(
        alloc,
        "([{'env': <[b'=bar']>}], b'', @a{sv} {}, @a{sv} {})",
    ));

    // A NUL inside an argument.
    try testing.expectError(error.InvalidArgs, testParse(
        alloc,
        "([{'exec': <[[byte 0x61, 0x00, 0x62]]>}], b'', @a{sv} {}, @a{sv} {})",
    ));

    // The wrong signature altogether.
    try testing.expectError(error.InvalidArgs, testParse(alloc, "('vim',)"));
}
