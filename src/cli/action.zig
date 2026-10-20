const std = @import("std");
const Allocator = std.mem.Allocator;

/// Build a type to handle parsing CLI args for an action. The `parse`
/// function of the resulting type will parse the CLI args looking for an
/// action and filtering the found action from the list of arguments, making
/// subsequent processing steps easier.
///
/// The comptime type E must be an enum with the available actions.
/// If the type E has a decl `detectSpecialCase`, then it will be called
/// for each argument to allow handling of special cases. The function
/// signature for `detectSpecialCase` should be:
///
///   fn detectSpecialCase(arg: []const u8) ?ActionParser(E).SpecialCase
///
pub fn ActionParser(comptime E: type) type {
    return struct {
        const Self = @This();

        /// The action that was found, if any.
        action: ?E,

        /// A copy of all of the arguments (including argv0, if the
        /// iterator returned it) with the action removed.
        args: []const [:0]const u8,

        /// A result with no action and no arguments. Safe to deinit.
        pub const empty: Self = .{ .action = null, .args = &.{} };

        pub const Error = error{
            /// Multiple actions were detected. You can specify at most one
            /// action on the CLI otherwise the behavior desired is ambiguous.
            MultipleActions,

            /// Multiple fallback actions were detected. You can specify at
            /// most one fallback action on the CLI otherwise the behavior
            /// desired is ambiguous.
            MultipleFallbackActions,

            /// An unknown action was specified.
            InvalidAction,
        };

        /// The action enum E can implement the decl `detectSpecialCase` to
        /// return this enum in order to perform various special case actions.
        pub const SpecialCase = union(enum) {
            /// Immediately return this action.
            action: E,

            /// Return this action if no other action is found.
            fallback: E,

            /// Stop looking for actions. Every argument from this one on
            /// is kept as-is, even if it starts with `+`. This is a special
            /// case to allow "-e" in Ghostty.
            abort,
        };

        /// Parse the action from the process arguments.
        pub fn parseArgs(
            alloc: Allocator,
            args: std.process.Args,
        ) (std.process.Args.Iterator.InitError || Allocator.Error || Error)!Self {
            var iter = try args.iterateAllocator(alloc);
            defer iter.deinit();
            return try parse(alloc, &iter);
        }

        /// Parse the action from any iterator. Each iterator value should
        /// yield a CLI argument such as "--foo".
        pub fn parse(
            alloc: Allocator,
            iter: anytype,
        ) (Allocator.Error || Error)!Self {
            var args: std.ArrayList([:0]const u8) = .empty;
            errdefer {
                for (args.items) |arg| alloc.free(arg);
                args.deinit(alloc);
            }

            const action = action: {
                var fallback: ?struct {
                    /// The action to fall back to.
                    action: E,
                    /// If we fall back to this action, use this position to
                    /// remove it from the copied list of arguments.
                    pos: usize,
                } = null;
                var pending: ?E = null;

                while (iter.next()) |arg| {
                    // Allow handling of special cases.
                    if (@hasDecl(E, "detectSpecialCase")) special: {
                        const special = E.detectSpecialCase(arg) orelse break :special;
                        switch (special) {
                            .action => |a| break :action a,
                            .fallback => |a| {
                                if (fallback != null) return Error.MultipleFallbackActions;
                                try args.append(alloc, try alloc.dupeZ(u8, arg));
                                fallback = .{
                                    .action = a,
                                    .pos = args.items.len - 1,
                                };
                                continue;
                            },
                            .abort => {
                                try args.append(alloc, try alloc.dupeZ(u8, arg));
                                break :action pending;
                            },
                        }
                    }

                    // Commands must start with "+"
                    if (arg.len == 0 or arg[0] != '+') {
                        try args.append(alloc, try alloc.dupeZ(u8, arg));
                        continue;
                    }
                    if (pending != null) return Error.MultipleActions;
                    pending = std.meta.stringToEnum(E, arg[1..]) orelse
                        return Error.InvalidAction;
                }

                // If we have an action, we always return that action, even
                // if we've seen "--help" or "-h" because the action may have
                // its own help text.
                if (pending != null) break :action pending;

                // If we have no action but we have a fallback, then we
                // return that and remove the argument that created it.
                if (fallback) |a| {
                    alloc.free(args.orderedRemove(a.pos));
                    break :action a.action;
                }

                break :action null;
            };

            // Keep everything after the point where we stopped looking.
            while (iter.next()) |arg| {
                try args.append(alloc, try alloc.dupeZ(u8, arg));
            }

            return .{
                .action = action,
                .args = try args.toOwnedSlice(alloc),
            };
        }

        pub fn deinit(self: *const Self, alloc: Allocator) void {
            for (self.args) |arg| alloc.free(arg);
            alloc.free(self.args);
        }
    };
}

