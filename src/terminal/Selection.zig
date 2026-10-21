//! Represents a single selection within the terminal (i.e. a highlight region).
const Selection = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const lib = @import("lib.zig");
const page = @import("page.zig");
const point = @import("point.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Pin = PageList.Pin;

// NOTE(mitchellh): I'm not very happy with how this is implemented, because
// the ordering operations which are used frequently require using
// pointFromPin which -- at the time of writing this -- is slow. The overall
// style of this struct is due to porting it from the previous implementation
// which had an efficient ordering operation.
//
// While reimplementing this, there were too many callers that already
// depended on this behavior so I kept it despite the inefficiency. In the
// future, we should take a look at this again!

/// The bounds of the selection.
bounds: Bounds,

/// Whether or not this selection refers to a rectangle, rather than whole
/// lines of a buffer. In this mode, start and end refer to the top left and
/// bottom right of the rectangle, or vice versa if the selection is backwards.
rectangle: bool = false,

/// The bounds of the selection. A selection bounds can be either tracked
/// or untracked. Untracked bounds are unsafe beyond the point the terminal
/// screen may be modified, since they may point to invalid memory. Tracked
/// bounds are always valid and will be updated as the screen changes, but
/// are more expensive to exist.
///
/// In all cases, start and end can be in any order. There is no guarantee that
/// start is before end or vice versa. If a user selects backwards,
/// start will be after end, and vice versa. Use the struct functions
/// to not have to worry about this.
pub const Bounds = union(enum) {
    untracked: struct {
        start: Pin,
        end: Pin,
    },

    tracked: struct {
        start: *Pin,
        end: *Pin,
    },
};

/// Initialize a new selection with the given start and end pins on
/// the screen. The screen will be used for pin tracking.
pub fn init(
    start_pin: Pin,
    end_pin: Pin,
    rect: bool,
) Selection {
    return .{
        .bounds = .{ .untracked = .{
            .start = start_pin,
            .end = end_pin,
        } },
        .rectangle = rect,
    };
}

pub fn deinit(
    self: Selection,
    s: *Screen,
) void {
    switch (self.bounds) {
        .tracked => |v| {
            s.pages.untrackPin(v.start);
            s.pages.untrackPin(v.end);
        },

        .untracked => {},
    }
}

/// Returns true if this selection is equal to another selection.
pub fn eql(self: Selection, other: Selection) bool {
    return self.start().eql(other.start()) and
        self.end().eql(other.end()) and
        self.rectangle == other.rectangle;
}

/// The starting pin of the selection. This is NOT ordered.
pub fn startPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.start,
        .tracked => |v| v.start,
    };
}

/// The ending pin of the selection. This is NOT ordered.
pub fn endPtr(self: *Selection) *Pin {
    return switch (self.bounds) {
        .untracked => |*v| &v.end,
        .tracked => |v| v.end,
    };
}

pub fn start(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.start,
        .tracked => |v| v.start.*,
    };
}

pub fn end(self: Selection) Pin {
    return switch (self.bounds) {
        .untracked => |v| v.end,
        .tracked => |v| v.end.*,
    };
}

/// Returns true if this is a tracked selection.
pub fn tracked(self: *const Selection) bool {
    return switch (self.bounds) {
        .untracked => false,
        .tracked => true,
    };
}

/// Convert this selection a tracked selection. It is asserted this is
/// an untracked selection. The tracked selection is returned.
pub fn track(self: *const Selection, s: *Screen) Allocator.Error!Selection {
    assert(!self.tracked());

    // Track our pins
    const start_pin = self.bounds.untracked.start;
    const end_pin = self.bounds.untracked.end;
    const tracked_start = try s.pages.trackPin(start_pin);
    errdefer s.pages.untrackPin(tracked_start);
    const tracked_end = try s.pages.trackPin(end_pin);
    errdefer s.pages.untrackPin(tracked_end);

    return .{
        .bounds = .{ .tracked = .{
            .start = tracked_start,
            .end = tracked_end,
        } },
        .rectangle = self.rectangle,
    };
}

/// Returns the top left point of the selection.
pub fn topLeft(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.start(),
        .reverse => self.end(),
        .mirrored_forward => pin: {
            var p = self.start();
            p.x = @min(self.end().x, p.node.cols() - 1);
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.end();
            p.x = @min(self.start().x, p.node.cols() - 1);
            break :pin p;
        },
    };
}

/// Returns the bottom right point of the selection.
pub fn bottomRight(self: Selection, s: *const Screen) Pin {
    return switch (self.order(s)) {
        .forward => self.end(),
        .reverse => self.start(),
        .mirrored_forward => pin: {
            var p = self.end();
            p.x = @min(self.start().x, p.node.cols() - 1);
            break :pin p;
        },
        .mirrored_reverse => pin: {
            var p = self.start();
            p.x = @min(self.end().x, p.node.cols() - 1);
            break :pin p;
        },
    };
}

