//! The primary export of this file is "table", which contains a
//! comptime-generated state transition table for VT emulation.
//!
//! This is based on the vt100.net state machine:
//! https://vt100.net/emu/dec_ansi_parser
//! But has some modifications:
//!
//!   * csi_param accepts the colon character (':') since the SGR command
//!     accepts colon as a valid parameter value.
//!

const std = @import("std");
const parser = @import("Parser.zig");
const State = parser.State;
const Action = parser.TransitionAction;

/// The state transition table. The type is [u8][State]Transition but
/// comptime-generated to be exactly-sized.
pub const table = genTable();

/// Table is the type of the state table. This is dynamically (comptime)
/// generated to be exactly sized.
pub const Table = genTableType(false);

/// OptionalTable is private to this file. We use this to accumulate and
/// detect invalid transitions created.
const OptionalTable = genTableType(true);

// Transition is the transition to take within the table
pub const Transition = struct {
    state: State,
    action: Action,
};

/// Table is the type of the state transition table.
fn genTableType(comptime optional: bool) type {
    const max_u8 = std.math.maxInt(u8);
    const stateInfo = @typeInfo(State);
    const max_state = stateInfo.@"enum".fields.len;
    const Elem = if (optional) ?Transition else Transition;
    return [max_u8 + 1][max_state]Elem;
}

