//! VT-series parser for escape and control sequences.
//!
//! This is implemented directly as the state machine described on
//! vt100.net: https://vt100.net/emu/dec_ansi_parser
const Parser = @This();

const std = @import("std");
const testing = std.testing;
const sgr = @import("sgr.zig");
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
        intermediates: []const u8,
        params: []const u16,

        /// The separator that follows each parameter.
        ///
        /// Borrowed from the parser like `params` and `intermediates`,
        /// so it dies on the next byte fed to the parser. It is a
        /// pointer because the bit set covers every possible parameter
        /// and copying it into a hot dispatch costs more than it saves.
        /// Only bits below `params.len` mean anything; the last
        /// parameter has nothing after it.
        params_sep: *const SepList,

        final: u8,

        /// The list of separators used for CSI params. The value of the
        /// bit can be mapped to Sep. The index of this bit set specifies
        /// the separator AFTER that param. For example: 0;4:3 would have
        /// index 1 set.
        pub const SepList = Params.SepList;

        /// The separator used for CSI params.
        pub const Sep = enum(u1) { semicolon = 0, colon = 1 };

        /// Whether this command defines colon-joined subparameters.
        ///
        /// A colon introduces a subparameter (ECMA-48 5.4.2). Only the
        /// commands that define one can read it. The rest have to drop
        /// the whole sequence: reading the subparameters positionally
        /// would turn `CSI 1:2 H` into a cursor move to (1, 2).
        pub fn allowsSubparams(self: CSI) bool {
            return switch (self.final) {
                // SGR: direct colors and underline styles.
                'm' => true,

                // Kitty multiple cursors: coordinate and color groups.
                // DECSCUSR shares the 'q' final but has no '>', so it
                // falls through to false.
                'q' => std.mem.eql(u8, self.intermediates, "> "),

                else => false,
            };
        }

        /// Iterates the parameters as semicolon-separated groups, where
        /// a group is the maximal run of parameters joined by colons.
        /// `1;2:3:4;5` yields `{1}`, `{2,3,4}`, and `{5}`.
        ///
        /// This saves protocols that structure their parameters with
        /// colons, such as the kitty multiple cursors protocol, from
        /// walking the separator bits themselves.
        pub const GroupIterator = struct {
            params: []const u16,
            params_sep: *const SepList,

            /// The parameter the next group starts at. Set this past a
            /// leading parameter you have already consumed, such as an
            /// operation code.
            index: usize = 0,

            pub fn next(self: *GroupIterator) ?[]const u16 {
                if (self.index >= self.params.len) return null;

                // A set bit at i means parameter i is followed by ':',
                // so the group continues past it. The bound keeps a
                // trailing bit from running off the end.
                const start = self.index;
                var end = start;
                while (end + 1 < self.params.len and
                    self.params_sep.isSet(end)) : (end += 1)
                {}

                self.index = end + 1;
                return self.params[start .. end + 1];
            }
        };

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

/// Maximum number of CSI parameters.
///
/// Only two CSI commands use more than three parameters: SGR, which has
/// no bound at all, and the kitty multiple cursors protocol, which packs
/// a batch of cursor coordinates into one sequence. This was 16 until
/// Kakoune turned up with an SGR command that uses 17, then 24 on
/// empirical data, and is now 256 to match kitty's own limit, which the
/// cursors protocol is written against.
///
/// A longer sequence is dropped whole. Acting on one with parameters
/// silently missing from the middle is worse than not acting at all.
pub const MAX_PARAMS = 256;

/// Parameters retained without allocating.
///
/// Nearly every sequence fits here; longer ones spill to the heap. On a
/// parser with no allocator, which a freestanding target may well be,
/// this is the hard limit.
pub const INLINE_PARAMS = 24;

/// Current state of the state machine
state: State,

/// Intermediate tracking.
intermediates: [MAX_INTERMEDIATE]u8,
intermediates_idx: u8,

/// The parameters of the CSI or DCS sequence being parsed.
params: Params,

/// Parser for OSC sequences
osc_parser: osc.Parser,