/// The order of the selection:
///
///  * forward: start(x, y) is before end(x, y) (top-left to bottom-right).
///  * reverse: end(x, y) is before start(x, y) (bottom-right to top-left).
///  * mirrored_[forward|reverse]: special, rectangle selections only (see below).
///
///  For regular selections, the above also holds for top-right to bottom-left
///  (forward) and bottom-left to top-right (reverse). However, for rectangle
///  selections, both of these selections are *mirrored* as orientation
///  operations only flip the x or y axis, not both. Depending on the y axis
///  direction, this is either mirrored_forward or mirrored_reverse.
///
pub const Order = lib.Enum(lib.target, &.{
    "forward",
    "reverse",
    "mirrored_forward",
    "mirrored_reverse",
});

pub fn order(self: Selection, s: *const Screen) Order {
    const start_pt = s.pages.pointFromPin(.screen, self.start()).?.screen;
    const end_pt = s.pages.pointFromPin(.screen, self.end()).?.screen;

    if (self.rectangle) {
        // Reverse (also handles single-column)
        if (start_pt.y > end_pt.y and start_pt.x >= end_pt.x) return .reverse;
        if (start_pt.y >= end_pt.y and start_pt.x > end_pt.x) return .reverse;

        // Mirror, bottom-left to top-right
        if (start_pt.y > end_pt.y and start_pt.x < end_pt.x) return .mirrored_reverse;

        // Mirror, top-right to bottom-left
        if (start_pt.y < end_pt.y and start_pt.x > end_pt.x) return .mirrored_forward;

        // Forward
        return .forward;
    }

    if (start_pt.y < end_pt.y) return .forward;
    if (start_pt.y > end_pt.y) return .reverse;
    if (start_pt.x <= end_pt.x) return .forward;
    return .reverse;
}

/// Returns the selection in the given order.
///
/// The returned selection is always a new untracked selection.
///
/// Note that only forward and reverse are useful desired orders for this
/// function. All other orders act as if forward order was desired.
pub fn ordered(self: Selection, s: *const Screen, desired: Order) Selection {
    if (self.order(s) == desired) return .init(
        self.start(),
        self.end(),
        self.rectangle,
    );

    const tl = self.topLeft(s);
    const br = self.bottomRight(s);
    return switch (desired) {
        .forward => .init(tl, br, self.rectangle),
        .reverse => .init(br, tl, self.rectangle),
        else => .init(tl, br, self.rectangle),
    };
}

/// Returns true if the selection contains the given point.
///
/// This recalculates top left and bottom right each call. If you have
/// many points to check, it is cheaper to do the containment logic
/// yourself and cache the topleft/bottomright.
pub fn contains(self: Selection, s: *const Screen, pin: Pin) bool {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);

    // This is definitely not very efficient. Low-hanging fruit to
    // improve this.
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;

    // If we're in rectangle select, we can short-circuit with an easy check
    // here
    if (self.rectangle)
        return p.y >= tl.y and p.y <= br.y and p.x >= tl.x and p.x <= br.x;

    // If tl/br are same line
    if (tl.y == br.y) return p.y == tl.y and
        p.x >= tl.x and
        p.x <= br.x;

    // If on top line, just has to be left of X
    if (p.y == tl.y) return p.x >= tl.x;

    // If on bottom line, just has to be right of X
    if (p.y == br.y) return p.x <= br.x;

    // If between the top/bottom, always good.
    return p.y > tl.y and p.y < br.y;
}

/// Get a selection for a single row in the screen. This will return null
/// if the row is not included in the selection.
///
/// This is a very expensive operation. It has to traverse the linked list
/// of pages for the top-left, bottom-right, and the given pin to find
/// the coordinates. If you are calling this repeatedly, prefer
/// `containedRowCached`.
pub fn containedRow(self: Selection, s: *const Screen, pin: Pin) ?Selection {
    const tl_pin = self.topLeft(s);
    const br_pin = self.bottomRight(s);

    // This is definitely not very efficient. Low-hanging fruit to
    // improve this. Callers should prefer containedRowCached if they
    // can swing it.
    const tl = s.pages.pointFromPin(.screen, tl_pin).?.screen;
    const br = s.pages.pointFromPin(.screen, br_pin).?.screen;
    const p = s.pages.pointFromPin(.screen, pin).?.screen;

    return self.containedRowCached(
        s,
        tl_pin,
        br_pin,
        pin,
        tl,
        br,
        p,
    );
}

