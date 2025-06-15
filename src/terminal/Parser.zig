//! VT-series parser for escape and control sequences.
//!
//! This is implemented directly as the state machine described on
//! vt100.net: https://vt100.net/emu/dec_ansi_parser
const Parser = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const table = @import("parse_table.zig").table;
const osc = @import("osc.zig");

const log = std.log.scoped(.parser);

/// States for the state machine
pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_intermediate,
    csi_param,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
};

/// Transition action is an action that can be taken during a state
/// transition. This is more of an internal action, not one used by
/// end users, typically.
pub const TransitionAction = enum {
    none,
    ignore,
    print,
    execute,
    collect,
    param,
    esc_dispatch,
    csi_dispatch,
    put,
    osc_put,
    apc_put,
};

/// Action is the action that a caller of the parser is expected to
/// take as a result of some input character.
pub const Action = union(enum) {
    pub const Tag = std.meta.FieldEnum(Action);

    /// Draw character to the screen. This is a unicode codepoint.
    print: u21,

    /// Execute the C0 or C1 function.
    execute: u8,

    /// Execute the CSI command. Note that pointers within this
    /// structure are only valid until the next call to "next".
    csi_dispatch: CSI,

    /// Execute the ESC command.
    esc_dispatch: ESC,

    /// Execute the OSC command.
    osc_dispatch: osc.Command,

    /// DCS-related events.
    dcs_hook: DCS,
    dcs_put: u8,
    dcs_unhook: void,

    /// APC data
    apc_start: void,
    apc_put: u8,
    apc_end: void,

    pub const CSI = struct {
        intermediates: []u8,
        params: []u16,
        params_sep: SepList,
        final: u8,

        /// The list of separators used for CSI params. The value of the
        /// bit can be mapped to Sep. The index of this bit set specifies
        /// the separator AFTER that param. For example: 0;4:3 would have
        /// index 1 set.
        pub const SepList = std.StaticBitSet(MAX_PARAMS);

        /// The separator used for CSI params.
        pub const Sep = enum(u1) { semicolon = 0, colon = 1 };

        // Implement formatter for logging
        pub fn format(
            self: CSI,
            comptime layout: []const u8,
            opts: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = layout;
            _ = opts;
            try std.fmt.format(writer, "ESC [ {s} {any} {c}", .{
                self.intermediates,
                self.params,
                self.final,
            });
        }
    };

    pub const ESC = struct {
        intermediates: []u8,
        final: u8,

        // Implement formatter for logging
        pub fn format(
            self: ESC,
            comptime layout: []const u8,
            opts: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = layout;
            _ = opts;
            try std.fmt.format(writer, "ESC {s} {c}", .{
                self.intermediates,
                self.final,
            });
        }
    };

    pub const DCS = struct {
        intermediates: []const u8 = "",
        params: []const u16 = &.{},
        final: u8,
    };

    // Implement formatter for logging. This is mostly copied from the
    // std.fmt implementation, but we modify it slightly so that we can
    // print out custom formats for some of our primitives.
    pub fn format(
        self: Action,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        const T = Action;
        const info = @typeInfo(T).@"union";

        try writer.writeAll(@typeName(T));
        if (info.tag_type) |TagType| {
            try writer.writeAll("{ .");
            try writer.writeAll(@tagName(@as(TagType, self)));
            try writer.writeAll(" = ");

            inline for (info.fields) |u_field| {
                // If this is the active field...
                if (self == @field(TagType, u_field.name)) {
                    const value = @field(self, u_field.name);
                    switch (@TypeOf(value)) {
                        // Unicode
                        u21 => try std.fmt.format(writer, "'{u}' (U+{X})", .{ value, value }),

                        // Byte
                        u8 => try std.fmt.format(writer, "0x{x}", .{value}),

                        // Note: we don't do ASCII (u8) because there are a lot
                        // of invisible characters we don't want to handle right
                        // now.

                        // All others do the default behavior
                        else => try std.fmt.formatType(
                            @field(self, u_field.name),
                            "any",
                            opts,
                            writer,
                            3,
                        ),
                    }
                }
            }

            try writer.writeAll(" }");
        } else {
            try format(writer, "@{x}", .{@intFromPtr(&self)});
        }
    }
};

