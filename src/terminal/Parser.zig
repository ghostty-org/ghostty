//! VT-series parser for escape and control sequences.
//!
//! This is implemented directly as the state machine described on
//! vt100.net: https://vt100.net/emu/dec_ansi_parser
const Parser = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
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

        /// The separators, or null if every one is a semicolon, as in
        /// nearly every sequence.
        params_sep: ?*const SepList,

        final: u8,

        /// The list of separators used for CSI params. The value of the
        /// bit can be mapped to Sep. The index of this bit set specifies
        /// the separator AFTER that param. For example: 0;4:3 would have
        /// index 1 set.
        pub const SepList = std.StaticBitSet(MAX_PARAMS);

        /// The separator used for CSI params.
        pub const Sep = enum(u1) { semicolon = 0, colon = 1 };

        /// Whether this command defines subparameters, which a colon
        /// joins to the parameter before them (ECMA-48 5.4.2). Colons
        /// mean NOTHING to any other command or ruins positional reads.
        pub fn allowsSubparams(self: CSI) bool {
            return switch (self.final) {
                // SGR
                'm' => true,

                // Kitty multiple cursors
                'q' => std.mem.eql(u8, self.intermediates, "> "),

                else => false,
            };
        }

        // Implement formatter for logging
        pub fn format(
            self: CSI,
            writer: *std.Io.Writer,
        ) !void {
            try writer.print("ESC [ {s} {any} {c}", .{
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
            writer: *std.Io.Writer,
        ) !void {
            try writer.print("ESC {s} {c}", .{
                self.intermediates,
                self.final,
            });
        }
    };

    pub const DCS = struct {
        intermediates: []const u8 = "",
        params: []const u16 = &.{},
        final: u8,

        pub const C = extern struct {
            intermediates: [*]const u8,
            intermediates_len: usize,
            params: [*]const u16,
            params_len: usize,
            final: u8,
        };
    };

    // Implement formatter for logging. This is mostly copied from the
    // std.fmt implementation, but we modify it slightly so that we can
    // print out custom formats for some of our primitives.
    pub fn format(
        self: Action,
        writer: *std.Io.Writer,
    ) !void {
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
                        u21 => try writer.print("'{u}' (U+{X})", .{ value, value }),

                        // Byte
                        u8 => try writer.print("0x{x}", .{value}),

                        // Note: we don't do ASCII (u8) because there are a lot
                        // of invisible characters we don't want to handle right
                        // now.

                        // All others do the default behavior. Note the max
                        // depth of 1: this is only used for logging so we
                        // only want the top-level fields. Larger depths
                        // instantiate a recursive formatter for every nested
                        // type of every action payload (e.g. the full
                        // osc.Command union), which costs tens of kilobytes
                        // of binary size.
                        else => try writer.printValue(
                            "any",
                            .{},
                            @field(self, u_field.name),
                            1,
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
pub const MAX_INTERMEDIATE = 4;

/// Maximum number of CSI and DCS parameters. A sequence with more is
/// dropped entirely.
///
/// This is kitty's limit, which matters because the kitty multiple
/// cursors protocol is the one protocol which adores sending parameters in bulk:
/// a single painted cell costs three of them (`2:row:column`), so this
/// takes *up to* a batch of 85 of them, or 51 rectangles of any size. A program
/// wanting more splits it over several sequences.
pub const MAX_PARAMS = 256;

/// Current state of the state machine
state: State,

/// Intermediate tracking.
intermediates_idx: u8,

/// The number of parameters collected so far, or `MAX_PARAMS + 1` once
/// there have been more than fit. The one after them is being
/// accumulated in `param_acc`. See `pushParam`.
params_idx: u16,
param_acc: u16,

/// Whether `param_acc` has taken a digit, and so names a parameter that
/// hasn't been stored yet.
param_acc_set: bool,

/// The separators below this index say what they mean for this
/// sequence. Zero means no colon has turned up, and so that the
/// separators have not been touched at all. See `clearSeps`.
sep_upto: u16,

intermediates: [MAX_INTERMEDIATE]u8,

/// The values.
params: [MAX_PARAMS]u16,

params_sep: Action.CSI.SepList,

/// Parser for OSC sequences
osc_parser: osc.Parser,

pub fn init() Parser {
    var result: Parser = .{
        .state = .ground,
        .intermediates_idx = 0,
        .params_idx = 0,
        .param_acc = 0,
        .param_acc_set = false,
        .sep_upto = 0,
        .osc_parser = .init(null),

        .intermediates = undefined,
        .params = undefined,
        .params_sep = undefined,
    };
    if (std.valgrind.runningOnValgrind() > 0) {
        // Initialize our undefined fields so Valgrind can catch it.
        // https://github.com/ziglang/zig/issues/19148
        result.intermediates = undefined;
        result.params = undefined;
        result.params_sep = undefined;
    }
    return result;
}

/// The number of separator bits that share one word of `params_sep`.
const sep_word_bits = @bitSizeOf(Action.CSI.SepList.MaskInt);

/// Make the separators below `upto` mean what they say for this
/// sequence, so that the ones no colon reached read as semicolons.
///
/// The separators are cleared here rather than in `clear`, so that a
/// sequence with no colon in it, which is nearly all of them, never
/// messes with em.
inline fn clearSeps(self: *Parser, upto: usize) void {
    assert(upto <= MAX_PARAMS);
    if (self.sep_upto >= upto) return;
    // `MAX_PARAMS` need not be a whole number of words, and the set is
    // only that many bits wide, so the last word can stop early
    const end = @min(
        std.mem.alignForward(usize, upto, sep_word_bits),
        MAX_PARAMS,
    );
    self.params_sep.setRangeValue(.{ .start = self.sep_upto, .end = end }, false);
    self.sep_upto = @intCast(end);
}

/// Mark the separator after parameter `i` a colon. Separators are written
/// for increasing `i`, (lets `clearSeps` run behind them).
pub inline fn setColon(self: *Parser, i: usize) void {
    self.clearSeps(i + 1);
    self.params_sep.set(i);
}

/// Store the parameter being accumulated and begin the next one.
///
/// This is the only place a parameter is stored. `Stream` mirrors it with
/// the count and accumulator in locals for its bulk loop.
inline fn pushParam(self: *Parser, colon: bool) void {
    if (self.params_idx < MAX_PARAMS) {
        self.params[self.params_idx] = self.param_acc;
        if (colon) self.setColon(self.params_idx);
        self.params_idx += 1;
    } else {
        @branchHint(.cold);
        self.params_idx = MAX_PARAMS + 1;
    }
    self.param_acc = 0;
    self.param_acc_set = false;
}

/// Collect a parameter byte: a digit, or a separator ending the parameter
/// before it.
pub inline fn param(self: *Parser, c: u8) void {
    switch (c) {
        '0'...'9' => {
            self.param_acc *|= 10;
            self.param_acc +|= c - '0';
            self.param_acc_set = true;
        },

        ':', ';' => self.pushParam(c == ':'),

        else => unreachable,
    }
}

/// Finish a CSI with the final byte `c`. Returns null if the sequence must
/// be dropped: it has too many parameters, or colons in a command without
/// subparameters (see `Action.CSI.allowsSubparams`).
pub inline fn csiDispatch(self: *Parser, c: u8) ?Action.CSI {
    var csi: Action.CSI = .{
        .intermediates = self.intermediates[0..self.intermediates_idx],
        .params = self.finishParams() orelse return null,
        .params_sep = null,
        .final = c,
    };

    if (self.sep_upto > 0) {
        @branchHint(.unlikely);
        if (!csi.allowsSubparams()) {
            @branchHint(.cold);
            warnCsiSubparams(csi);
            return null;
        }
        self.clearSeps(self.params_idx);
        csi.params_sep = &self.params_sep;
    }

    return csi;
}

/// The state machine's `csi_dispatch` action. Inlined into `next`, this
/// slows down every byte the parser handles, CSI or not.
noinline fn csiDispatchAction(self: *Parser, c: u8) ?Action {
    return .{ .csi_dispatch = self.csiDispatch(c) orelse return null };
}

/// Store the parameter being collected, if there is one, and return every
/// parameter, or null if the sequence had more than `MAX_PARAMS` of them
/// and so must be dropped.
inline fn finishParams(self: *Parser) ?[]u16 {
    if (self.param_acc_set) self.pushParam(false);
    if (self.params_idx > MAX_PARAMS) {
        @branchHint(.unlikely);
        return null;
    }
    return self.params[0..self.params_idx];
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
                Action{ .osc_dispatch = cmd.* }
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
                const params_ = self.finishParams() orelse break :dcs_hook null;
                break :dcs_hook .{
                    .dcs_hook = .{
                        .intermediates = self.intermediates[0..self.intermediates_idx],
                        .params = params_,
                        .final = c,
                    },
                };
            },
            .sos_pm_apc_string => Action{ .apc_start = {} },
            else => null,
        },
    };
}