/// Same as containedRow but useful if you're calling it repeatedly
/// so that the pins can be cached across calls. Advanced.
pub fn containedRowCached(
    self: Selection,
    s: *const Screen,
    tl_pin: Pin,
    br_pin: Pin,
    pin: Pin,
    tl: point.Coordinate,
    br: point.Coordinate,
    p: point.Coordinate,
) ?Selection {
    _ = s;
    if (p.y < tl.y or p.y > br.y) return null;

    // Rectangle case: we can return early as the x range will always be the
    // same. We've already validated that the row is in the selection.
    if (self.rectangle) return init(
        start: {
            var copy: Pin = pin;
            copy.x = @min(tl.x, copy.node.cols() - 1);
            break :start copy;
        },
        end: {
            var copy: Pin = pin;
            copy.x = @min(br.x, copy.node.cols() - 1);
            break :end copy;
        },
        true,
    );

    if (p.y == tl.y) {
        // If the selection is JUST this line, return it as-is.
        if (p.y == br.y) {
            return init(tl_pin, br_pin, false);
        }

        // Selection top-left line matches only.
        return init(
            tl_pin,
            end: {
                var copy: Pin = pin;
                copy.x = copy.node.cols() - 1;
                break :end copy;
            },
            false,
        );
    }

    // Row is our bottom selection, so we return the selection from the
    // beginning of the line to the br. We know our selection is more than
    // one line (due to conditionals above)
    if (p.y == br.y) {
        assert(p.y != tl.y);
        return init(
            start: {
                var copy: Pin = pin;
                copy.x = 0;
                break :start copy;
            },
            br_pin,
            false,
        );
    }

    // Row is somewhere between our selection lines so we return the full line.
    return init(
        start: {
            var copy: Pin = pin;
            copy.x = 0;
            break :start copy;
        },
        end: {
            var copy: Pin = pin;
            copy.x = copy.node.cols() - 1;
            break :end copy;
        },
        false,
    );
}

/// Possible adjustments to the selection.
pub const Adjustment = lib.Enum(lib.target, &.{
    "left",
    "right",
    "up",
    "down",
    "home",
    "end",
    "page_up",
    "page_down",
    "beginning_of_line",
    "end_of_line",
});

/// Adjust the selection by some given adjustment. An adjustment allows
/// a selection to be expanded slightly left, right, up, down, etc.
pub fn adjust(
    self: *Selection,
    s: *const Screen,
    adjustment: Adjustment,
) void {
    // Note that we always adjust "end" because end always represents
    // the last point of the selection by mouse, not necessarily the
    // top/bottom visually. So this results in the correct behavior
    // whether the user drags up or down.
    const end_pin = self.endPtr();
    switch (adjustment) {
        .up => if (end_pin.up(1)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .beginning_of_line);
        },

        .down => {
            // Find the next non-blank row
            var current = end_pin.*;
            while (current.down(1)) |next| : (current = next) {
                const rac = next.rowAndCell();
                const cells = next.node.page().getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    break;
                }
            } else {
                // If we're at the bottom, just go to the end of the line
                self.adjust(s, .end_of_line);
            }
        },

        .left => {
            var it = end_pin.cellIterator(.left_up, null);
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },

        .right => {
            // Step right, wrapping to the next row down at the start of each new line,
            // until we find a non-empty cell.
            var it = end_pin.cellIterator(.right_down, null);
            _ = it.next();
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                if (rac.cell.hasText()) {
                    end_pin.* = next;
                    break;
                }
            }
        },

        .page_up => if (end_pin.up(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .home);
        },

        .page_down => if (end_pin.down(s.pages.rows)) |new_end| {
            end_pin.* = new_end;
        } else {
            self.adjust(s, .end);
        },

        .home => end_pin.* = s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?,

        .end => {
            var it = s.pages.rowIterator(
                .left_up,
                .{ .screen = .{} },
                null,
            );
            while (it.next()) |next| {
                const rac = next.rowAndCell();
                const cells = next.node.page().getCells(rac.row);
                if (page.Cell.hasTextAny(cells)) {
                    end_pin.* = next;
                    end_pin.x = @intCast(cells.len - 1);
                    break;
                }
            }
        },

        .beginning_of_line => end_pin.x = 0,

        .end_of_line => end_pin.x = end_pin.node.cols() - 1,
    }
}

/// A motion of the selection head, as a keyboard copy mode moves a cursor.
/// Unlike `Adjustment`, each motion goes exactly where the cursor of a text
/// editor would go: one cell, one row or one word. It does not skip blank
/// cells and it does not wrap at the edge of the row.
pub const Motion = enum {
    left,
    right,
    up,
    down,
    word_next,
    word_end,
    word_prev,
    next_word_start,
    line_start,
    line_end,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    top,
    bottom,
};

