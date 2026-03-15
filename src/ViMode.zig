const std = @import("std");
const terminal = @import("terminal/main.zig");
const input = @import("input.zig");
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Cell = terminal.page.Cell;

const ViMode = @This();

pub const SubMode = enum {
    normal,
    visual,
    visual_line,
    visual_block,
};

pub const ViResult = struct {
    scroll_delta: ?isize = null,
    scroll_top: bool = false,
    scroll_bottom: bool = false,
    selection_changed: bool = false,
    copy_clipboard: bool = false,
    start_search_forward: bool = false,
    start_search_backward: bool = false,
    navigate_search_next: bool = false,
    navigate_search_prev: bool = false,
    exit: bool = false,
    redraw: bool = false,
};

pub const ViewportInfo = struct {
    top: Pin,
    rows: usize,
};

cursor_pin: *Pin,
sub_mode: SubMode = .normal,
count: ?u32 = null,
pending_key: ?u8 = null,
selection_anchor: ?*Pin = null,
marks: [26]?*Pin = .{null} ** 26,
search_direction: enum { forward, backward } = .forward,

pub fn init(cursor_pin: *Pin) ViMode {
    return .{ .cursor_pin = cursor_pin };
}

pub fn deinit(self: *ViMode, pages: *PageList) void {
    pages.untrackPin(self.cursor_pin);
    if (self.selection_anchor) |anchor| {
        pages.untrackPin(anchor);
        self.selection_anchor = null;
    }
    for (&self.marks) |*mark| {
        if (mark.*) |pin| {
            pages.untrackPin(pin);
            mark.* = null;
        }
    }
}

/// Consume the accumulated count prefix, returning 1 if none was set.
fn getEffectiveCount(self: *ViMode) u32 {
    const c = self.count orelse 1;
    self.count = null;
    return c;
}

/// Returns the column index of the last non-empty cell on the row
/// that `p` points to, or 0 if the entire row is empty.
fn lineLength(p: Pin) u16 {
    const all_cells = p.cells(.all);
    var last: u16 = 0;
    for (all_cells, 0..) |cell, i| {
        if (cell.codepoint() != 0 and cell.codepoint() != ' ') {
            last = @intCast(i);
        }
    }
    return last;
}

/// Returns the column of the first non-whitespace cell on the row, or 0.
fn firstNonBlank(p: Pin) u16 {
    const all_cells = p.cells(.all);
    for (all_cells, 0..) |cell, i| {
        const cp = cell.codepoint();
        if (cp != 0 and cp != ' ' and cp != '\t') {
            return @intCast(i);
        }
    }
    return 0;
}

/// Check whether the cell at pin position is a "word" character
/// (non-whitespace, non-empty).
fn isWordChar(p: Pin) bool {
    const all_cells = p.cells(.all);
    if (p.x >= all_cells.len) return false;
    const cp = all_cells[p.x].codepoint();
    return cp != 0 and cp != ' ' and cp != '\t';
}

/// Advance pin one character to the right, wrapping to next line if needed.
/// Returns null if we can't advance further (end of scrollback).
fn advanceChar(p: Pin) ?Pin {
    const all_cells = p.cells(.all);
    if (p.x + 1 < all_cells.len) {
        var next = p;
        next.x += 1;
        return next;
    }
    // Wrap to next line
    if (p.down(1)) |next_row| {
        var next = next_row;
        next.x = 0;
        return next;
    }
    return null;
}

/// Move pin one character to the left, wrapping to previous line if needed.
/// Returns null if we can't retreat further (start of scrollback).
fn retreatChar(p: Pin) ?Pin {
    if (p.x > 0) {
        var prev = p;
        prev.x -= 1;
        return prev;
    }
    // Wrap to previous line end
    if (p.up(1)) |prev_row| {
        var prev = prev_row;
        prev.x = lineLength(prev);
        return prev;
    }
    return null;
}

