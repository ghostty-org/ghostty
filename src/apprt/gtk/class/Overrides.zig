const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");

const cli = @import("../../../cli.zig");
const configpkg = @import("../../../config.zig");

const log = std.log.scoped(.gtk_ghostty_overrides);

const Overrides = @This();
const ParseError = Allocator.Error || error{ValueRequired};

command: ?configpkg.Command,
shell_integration: ?configpkg.Config.ShellIntegration,
working_directory: ?[:0]const u8,
title: ?[:0]const u8,

pub const none: Overrides = .{
    .command = null,
    .shell_integration = null,
    .working_directory = null,
    .title = null,
};

pub fn clone(self: Overrides, arena_alloc: Allocator) Allocator.Error!Overrides {
    return .{
        .command = if (self.command) |v| try v.clone(arena_alloc) else null,
        .shell_integration = self.shell_integration,
        .working_directory = if (self.working_directory) |v| try arena_alloc.dupeSentinel(u8, v, 0) else null,
        .title = if (self.title) |v| try arena_alloc.dupeSentinel(u8, v, 0) else null,
    };
}

pub fn parse(arena_alloc: Allocator, arguments_it: *glib.VariantIter) ParseError!Overrides {
    var args: std.ArrayList([:0]const u8) = .empty;

    var working_directory: ?[:0]const u8 = null;
    var title: ?[:0]const u8 = null;
    var command: ?configpkg.Command = null;
    var parsed_shell_integration: struct {
        @"shell-integration": ?configpkg.Config.ShellIntegration = null,
    } = .{};

    const s_variant_type = glib.VariantType.new("s");
    defer s_variant_type.free();

    var e_seen: bool = false;
    var i: usize = 0;

    while (arguments_it.nextValue()) |value| : (i += 1) {
        defer value.unref();

        // just to be sure
        if (value.isOfType(s_variant_type) == 0) continue;

        var len: usize = undefined;
        const buf = value.getString(&len);
        const str = buf[0..len];

        log.debug("argument: {d} {s}", .{ i, str });

        if (e_seen) {
            const copy = arena_alloc.dupeSentinel(u8, str, 0) catch |err| {
                log.warn("unable to duplicate argument {d} {s}: {t}", .{ i, str, err });
                return err;
            };
            args.append(arena_alloc, copy) catch |err| {
                log.warn("unable to append argument {d} {s}: {t}", .{ i, str, err });
                return err;
            };
            continue;
        }

        if (std.mem.eql(u8, str, "-e")) {
            e_seen = true;
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--command=")) |v| {
            var cmd: configpkg.Command = undefined;
            cmd.parseCLI(arena_alloc, v) catch |err| {
                log.warn("unable to parse command: {t}", .{err});
                return err;
            };
            command = cmd;
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--shell-integration=")) |v| {
            cli.args.parseIntoField(
                @TypeOf(parsed_shell_integration),
                arena_alloc,
                &parsed_shell_integration,
                "shell-integration",
                std.mem.trim(u8, v, &std.ascii.whitespace),
            ) catch |err| {
                log.warn("unable to parse shell integration {s}: {t}", .{ v, err });
                continue;
            };
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--working-directory=")) |v| {
            working_directory = arena_alloc.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0) catch |err| {
                log.warn("unable to duplicate working directory: {t}", .{err});
                return err;
            };
            continue;
        }

        if (std.mem.cutPrefix(u8, str, "--title=")) |v| {
            title = arena_alloc.dupeSentinel(u8, std.mem.trim(u8, v, &std.ascii.whitespace), 0) catch |err| {
                log.warn("unable to duplicate title: {t}", .{err});
                return err;
            };
            continue;
        }
    }

    if (args.items.len > 0) {
        command = .{
            .direct = args.items,
        };
    }

    return .{
        .command = command,
        .shell_integration = parsed_shell_integration.@"shell-integration",
        .working_directory = working_directory,
        .title = title,
    };
}

test "Overrides clone retains creation arguments" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn testClone(alloc: Allocator) !void {
            var arena: std.heap.ArenaAllocator = .init(alloc);
            defer arena.deinit();
            for ([_]?configpkg.Command{ null, .{ .shell = "echo hello" }, .{ .direct = &.{ "echo", "hello" } } }) |command| {
                const original: Overrides = .{
                    .command = command,
                    .shell_integration = .none,
                    .working_directory = "/tmp",
                    .title = "restored",
                };
                const copy = try original.clone(arena.allocator());
                try testing.expectEqualDeep(original, copy);
                try testing.expect(original.title.?.ptr != copy.title.?.ptr);
                try testing.expect(original.working_directory.?.ptr != copy.working_directory.?.ptr);
                if (copy.command) |value| switch (value) {
                    .shell => |shell| try testing.expect(shell.ptr != command.?.shell.ptr),
                    .direct => |args| for (args, command.?.direct) |arg, source| {
                        try testing.expect(arg.ptr != source.ptr);
                    },
                };
            }
            try testing.expectEqualDeep(Overrides.none, try Overrides.none.clone(arena.allocator()));
        }
    }.testClone, .{});
}
