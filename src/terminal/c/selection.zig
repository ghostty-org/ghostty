const std = @import("std");
const lib = @import("../lib.zig");
const grid_ref = @import("grid_ref.zig");
const point = @import("../point.zig");
const selection_codepoints = @import("../selection_codepoints.zig");
const Selection = @import("../Selection.zig");
const Result = @import("result.zig").Result;
const terminal_c = @import("terminal.zig");

const log = std.log.scoped(.selection_c);

pub const Adjustment = Selection.Adjustment;
pub const Order = Selection.Order;

/// C: GhosttySelection
///
/// A range of terminal content between two cells. C callers allocate this
/// struct themselves, so its size and field offsets are part of the ABI.
/// The C header documents them, and the comptime block below keeps the
/// two in sync.
pub const CSelection = extern struct {
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    rectangle: bool = false,

    // Expected sizes: 40 bytes on 64-bit targets, 20 bytes on 32-bit.
    comptime {
        std.debug.assert(@sizeOf(CSelection) == switch (@sizeOf(usize)) {
            8 => 40,
            4 => 20,
            else => unreachable,
        });
    }

    pub fn toZig(self: CSelection) ?Selection {
        const start_pin = self.start.toPin() orelse return null;
        const end_pin = self.end.toPin() orelse return null;
        return Selection.init(start_pin, end_pin, self.rectangle);
    }

    pub fn fromZig(sel: Selection) CSelection {
        return .{
            .start = .fromPin(sel.start()),
            .end = .fromPin(sel.end()),
            .rectangle = sel.rectangle,
        };
    }
};

/// C: GhosttySelectionBuffer
///
/// A caller-provided buffer of selections. This follows the same
/// conventions as GhosttyBuffer: ptr may be NULL with cap 0 to query
/// the required capacity, and len is set to the entries written on
/// success or to the required capacity on GHOSTTY_OUT_OF_SPACE.
pub const CSelectionBuffer = extern struct {
    ptr: ?[*]CSelection = null,
    cap: usize = 0,
    len: usize = 0,
};

/// C: GhosttyTerminalSelectWordOptions
pub const SelectWordOptions = extern struct {
    size: usize = @sizeOf(SelectWordOptions),
    ref: grid_ref.CGridRef,
    boundary_codepoints: ?[*]const u32 = null,
    boundary_codepoints_len: usize = 0,

    pub const sized_base = "boundary_codepoints_len";
};

/// C: GhosttyTerminalSelectWordBetweenOptions
pub const SelectWordBetweenOptions = extern struct {
    size: usize = @sizeOf(SelectWordBetweenOptions),
    start: grid_ref.CGridRef,
    end: grid_ref.CGridRef,
    boundary_codepoints: ?[*]const u32 = null,
    boundary_codepoints_len: usize = 0,

    pub const sized_base = "boundary_codepoints_len";
};

/// C: GhosttyTerminalSelectLineOptions
pub const SelectLineOptions = extern struct {
    size: usize = @sizeOf(SelectLineOptions),
    ref: grid_ref.CGridRef,
    whitespace: ?[*]const u32 = null,
    whitespace_len: usize = 0,
    semantic_prompt_boundary: bool = false,

    pub const sized_base = "semantic_prompt_boundary";
};