/// Move the selection head (`end`) by a motion. With `extend` the anchor
/// (`start`) stays, so the selection grows or shrinks. Without it the anchor
/// follows the head, and the selection is one cell: a cursor.
///
/// `boundary_codepoints` are the word boundary codepoints of the config
/// (`selection-word-chars`), as `Screen.selectWord` takes them. A word is a
/// run of cells that are all boundary codepoints or all not. Space, tab, an
/// empty cell and the end of a row that does not wrap are blank. A word
/// motion steps over blanks.
pub fn move(
    self: *Selection,
    s: *const Screen,
    motion: Motion,
    extend: bool,
    boundary_codepoints: []const u21,
) void {
    const head = self.endPtr();
    const target: Pin = switch (motion) {
        .left => if (head.x > 0) head.left(1) else head.*,
        .right => if (@as(usize, head.x) + 1 < head.node.cols()) head.right(1) else head.*,
        .up => head.up(1) orelse head.*,
        .down => head.down(1) orelse head.*,
        .page_up => head.up(s.pages.rows) orelse edgeRow(s, head.*, .top),
        .page_down => head.down(s.pages.rows) orelse edgeRow(s, head.*, .bottom),
        .half_page_up => head.up(@max(1, s.pages.rows / 2)) orelse edgeRow(s, head.*, .top),
        .half_page_down => head.down(@max(1, s.pages.rows / 2)) orelse edgeRow(s, head.*, .bottom),
        .line_start => pin: {
            var p = head.*;
            p.x = 0;
            break :pin p;
        },
        .line_end => lastTextCell(head.*) orelse pin: {
            var p = head.*;
            p.x = 0;
            break :pin p;
        },
        .top => s.pages.getTopLeft(.screen),
        .bottom => lastTextCellOfScreen(s) orelse head.*,
        .word_next => wordNext(head.*, boundary_codepoints),
        .word_end => wordEnd(head.*, boundary_codepoints),
        .word_prev => wordPrev(head.*, boundary_codepoints),
        .next_word_start => nextWordStart(head.*, boundary_codepoints),
    };

    head.* = target;
    if (!extend) self.startPtr().* = target;
}

/// Grow the selection to whole rows, as `x` does in Helix. The anchor goes to
/// the start of its row and the head to the end of its row, with the head
/// below the anchor. Rows that soft-wrap are one line. A selection that
/// already covers whole rows grows by one row at the bottom.
pub fn expandToLines(self: *Selection, s: *const Screen) void {
    const tl = self.topLeft(s);
    const br = self.bottomRight(s);

    var start_pin = tl;
    while (start_pin.up(1)) |above| {
        if (!above.rowAndCell().row.wrap) break;
        start_pin = above;
    }
    start_pin.x = 0;

    const whole = tl.x == 0 and
        br.x == br.node.cols() - 1 and
        !br.rowAndCell().row.wrap;
    var end_pin = if (whole) br.down(1) orelse br else br;
    while (end_pin.rowAndCell().row.wrap) {
        end_pin = end_pin.down(1) orelse break;
    }
    end_pin.x = end_pin.node.cols() - 1;

    self.startPtr().* = start_pin;
    self.endPtr().* = end_pin;
}

/// Grow the selection to whole rows and keep its direction, as `V` does in
/// Vim and `X` in Helix. The end that is above goes to the start of its row,
/// the end that is below goes to the end of its row, and each stays the
/// anchor or the head that it was, so a motion of the head after this still
/// moves the same end. Rows that soft-wrap are one line. A selection that
/// already covers whole rows does not change.
pub fn expandToLineBounds(self: *Selection, s: *const Screen) void {
    var top = self.topLeft(s);
    while (top.up(1)) |above| {
        if (!above.rowAndCell().row.wrap) break;
        top = above;
    }
    top.x = 0;

    var bottom = self.bottomRight(s);
    while (bottom.rowAndCell().row.wrap) {
        bottom = bottom.down(1) orelse break;
    }
    bottom.x = bottom.node.cols() - 1;

    if (self.order(s) == .reverse) {
        self.startPtr().* = bottom;
        self.endPtr().* = top;
    } else {
        self.startPtr().* = top;
        self.endPtr().* = bottom;
    }
}

/// The first or last row of the written screen, in the column of `pin`.
fn edgeRow(s: *const Screen, pin: Pin, edge: enum { top, bottom }) Pin {
    var p = switch (edge) {
        .top => s.pages.getTopLeft(.screen),
        .bottom => s.pages.getBottomRight(.screen) orelse return pin,
    };
    p.x = @min(pin.x, p.node.cols() - 1);
    return p;
}

/// The last cell with text on the row of `pin`, or null for a blank row.
fn lastTextCell(pin: Pin) ?Pin {
    const cells = pin.cells(.all);
    var x: usize = cells.len;
    while (x > 0) {
        x -= 1;
        if (cells[x].hasText()) {
            var p = pin;
            p.x = @intCast(x);
            return p;
        }
    }
    return null;
}

/// The last cell with text on the screen, or null for a blank screen.
fn lastTextCellOfScreen(s: *const Screen) ?Pin {
    var it = s.pages.rowIterator(.left_up, .{ .screen = .{} }, null);
    while (it.next()) |row| {
        if (lastTextCell(row)) |p| return p;
    }
    return null;
}

/// What a cell is to a word motion.
const CellClass = enum { blank, boundary, word };

fn classAt(pin: Pin, boundary_codepoints: []const u21) CellClass {
    const rac = pin.rowAndCell();
    const cell = switch (rac.cell.wide) {
        .narrow, .wide => rac.cell,
        // The tail of a wide character belongs to the character.
        .spacer_tail => pin.left(1).rowAndCell().cell,
        .spacer_head => return .blank,
    };
    if (!cell.hasText()) return .blank;
    const cp = cell.content.codepoint.data;
    if (cp == ' ' or cp == '\t') return .blank;
    return if (std.mem.indexOfScalar(u21, boundary_codepoints, cp) != null)
        .boundary
    else
        .word;
}