/// Maximum number of intermediate characters during parsing. This is
/// 4 because we also use the intermediates array for UTF8 decoding which
/// can be at most 4 bytes.
const MAX_INTERMEDIATE = 4;

/// Maximum number of CSI parameters. This is arbitrary. Practically, the
/// only CSI command that uses more than 3 parameters is the SGR command
/// which can be infinitely long. 24 is a reasonable limit based on empirical
/// data. This used to be 16 but Kakoune has a SGR command that uses 17
/// parameters.
///
/// We could in the future make this the static limit and then allocate after
/// but that's a lot more work and practically its so rare to exceed this
/// number. I implore TUI authors to not use more than this number of CSI
/// params, but I suspect we'll introduce a slow path with heap allocation
/// one day.
const MAX_PARAMS = 24;

/// Current state of the state machine
state: State = .ground,

/// Intermediate tracking.
intermediates: [MAX_INTERMEDIATE]u8 = undefined,
intermediates_idx: u8 = 0,

/// Param tracking, building
params: [MAX_PARAMS]u16 = undefined,
params_sep: Action.CSI.SepList = .initEmpty(),
params_idx: u8 = 0,
param_acc: u16 = 0,
param_acc_idx: u8 = 0,

/// Parser for OSC sequences
osc_parser: osc.Parser = .{},

pub fn init() Parser {
    return .{};
}

pub fn deinit(self: *Parser) void {
    self.osc_parser.deinit();
}

/// Next consumes the next character c and returns the actions to execute.
/// Up to 3 actions may need to be executed -- in order -- representing
/// the state exit, transition, and entry actions.
pub fn next(self: *Parser, c: u8) [3]?Action {
    const effect = table[c][@intFromEnum(self.state)];

    // log.info("next: {x}", .{c});

    const next_state = effect.state;
    const action = effect.action;

    // After generating the actions, we set our next state.
    defer self.state = next_state;

    // When going from one state to another, the actions take place in this order:
    //
    // 1. exit action from old state
    // 2. transition action
    // 3. entry action to new state
    return [3]?Action{
        // Exit depends on current state
        if (self.state == next_state) null else switch (self.state) {
            .osc_string => if (self.osc_parser.end(c)) |cmd|
                Action{ .osc_dispatch = cmd }
            else
                null,
            .dcs_passthrough => Action{ .dcs_unhook = {} },
            .sos_pm_apc_string => Action{ .apc_end = {} },
            else => null,
        },

        self.doAction(action, c),

        // Entry depends on new state
        if (self.state == next_state) null else switch (next_state) {
            .escape, .dcs_entry, .csi_entry => clear: {
                self.clear();
                break :clear null;
            },
            .osc_string => osc_string: {
                self.osc_parser.reset();
                break :osc_string null;
            },
            .dcs_passthrough => dcs_hook: {
                // Finalize parameters
                if (self.param_acc_idx > 0) {
                    self.params[self.params_idx] = self.param_acc;
                    self.params_idx += 1;
                }
                break :dcs_hook .{
                    .dcs_hook = .{
                        .intermediates = self.intermediates[0..self.intermediates_idx],
                        .params = self.params[0..self.params_idx],
                        .final = c,
                    },
                };
            },
            .sos_pm_apc_string => Action{ .apc_start = {} },
            else => null,
        },
    };
}

pub fn collect(self: *Parser, c: u8) void {
    if (self.intermediates_idx >= MAX_INTERMEDIATE) {
        log.warn("invalid intermediates count", .{});
        return;
    }

    self.intermediates[self.intermediates_idx] = c;
    self.intermediates_idx += 1;
}