pub inline fn collect(self: *Parser, c: u8) void {
    if (self.intermediates_idx >= MAX_INTERMEDIATE) {
        @branchHint(.cold);
        log.warn("invalid intermediates count", .{});
        return;
    }

    self.intermediates[self.intermediates_idx] = c;
    self.intermediates_idx += 1;
}

inline fn doAction(self: *Parser, action: TransitionAction, c: u8) ?Action {
    return switch (action) {
        .none, .ignore => null,
        .print => Action{ .print = c },
        .execute => Action{ .execute = c },
        .collect => collect: {
            self.collect(c);
            break :collect null;
        },
        .param => param: {
            self.param(c);
            break :param null;
        },
        .osc_put => osc_put: {
            @call(.always_inline, osc.Parser.next, .{ &self.osc_parser, c });
            break :osc_put null;
        },
        .csi_dispatch => self.csiDispatchAction(c),
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

/// Log a warning for a CSI dispatch with colon/mixed separators on a
/// command without subparameters.
///
/// This is noinline on purpose so that this unlikely (cold) behavior
/// doesn't bloat the hot dispatch path which has been measured to actually
/// affect both binary size and performance due to icache busts.
noinline fn warnCsiSubparams(csi: Action.CSI) void {
    @branchHint(.cold);
    log.warn(
        "CSI colon or mixed separators on a command without subparameters: {f}",
        .{csi},
    );
}

pub inline fn clear(self: *Parser) void {
    self.intermediates_idx = 0;
    self.params_idx = 0;
    self.sep_upto = 0;
    self.param_acc = 0;
    self.param_acc_set = false;
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
        try testing.expect(d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(!d.params_sep.?.isSet(1));
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
        try testing.expect(d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(d.params_sep.?.isSet(1));
        try testing.expectEqual(@as(u16, 240), d.params[2]);
        try testing.expect(d.params_sep.?.isSet(2));
        try testing.expectEqual(@as(u16, 143), d.params[3]);
        try testing.expect(d.params_sep.?.isSet(3));
        try testing.expectEqual(@as(u16, 104), d.params[4]);
        try testing.expect(!d.params_sep.?.isSet(4));
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
        try testing.expect(d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 3), d.params[1]);
        try testing.expect(!d.params_sep.?.isSet(1));
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
        try testing.expect(d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 2), d.params[1]);
        try testing.expect(d.params_sep.?.isSet(1));
        try testing.expectEqual(@as(u16, 0), d.params[2]);
        try testing.expect(d.params_sep.?.isSet(2));
        try testing.expectEqual(@as(u16, 240), d.params[3]);
        try testing.expect(d.params_sep.?.isSet(3));
        try testing.expectEqual(@as(u16, 143), d.params[4]);
        try testing.expect(d.params_sep.?.isSet(4));
        try testing.expectEqual(@as(u16, 104), d.params[5]);
        try testing.expect(!d.params_sep.?.isSet(5));
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
        try testing.expect(!d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 4), d.params[1]);
        try testing.expect(d.params_sep.?.isSet(1));
        try testing.expectEqual(@as(u16, 3), d.params[2]);
        try testing.expect(!d.params_sep.?.isSet(2));
        try testing.expectEqual(@as(u16, 38), d.params[3]);
        try testing.expect(!d.params_sep.?.isSet(3));
        try testing.expectEqual(@as(u16, 2), d.params[4]);
        try testing.expect(!d.params_sep.?.isSet(4));
        try testing.expectEqual(@as(u16, 175), d.params[5]);
        try testing.expect(!d.params_sep.?.isSet(5));
        try testing.expectEqual(@as(u16, 175), d.params[6]);
        try testing.expect(!d.params_sep.?.isSet(6));
        try testing.expectEqual(@as(u16, 215), d.params[7]);
        try testing.expect(!d.params_sep.?.isSet(7));
        try testing.expectEqual(@as(u16, 58), d.params[8]);
        try testing.expect(d.params_sep.?.isSet(8));
        try testing.expectEqual(@as(u16, 2), d.params[9]);
        try testing.expect(d.params_sep.?.isSet(9));
        try testing.expectEqual(@as(u16, 0), d.params[10]);
        try testing.expect(d.params_sep.?.isSet(10));
        try testing.expectEqual(@as(u16, 190), d.params[11]);
        try testing.expect(d.params_sep.?.isSet(11));
        try testing.expectEqual(@as(u16, 80), d.params[12]);
        try testing.expect(d.params_sep.?.isSet(12));
        try testing.expectEqual(@as(u16, 70), d.params[13]);
        try testing.expect(!d.params_sep.?.isSet(13));
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
        try testing.expect(d.params_sep.?.isSet(0));
        try testing.expectEqual(@as(u16, 3), d.params[1]);
        try testing.expect(!d.params_sep.?.isSet(1));
        try testing.expectEqual(@as(u16, 38), d.params[2]);
        try testing.expect(!d.params_sep.?.isSet(2));
        try testing.expectEqual(@as(u16, 2), d.params[3]);
        try testing.expect(!d.params_sep.?.isSet(3));
        try testing.expectEqual(@as(u16, 51), d.params[4]);
        try testing.expect(!d.params_sep.?.isSet(4));
        try testing.expectEqual(@as(u16, 51), d.params[5]);
        try testing.expect(!d.params_sep.?.isSet(5));
        try testing.expectEqual(@as(u16, 51), d.params[6]);
        try testing.expect(!d.params_sep.?.isSet(6));
        try testing.expectEqual(@as(u16, 48), d.params[7]);
        try testing.expect(!d.params_sep.?.isSet(7));
        try testing.expectEqual(@as(u16, 2), d.params[8]);
        try testing.expect(!d.params_sep.?.isSet(8));
        try testing.expectEqual(@as(u16, 170), d.params[9]);
        try testing.expect(!d.params_sep.?.isSet(9));
        try testing.expectEqual(@as(u16, 170), d.params[10]);
        try testing.expect(!d.params_sep.?.isSet(10));
        try testing.expectEqual(@as(u16, 170), d.params[11]);
        try testing.expect(!d.params_sep.?.isSet(11));
        try testing.expectEqual(@as(u16, 58), d.params[12]);
        try testing.expect(!d.params_sep.?.isSet(12));
        try testing.expectEqual(@as(u16, 2), d.params[13]);
        try testing.expect(!d.params_sep.?.isSet(13));
        try testing.expectEqual(@as(u16, 255), d.params[14]);
        try testing.expect(!d.params_sep.?.isSet(14));
        try testing.expectEqual(@as(u16, 97), d.params[15]);
        try testing.expect(!d.params_sep.?.isSet(15));
        try testing.expectEqual(@as(u16, 136), d.params[16]);
        try testing.expect(!d.params_sep.?.isSet(16));
    }
}