/// Steps one cell at a time through the screen for the word motions. The end
/// of a row that does not wrap is one blank step between the two rows, so a
/// word never continues across it, and a word motion crosses it as it
/// crosses a space.
const WordWalker = struct {
    pin: Pin,
    boundary_codepoints: []const u21,
    /// True while the walker stands on the blank between two rows. `pin` is
    /// then already the cell on the far side.
    at_break: bool = false,
    /// The last real cell the walker stood on before `pin`.
    last: Pin,

    fn init(pin: Pin, boundary_codepoints: []const u21) WordWalker {
        return .{ .pin = pin, .boundary_codepoints = boundary_codepoints, .last = pin };
    }

    fn class(self: WordWalker) CellClass {
        if (self.at_break) return .blank;
        return classAt(self.pin, self.boundary_codepoints);
    }

    /// Step right. Returns false at the end of the screen.
    fn right(self: *WordWalker) bool {
        if (self.at_break) {
            self.at_break = false;
            return true;
        }
        if (@as(usize, self.pin.x) + 1 < self.pin.node.cols()) {
            self.last = self.pin;
            self.pin = self.pin.right(1);
            return true;
        }
        const wrap = self.pin.rowAndCell().row.wrap;
        var next = self.pin.down(1) orelse return false;
        next.x = 0;
        self.last = self.pin;
        self.pin = next;
        self.at_break = !wrap;
        return true;
    }

    /// Step left. Returns false at the start of the screen.
    fn left(self: *WordWalker) bool {
        if (self.at_break) {
            self.at_break = false;
            return true;
        }
        if (self.pin.x > 0) {
            self.last = self.pin;
            self.pin = self.pin.left(1);
            return true;
        }
        var prev = self.pin.up(1) orelse return false;
        prev.x = prev.node.cols() - 1;
        const wrap = prev.rowAndCell().row.wrap;
        self.last = self.pin;
        self.pin = prev;
        self.at_break = !wrap;
        return true;
    }
};

/// Helix `w`: the cell before the start of the next word. From inside a word
/// this is the last blank after it, so the selection covers the word and the
/// blanks that follow it. With no next word the head stays.
///
/// When the head is the last cell before a word (the cell that a `w` leaves
/// it on, the end of a word with a boundary run after it, or the end of a row
/// with a word at the start of the next row), the walk starts on that word,
/// as in Helix. Without this a repeated `w` would not move.
fn wordNext(pin: Pin, boundary_codepoints: []const u21) Pin {
    var w = WordWalker.init(pin, boundary_codepoints);
    const head_class = w.class();
    var next = w;
    if (!next.right()) return pin;
    // The end of a row that does not wrap ends a word too.
    const crossed_row = next.at_break;
    if (crossed_row and !next.right()) return pin;
    const next_class = next.class();
    if (next_class != .blank and (crossed_row or next_class != head_class)) w = next;
    const start_class = w.class();
    if (start_class != .blank) {
        while (true) {
            if (!w.right()) return pin;
            if (w.class() != start_class) break;
        }
    }
    while (w.class() == .blank) {
        if (!w.right()) return pin;
    }
    return w.last;
}

/// Helix `e`: the last cell of the word the head is in, or of the next word
/// when the head is at the end of a word or on a blank. With no word ahead
/// the head stays.
fn wordEnd(pin: Pin, boundary_codepoints: []const u21) Pin {
    var w = WordWalker.init(pin, boundary_codepoints);
    if (!w.right()) return pin;
    while (w.class() == .blank) {
        if (!w.right()) return pin;
    }
    const cls = w.class();
    while (true) {
        const here = w.pin;
        if (!w.right()) return here;
        if (w.class() != cls) return here;
    }
}

/// Helix `b`: the first cell of the word the head is in, or of the previous
/// word when the head is at the start of a word or on a blank. With no word
/// behind the head stays.
fn wordPrev(pin: Pin, boundary_codepoints: []const u21) Pin {
    var w = WordWalker.init(pin, boundary_codepoints);
    if (!w.left()) return pin;
    while (w.class() == .blank) {
        if (!w.left()) return pin;
    }
    const cls = w.class();
    while (true) {
        const here = w.pin;
        if (!w.left()) return here;
        if (w.class() != cls) return here;
    }
}

/// Vim `w`: the first cell of the next word. From inside a word this is the
/// start of the word after it; a run of boundary codepoints after a word is
/// the next word (`foo.bar`: `w` lands on the dot). With no next word the
/// head stays.
fn nextWordStart(pin: Pin, boundary_codepoints: []const u21) Pin {
    var w = WordWalker.init(pin, boundary_codepoints);
    const start_class = w.class();
    if (start_class != .blank) {
        while (true) {
            if (!w.right()) return pin;
            if (w.class() != start_class) break;
        }
    }
    while (w.class() == .blank) {
        if (!w.right()) return pin;
    }
    return w.pin;
}

