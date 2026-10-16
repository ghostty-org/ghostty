//! DECRQCRA (Request Checksum of Rectangular Area) and XTCHECKSUM
//! (select the checksum variant DECRQCRA computes).
//!
//! The checksum follows xterm's `xtermCheckRect`. No real VT420 was
//! available to compare against while this was written, so xterm is the
//! reference:
//!
//! - `xtermCheckRect`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/screen.c#L3162-L3290
//! - `xtermCharSetDec`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/charsets.c#L608
const std = @import("std");
const testing = std.testing;
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const Selection = @import("Selection.zig");
const Terminal = @import("Terminal.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const style = @import("style.zig");

/// The XTCHECKSUM (CSI Ps # y) bits. The zero value is the DEC checksum,
/// which is also what a full reset restores.
///
/// These are xterm's `CSBITS`, which it also takes from the
/// `checksumExtension` resource:
///
/// - `CSBITS`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/ptyx.h#L488-L496
/// - XTCHECKSUM: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/charproc.c#L6044-L6050
/// - Reset to `checksumExtension`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/charproc.c#L14424-L14426
/// - `checksumExtension` docs: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/xterm.man#L2870-L2896
/// - XTCHECKSUM docs: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/ctlseqs.ms#L2562-L2569
///
/// xterm's documentation disagrees with its code in two places, and we
/// follow the code. The docs describe bit 3 as "omit checksum for cells
/// not explicitly initialized", but `csDRAWN` does the opposite: without
/// it those cells are skipped, and with it they count as spaces. The man
/// page also lists a bit 5, "do not mask cell value to 7 bits", which
/// `xtermCheckRect` never looks at.
pub const Flags = packed struct(u5) {
    /// Don't negate the result.
    positive: bool = false,

    /// Don't add the VT100 video attributes to each cell.
    no_attributes: bool = false,

    /// Don't omit blanks. The DEC checksum only counts a plain space if it
    /// is the first cell of the rectangle.
    no_trim: bool = false,

    /// Count cells that were never written to as spaces instead of
    /// skipping them.
    undrawn: bool = false,

    /// Use the full codepoint rather than the DEC 8-bit value. Wide
    /// spacers are skipped and, as in xterm, combining marks are not
    /// counted in this mode.
    full: bool = false,
};

/// A DECRQCRA request as it arrives in `CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y`.
/// The coordinates are 1-based and zero means the parameter was omitted.
/// The page number (Pg) is ignored since we only have one page.
pub const Request = extern struct {
    id: u16 = 0,
    top: u16 = 0,
    left: u16 = 0,
    bottom: u16 = 0,
    right: u16 = 0,

    /// Resolve the request to a rectangle selection of the active area.
    /// If `origin` is set (DECOM), coordinates are relative to its
    /// top-left, as in xterm. Coordinates are clamped to the screen.
    /// Returns null if the rectangle is empty.
    pub fn selection(
        self: Request,
        pages: *const PageList,
        origin: ?Terminal.ScrollingRegion,
    ) ?Selection {
        const rows = pages.rows;
        const cols = pages.cols;
        if (rows == 0 or cols == 0) return null;
        const top_margin: u16 = if (origin) |o| o.top else 0;
        const left_margin: u16 = if (origin) |o| o.left else 0;
        const top = limit(self.top, 1, top_margin, rows);
        const left = limit(self.left, 1, left_margin, cols);
        const bottom = limit(self.bottom, rows, top_margin, rows);
        const right = limit(self.right, cols, left_margin, cols);
        if (top > bottom or left > right) return null;
        return .init(
            pages.pin(.{ .active = .{ .x = left - 1, .y = top - 1 } }) orelse return null,
            pages.pin(.{ .active = .{ .x = right - 1, .y = bottom - 1 } }) orelse return null,
            true,
        );
    }

    fn limit(v: u16, default: u16, margin: u16, max: u16) u16 {
        const n = if (v == 0) default else v;
        return std.math.clamp(n +| margin, 1, max);
    }
};

/// Compute the checksum of a rectangle selection.
pub fn compute(screen: *const Screen, sel_: ?Selection, flags: Flags) u16 {
    // An empty rectangle still gets a reply, with a sum of zero.
    const sel = sel_ orelse return 0;
    const tl = sel.topLeft(screen);
    const br = sel.bottomRight(screen);

    // Everything is summed modulo 2^16 since only 16 bits are reported.
    var sum: u16 = 0;

    // The DEC checksum omits plain spaces except for the very first cell
    // counted in the rectangle.
    var first = true;

    var it = tl.rowIterator(.right_down, br);
    while (it.next()) |row| {
        // Pages may be narrower than the rectangle, as in xterm, where
        // a line may be shorter than the screen.
        const cells = row.cells(.all);
        const left = @min(tl.x, cells.len);
        const right = @min(br.x + 1, cells.len);

        for (cells[left..right]) |*cell| {
            var ch: u16 = switch (value(cell, flags)) {
                .skip => continue,
                .undrawn => if (flags.no_trim or flags.undrawn) ' ' else continue,
                .value => |v| v,
            };

            const s = row.style(cell);
            if (!flags.no_attributes) ch +%= attributes(cell, s);

            if (flags.no_trim) {
                sum +%= ch;

                // xterm adds combining marks only in the DEC mode, and
                // only to the untrimmed sum.
                if (!flags.full and cell.hasGrapheme()) {
                    if (row.grapheme(cell)) |cps| {
                        for (cps) |cp| sum +%= @truncate(cp);
                    }
                }
            } else if (first or ch != ' ' or extended(s)) {
                sum +%= ch;
            }

            first = flags.no_trim;
        }

        if (!flags.no_trim) first = false;
    }

    return if (flags.positive) sum else 0 -% sum;
}

const Value = union(enum) {
    /// Not counted at all.
    skip,

    /// Never written to.
    undrawn,

    /// The value of the character, before attributes.
    value: u16,
};

fn value(cell: *const pagepkg.Cell, flags: Flags) Value {
    // The right half of a wide character. xterm stores a placeholder
    // outside of 8 bits there, so the DEC checksum counts it as ESC.
    if (cell.wide == .spacer_tail) {
        return if (flags.full) .skip else .{ .value = 0x1B };
    }

    if (!cell.hasText()) return .undrawn;

    const cp = cell.codepoint();
    if (flags.full) return .{ .value = @truncate(cp) };

    // The DEC 8-bit value, as xterm's `xtermCharSetDec` produces it for
    // the ASCII character set. xterm works from the byte as it was
    // received, before character set translation, so it counts DEC line
    // drawing as the letter that was sent. We only have the translated
    // codepoint, so those count as characters outside of 8 bits.
    return .{ .value = switch (cp) {
        0x7F, 0xFF => 0,
        0x20...0x7E, 0x80...0x9F, 0xA1...0xFE => @intCast(cp & 0x7F),
        else => 0x1B,
    } };
}

/// The VT100 video attributes xterm adds to each cell.
fn attributes(cell: *const pagepkg.Cell, s: style.Style) u16 {
    var result: u16 = 0;
    if (cell.protected) result += 0x04;
    if (s.flags.invisible) result += 0x08;
    if (s.flags.underline != .none) result += 0x10;
    if (s.flags.inverse) result += 0x20;
    if (s.flags.blink) result += 0x40;
    if (s.flags.bold) result += 0x80;
    return result;
}

/// Attributes that xterm doesn't add to the sum but that still keep a
/// space from being trimmed.
fn extended(s: style.Style) bool {
    return s.flags.faint or
        s.flags.italic or
        s.flags.strikethrough or
        s.flags.underline == .double;
}

/// The largest reply `encode` writes.
pub const max_encode_size = "\x1bP65535!~FFFF\x1b\\".len;

/// Encode the DECRQCRA reply, `DCS Pi ! ~ XXXX ST`.
pub fn encode(
    writer: *std.Io.Writer,
    id: u16,
    sum: u16,
) std.Io.Writer.Error!void {
    try writer.print("\x1bP{d}!~{X:0>4}\x1b\\", .{ id, sum });
}

test "xt_checksum: encode" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, 65535, 0xFFFF);
    try testing.expectEqualStrings("\x1bP65535!~FFFF\x1b\\", writer.buffered());

    writer = .fixed(&buf);
    try encode(&writer, 1, 0x1A);
    try testing.expectEqualStrings("\x1bP1!~001A\x1b\\", writer.buffered());
}