test "csi: colons only for commands with subparameters" {
    const cases = [_]struct { []const u8, bool }{
        // SGR
        .{ "[38:2::1:2:3m", true },
        // Kitty multiple cursors
        .{ "[>1;2:3:4 q", true },
        // Commands that share bytes with those
        .{ "[38:2h", false },
        .{ "[1:2H", false },
        .{ "[2:1 q", false },
        .{ "[>1:2q", false },
        .{ "[?1:2 q", false },
    };
    for (cases) |case| {
        const seq, const dispatched = case;
        var p = init();
        _ = p.next(0x1B);
        for (seq[0 .. seq.len - 1]) |c| _ = p.next(c);
        const a = p.next(seq[seq.len - 1]);
        try testing.expect(p.state == .ground);
        try testing.expectEqual(dispatched, a[1] != null);
    }
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
        try testing.expect(cmd.color_operation.op == .osc_112);
        try testing.expect(cmd.color_operation.requests.count() == 1);
        var it = cmd.color_operation.requests.constIterator(0);
        {
            const op = it.next().?;
            try testing.expect(op.* == .reset);
            try testing.expectEqual(
                osc.color.Request{ .reset = .{ .dynamic = .cursor } },
                op.*,
            );
        }
        try std.testing.expect(it.next() == null);
    }
}