test "detect direct match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        baz,

        const ParseResult = ActionParser(@This());
    };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo",
    );
    defer iter.deinit();
    const result: Enum.ParseResult = try .parse(alloc, &iter);
    defer result.deinit(alloc);
    try testing.expectEqual(Enum.foo, result.action.?);
    try testing.expectEqual(0, result.args.len);
}

test "detect invalid match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        baz,

        const ParseResult = ActionParser(@This());
    };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+invalid",
    );
    defer iter.deinit();
    try testing.expectError(
        error.InvalidAction,
        Enum.ParseResult.parse(alloc, &iter),
    );
}

test "detect multiple actions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        baz,

        const ParseResult = ActionParser(@This());
    };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "+foo +bar",
    );
    defer iter.deinit();
    try testing.expectError(
        error.MultipleActions,
        Enum.ParseResult.parse(alloc, &iter),
    );
}

test "detect no match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        baz,

        const ParseResult = ActionParser(@This());
    };

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--some-flag",
    );
    defer iter.deinit();
    const result: Enum.ParseResult = try .parse(alloc, &iter);
    defer result.deinit(alloc);
    try testing.expect(result.action == null);
    try testing.expectEqual(1, result.args.len);
    try testing.expectEqualStrings("--some-flag", result.args[0]);
}

test "detect special case action" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,

        const ParseResult = ActionParser(@This());

        fn detectSpecialCase(arg: []const u8) ?ParseResult.SpecialCase {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .action = .foo }
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.foo, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("+bar", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.foo, result.action.?);
        try testing.expectEqual(0, result.args.len);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.bar, result.action.?);
        try testing.expectEqual(0, result.args.len);
    }
}

test "detect special case fallback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,
        baz,

        pub const ParseResult = ActionParser(@This());

        fn detectSpecialCase(arg: []const u8) ?ParseResult.SpecialCase {
            return if (std.mem.eql(u8, arg, "--special"))
                .{ .fallback = .foo }
            else if (std.mem.eql(u8, arg, "--super-special"))
                .{ .fallback = .baz }
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.foo, result.action.?);
        try testing.expectEqual(0, result.args.len);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.bar, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("--special", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special +bar",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.bar, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("--special", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--a=42 --special --b=67",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.foo, result.action.?);
        try testing.expectEqual(2, result.args.len);
        try testing.expectEqualStrings("--a=42", result.args[0]);
        try testing.expectEqualStrings("--b=67", result.args[1]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--special --super-special",
        );
        defer iter.deinit();
        try testing.expectError(error.MultipleFallbackActions, Enum.ParseResult.parse(alloc, &iter));
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --special --super-special",
        );
        defer iter.deinit();
        try testing.expectError(error.MultipleFallbackActions, Enum.ParseResult.parse(alloc, &iter));
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar --super-special",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.bar, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("--super-special", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--super-special --a=42",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.baz, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("--a=42", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--super-special",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.baz, result.action.?);
        try testing.expectEqual(0, result.args.len);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "--b=67 --super-special --a=42",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.baz, result.action.?);
        try testing.expectEqual(2, result.args.len);
        try testing.expectEqualStrings("--b=67", result.args[0]);
        try testing.expectEqualStrings("--a=42", result.args[1]);
    }
}

test "detect special case abort" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const Enum = enum {
        foo,
        bar,

        pub const ParseResult = ActionParser(@This());

        fn detectSpecialCase(arg: []const u8) ?ParseResult.SpecialCase {
            return if (std.mem.eql(u8, arg, "-e"))
                .abort
            else
                null;
        }
    };

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expect(result.action == null);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("-e", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+foo -e",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.foo, result.action.?);
        try testing.expectEqual(1, result.args.len);
        try testing.expectEqualStrings("-e", result.args[0]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "-e +bar",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expect(result.action == null);
        try testing.expectEqual(2, result.args.len);
        try testing.expectEqualStrings("-e", result.args[0]);
        try testing.expectEqualStrings("+bar", result.args[1]);
    }

    {
        var iter = try std.process.Args.IteratorGeneral(.{}).init(
            alloc,
            "+bar -e +bar",
        );
        defer iter.deinit();
        const result: Enum.ParseResult = try .parse(alloc, &iter);
        defer result.deinit(alloc);
        try testing.expectEqual(Enum.bar, result.action.?);
        try testing.expectEqual(2, result.args.len);
        try testing.expectEqualStrings("-e", result.args[0]);
        try testing.expectEqualStrings("+bar", result.args[1]);
    }
}