/// The parameters of one control sequence, under construction.
///
/// Parameters arrive from the state machine one digit and one separator
/// at a time, and are consumed all at once at dispatch. This type owns
/// that whole lifecycle, so the byte-at-a-time state machine in `next`
/// and the bulk loop in `Stream` share one copy of the limit and
/// separator policy.
pub const Params = struct {
    /// The first `INLINE_PARAMS` completed parameters. Past that
    /// everything moves to `spill`, so the two are never read together.
    values: [INLINE_PARAMS]u16,

    /// Parameters past `INLINE_PARAMS`, preceded by a copy of `values`
    /// so `take` can return one contiguous slice. Empty until a sequence
    /// outgrows the inline storage.
    spill: std.ArrayListUnmanaged(u16),

    /// The separator that follows each parameter. See `SepList`.
    seps: SepList,

    /// Set by `Parser.setAllocator`. Null on a parser that cannot
    /// allocate, which caps a sequence at `INLINE_PARAMS`.
    alloc: ?std.mem.Allocator,

    /// The number of completed parameters.
    len: u16,

    /// Set once a parameter has been dropped, either past `MAX_PARAMS`
    /// or on a failed spill. Dispatch then discards the whole sequence.
    failed: bool,

    /// Whether any parameter is colon-joined to the next. Colons are
    /// rare, and this lets `reset` and the subparameter policy check
    /// skip `seps` for almost every sequence the parser sees.
    colons: bool,

    /// The parameter currently being accumulated, and whether any digit
    /// has fed it. The flag separates a trailing separator (`1;`, one
    /// parameter) from a trailing value (`1;2`, two).
    acc: u16,
    acc_set: bool,

    /// One bit per parameter, set when a ':' follows that parameter
    /// instead of a ';'. See `Action.CSI.SepList`.
    pub const SepList = std.StaticBitSet(MAX_PARAMS);

    pub const empty: Params = .{
        .values = undefined,
        .spill = .empty,
        .seps = .initEmpty(),
        .alloc = null,
        .len = 0,
        .failed = false,
        .colons = false,
        .acc = 0,
        .acc_set = false,
    };

    pub fn deinit(self: *Params) void {
        if (self.alloc) |alloc| self.spill.deinit(alloc);
        self.* = undefined;
    }

    /// Discard the sequence under construction, keeping any spill
    /// capacity for the next one.
    pub inline fn reset(self: *Params) void {
        // Only bits below `len` can ever be set, and only if a colon
        // was seen at all. `initEmpty` would zero the whole 32-byte mask
        // on every escape sequence, and this is the parser's hot path.
        if (self.colons) {
            @branchHint(.unlikely);
            self.seps.setRangeValue(.{ .start = 0, .end = self.len }, false);
            self.colons = false;
        }

        self.spill.clearRetainingCapacity();
        self.len = 0;
        self.failed = false;
        self.acc = 0;
        self.acc_set = false;
    }

    /// Accumulate one digit into the parameter being built. Values
    /// saturate: a parameter that large is nonsense already, and every
    /// consumer clamps it.
    ///
    /// There is no limit check here. A digit past the limit only feeds a
    /// parameter `push` refuses anyway, and this is the hottest step in
    /// CSI parsing.
    pub inline fn digit(self: *Params, value: u8) void {
        self.acc = (self.acc *| 10) +| value;
        self.acc_set = true;
    }

    /// Finish the parameter being built because a separator was reached.
    pub fn separator(self: *Params, colon: bool) void {
        self.push(self.acc, colon);
        self.acc = 0;
        self.acc_set = false;
    }

    /// Append a completed parameter and the separator that follows it.
    /// Once the inline storage is full this moves the whole sequence to
    /// the heap, and sets `failed` if it cannot.
    pub fn push(self: *Params, value: u16, colon: bool) void {
        if (self.failed) return;
        if (self.len >= MAX_PARAMS) {
            @branchHint(.cold);
            self.failed = true;
            return;
        }

        if (self.len < INLINE_PARAMS) {
            self.values[self.len] = value;
        } else {
            const alloc = self.alloc orelse {
                self.failed = true;
                return;
            };
            if (self.spill.items.len == 0) {
                self.spill.ensureTotalCapacity(
                    alloc,
                    @as(usize, self.len) + 1,
                ) catch {
                    self.failed = true;
                    return;
                };
                self.spill.appendSliceAssumeCapacity(
                    self.values[0..INLINE_PARAMS],
                );
            } else self.spill.ensureUnusedCapacity(alloc, 1) catch {
                self.failed = true;
                return;
            };
            self.spill.appendAssumeCapacity(value);
        }

        if (colon) {
            self.seps.set(self.len);
            self.colons = true;
        }
        self.len += 1;
    }

    /// Consume the pending parameter and return the whole sequence, or
    /// null if it overflowed and must be dropped.
    pub fn take(self: *Params) ?[]const u16 {
        if (self.acc_set) {
            self.push(self.acc, false);
            self.acc_set = false;
        }
        if (self.failed) {
            @branchHint(.cold);
            return null;
        }
        return if (self.spill.items.len > 0)
            self.spill.items
        else
            self.values[0..self.len];
    }
};