test "osc: 104 empty" {
    var p: Parser = init();
    defer p.deinit();
    p.osc_parser.alloc = std.testing.allocator;

    _ = p.next(0x1B);
    _ = p.next(']');
    _ = p.next('1');
    _ = p.next('0');
    _ = p.next('4');

    {
        const a = p.next(0x07);
        try testing.expect(p.state == .ground);
        try testing.expect(a[0].? == .osc_dispatch);
        try testing.expect(a[1] == null);
        try testing.expect(a[2] == null);

        const cmd = a[0].?.osc_dispatch;
        try testing.expect(cmd == .color_operation);
        try testing.expectEqual(cmd.color_operation.terminator, .bel);
        try testing.expect(cmd.color_operation.op == .osc_104);
        try testing.expect(cmd.color_operation.requests.count() == 1);
        var it = cmd.color_operation.requests.constIterator(0);
        {
            const op = it.next().?;
            try testing.expect(op.* == .reset_palette);
        }
        try std.testing.expect(it.next() == null);
    }
}

test "osc: 105 empty" {
    var p: Parser = init();
    defer p.deinit();
    p.osc_parser.alloc = std.testing.allocator;

    for ("\x1b]105") |c| _ = p.next(c);

    const cmd = p.next(0x07)[0].?.osc_dispatch;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.op == .osc_105);
}