/// Process a key event. Returns side-effects for Surface.
pub fn handleKey(self: *ViMode, t: *terminal.Terminal, vp: ViewportInfo, event: input.KeyEvent) ViResult {
    // Decode the first codepoint from the UTF-8 text, if any.
    const cp: u21 = if (event.utf8.len > 0) blk: {
        const len = std.unicode.utf8ByteSequenceLength(event.utf8[0]) catch break :blk 0;
        if (event.utf8.len < len) break :blk 0;
        break :blk std.unicode.utf8Decode(event.utf8[0..len]) catch 0;
    } else 0;

    // Handle pending multi-key sequences (e.g. gg, m{a-z}, '{a-z})
    if (self.pending_key) |pending| {
        self.pending_key = null;
        if (pending == 'g' and cp == 'g') {
            // gg: jump to top of scrollback
            const screen = t.screens.active;
            if (screen.pages.pin(.{ .screen = .{} })) |top_pin| {
                self.cursor_pin.* = top_pin;
                self.cursor_pin.x = 0;
            }
            self.count = null;
            var result: ViResult = .{ .scroll_top = true, .redraw = true };
            if (self.sub_mode != .normal) result.selection_changed = true;
            return result;
        }
        if (pending == 'm') {
            // m{a-z}: set mark at current cursor position
            if (cp >= 'a' and cp <= 'z') {
                const idx = @as(usize, @intCast(cp - 'a'));
                const screen = t.screens.active;
                // Untrack old mark if it exists
                if (self.marks[idx]) |old_pin| {
                    screen.pages.untrackPin(old_pin);
                }
                // Track a new pin at current cursor position
                self.marks[idx] = screen.pages.trackPin(self.cursor_pin.*) catch {
                    self.marks[idx] = null;
                    return .{ .redraw = true };
                };
                return .{ .redraw = true };
            }
            return .{ .redraw = true };
        }
        if (pending == '\'') {
            // '{a-z}: jump to mark
            if (cp >= 'a' and cp <= 'z') {
                const idx = @as(usize, @intCast(cp - 'a'));
                if (self.marks[idx]) |mark_pin| {
                    if (mark_pin.garbage) {
                        const screen = t.screens.active;
                        screen.pages.untrackPin(mark_pin);
                        self.marks[idx] = null;
                    } else {
                        self.cursor_pin.* = mark_pin.*;
                        var result: ViResult = .{ .redraw = true };
                        if (self.sub_mode != .normal) result.selection_changed = true;
                        return result;
                    }
                }
                return .{ .redraw = true };
            }
            return .{ .redraw = true };
        }
        // Unknown pending sequence — ignore
        return .{ .redraw = true };
    }

    // Escape key handling: if in visual mode, return to normal; otherwise exit.
    if (event.key == .escape) {
        self.pending_key = null;
        self.count = null;
        if (self.sub_mode != .normal) {
            self.sub_mode = .normal;
            return .{ .selection_changed = true, .redraw = true };
        }
        return .{ .exit = true, .redraw = true };
    }

    // Other exit keys (q, Enter): exit visual mode first, like Esc.
    if (cp == 'q' or event.key == .enter) {
        self.pending_key = null;
        self.count = null;
        if (self.sub_mode != .normal) {
            self.sub_mode = .normal;
            return .{ .selection_changed = true, .redraw = true };
        }
        return .{ .exit = true, .redraw = true };
    }

    // Arrow keys and page keys — so users don't need to know vim keys
    switch (event.key) {
        .arrow_left => return self.motionH(),
        .arrow_right => return self.motionL(),
        .arrow_down => return self.motionJ(),
        .arrow_up => return self.motionK(),
        .page_up => return self.handleCtrlKey('b', vp),
        .page_down => return self.handleCtrlKey('f', vp),
        .home => {
            _ = self.getEffectiveCount();
            const top_pin = t.screens.active.pages.pin(.{ .screen = .{} }) orelse return .{};
            self.cursor_pin.* = top_pin;
            self.cursor_pin.x = 0;
            return .{ .scroll_top = true, .redraw = true };
        },
        .end => return self.motionBigG(t),
        else => {},
    }

    // Ctrl+key motions (check before digit/letter dispatch)
    if (event.mods.ctrl) {
        if (cp == 'v') {
            return self.toggleVisualMode(.visual_block);
        }
        return self.handleCtrlKey(cp, vp);
    }

    // Count accumulation: digits 1-9 always start/extend count,
    // digit 0 extends count only if already accumulating.
    if (cp >= '1' and cp <= '9') {
        const base = self.count orelse 0;
        self.count = std.math.mul(u32, base, 10) catch return .{};
        self.count = std.math.add(u32, self.count.?, @as(u32, @intCast(cp - '0'))) catch return .{};
        return .{ .redraw = false };
    }
    if (cp == '0' and self.count != null) {
        self.count = std.math.mul(u32, self.count.?, 10) catch return .{};
        return .{ .redraw = false };
    }

    // Motion dispatch
    const motion_result: ViResult = switch (cp) {
        'h' => self.motionH(),
        'l' => self.motionL(),
        'j' => self.motionJ(),
        'k' => self.motionK(),
        '0' => self.motionZero(),
        '$' => self.motionDollar(),
        '^' => self.motionCaret(),
        'G' => self.motionBigG(t),
        'H' => self.motionBigH(vp),
        'M' => self.motionBigM(vp),
        'L' => self.motionBigL(vp),
        'g' => self.motionSmallG(),
        'w' => self.motionW(),
        'b' => self.motionB(),
        'e' => self.motionE(),
        'v' => self.toggleVisualMode(.visual),
        'V' => self.toggleVisualMode(.visual_line),
        '/' => self.startSearchForward(),
        '?' => self.startSearchBackward(),
        'n' => self.navigateSearchNext(),
        'N' => self.navigateSearchPrev(),
        'y' => self.handleYank(),
        'Y' => self.handleYankLine(),
        'm' => self.startPending('m'),
        '\'' => self.startPending('\''),
        else => .{},
    };

    // If we're in a visual sub-mode and a motion moved the cursor,
    // mark the selection as changed so Surface can update it.
    if (self.sub_mode != .normal and motion_result.redraw and !motion_result.selection_changed) {
        var result = motion_result;
        result.selection_changed = true;
        return result;
    }
    return motion_result;
}