fn doAction(self: *Parser, action: TransitionAction, c: u8) ?Action {
    return switch (action) {
        .none, .ignore => null,
        .print => Action{ .print = c },
        .execute => Action{ .execute = c },
        .collect => collect: {
            self.collect(c);
            break :collect null;
        },
        .param => param: {
            // Semicolon separates parameters. If we encounter a semicolon
            // we need to store and move on to the next parameter.
            if (c == ';' or c == ':') {
                // Ignore too many parameters
                if (self.params_idx >= MAX_PARAMS) break :param null;

                // Set param final value
                self.params[self.params_idx] = self.param_acc;
                if (c == ':') self.params_sep.set(self.params_idx);
                self.params_idx += 1;

                // Reset current param value to 0
                self.param_acc = 0;
                self.param_acc_idx = 0;
                break :param null;
            }

            // A numeric value. Add it to our accumulator.
            if (self.param_acc_idx > 0) {
                self.param_acc *|= 10;
            }
            self.param_acc +|= c - '0';

            // Increment our accumulator index. If we overflow then
            // we're out of bounds and we exit immediately.
            self.param_acc_idx, const overflow = @addWithOverflow(self.param_acc_idx, 1);
            if (overflow > 0) break :param null;

            // The client is expected to perform no action.
            break :param null;
        },
        .osc_put => osc_put: {
            self.osc_parser.next(c);
            break :osc_put null;
        },
        .csi_dispatch => csi_dispatch: {
            // Ignore too many parameters
            if (self.params_idx >= MAX_PARAMS) break :csi_dispatch null;

            // Finalize parameters if we have one
            if (self.param_acc_idx > 0) {
                self.params[self.params_idx] = self.param_acc;
                self.params_idx += 1;
            }

            const result: Action = .{
                .csi_dispatch = .{
                    .intermediates = self.intermediates[0..self.intermediates_idx],
                    .params = self.params[0..self.params_idx],
                    .params_sep = self.params_sep,
                    .final = c,
                },
            };

            // We only allow colon or mixed separators for the 'm' command.
            if (c != 'm' and self.params_sep.count() > 0) {
                log.warn(
                    "CSI colon or mixed separators only allowed for 'm' command, got: {}",
                    .{result},
                );
                break :csi_dispatch null;
            }

            break :csi_dispatch result;
        },
        .esc_dispatch => Action{
            .esc_dispatch = .{
                .intermediates = self.intermediates[0..self.intermediates_idx],
                .final = c,
            },
        },
        .put => Action{ .dcs_put = c },
        .apc_put => Action{ .apc_put = c },
    };
}

pub fn clear(self: *Parser) void {
    self.intermediates_idx = 0;
    self.params_idx = 0;
    self.params_sep = .initEmpty();
    self.param_acc = 0;
    self.param_acc_idx = 0;
}

test {
    var p = init();
    _ = p.next(0x9E);
    try testing.expect(p.state == .sos_pm_apc_string);
    _ = p.next(0x9C);
    try testing.expect(p.state == .ground);

    {
        const a = p.next('a');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .print);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next(0x19);
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .execute);
        try testing.expect(a[2] == null);
    }
}

test "esc: ESC ( B" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next('(');

    {
        const a = p.next('B');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .esc_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.esc_dispatch;
        try testing.expect(d.final == 'B');
        try testing.expect(d.intermediates.len == 1);
        try testing.expect(d.intermediates[0] == '(');
    }
}

test "csi: ESC [ H" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next(0x5B);

    {
        const a = p.next(0x48);
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 0x48);
        try testing.expect(d.params.len == 0);
    }
}

test "csi: ESC [ 1 ; 4 H" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next(0x5B);
    _ = p.next(0x31); // 1
    _ = p.next(0x3B); // ;
    _ = p.next(0x34); // 4

    {
        const a = p.next(0x48); // H
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'H');
        try testing.expect(d.params.len == 2);
        try testing.expectEqual(@as(u16, 1), d.params[0]);
        try testing.expectEqual(@as(u16, 4), d.params[1]);
    }
}