test "csi: too many params" {
    var p = init();
    _ = p.next(0x1B);
    _ = p.next('[');
    for (0..MAX_PARAMS) |_| {
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

test "csi: sgr with up to our max parameters" {
    for (1..MAX_PARAMS + 1) |max| {
        var p = init();
        _ = p.next(0x1B);
        _ = p.next('[');

        for (0..max - 1) |_| {
            _ = p.next('1');
            _ = p.next(';');
        }
        _ = p.next('2');

        {
            const a = p.next('H');
            try testing.expect(p.state == .ground);
            try testing.expect(a[0] == null);
            try testing.expect(a[1].? == .csi_dispatch);
            try testing.expect(a[2] == null);

            const csi = a[1].?.csi_dispatch;
            try testing.expectEqual(@as(usize, max), csi.params.len);
            try testing.expectEqual(@as(u16, 2), csi.params[max - 1]);
        }
    }
}

test "csi: sgr beyond our max drops it" {
    // Has to be +2 for the loops below
    const max = MAX_PARAMS + 2;

    var p = init();
    _ = p.next(0x1B);
    _ = p.next('[');

    for (0..max - 1) |_| {
        _ = p.next('1');
        _ = p.next(';');
    }
    _ = p.next('2');

    {
        const a = p.next('H');
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

test "dcs: too many params" {
    // Regression test for a crash found by fuzzing (afl). When a DCS
    // sequence has more than MAX_PARAMS parameters and a parameter is
    // still being accumulated,
    // entering dcs_passthrough wrote to params[params_idx] without a
    // bounds check, causing an out-of-bounds access.
    var p = init();
    _ = p.next(0x1B); // ESC
    _ = p.next('P'); // DCS entry

    // Feed a digit then MAX_PARAMS semicolons to fill all param slots.
    _ = p.next('6');
    for (0..MAX_PARAMS) |_| {
        _ = p.next(';');
    }
    // Feed another digit so a parameter is pending while params_idx is
    // already MAX_PARAMS.
    _ = p.next('7');

    // A final byte triggers entry to dcs_passthrough. The DCS should
    // be dropped entirely, consistent with how CSI handles overflow.
    const a = p.next('p');
    try testing.expect(a[0] == null);
    try testing.expect(a[1] == null);
    try testing.expect(a[2] == null);
}