// ── h/l motions ──────────────────────────────────────────────────────

fn motionH(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    if (self.cursor_pin.x >= count) {
        self.cursor_pin.x -= @intCast(count);
    } else {
        self.cursor_pin.x = 0;
    }
    return .{ .redraw = true };
}

fn motionL(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    const max_x = lineLength(self.cursor_pin.*);
    const new_x = @as(u32, self.cursor_pin.x) + count;
    self.cursor_pin.x = if (new_x > max_x) max_x else @intCast(new_x);
    return .{ .redraw = true };
}

// ── j/k motions ──────────────────────────────────────────────────────

fn motionJ(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (self.cursor_pin.down(1)) |new_pin| {
            self.cursor_pin.* = new_pin;
            // TODO: implement curswant (remember desired column across vertical moves)
        } else break;
    }
    // Clamp x to new line length
    const max_x = lineLength(self.cursor_pin.*);
    if (self.cursor_pin.x > max_x) {
        self.cursor_pin.x = max_x;
    }
    return .{ .redraw = true };
}

fn motionK(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (self.cursor_pin.up(1)) |new_pin| {
            self.cursor_pin.* = new_pin;
            self.cursor_pin.x = self.cursor_pin.x;
        } else break;
    }
    const max_x = lineLength(self.cursor_pin.*);
    if (self.cursor_pin.x > max_x) {
        self.cursor_pin.x = max_x;
    }
    return .{ .redraw = true };
}

// ── 0, $, ^ motions ─────────────────────────────────────────────────

fn motionZero(self: *ViMode) ViResult {
    self.count = null;
    self.cursor_pin.x = 0;
    return .{ .redraw = true };
}

fn motionDollar(self: *ViMode) ViResult {
    self.count = null;
    self.cursor_pin.x = lineLength(self.cursor_pin.*);
    return .{ .redraw = true };
}

fn motionCaret(self: *ViMode) ViResult {
    self.count = null;
    self.cursor_pin.x = firstNonBlank(self.cursor_pin.*);
    return .{ .redraw = true };
}

// ── gg, G, H, M, L motions ──────────────────────────────────────────

fn motionSmallG(self: *ViMode) ViResult {
    self.pending_key = 'g';
    return .{ .redraw = false };
}