pub fn init() Parser {
    var result: Parser = .{
        .state = .ground,
        .intermediates_idx = 0,
        .params = .empty,
        .osc_parser = .init(null),

        .intermediates = undefined,
    };
    if (std.valgrind.runningOnValgrind() > 0) {
        // Initialize our undefined fields so Valgrind can catch it.
        // https://github.com/ziglang/zig/issues/19148
        result.intermediates = undefined;
        result.params.values = undefined;
    }
    return result;
}

/// Let the parser allocate for the two features a sequence can outgrow
/// the inline storage of: CSI parameters and OSC strings. A parser with
/// no allocator still works and drops those sequences instead.
pub fn setAllocator(self: *Parser, alloc: std.mem.Allocator) void {
    std.debug.assert(self.params.alloc == null);
    self.params.alloc = alloc;
    self.osc_parser.alloc = alloc;
}

pub fn deinit(self: *Parser) void {
    self.params.deinit();
    self.osc_parser.deinit();
}

/// Log a CSI dispatch dropped for parameters we could not keep: past
/// `MAX_PARAMS`, or a failed spill allocation.
///
/// This and `warnCsiSepMismatch` are noinline on purpose. Both are cold,
/// and inlining them into the hot dispatch path has been measured to
/// cost binary size and performance through icache pressure. Both are
/// public so the stream's own CSI fast path, which bypasses the state
/// machine, reports drops identically.
pub noinline fn warnCsiParams() void {
    @branchHint(.cold);
    log.warn("unable to retain CSI parameters, dropping sequence", .{});
}

/// Log a CSI dispatch dropped for using subparameters its final byte
/// does not define. See `Action.CSI.allowsSubparams`.
pub noinline fn warnCsiSepMismatch(csi: Action.CSI) void {
    @branchHint(.cold);
    log.warn(
        "CSI subparameters are not defined for this command, got: {f}",
        .{csi},
    );
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
                const params = self.params.take() orelse break :dcs_hook null;
                break :dcs_hook .{
                    .dcs_hook = .{
                        .intermediates = self.intermediates[0..self.intermediates_idx],
                        .params = params,
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
            // Semicolon separates parameters. If we encounter a semicolon
            // we need to store and move on to the next parameter.
            if (c == ';' or c == ':') {
                self.params.separator(c == ':');
                break :param null;
            }

            // A numeric value. Add it to our accumulator.
            self.params.digit(c - '0');

            // The client is expected to perform no action.
            break :param null;
        },
        .osc_put => osc_put: {
            @call(.always_inline, osc.Parser.next, .{ &self.osc_parser, c });
            break :osc_put null;
        },
        .csi_dispatch => csi_dispatch: {
            const params = self.params.take() orelse {
                warnCsiParams();
                break :csi_dispatch null;
            };

            const result: Action = .{
                .csi_dispatch = .{
                    .intermediates = self.intermediates[0..self.intermediates_idx],
                    .params = params,
                    .params_sep = &self.params.seps,
                    .final = c,
                },
            };

            if (self.params.colons and
                !result.csi_dispatch.allowsSubparams())
            {
                @branchHint(.cold);
                warnCsiSepMismatch(result.csi_dispatch);
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

pub inline fn clear(self: *Parser) void {
    self.intermediates_idx = 0;
    self.params.reset();
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
    p.setAllocator(std.testing.allocator);

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
    p.setAllocator(std.testing.allocator);

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

test "csi: too many params" {
    var p = init();
    p.setAllocator(testing.allocator);
    defer p.deinit();
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
        p.setAllocator(testing.allocator);
        defer p.deinit();
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
    p.setAllocator(testing.allocator);
    defer p.deinit();
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
    // sequence has more than MAX_PARAMS parameters and param_acc_set is
    // true, entering dcs_passthrough wrote to params[len] without a
    // bounds check, causing an out-of-bounds access.
    var p = init();
    p.setAllocator(testing.allocator);
    defer p.deinit();
    _ = p.next(0x1B); // ESC
    _ = p.next('P'); // DCS entry

    // Feed a digit then MAX_PARAMS semicolons to fill all param slots.
    _ = p.next('6');
    for (0..MAX_PARAMS) |_| {
        _ = p.next(';');
    }
    // Feed another digit so param_acc_set is true while len == MAX_PARAMS.
    _ = p.next('7');

    // A final byte triggers entry to dcs_passthrough. The DCS should
    // be dropped entirely, consistent with how CSI handles overflow.
    const a = p.next('p');
    try testing.expect(a[0] == null);
    try testing.expect(a[1] == null);
    try testing.expect(a[2] == null);
}