test "csi: SGR ESC [ 38 : 2 m" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('3');
    _ = p.next('8');
    _ = p.next(':');
    _ = p.next('2');

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expect(d.params.len == 2);
        try testing.expectEqual(@as(u16, 38), d.params[0]);
        try testing.expect(d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(!d.params_sep.isSet(1));
    }
}

test "csi: SGR colon followed by semicolon" {
    var p = init();
    _ = p.next(0x1B);
    for ("[48:2") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);
    }

    _ = p.next(0x1B);
    _ = p.next('[');
    {
        const a = p.next('H');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);
    }
}

test "csi: SGR mixed colon and semicolon" {
    var p = init();
    _ = p.next(0x1B);
    for ("[38:5:1;48:5:0") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);
    }
}

test "csi: SGR ESC [ 48 : 2 m" {
    var p = init();
    _ = p.next(0x1B);
    for ("[48:2:240:143:104") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expect(d.params.len == 5);
        try testing.expectEqual(@as(u16, 48), d.params[0]);
        try testing.expect(d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(d.params_sep.isSet(1));
        try testing.expectEqual(@as(u16, 240), d.params[2]);
        try testing.expect(d.params_sep.isSet(2));
        try testing.expectEqual(@as(u16, 143), d.params[3]);
        try testing.expect(d.params_sep.isSet(3));
        try testing.expectEqual(@as(u16, 104), d.params[4]);
        try testing.expect(!d.params_sep.isSet(4));
    }
}

test "csi: SGR ESC [4:3m colon" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next('[');
    _ = p.next('4');
    _ = p.next(':');
    _ = p.next('3');

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expect(d.params.len == 2);
        try testing.expectEqual(@as(u16, 4), d.params[0]);
        try testing.expect(d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 3), d.params[1]);
        try testing.expect(!d.params_sep.isSet(1));
    }
}

test "csi: SGR with many blank and colon" {
    var p = init();
    _ = p.next(0x1B);
    for ("[58:2::240:143:104") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expect(d.params.len == 6);
        try testing.expectEqual(@as(u16, 58), d.params[0]);
        try testing.expect(d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(d.params_sep.isSet(1));
        try testing.expectEqual(@as(u16, 0), d.params[2]);
        try testing.expect(d.params_sep.isSet(2));
        try testing.expectEqual(@as(u16, 240), d.params[3]);
        try testing.expect(d.params_sep.isSet(3));
        try testing.expectEqual(@as(u16, 143), d.params[4]);
        try testing.expect(d.params_sep.isSet(4));
        try testing.expectEqual(@as(u16, 104), d.params[5]);
        try testing.expect(!d.params_sep.isSet(5));
    }
}

// This is from a Kakoune actual SGR sequence.
test "csi: SGR mixed colon and semicolon with blank" {
    var p = init();
    _ = p.next(0x1B);
    for ("[;4:3;38;2;175;175;215;58:2::190:80:70") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expectEqual(14, d.params.len);
        try testing.expectEqual(@as(u16, 0), d.params[0]);
        try testing.expect(!d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 4), d.params[1]);
        try testing.expect(d.params_sep.isSet(1));
        try testing.expectEqual(@as(u16, 3), d.params[2]);
        try testing.expect(!d.params_sep.isSet(2));
        try testing.expectEqual(@as(u16, 38), d.params[3]);
        try testing.expect(!d.params_sep.isSet(3));
        try testing.expectEqual(@as(u16, 2), d.params[4]);
        try testing.expect(!d.params_sep.isSet(4));
        try testing.expectEqual(@as(u16, 175), d.params[5]);
        try testing.expect(!d.params_sep.isSet(5));
        try testing.expectEqual(@as(u16, 175), d.params[6]);
        try testing.expect(!d.params_sep.isSet(6));
        try testing.expectEqual(@as(u16, 215), d.params[7]);
        try testing.expect(!d.params_sep.isSet(7));
        try testing.expectEqual(@as(u16, 58), d.params[8]);
        try testing.expect(d.params_sep.isSet(8));
        try testing.expectEqual(@as(u16, 2), d.params[9]);
        try testing.expect(d.params_sep.isSet(9));
        try testing.expectEqual(@as(u16, 0), d.params[10]);
        try testing.expect(d.params_sep.isSet(10));
        try testing.expectEqual(@as(u16, 190), d.params[11]);
        try testing.expect(d.params_sep.isSet(11));
        try testing.expectEqual(@as(u16, 80), d.params[12]);
        try testing.expect(d.params_sep.isSet(12));
        try testing.expectEqual(@as(u16, 70), d.params[13]);
        try testing.expect(!d.params_sep.isSet(13));
    }
}