fn motionBigG(self: *ViMode, t: *terminal.Terminal) ViResult {
    self.count = null;
    const screen = t.screens.active;
    if (screen.pages.pin(.{ .active = .{} })) |bottom_pin| {
        self.cursor_pin.* = bottom_pin;
        self.cursor_pin.x = 0;
    }
    return .{ .scroll_bottom = true, .redraw = true };
}

fn motionBigH(self: *ViMode, vp: ViewportInfo) ViResult {
    self.count = null;
    self.cursor_pin.* = vp.top;
    self.cursor_pin.x = firstNonBlank(self.cursor_pin.*);
    return .{ .redraw = true };
}

fn motionBigM(self: *ViMode, vp: ViewportInfo) ViResult {
    self.count = null;
    const mid = vp.rows / 2;
    var pin = vp.top;
    if (pin.down(mid)) |mid_pin| {
        pin = mid_pin;
    }
    self.cursor_pin.* = pin;
    self.cursor_pin.x = firstNonBlank(self.cursor_pin.*);
    return .{ .redraw = true };
}

fn motionBigL(self: *ViMode, vp: ViewportInfo) ViResult {
    self.count = null;
    var pin = vp.top;
    // Go to the last row of the viewport (rows - 1)
    const bottom_offset = if (vp.rows > 0) vp.rows - 1 else 0;
    if (pin.down(bottom_offset)) |bot_pin| {
        pin = bot_pin;
    }
    self.cursor_pin.* = pin;
    self.cursor_pin.x = firstNonBlank(self.cursor_pin.*);
    return .{ .redraw = true };
}

// ── Visual mode toggling ─────────────────────────────────────────────

fn toggleVisualMode(self: *ViMode, target: SubMode) ViResult {
    self.count = null;
    if (self.sub_mode == target) {
        // Toggling same mode off → return to normal
        self.sub_mode = .normal;
    } else {
        // Enter target visual mode (or switch between visual modes)
        self.sub_mode = target;
    }
    return .{ .selection_changed = true, .redraw = true };
}

// ── Yank ─────────────────────────────────────────────────────────────

fn handleYank(self: *ViMode) ViResult {
    self.count = null;
    if (self.sub_mode != .normal) {
        // Yank the visual selection
        return .{ .copy_clipboard = true, .exit = true, .redraw = true };
    }
    return .{ .redraw = true };
}

fn handleYankLine(self: *ViMode) ViResult {
    self.count = null;
    // Y: yank current line — temporarily enter visual_line to select the line
    self.sub_mode = .visual_line;
    return .{ .selection_changed = true, .copy_clipboard = true, .exit = true, .redraw = true };
}

// ── Search triggers ──────────────────────────────────────────────────

fn startSearchForward(self: *ViMode) ViResult {
    self.count = null;
    self.search_direction = .forward;
    return .{ .start_search_forward = true, .redraw = true };
}

fn startSearchBackward(self: *ViMode) ViResult {
    self.count = null;
    self.search_direction = .backward;
    return .{ .start_search_backward = true, .redraw = true };
}

fn navigateSearchNext(self: *ViMode) ViResult {
    self.count = null;
    return switch (self.search_direction) {
        .forward => .{ .navigate_search_next = true, .redraw = true },
        .backward => .{ .navigate_search_prev = true, .redraw = true },
    };
}

fn navigateSearchPrev(self: *ViMode) ViResult {
    self.count = null;
    return switch (self.search_direction) {
        .forward => .{ .navigate_search_prev = true, .redraw = true },
        .backward => .{ .navigate_search_next = true, .redraw = true },
    };
}

// ── Pending key helpers ──────────────────────────────────────────────

fn startPending(self: *ViMode, key: u8) ViResult {
    self.pending_key = key;
    return .{ .redraw = false };
}

// ── Ctrl+u/d/b/f scroll motions ─────────────────────────────────────