pub fn word(
    terminal: terminal_c.Terminal,
    options: ?*const SelectWordOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (!lib.sizedCheck(.input, opts)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const boundary_codepoints = codepointSlice(
        opts.boundary_codepoints,
        opts.boundary_codepoints_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const pin = opts.ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectWord(
        pin,
        boundary_codepoints orelse &selection_codepoints.default_word_boundaries,
    ) orelse
        return .no_value);
    return .success;
}

pub fn word_between(
    terminal: terminal_c.Terminal,
    options: ?*const SelectWordBetweenOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (!lib.sizedCheck(.input, opts)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const boundary_codepoints = codepointSlice(
        opts.boundary_codepoints,
        opts.boundary_codepoints_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const start = opts.start.toPin() orelse return .invalid_value;
    const end = opts.end.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectWordBetween(
        start,
        end,
        boundary_codepoints orelse &selection_codepoints.default_word_boundaries,
    ) orelse
        return .no_value);
    return .success;
}

pub fn line(
    terminal: terminal_c.Terminal,
    options: ?*const SelectLineOptions,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const opts = options orelse return .invalid_value;
    if (!lib.sizedCheck(.input, opts)) return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const whitespace = codepointSlice(
        opts.whitespace,
        opts.whitespace_len,
    ) catch return .invalid_value;

    const screen = t.screens.active;
    const pin = opts.ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectLine(.{
        .pin = pin,
        .whitespace = whitespace orelse &selection_codepoints.default_line_whitespace,
        .semantic_prompt_boundary = opts.semantic_prompt_boundary,
    }) orelse return .no_value);
    return .success;
}

pub fn all(
    terminal: terminal_c.Terminal,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    out.* = .fromZig(t.screens.active.selectAll() orelse return .no_value);
    return .success;
}

pub fn output(
    terminal: terminal_c.Terminal,
    ref: grid_ref.CGridRef,
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    const screen = t.screens.active;
    const pin = ref.toPin() orelse return .invalid_value;
    out.* = .fromZig(screen.selectOutput(pin) orelse return .no_value);
    return .success;
}

/// Return the borrowed C array of `uint32_t` codepoints as a `[]const u21`.
///
/// `NULL + len 0` returns null, which callers treat as “use the API default
/// set.” A non-null pointer with `len 0` returns an empty slice, meaning “use an
/// explicitly empty set.” A non-zero length requires a non-null pointer.
///
/// This is intentionally zero-copy. In the C ABI, codepoints are `uint32_t`,
/// but selection internals use Zig's `u21` to represent valid Unicode scalar
/// values. Zig currently stores `u21` in the same size and alignment as `u32`,
/// so we assert that layout relationship and reinterpret the borrowed slice.
/// If Zig ever changes that representation, these comptime assertions fail
/// loudly rather than silently making this cast wrong.
fn codepointSlice(
    ptr: ?[*]const u32,
    len: usize,
) error{InvalidValue}!?[]const u21 {
    comptime {
        std.debug.assert(@sizeOf(u21) == @sizeOf(u32));
        std.debug.assert(@alignOf(u21) == @alignOf(u32));
    }

    if (len == 0) {
        const p = ptr orelse return null;
        _ = p;
        return &.{};
    }

    const p = ptr orelse return error.InvalidValue;
    const cps: [*]const u21 = @ptrCast(p);
    return cps[0..len];
}

pub fn adjust(
    terminal: terminal_c.Terminal,
    selection: ?*CSelection,
    adjustment_: lib.CEnum(Selection.Adjustment),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const adjustment = lib.enumFromC(Selection.Adjustment, adjustment_) orelse
        return .invalid_value;

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_ptr = selection orelse return .invalid_value;
    var sel = sel_ptr.toZig() orelse return .invalid_value;
    sel.adjust(t.screens.active, adjustment);
    sel_ptr.* = .fromZig(sel);
    return .success;
}

pub fn order(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    out_order: ?*Selection.Order,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_order orelse return .invalid_value;

    out.* = sel.order(t.screens.active);
    return .success;
}

pub fn ordered(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    desired_: lib.CEnum(Selection.Order),
    out_selection: ?*CSelection,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const desired = lib.enumFromC(Selection.Order, desired_) orelse
        return .invalid_value;

    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_selection orelse return .invalid_value;

    out.* = .fromZig(sel.ordered(t.screens.active, desired));
    return .success;
}

pub fn contains(
    terminal: terminal_c.Terminal,
    selection: ?*const CSelection,
    pt: point.Point.C,
    out_contains: ?*bool,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    const t = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel = (selection orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_contains orelse return .invalid_value;

    const screen = t.screens.active;
    const pin = screen.pages.pin(point.Point.fromC(pt) orelse return .invalid_value) orelse
        return .invalid_value;
    out.* = sel.contains(screen, pin);
    return .success;
}

pub fn equal(
    terminal: terminal_c.Terminal,
    a: ?*const CSelection,
    b: ?*const CSelection,
    out_equal: ?*bool,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.selection)) return .unsupported;
    _ = terminal_c.zigTerminal(terminal) orelse return .invalid_value;
    const sel_a = (a orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const sel_b = (b orelse return .invalid_value).toZig() orelse
        return .invalid_value;
    const out = out_equal orelse return .invalid_value;

    out.* = sel_a.eql(sel_b);
    return .success;
}