test "xt_checksum: selection defaults and clamping" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const pages = &t.screens.active.pages;

    {
        const sel = (Request{}).selection(pages, null).?;
        try testing.expect(sel.rectangle);
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 0, .y = 0 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }

    {
        const req: Request = .{ .top = 2, .left = 3, .bottom = 99, .right = 99 };
        const sel = req.selection(pages, null).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }

    try testing.expectEqual(
        null,
        (Request{ .top = 3, .bottom = 2 }).selection(pages, null),
    );
    try testing.expectEqual(
        null,
        (Request{ .left = 3, .right = 2 }).selection(pages, null),
    );
}

test "xt_checksum: selection origin mode" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const pages = &t.screens.active.pages;
    const region: Terminal.ScrollingRegion = .{
        .top = 1,
        .bottom = 3,
        .left = 2,
        .right = 8,
    };

    {
        const sel = (Request{}).selection(pages, region).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 9, .y = 4 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }

    {
        const req: Request = .{ .top = 1, .left = 1, .bottom = 1, .right = 1 };
        const sel = req.selection(pages, region).?;
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.start()).?,
        );
        try testing.expectEqual(
            point.Point{ .active = .{ .x = 2, .y = 1 } },
            pages.pointFromPin(.active, sel.end()).?,
        );
    }
}