// This is from a Kakoune actual SGR sequence also.
test "csi: SGR mixed colon and semicolon setting underline, bg, fg" {
    var p = init();
    _ = p.next(0x1B);
    for ("[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('m');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'm');
        try testing.expectEqual(17, d.params.len);
        try testing.expectEqual(@as(u16, 4), d.params[0]);
        try testing.expect(d.params_sep.isSet(0));
        try testing.expectEqual(@as(u16, 3), d.params[1]);
        try testing.expect(!d.params_sep.isSet(1));
        try testing.expectEqual(@as(u16, 38), d.params[2]);
        try testing.expect(!d.params_sep.isSet(2));
        try testing.expectEqual(@as(u16, 2), d.params[3]);
        try testing.expect(!d.params_sep.isSet(3));
        try testing.expectEqual(@as(u16, 51), d.params[4]);
        try testing.expect(!d.params_sep.isSet(4));
        try testing.expectEqual(@as(u16, 51), d.params[5]);
        try testing.expect(!d.params_sep.isSet(5));
        try testing.expectEqual(@as(u16, 51), d.params[6]);
        try testing.expect(!d.params_sep.isSet(6));
        try testing.expectEqual(@as(u16, 48), d.params[7]);
        try testing.expect(!d.params_sep.isSet(7));
        try testing.expectEqual(@as(u16, 2), d.params[8]);
        try testing.expect(!d.params_sep.isSet(8));
        try testing.expectEqual(@as(u16, 170), d.params[9]);
        try testing.expect(!d.params_sep.isSet(9));
        try testing.expectEqual(@as(u16, 170), d.params[10]);
        try testing.expect(!d.params_sep.isSet(10));
        try testing.expectEqual(@as(u16, 170), d.params[11]);
        try testing.expect(!d.params_sep.isSet(11));
        try testing.expectEqual(@as(u16, 58), d.params[12]);
        try testing.expect(!d.params_sep.isSet(12));
        try testing.expectEqual(@as(u16, 2), d.params[13]);
        try testing.expect(!d.params_sep.isSet(13));
        try testing.expectEqual(@as(u16, 255), d.params[14]);
        try testing.expect(!d.params_sep.isSet(14));
        try testing.expectEqual(@as(u16, 97), d.params[15]);
        try testing.expect(!d.params_sep.isSet(15));
        try testing.expectEqual(@as(u16, 136), d.params[16]);
        try testing.expect(!d.params_sep.isSet(16));
    }
}

test "csi: colon for non-m final" {
    var p = init();
    _ = p.next(0x1B);
    for ("[38:2h") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    try testing.expect(p.state == .ground);
}

test "csi: request mode decrqm" {
    var p = init();
    _ = p.next(0x1B);
    for ("[?2026$") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('p');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'p');
        try testing.expectEqual(@as(usize, 2), d.intermediates.len);
        try testing.expectEqual(@as(usize, 1), d.params.len);
        try testing.expectEqual(@as(u16, '?'), d.intermediates[0]);
        try testing.expectEqual(@as(u16, '$'), d.intermediates[1]);
        try testing.expectEqual(@as(u16, 2026), d.params[0]);
    }
}