test "Selection: adjust right" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement right
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at end of the line.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at end of the screen
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .right);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust left" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // Simple movement left
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at beginning of the line.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust left skips blanks" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC12\nD56");

    // Same line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Edge
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .left);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust up" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // On the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .up);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust down" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC\nD\nE");

    // Not on the first line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 4 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 4,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust down with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .down);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust home" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .home);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust end with not full screen" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A\nB\nC");

    // On the last line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 4, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 4,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 9,
            .y = 2,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust beginning of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");

    // Not at beginning of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at beginning of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 5,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // End pin moves to start pin
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .beginning_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

test "Selection: adjust end of line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 8, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A12 B34\nC12 D34");

    // Not at end of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // Already at end of the line
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    // End pin moves to start pin
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);
        sel.adjust(&s, .end_of_line);

        // Start line
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 7,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }
}

/// Test helper: the screen point of a pin.
fn testPoint(s: *const Screen, p: Pin) point.Point {
    return s.pages.pointFromPin(.screen, p).?;
}

/// Test helper: a screen point.
fn testScreen(x: u16, y: u16) point.Point {
    return .{ .screen = .{ .x = x, .y = y } };
}

const test_word_boundaries = [_]u21{ 0, ' ', '\t', '-' };

test "Selection: move left and right stay on the row and collapse" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    var sel = Selection.init(
        s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
        s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?,
        false,
    );
    defer sel.deinit(&s);

    sel.move(&s, .right, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));

    sel.move(&s, .left, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));

    // The row edges stop the head.
    sel.move(&s, .line_start, false, &test_word_boundaries);
    sel.move(&s, .left, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.end()));
    sel.endPtr().x = 9;
    sel.move(&s, .right, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(9, 0), testPoint(&s, sel.end()));
}

test "Selection: move with extend keeps the anchor" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .right, true, &test_word_boundaries);
    sel.move(&s, .down, true, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(1, 1), testPoint(&s, sel.end()));
}

test "Selection: move up and down stop at the screen edges" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234");

    const origin = s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .up, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));
    sel.move(&s, .up, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));

    sel.move(&s, .down, false, &test_word_boundaries);
    sel.move(&s, .down, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 2), testPoint(&s, sel.end()));
    sel.move(&s, .down, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 2), testPoint(&s, sel.end()));
}

test "Selection: move word_next selects the word and the blanks after it" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    // From inside a word: the blank before the next word.
    sel.move(&s, .word_next, true, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));

    // From a blank right before a word: that word and the blanks after
    // it, so a repeated `w` moves on.
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(9, 0), testPoint(&s, sel.end()));

    // The last word of a row: the end of the row, because the next word
    // is on the next row.
    sel.endPtr().x = 4;
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(9, 0), testPoint(&s, sel.end()));

    // No next word: stays.
    sel.endPtr().* = s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.end()));
}

test "Selection: move word_next goes on from the end of a row" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ab\ncd ef");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    // The last word of a row: the end of the row.
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(9, 0), testPoint(&s, sel.end()));

    // Again from the end of the row: the first word of the next row and
    // the blank after it.
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 1), testPoint(&s, sel.end()));
}

test "Selection: move word_end goes to the end of the word" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 0), testPoint(&s, sel.end()));

    // At the end of a word: the end of the next word.
    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(6, 0), testPoint(&s, sel.end()));

    // Across the end of the row.
    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 1), testPoint(&s, sel.end()));

    // No word ahead: stays.
    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 1), testPoint(&s, sel.end()));
}

test "Selection: move word_prev goes to the start of the word" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 6, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .word_prev, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));

    // At the start of a word: the start of the previous word.
    sel.move(&s, .word_prev, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.end()));

    // No word behind: stays.
    sel.move(&s, .word_prev, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.end()));

    // Across the start of the row.
    sel.endPtr().* = s.pages.pin(.{ .screen = .{ .x = 0, .y = 1 } }).?;
    sel.move(&s, .word_prev, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));
}

test "Selection: move word motions treat a boundary run as a word" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ab--cd ef");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(1, 0), testPoint(&s, sel.end()));
    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));
    sel.move(&s, .word_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(5, 0), testPoint(&s, sel.end()));

    // `w` with no blank between the runs: the last cell of the run.
    sel.endPtr().x = 0;
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(1, 0), testPoint(&s, sel.end()));

    // A repeated `w` moves on: to the end of the next run, then to the
    // blank before the next word.
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(3, 0), testPoint(&s, sel.end()));
    sel.move(&s, .word_next, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(6, 0), testPoint(&s, sel.end()));
}

test "Selection: move line_start, line_end, top and bottom" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .line_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 1), testPoint(&s, sel.end()));
    sel.move(&s, .line_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.end()));
    sel.move(&s, .top, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.end()));
    sel.move(&s, .bottom, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 1), testPoint(&s, sel.end()));

    // A blank row has no end: the head goes to its start.
    sel.endPtr().* = s.pages.pin(.{ .screen = .{ .x = 3, .y = 5 } }).?;
    sel.move(&s, .line_end, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 5), testPoint(&s, sel.end()));
}