/// Function to generate the full state transition table for VT emulation.
fn genTable() Table {
    @setEvalBranchQuota(20000);

    // We accumulate using an "optional" table so we can detect duplicates.
    var result: OptionalTable = undefined;
    for (0..result.len) |i| {
        for (0..result[0].len) |j| {
            result[i][j] = null;
        }
    }

    // anywhere transitions
    const stateInfo = @typeInfo(State);
    inline for (stateInfo.@"enum".fields) |field| {
        const source: State = @enumFromInt(field.value);

        // anywhere => ground
        single(&result, 0x18, source, .ground, .execute);
        single(&result, 0x1A, source, .ground, .execute);
        range(&result, 0x80, 0x8F, source, .ground, .execute);
        range(&result, 0x91, 0x97, source, .ground, .execute);
        single(&result, 0x99, source, .ground, .execute);
        single(&result, 0x9A, source, .ground, .execute);
        single(&result, 0x9C, source, .ground, .none);

        // anywhere => escape
        single(&result, 0x1B, source, .escape, .none);

        // anywhere => sos_pm_apc_string
        single(&result, 0x98, source, .sos_pm_apc_string, .none);
        single(&result, 0x9E, source, .sos_pm_apc_string, .none);
        single(&result, 0x9F, source, .sos_pm_apc_string, .none);

        // anywhere => csi_entry
        single(&result, 0x9B, source, .csi_entry, .none);

        // anywhere => dcs_entry
        single(&result, 0x90, source, .dcs_entry, .none);

        // anywhere => osc_string
        single(&result, 0x9D, source, .osc_string, .none);
    }

    // ground
    {
        // events
        single(&result, 0x19, .ground, .ground, .execute);
        range(&result, 0, 0x17, .ground, .ground, .execute);
        range(&result, 0x1C, 0x1F, .ground, .ground, .execute);
        range(&result, 0x20, 0x7F, .ground, .ground, .print);
    }

    // escape_intermediate
    {
        const source = State.escape_intermediate;

        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x30, 0x7E, source, .ground, .esc_dispatch);
    }

    // sos_pm_apc_string
    {
        const source = State.sos_pm_apc_string;

        // events
        single(&result, 0x19, source, source, .apc_put);
        range(&result, 0, 0x17, source, source, .apc_put);
        range(&result, 0x1C, 0x1F, source, source, .apc_put);
        range(&result, 0x20, 0x7F, source, source, .apc_put);
    }

    // escape
    {
        const source = State.escape;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x30, 0x4F, source, .ground, .esc_dispatch);
        range(&result, 0x51, 0x57, source, .ground, .esc_dispatch);
        range(&result, 0x60, 0x7E, source, .ground, .esc_dispatch);
        single(&result, 0x59, source, .ground, .esc_dispatch);
        single(&result, 0x5A, source, .ground, .esc_dispatch);
        single(&result, 0x5C, source, .ground, .esc_dispatch);

        // => escape_intermediate
        range(&result, 0x20, 0x2F, source, .escape_intermediate, .collect);

        // => sos_pm_apc_string
        single(&result, 0x58, source, .sos_pm_apc_string, .none);
        single(&result, 0x5E, source, .sos_pm_apc_string, .none);
        single(&result, 0x5F, source, .sos_pm_apc_string, .none);

        // => dcs_entry
        single(&result, 0x50, source, .dcs_entry, .none);

        // => csi_entry
        single(&result, 0x5B, source, .csi_entry, .none);

        // => osc_string
        single(&result, 0x5D, source, .osc_string, .none);
    }

    // dcs_entry
    {
        const source = State.dcs_entry;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_intermediate
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);

        // => dcs_ignore
        single(&result, 0x3A, source, .dcs_ignore, .none);

        // => dcs_param
        range(&result, 0x30, 0x39, source, .dcs_param, .param);
        single(&result, 0x3B, source, .dcs_param, .param);
        range(&result, 0x3C, 0x3F, source, .dcs_param, .collect);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_intermediate
    {
        const source = State.dcs_intermediate;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_ignore
        range(&result, 0x30, 0x3F, source, .dcs_ignore, .none);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_ignore
    {
        const source = State.dcs_ignore;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
    }

    // dcs_param
    {
        const source = State.dcs_param;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);

        // => dcs_ignore
        single(&result, 0x3A, source, .dcs_ignore, .none);
        range(&result, 0x3C, 0x3F, source, .dcs_ignore, .none);

        // => dcs_intermediate
        range(&result, 0x20, 0x2F, source, .dcs_intermediate, .collect);

        // => dcs_passthrough
        range(&result, 0x40, 0x7E, source, .dcs_passthrough, .none);
    }

    // dcs_passthrough
    {
        const source = State.dcs_passthrough;

        // events
        single(&result, 0x19, source, source, .put);
        range(&result, 0, 0x17, source, source, .put);
        range(&result, 0x1C, 0x1F, source, source, .put);
        range(&result, 0x20, 0x7E, source, source, .put);
        single(&result, 0x7F, source, source, .ignore);
    }

    // csi_param
    {
        const source = State.csi_param;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x30, 0x39, source, source, .param);
        single(&result, 0x3A, source, source, .param);
        single(&result, 0x3B, source, source, .param);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        range(&result, 0x3C, 0x3F, source, .csi_ignore, .none);

        // => csi_intermediate
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);
    }

    // csi_ignore
    {
        const source = State.csi_ignore;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x3F, source, source, .ignore);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .none);
    }

    // csi_intermediate
    {
        const source = State.csi_intermediate;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        range(&result, 0x20, 0x2F, source, source, .collect);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        range(&result, 0x30, 0x3F, source, .csi_ignore, .none);
    }

    // csi_entry
    {
        const source = State.csi_entry;

        // events
        single(&result, 0x19, source, source, .execute);
        range(&result, 0, 0x17, source, source, .execute);
        range(&result, 0x1C, 0x1F, source, source, .execute);
        single(&result, 0x7F, source, source, .ignore);

        // => ground
        range(&result, 0x40, 0x7E, source, .ground, .csi_dispatch);

        // => csi_ignore
        single(&result, 0x3A, source, .csi_ignore, .none);

        // => csi_intermediate
        range(&result, 0x20, 0x2F, source, .csi_intermediate, .collect);

        // => csi_param
        range(&result, 0x30, 0x39, source, .csi_param, .param);
        single(&result, 0x3B, source, .csi_param, .param);
        range(&result, 0x3C, 0x3F, source, .csi_param, .collect);
    }

    // osc_string
    {
        const source = State.osc_string;

        // events
        single(&result, 0x19, source, source, .ignore);
        range(&result, 0, 0x06, source, source, .ignore);
        range(&result, 0x08, 0x17, source, source, .ignore);
        range(&result, 0x1C, 0x1F, source, source, .ignore);
        range(&result, 0x20, 0xFF, source, source, .osc_put);

        // XTerm accepts either BEL  or ST  for terminating OSC
        // sequences, and when returning information, uses the same
        // terminator used in a query.
        single(&result, 0x07, source, .ground, .none);
    }

    // Create our immutable version
    var final: Table = undefined;
    for (0..final.len) |i| {
        for (0..final[0].len) |j| {
            final[i][j] = result[i][j] orelse transition(@enumFromInt(j), .none);
        }
    }

    return final;
}

fn single(t: *OptionalTable, c: u8, s0: State, s1: State, a: Action) void {
    const s0_int = @intFromEnum(s0);

    // TODO: enable this but it thinks we're in runtime right now
    // if (t[c][s0_int]) |existing| {
    //     @compileLog(c);
    //     @compileLog(s0);
    //     @compileLog(s1);
    //     @compileLog(existing);
    //     @compileError("transition set multiple times");
    // }

    t[c][s0_int] = transition(s1, a);
}

fn range(t: *OptionalTable, from: u8, to: u8, s0: State, s1: State, a: Action) void {
    var i = from;
    while (i <= to) : (i += 1) {
        single(t, i, s0, s1, a);
        // If 'to' is 0xFF, our next pass will overflow. Return early to prevent
        // the loop from executing it's continue expression
        if (i == to) break;
    }
}

fn transition(state: State, action: Action) Transition {
    return .{ .state = state, .action = action };
}

test {
    // This forces comptime-evaluation of table, so we're just testing
    // that it succeeds in creation.
    _ = table;
}