fn handleCtrlKey(self: *ViMode, cp: u21, vp: ViewportInfo) ViResult {
    const effective_count = self.getEffectiveCount();
    const half: usize = std.math.mul(usize, @max(vp.rows / 2, 1), effective_count) catch std.math.maxInt(isize);
    const full: usize = std.math.mul(usize, @max(vp.rows, 1), effective_count) catch std.math.maxInt(isize);
    const in_visual = self.sub_mode != .normal;

    switch (cp) {
        'u' => {
            // Half page up
            var i: usize = 0;
            while (i < half) : (i += 1) {
                if (self.cursor_pin.up(1)) |new_pin| {
                    self.cursor_pin.* = new_pin;
                } else break;
            }
            return .{ .scroll_delta = -@as(isize, @intCast(half)), .selection_changed = in_visual, .redraw = true };
        },
        'd' => {
            // Half page down
            var i: usize = 0;
            while (i < half) : (i += 1) {
                if (self.cursor_pin.down(1)) |new_pin| {
                    self.cursor_pin.* = new_pin;
                } else break;
            }
            return .{ .scroll_delta = @as(isize, @intCast(half)), .selection_changed = in_visual, .redraw = true };
        },
        'b' => {
            // Full page up
            var i: usize = 0;
            while (i < full) : (i += 1) {
                if (self.cursor_pin.up(1)) |new_pin| {
                    self.cursor_pin.* = new_pin;
                } else break;
            }
            return .{ .scroll_delta = -@as(isize, @intCast(full)), .selection_changed = in_visual, .redraw = true };
        },
        'f' => {
            // Full page down
            var i: usize = 0;
            while (i < full) : (i += 1) {
                if (self.cursor_pin.down(1)) |new_pin| {
                    self.cursor_pin.* = new_pin;
                } else break;
            }
            return .{ .scroll_delta = @as(isize, @intCast(full)), .selection_changed = in_visual, .redraw = true };
        },
        else => return .{},
    }
}

// ── w/b/e word motions ──────────────────────────────────────────────

fn motionW(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    var pin = self.cursor_pin.*;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Skip current word (non-whitespace characters)
        while (isWordChar(pin)) {
            if (advanceChar(pin)) |next| {
                pin = next;
            } else {
                self.cursor_pin.* = pin;
                return .{ .redraw = true };
            }
        }
        // Skip whitespace
        while (!isWordChar(pin)) {
            if (advanceChar(pin)) |next| {
                pin = next;
            } else {
                self.cursor_pin.* = pin;
                return .{ .redraw = true };
            }
        }
    }
    self.cursor_pin.* = pin;
    return .{ .redraw = true };
}

fn motionB(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    var pin = self.cursor_pin.*;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Move back one character first to get off current position
        if (retreatChar(pin)) |prev| {
            pin = prev;
        } else {
            break;
        }
        // Skip whitespace backwards
        while (!isWordChar(pin)) {
            if (retreatChar(pin)) |prev| {
                pin = prev;
            } else {
                self.cursor_pin.* = pin;
                return .{ .redraw = true };
            }
        }
        // Skip word characters backwards to find start of word
        while (isWordChar(pin)) {
            if (retreatChar(pin)) |prev| {
                if (!isWordChar(prev)) break;
                pin = prev;
            } else break;
        }
    }
    self.cursor_pin.* = pin;
    return .{ .redraw = true };
}

fn motionE(self: *ViMode) ViResult {
    const count = self.getEffectiveCount();
    var pin = self.cursor_pin.*;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        // Advance one character to get off current position
        if (advanceChar(pin)) |next| {
            pin = next;
        } else break;
        // Skip whitespace
        while (!isWordChar(pin)) {
            if (advanceChar(pin)) |next| {
                pin = next;
            } else {
                self.cursor_pin.* = pin;
                return .{ .redraw = true };
            }
        }
        // Move to end of word
        while (isWordChar(pin)) {
            if (advanceChar(pin)) |next| {
                if (!isWordChar(next)) break;
                pin = next;
            } else break;
        }
    }
    self.cursor_pin.* = pin;
    return .{ .redraw = true };
}

test "ViMode init defaults" {
    var vi = ViMode{
        .cursor_pin = undefined,
    };
    try std.testing.expectEqual(SubMode.normal, vi.sub_mode);
    try std.testing.expectEqual(@as(?u32, null), vi.count);
    try std.testing.expectEqual(@as(?u8, null), vi.pending_key);
    _ = &vi;
}