test "Selection: move page motions clamp to the screen and keep the column" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 4, .y = 1 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .page_up, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));
    sel.move(&s, .half_page_down, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 5), testPoint(&s, sel.end()));
    sel.move(&s, .page_down, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 9), testPoint(&s, sel.end()));
    sel.move(&s, .half_page_up, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 4), testPoint(&s, sel.end()));
}

test "Selection: expandToLines selects whole rows, then grows by a row" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    {
        const origin = s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?;
        var sel = Selection.init(origin, origin, false);
        defer sel.deinit(&s);

        sel.expandToLines(&s);
        try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 1), testPoint(&s, sel.end()));

        sel.expandToLines(&s);
        try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 2), testPoint(&s, sel.end()));
    }

    // A reverse selection becomes forward, anchor on top.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);

        sel.expandToLines(&s);
        try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 2), testPoint(&s, sel.end()));
    }
}

test "Selection: expandToLines takes a soft-wrapped line as one line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("0123456789abc\nnext");

    const origin = s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.expandToLines(&s);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(9, 1), testPoint(&s, sel.end()));

    sel.expandToLines(&s);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(9, 2), testPoint(&s, sel.end()));
}

test "Selection: move next_word_start lands on the next word" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("foo bar\nbaz");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    // From inside a word: the first cell of the next word.
    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.start()));

    // From the last word of a row: the first word of the next row.
    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.end()));

    // No next word: stays.
    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.end()));

    // From a blank: the word after it.
    sel.endPtr().* = s.pages.pin(.{ .screen = .{ .x = 3, .y = 0 } }).?;
    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));
}

test "Selection: move next_word_start takes a boundary run as a word" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("ab--cd");

    const origin = s.pages.pin(.{ .screen = .{ .x = 0, .y = 0 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(2, 0), testPoint(&s, sel.end()));
    sel.move(&s, .next_word_start, false, &test_word_boundaries);
    try testing.expectEqual(testScreen(4, 0), testPoint(&s, sel.end()));
}

test "Selection: expandToLineBounds keeps the direction and does not grow" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("A1234\nB5678\nC1234\nD5678");

    // One cell: its row, head at the end.
    {
        const origin = s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?;
        var sel = Selection.init(origin, origin, false);
        defer sel.deinit(&s);

        sel.expandToLineBounds(&s);
        try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 1), testPoint(&s, sel.end()));

        // Whole rows already: no change.
        sel.expandToLineBounds(&s);
        try testing.expectEqual(testScreen(0, 1), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 1), testPoint(&s, sel.end()));
    }

    // Head below the anchor: the anchor takes the top start, the head the
    // bottom end.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);

        sel.expandToLineBounds(&s);
        try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(9, 2), testPoint(&s, sel.end()));
    }

    // Head above the anchor: the anchor takes the bottom end, the head the
    // top start, so a motion of the head still moves the top.
    {
        var sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
            false,
        );
        defer sel.deinit(&s);

        sel.expandToLineBounds(&s);
        try testing.expectEqual(testScreen(9, 2), testPoint(&s, sel.start()));
        try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.end()));
    }
}

test "Selection: expandToLineBounds takes a soft-wrapped line as one line" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    try s.testWriteString("0123456789abc\nnext");

    const origin = s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?;
    var sel = Selection.init(origin, origin, false);
    defer sel.deinit(&s);

    sel.expandToLineBounds(&s);
    try testing.expectEqual(testScreen(0, 0), testPoint(&s, sel.start()));
    try testing.expectEqual(testScreen(9, 1), testPoint(&s, sel.end()));
}

test "Selection: order, standard" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 100, .rows = 100, .max_scrollback_bytes = 1 });
    defer s.deinit();

    {
        // forward, multi-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, multi-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, same-line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // forward, single char
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
}

test "Selection: rectangle corners clamp across mixed-width pages" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 2,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 1 });
    const second = first.next.?;
    second.page().size.cols = 2;

    const sel = Selection.init(
        .{ .node = first, .x = 3 },
        .{ .node = second, .x = 1 },
        true,
    );
    try testing.expectEqual(.mirrored_forward, sel.order(&s));

    const bottom_right = sel.bottomRight(&s);
    _ = bottom_right.rowAndCell();
    try testing.expect((Pin{ .node = second, .x = 1 }).eql(bottom_right));
}

test "Selection: order, rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var s = try Screen.init(io, alloc, .{ .cols = 100, .rows = 100, .max_scrollback_bytes = 1 });
    defer s.deinit();

    // Conventions:
    // TL - top left
    // BL - bottom left
    // TR - top right
    // BR - bottom right
    {
        // forward (TL -> BR)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse (BR -> TL)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // mirrored_forward (TR -> BL)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_forward);
    }
    {
        // mirrored_reverse (BL -> TR)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .mirrored_reverse);
    }
    {
        // forward, single line (left -> right )
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single line (right -> left)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single column (top -> bottom)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
    {
        // reverse, single column (bottom -> top)
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .reverse);
    }
    {
        // forward, single cell
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);

        try testing.expect(sel.order(&s) == .forward);
    }
}