test "xt_checksum: DEC trims blanks and skips undrawn cells" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("a b");

    // Only the first row, the whole width. The space is omitted and the
    // unwritten cells are skipped.
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(0 -% @as(u16, 'a' + 'b'), compute(s, sel, .{}));
    try testing.expectEqual(@as(u16, 'a' + 'b'), compute(s, sel, .{ .positive = true }));

    // Untrimmed counts the space and the undrawn cells as spaces.
    try testing.expectEqual(
        @as(u16, 'a' + 'b' + ' ' * 8),
        compute(s, sel, .{ .positive = true, .no_trim = true }),
    );

    // Undrawn cells are spaces, which are then trimmed.
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        compute(s, sel, .{ .positive = true, .undrawn = true }),
    );
}

test "xt_checksum: DEC counts a leading space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString(" a\n b");

    // The very first counted cell is kept even if it's a space, but not
    // the first cell of later rows.
    const req: Request = .{};
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, ' ' + 'a' + 'b'),
        compute(s, sel, .{ .positive = true }),
    );
}

test "xt_checksum: empty rectangle" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("abc");
    const req: Request = .{ .left = 3, .right = 2 };
    try testing.expectEqual(0, compute(s, req.selection(&s.pages, null), .{}));
}

test "xt_checksum: rectangle bounds" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("abc\ndef\nghi");
    const req: Request = .{ .top = 2, .left = 2, .bottom = 3, .right = 3 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'e' + 'f' + 'h' + 'i'),
        compute(s, sel, .{ .positive = true }),
    );
}

test "xt_checksum: attributes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.setAttribute(.bold);
    try t.setAttribute(.{ .underline = .single });
    try t.printString("a");
    try t.setAttribute(.unset);
    try t.setAttribute(.inverse);
    try t.setAttribute(.blink);
    try t.printString(" ");
    try t.setAttribute(.unset);
    try t.setAttribute(.invisible);
    t.setProtectedMode(.dec);
    try t.printString("b");

    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'a' + 0x80 + 0x10 + ' ' + 0x20 + 0x40 + 'b' + 0x08 + 0x04),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        compute(s, sel, .{ .positive = true, .no_attributes = true }),
    );
}

test "xt_checksum: extended attributes keep a space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("a");
    try t.setAttribute(.italic);
    try t.printString(" ");

    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'a' + ' '),
        compute(s, sel, .{ .positive = true }),
    );
}

test "xt_checksum: DEC 8-bit values" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;

    // é is 0xE9, masked to 7 bits; the euro sign is outside of 8 bits.
    try t.printString("é€");
    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 0x69 + 0x1B),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0xE9 + 0x20AC),
        compute(s, sel, .{ .positive = true, .full = true }),
    );
}

test "xt_checksum: wide characters" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    try t.printString("橋");

    const req: Request = .{ .top = 1, .bottom = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 0x1B + 0x1B),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0x6A4B),
        compute(s, sel, .{ .positive = true, .full = true }),
    );
}

test "xt_checksum: combining marks" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    const s = t.screens.active;
    t.modes.set(.grapheme_cluster, true);
    try t.printString("e\u{301}");

    const req: Request = .{ .top = 1, .bottom = 1, .right = 1 };
    const sel = req.selection(&s.pages, null);
    try testing.expectEqual(
        @as(u16, 'e'),
        compute(s, sel, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e' + 0x301),
        compute(s, sel, .{ .positive = true, .no_trim = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e'),
        compute(s, sel, .{ .positive = true, .no_trim = true, .full = true }),
    );
}