test "csi: change cursor" {
    var p = init();
    _ = p.next(0x1B);
    for ("[3 ") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('q');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1].? == .csi_dispatch);
        try testing.expect(a[2] == null);

        const d = a[1].?.csi_dispatch;
        try testing.expect(d.final == 'q');
        try testing.expectEqual(@as(usize, 1), d.intermediates.len);
        try testing.expectEqual(@as(usize, 1), d.params.len);
        try testing.expectEqual(@as(u16, ' '), d.intermediates[0]);
        try testing.expectEqual(@as(u16, 3), d.params[0]);
    }
}

test "osc: change window title" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next(']');
    _ = p.next('0');
    _ = p.next(';');
    _ = p.next('a');
    _ = p.next('b');
    _ = p.next('c');

    {
        const a = p.next(0x07); // BEL
        try testing.expect(p.state == .ground);
        try testing.expect(a[0].? == .osc_dispatch);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);

        const cmd = a[0].?.osc_dispatch;
        try testing.expect(cmd == .change_window_title);
        try testing.expectEqualStrings("abc", cmd.change_window_title);
    }
}

test "osc: change window title (end in esc)" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next(']');
    _ = p.next('0');
    _ = p.next(';');
    _ = p.next('a');
    _ = p.next('b');
    _ = p.next('c');

    {
        const a = p.next(0x1B);
        _ = p.next('\\');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0].? == .osc_dispatch);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);

        const cmd = a[0].?.osc_dispatch;
        try testing.expect(cmd == .change_window_title);
        try testing.expectEqualStrings("abc", cmd.change_window_title);
    }
}

// https://github.com/darrenstarr/VtNetCore/pull/14
// Saw this on HN, decided to add a test case because why not.
test "osc: 112 incomplete sequence" {
    var p: Parser = init();
    defer p.deinit();
    p.osc_parser.alloc = std.testing.allocator;

    _ = p.next(0x1B);
    _ = p.next(']');
    _ = p.next('1');
    _ = p.next('1');
    _ = p.next('2');

    {
        const a = p.next(0x07);
        try testing.expect(p.state == .ground);
        try testing.expect(a[0].? == .osc_dispatch);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);

        const cmd = a[0].?.osc_dispatch;
        try testing.expect(cmd == .color_operation);
        try testing.expectEqual(cmd.color_operation.terminator, .bel);
        try testing.expect(cmd.color_operation.source == .reset_cursor);
        try testing.expect(cmd.color_operation.operations.count() == 1);
        var it = cmd.color_operation.operations.constIterator(0);
        {
            const op = it.next().?;
            try testing.expect(op.* == .reset);
            try testing.expectEqual(
                osc.Command.ColorOperation.Kind.cursor,
                op.reset,
            );
        }
        try std.testing.expect(it.next() == null);
    }
}

test "csi: too many params" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next('[');
    for (0..100) |_| {
        _ = p.next('1');
        _ = p.next(';');
    }
    _ = p.next('1');

    {
        const a = p.next('C');
        try testing.expect(p.state == .ground);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }
}

test "dcs: XTGETTCAP" {
    var p = init();
    _ = p.next(0x1B);
    for ("P+") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('q');
        try testing.expect(p.state == .dcs_passthrough);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2].? == .dcs_hook);

        const hook = a[2].?.dcs_hook;
        try testing.expectEqualSlices(u8, &[_]u8{'+'}, hook.intermediates);
        try testing.expectEqualSlices(u16, &[_]u16{}, hook.params);
        try testing.expectEqual('q', hook.final);
    }
}

test "dcs: params" {
    var p = init();
    _ = p.next(0x1B);
    for ("P1000") |c| {
        const a = p.next(c);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);
    }

    {
        const a = p.next('p');
        try testing.expect(p.state == .dcs_passthrough);
        try testing.expect(a[0] == null);
        try testing.expect(a[1] == null);
        try testing.expect(a[2].? == .dcs_hook);

        const hook = a[2].?.dcs_hook;
        try testing.expectEqualSlices(u16, &[_]u16{1000}, hook.params);
        try testing.expectEqual('p', hook.final);
    }
}