test "topLeft" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const tl = sel.topLeft(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, tl));
    }
}

test "bottomRight" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 1,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        defer sel.deinit(&s);
        const br = sel.bottomRight(&s);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 3,
            .y = 3,
        } }, s.pages.pointFromPin(.screen, br));
    }
}

test "ordered" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        // forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel));
    }
    {
        // reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            false,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            false,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
    {
        // mirrored_forward
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_reverse).eql(sel_forward));
    }
    {
        // mirrored_reverse
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            true,
        );
        const sel_forward = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );
        const sel_reverse = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
            true,
        );
        try testing.expect(sel.ordered(&s, .forward).eql(sel_forward));
        try testing.expect(sel.ordered(&s, .reverse).eql(sel_reverse));
        try testing.expect(sel.ordered(&s, .mirrored_forward).eql(sel_forward));
    }
}

test "Selection: contains" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }

    // Reverse
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?));
    }

    // Single line
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 8, .y = 1 } }).?,
            false,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 9, .y = 1 } }).?));
    }
}

test "Selection: contains, rectangle" {
    const testing = std.testing;

    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 15, .rows = 15, .max_scrollback_bytes = 0 });
    defer s.deinit();
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); // Center
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); // Left border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); // Right border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); // Top border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); // Bottom border

        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); // Above center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); // Below center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); // Left center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); // Right center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); // Just right of top right
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); // Just left of bottom left
    }

    // Reverse
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 7, .y = 9 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 6 } }).?)); // Center
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 3, .y = 6 } }).?)); // Left border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 7, .y = 6 } }).?)); // Right border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 3 } }).?)); // Top border
        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 9 } }).?)); // Bottom border

        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 2 } }).?)); // Above center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 5, .y = 10 } }).?)); // Below center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 6 } }).?)); // Left center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 6 } }).?)); // Right center
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 8, .y = 3 } }).?)); // Just right of top right
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 9 } }).?)); // Just left of bottom left
    }

    // Single line
    // NOTE: This is the same as normal selection but we just do it for brevity
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 10, .y = 1 } }).?,
            true,
        );

        try testing.expect(sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?));
        try testing.expect(!sel.contains(&s, s.pages.pin(.{ .screen = .{ .x = 12, .y = 1 } }).?));
    }
}

test "Selection: containedRow" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5, .max_scrollback_bytes = 0 });
    defer s.deinit();

    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 5, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            false,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);

        // Start line
        try testing.expectEqual(Selection.init(
            sel.start(),
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 1 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);

        // End line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 3 } }).?,
            sel.end(),
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);

        // Middle line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 0, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = s.pages.cols - 1, .y = 2 } }).?,
            false,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }

    // Rectangle
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 4 } }).?,
        ) == null);

        // Start line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);

        // End line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 3 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 3 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 3 } }).?,
        ).?);

        // Middle line
        try testing.expectEqual(Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 3, .y = 2 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 2 } }).?,
            true,
        ), sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 2 } }).?,
        ).?);
    }

    // Single-line selection
    {
        const sel = Selection.init(
            s.pages.pin(.{ .screen = .{ .x = 2, .y = 1 } }).?,
            s.pages.pin(.{ .screen = .{ .x = 6, .y = 1 } }).?,
            false,
        );

        // Not contained
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 0 } }).?,
        ) == null);
        try testing.expect(sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 2 } }).?,
        ) == null);

        // Contained
        try testing.expectEqual(sel, sel.containedRow(
            &s,
            s.pages.pin(.{ .screen = .{ .x = 1, .y = 1 } }).?,
        ).?);
    }
}

test "Selection: containedRow clamps mixed-width pages" {
    const testing = std.testing;
    var s = try Screen.init(testing.io, testing.allocator, .{
        .cols = 4,
        .rows = 3,
        .max_scrollback_bytes = 0,
    });
    defer s.deinit();

    const first = s.pages.pages.first.?;
    try s.pages.split(.{ .node = first, .y = 2 });
    try s.pages.split(.{ .node = first, .y = 1 });
    const middle = first.next.?;
    const last = middle.next.?;
    middle.page().size.cols = 2;

    const linear = Selection.init(
        .{ .node = first, .x = 1 },
        .{ .node = last, .x = 1 },
        false,
    );
    const linear_row = linear.containedRow(
        &s,
        .{ .node = middle },
    ).?;
    _ = linear_row.end().rowAndCell();
    try testing.expect((Pin{ .node = middle }).eql(linear_row.start()));
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(linear_row.end()));

    const rectangle = Selection.init(
        .{ .node = first, .x = 1 },
        .{ .node = last, .x = 3 },
        true,
    );
    const rectangle_row = rectangle.containedRow(
        &s,
        .{ .node = middle },
    ).?;
    _ = rectangle_row.end().rowAndCell();
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(rectangle_row.start()));
    try testing.expect((Pin{ .node = middle, .x = 1 }).eql(rectangle_row.end()));
}
