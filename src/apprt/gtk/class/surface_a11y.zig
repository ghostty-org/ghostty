//! Accessibility support for the Surface class: the GtkAccessibleText
//! implementation and its state, embedded in the Surface's private data.
//!
//! Every offset crossing this boundary is a UTF-8 codepoint index, never
//! a byte index, per the AT-SPI Text contract. `a11y.offsets` owns that
//! arithmetic; the viewport walk lives in `a11y.text`.
const A11y = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

const a11y = @import("../../../a11y/main.zig");
const global = @import("../../../global.zig");
const terminal = @import("../../../terminal/main.zig");
const gtk_version = @import("../gtk_version.zig");
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_surface_a11y);

/// Viewport text served to AT reads. Served until a rendered frame
/// marks it stale, so offsets stay consistent across a multi-call read.
cached_text: ?[:0]const u8 = null,

/// Columns occupied by each codepoint of `cached_text`, filled by the
/// same walk that builds it. Read through `cellWidths`.
cached_widths: std.ArrayList(u8) = .empty,

/// Caret offset in codepoints within `cached_text`.
cached_cursor_offset: c_uint = 0,

/// Latched on the first AT query, never cleared: GTK has no "the last
/// AT client went away" signal. Gates the per-frame change probe.
active: bool = false,

/// Viewport text at the last change notification. Change events are
/// diffed against this so clients see minimal insert/remove ranges
/// rather than a whole-viewport replacement on every keystroke.
last_snapshot: ?[:0]const u8 = null,

/// Caret offset at the last caret notification.
last_notified_caret: c_uint = 0,

/// Set on every rendered frame; cleared when the cache is confirmed
/// to still match the viewport.
cache_stale: bool = false,

/// Retained scratch for `probeChanged` so the per-frame probe does
/// not allocate once it has grown to viewport size.
probe_buf: std.ArrayList(u8) = .empty,

pub fn deinit(self: *A11y, alloc: Allocator) void {
    self.probe_buf.deinit(alloc);
    self.cached_widths.deinit(alloc);
    if (self.cached_text) |v| alloc.free(v);
    if (self.last_snapshot) |v| alloc.free(v);
    self.* = .{};
}

/// Called by the surface after every rendered frame: mark the cache
/// stale and, if an AT client has ever queried us, emit change events.
///
/// Narrower gates than `active` are wrong: focus would silence
/// unfocused splits, and `org.a11y.Status.IsEnabled` is a hint ATs
/// write, not proof one is listening. The latch costs one probe per
/// rendered frame (6.7us at 30x80, 17.6us at 60x200, per
/// `ghostty-bench +a11y-text --mode=probe`); idle surfaces pay nothing.
pub fn frameRendered(self: *A11y, surface: *Surface) void {
    self.cache_stale = true;
    if (self.active) self.notifyIfChanged(surface);
}

//---------------------------------------------------------------
// GtkAccessible interface override

pub fn initAccessibleInterface(iface: *gtk.AccessibleInterface) callconv(.c) void {
    iface.f_get_first_accessible_child = &getFirstAccessibleChild;
}

/// Return no accessible children: GTK's default walks the widget tree
/// and exposes the GLArea and every template descendant to AT-SPI. The
/// surface presents as a single text-bearing object instead.
fn getFirstAccessibleChild(
    _: *gtk.Accessible,
) callconv(.c) ?*gtk.Accessible {
    return null;
}

//---------------------------------------------------------------
// GtkAccessibleText interface implementation

/// Install the parts of GtkAccessibleText this surface implements.
/// Slots left alone keep GTK's `default_init` implementations, which
/// decline gracefully (no selection, no attributes).
pub fn initAccessibleTextInterface(iface: *gtk.AccessibleTextInterface) callconv(.c) void {
    // Present since 4.14, which is the oldest GTK we run against.
    iface.f_get_contents = &getContents;
    iface.f_get_contents_at = &getContentsAt;
    iface.f_get_caret_position = &getCaretPosition;

    // `get_extents` and `get_offset` are 4.16 additions.
    // While they are accessible with current bindings, we need to make sure
    // we do not access invalid memory when running with older GTK versions
    // by writing to fields that don't yet exist.
    if (gtk_version.runtimeAtLeast(4, 16, 0)) {
        iface.f_get_extents = &getExtents;
        iface.f_get_offset = &getOffset;
    }
}

/// Return the extents of a text range, in widget coordinates (see
/// `deviceScale`). Orca's flat review groups text into lines by Y
/// coordinate, so each viewport row needs a distinct rect:
/// Y = row * cell_height.
fn getExtents(
    accessible: *gtk.AccessibleText,
    start: c_uint,
    end: c_uint,
    extents: *graphene.Rect,
) callconv(.c) c_int {
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    const core_surface = surface.core() orelse return 0;

    const text = self.refreshCache(surface) orelse return 0;

    const cell_w: f32 = @floatFromInt(core_surface.size.cell.width);
    const cell_h: f32 = @floatFromInt(core_surface.size.cell.height);
    if (cell_w <= 0 or cell_h <= 0) return 0;

    const rect = a11y.offsets.extentsCells(text, self.cellWidths(), start, end);
    const scale = deviceScale(surface);

    // Cell (0,0) is not at widget-local (0,0): the renderer leaves a
    // padding gutter that has to be added back here.
    const pad_left: f32 = @floatFromInt(core_surface.size.padding.left);
    const pad_top: f32 = @floatFromInt(core_surface.size.padding.top);

    extents.f_origin.f_x =
        (pad_left + @as(f32, @floatFromInt(rect.col)) * cell_w) / scale;
    extents.f_origin.f_y =
        (pad_top + @as(f32, @floatFromInt(rect.row)) * cell_h) / scale;
    extents.f_size.f_width =
        @as(f32, @floatFromInt(rect.width_cols)) * cell_w / scale;
    extents.f_size.f_height = cell_h / scale;
    return 1;
}

/// Device pixels per widget pixel: `core_surface.size` is in device
/// pixels, GTK accessibility coordinates are widget space. Not
/// `getContentScale`, which folds in the gtk-xft-dpi font scale.
fn deviceScale(surface: *Surface) f32 {
    const scale = surface.as(gtk.Widget).getScaleFactor();
    if (scale <= 0) return 1.0;
    return @floatFromInt(scale);
}

/// Map a widget-space point to a codepoint offset within the cached
/// text. Inverse of `getExtents`. Out-of-range points clamp, so the
/// AT client always gets an in-range offset when we return TRUE.
fn getOffset(
    accessible: *gtk.AccessibleText,
    point: *const graphene.Point,
    out_offset: *c_uint,
) callconv(.c) c_int {
    const surface = gobject.ext.cast(Surface, accessible) orelse {
        out_offset.* = 0;
        return 0;
    };
    const self = surface.a11y();
    const core_surface = surface.core() orelse {
        out_offset.* = 0;
        return 0;
    };

    const text = self.refreshCache(surface) orelse {
        out_offset.* = 0;
        return 0;
    };

    const cell_w: f32 = @floatFromInt(core_surface.size.cell.width);
    const cell_h: f32 = @floatFromInt(core_surface.size.cell.height);
    if (cell_w <= 0 or cell_h <= 0) {
        out_offset.* = 0;
        return 0;
    }

    // Exact inverse of `getExtents`: back into device pixels, then out
    // of the renderer's gutter. `pointToGrid` clamps negatives to cell
    // (0,0), so a point inside the padding lands on the first cell.
    const scale = deviceScale(surface);
    const pad_left: f32 = @floatFromInt(core_surface.size.padding.left);
    const pad_top: f32 = @floatFromInt(core_surface.size.padding.top);
    const grid = a11y.offsets.pointToGrid(
        point.f_x * scale - pad_left,
        point.f_y * scale - pad_top,
        cell_w,
        cell_h,
    );
    out_offset.* = @intCast(a11y.offsets.offsetAtGrid(
        text,
        self.cellWidths(),
        grid.row,
        grid.col,
    ));
    return 1;
}

/// Cell widths for the current `cached_text`, for converting between
/// codepoint offsets and grid positions. Only meaningful after
/// `refreshCache` has returned text; empty reads as one column per
/// codepoint.
fn cellWidths(self: *A11y) a11y.offsets.CellWidths {
    return .{ .per_cp = self.cached_widths.items };
}

/// Return the cached viewport text, rebuilding it first if a rendered
/// frame marked it stale. Deliberately not a TTL: that could refresh
/// mid-read, shifting offsets under the client. The text is one visual
/// row per `\n`-delimited line, including blank rows, so every row has
/// a range flat review can point at.
fn refreshCache(self: *A11y, surface: *Surface) ?[:0]const u8 {
    // Mark that an AT client is actively querying us.
    self.active = true;

    // A frame rendered since this cache was built and nothing has
    // since confirmed it still matches, so drop it. On a focused
    // surface `notifyIfChanged` normally clears the mark first; this
    // path keeps an unfocused surface's on-demand reads fresh.
    const alloc = Application.default().allocator();
    if (self.cache_stale) {
        if (self.cached_text) |old| {
            alloc.free(old);
            self.cached_text = null;
        }
        self.cache_stale = false;
    }

    if (self.cached_text != null) return self.cached_text;

    const core_surface = surface.core() orelse return null;

    // Widths are rebuilt in lockstep with the text below; `build` only
    // appends, so the retained list must start empty to stay aligned
    // with the fresh text. The writer takes over the list's memory and
    // the defer hands it back on every exit path.
    self.cached_widths.clearRetainingCapacity();
    var widths: std.Io.Writer.Allocating = .fromArrayList(alloc, &self.cached_widths);
    defer self.cached_widths = widths.toArrayList();

    var buffer: std.Io.Writer.Allocating = .init(alloc);
    defer buffer.deinit();

    // The renderer mutex covers only the walk; everything after this
    // point reads `buffer`, which is our own memory.
    const result = result: {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen: *terminal.Screen =
            core_surface.renderer_state.terminal.screens.active;

        break :result a11y.text.build(
            &buffer.writer,
            screen,
            .{ .widths = &widths.writer },
        ) catch |err| {
            log.warn("ax text build failed: {}", .{err});
            return null;
        };
    };

    const text = alloc.dupeZ(u8, buffer.written()) catch return null;
    self.cached_text = text;

    // AT-SPI wants the caret in codepoints; the walk reports a byte
    // position. A cursor row outside the viewport has no byte offset
    // and anchors at end-of-text.
    const cursor_byte = @min(result.cursor_byte orelse text.len, text.len);
    self.cached_cursor_offset = @intCast(utf8CpCount(text[0..cursor_byte]));

    return self.cached_text;
}

/// Cheap per-frame check for "could anything an AT client cares about
/// have changed?": build only the text into the retained scratch
/// buffer and compare it and the caret against the last notification.
/// Conservative: may answer true on a frame the full path then finds
/// nothing to emit for, never false when something moved.
fn probeChanged(self: *A11y, surface: *Surface) bool {
    const core_surface = surface.core() orelse return false;

    // No snapshot yet means we have never notified; take the full
    // path so the first frame establishes one.
    const old_text: []const u8 = self.last_snapshot orelse return true;

    const alloc = Application.default().allocator();

    // The writer takes over the retained scratch buffer's memory and
    // the defer hands it back on every exit path, so the capacity it
    // grew survives for the next frame's probe.
    self.probe_buf.clearRetainingCapacity();
    var probe: std.Io.Writer.Allocating = .fromArrayList(alloc, &self.probe_buf);
    defer self.probe_buf = probe.toArrayList();

    const result = result: {
        core_surface.renderer_state.mutex.lockUncancelable(global.io());
        defer core_surface.renderer_state.mutex.unlock(global.io());

        const screen: *terminal.Screen =
            core_surface.renderer_state.terminal.screens.active;

        break :result a11y.text.build(
            &probe.writer,
            screen,
            .{},
        ) catch |err| {
            // Probing failed; fall back to the full path rather than
            // risk swallowing a change.
            log.warn("ax probe build failed: {}", .{err});
            return true;
        };
    };

    const text = probe.written();
    if (!std.mem.eql(u8, old_text, text)) return true;

    // Text is identical, so the caret's byte offset converts against
    // the same bytes the cache was built from.
    const cursor_byte = @min(result.cursor_byte orelse text.len, text.len);
    const caret_cp: c_uint = @intCast(utf8CpCount(text[0..cursor_byte]));
    return caret_cp != self.last_notified_caret;
}

/// Emit AT-SPI change events if the viewport text or caret moved since
/// the last notification. We diff against the last notified snapshot
/// and emit the smallest remove/insert pair: firing unconditionally
/// would make an AT client restart reading on every rendered frame,
/// and Orca's terminal script classifies events by `any_data` length,
/// so a one-character insert reads as typing echo, not command output.
fn notifyIfChanged(self: *A11y, surface: *Surface) void {
    const alloc = Application.default().allocator();

    // On an unchanged frame the cache still describes the viewport:
    // retract this frame's staleness mark rather than making the next
    // AT read pay for a rebuild.
    if (!self.probeChanged(surface)) {
        self.cache_stale = false;
        return;
    }

    // Drop the cache so `refreshCache` rebuilds from the live
    // viewport; the cache is the sole source of truth for AT reads.
    if (self.cached_text) |old| {
        alloc.free(old);
        self.cached_text = null;
    }
    const new_text = self.refreshCache(surface) orelse return;
    const old_text: []const u8 = self.last_snapshot orelse "";

    const text_changed = !std.mem.eql(u8, old_text, new_text);
    const caret_changed = self.cached_cursor_offset != self.last_notified_caret;

    // First notification against an empty viewport: `text_changed` is
    // false because both sides are "", but the probe keys off having a
    // snapshot at all. Record one here or every later frame takes the
    // full rebuild path.
    if (self.last_snapshot == null and !text_changed) {
        self.last_snapshot = alloc.dupeZ(u8, new_text) catch null;
    }

    if (!text_changed and !caret_changed) return;

    if (text_changed) {
        self.emitTextDiff(surface, old_text, new_text);

        // Keep our own copy rather than aliasing `cached_text`: the
        // cache is freed and rewritten on every refresh.
        if (self.last_snapshot) |prev| alloc.free(prev);
        self.last_snapshot = alloc.dupeZ(u8, new_text) catch null;
    }
    if (caret_changed) {
        self.last_notified_caret = self.cached_cursor_offset;
        gtk.AccessibleText.updateCaretPosition(surface.as(gtk.AccessibleText));
    }
}

/// Cache state displaced by `aliasOldSnapshot`.
const AliasedCache = struct {
    text: ?[:0]const u8,
    cursor: c_uint,
    widths: std.ArrayList(u8),
};

/// Point the cache at the pre-change snapshot for the duration of a
/// `.remove` emit: GTK's bridge fills `any_data` by calling back into
/// `getContents` synchronously, and for a remove the client expects
/// the *deleted* substring, which the cache no longer holds. The
/// displaced widths go empty (one column per codepoint); nothing
/// inside the emit can rebuild the cache behind our back.
fn aliasOldSnapshot(self: *A11y) AliasedCache {
    const saved: AliasedCache = .{
        .text = self.cached_text,
        .cursor = self.cached_cursor_offset,
        .widths = self.cached_widths,
    };
    self.cached_text = self.last_snapshot;
    self.cached_cursor_offset = self.last_notified_caret;
    self.cached_widths = .empty;
    return saved;
}

fn restoreCache(self: *A11y, saved: AliasedCache) void {
    self.cached_text = saved.text;
    self.cached_cursor_offset = saved.cursor;
    self.cached_widths = saved.widths;
}

/// Prefix/suffix diff: bytes `[0..p)` and `[len-s..)` are unchanged,
/// the rest was replaced, with both cuts on codepoint boundaries.
const PrefixSuffixDiff = a11y.offsets.PrefixSuffixDiff;

/// Fire the AT-SPI events for the change from `old_text` to
/// `new_text`. `chooseDiff` owns the shape choice (pure arithmetic,
/// unit-tested). A line shift is a `.remove` at one end plus an
/// `.insert` at the other, matching what VTE exposes to Orca; a
/// whole-viewport replacement would be re-read in full on every scroll.
fn emitTextDiff(self: *A11y, surface: *Surface, old_text: []const u8, new_text: []const u8) void {
    switch (a11y.offsets.chooseDiff(old_text, new_text)) {
        .none => {},
        .shift_up => |k| self.emitShiftUp(surface, old_text, new_text, k),
        .shift_down => |j| self.emitShiftDown(surface, old_text, new_text, j),
        .replace => |ps| self.emitPrefixSuffix(surface, old_text, new_text, ps),
    }
}

/// Emit `.remove(0, K_cp)` + `.insert(tail_cp, |new|_cp)` for an
/// upward line shift. `scroll_k` is > 0 and lands on a `\n` boundary
/// of `old` (guaranteed by `chooseDiff`).
fn emitShiftUp(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    scroll_k: usize,
) void {
    const accessible = surface.as(gtk.AccessibleText);

    const removed_cp: c_uint = @intCast(utf8CpCount(old_text[0..scroll_k]));
    const tail_cp: c_uint = @intCast(utf8CpCount(old_text[scroll_k..]));
    const new_end_cp: c_uint = @intCast(utf8CpCount(new_text));

    // The bridge reads the deleted range back out of us synchronously,
    // so the cache must point at the pre-remove text for the call.
    {
        const saved = self.aliasOldSnapshot();
        defer self.restoreCache(saved);
        gtk.AccessibleText.updateContents(accessible, .remove, 0, removed_cp);
    }

    if (new_end_cp > tail_cp) {
        gtk.AccessibleText.updateContents(accessible, .insert, tail_cp, new_end_cp);
    }
}

/// Emit `.remove(kept_cp, |old|_cp)` + `.insert(0, J_cp)` for a
/// downward line shift (scrolling back through output). Remove first:
/// after it the exposed text is exactly `new[scroll_j..]`, so the
/// insert offset needs no adjustment.
fn emitShiftDown(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    scroll_j: usize,
) void {
    const accessible = surface.as(gtk.AccessibleText);

    // Bytes of `old` that survive the shift. `chooseDiff` guarantees
    // `old_text[0..kept] == new_text[scroll_j..]`.
    const kept = new_text.len - scroll_j;
    const kept_cp: c_uint = @intCast(utf8CpCount(old_text[0..kept]));
    const old_end_cp: c_uint = @intCast(utf8CpCount(old_text));
    const inserted_cp: c_uint = @intCast(utf8CpCount(new_text[0..scroll_j]));

    if (old_end_cp > kept_cp) {
        const saved = self.aliasOldSnapshot();
        defer self.restoreCache(saved);
        gtk.AccessibleText.updateContents(accessible, .remove, kept_cp, old_end_cp);
    }

    gtk.AccessibleText.updateContents(accessible, .insert, 0, inserted_cp);
}

/// Emit a single remove+insert pair covering the region between the
/// common prefix and common suffix of `old` and `new`.
fn emitPrefixSuffix(
    self: *A11y,
    surface: *Surface,
    old_text: []const u8,
    new_text: []const u8,
    diff: PrefixSuffixDiff,
) void {
    const p = diff.prefix_len;
    const s = diff.suffix_len;
    const removed_len = old_text.len - p - s;
    const inserted_len = new_text.len - p - s;

    const accessible = surface.as(gtk.AccessibleText);
    const start_cp: c_uint = @intCast(utf8CpCount(old_text[0..p]));
    if (removed_len != 0) {
        const saved = self.aliasOldSnapshot();
        defer self.restoreCache(saved);
        const end_cp: c_uint = @intCast(utf8CpCount(old_text[0..(old_text.len - s)]));
        gtk.AccessibleText.updateContents(accessible, .remove, start_cp, end_cp);
    }
    if (inserted_len != 0) {
        const end_cp: c_uint = @intCast(utf8CpCount(new_text[0..(new_text.len - s)]));
        gtk.AccessibleText.updateContents(accessible, .insert, start_cp, end_cp);
    }
}

fn getContents(
    accessible: *gtk.AccessibleText,
    start: c_uint,
    end: c_uint,
) callconv(.c) *glib.Bytes {
    const surface = gobject.ext.cast(Surface, accessible) orelse return emptyBytes();
    const self = surface.a11y();
    const text = self.refreshCache(surface) orelse return emptyBytes();

    // `start`/`end` are codepoint indices per the AT-SPI Text
    // contract; convert to byte offsets before slicing so the result
    // is valid UTF-8.
    const byte_start = utf8CpToByte(text, @intCast(start));
    const byte_end = utf8CpToByte(text, @intCast(end));
    if (byte_start >= byte_end) return emptyBytes();

    return bytesNulTerm(text[byte_start..byte_end]);
}

/// A NUL-terminated empty `GBytes`. A string literal points at static
/// storage; `&[_:0]u8{}` looks equivalent but is only valid for the
/// enclosing scope and can dangle by the time `g_bytes_new` copies it.
fn emptyBytes() *glib.Bytes {
    return glib.Bytes.new("", 1);
}

/// Wrap `slice` in a freshly-allocated, NUL-terminated `GBytes`.
/// GTK's bridge hands the payload to `g_variant_new_string`, which
/// needs NUL termination (despite the `get_contents` docs) or it reads
/// past the allocation, and returns NULL on invalid UTF-8, crashing the
/// AT-SPI bridge — so broken input becomes an empty result instead.
fn bytesNulTerm(slice: []const u8) *glib.Bytes {
    if (!std.unicode.utf8ValidateSlice(slice)) {
        log.warn("accessibility text is not valid UTF-8, ignoring", .{});
        return emptyBytes();
    }

    const alloc = Application.default().allocator();
    const buf = alloc.dupeSentinel(u8, slice, 0) catch return emptyBytes();
    defer alloc.free(buf);
    // g_bytes_new copies, so `buf` can be freed when this returns.
    return glib.Bytes.new(buf.ptr, slice.len + 1);
}

// UTF-8 codepoint offset helpers; `a11y.offsets` owns the arithmetic
// and the tests that pin it down.
const utf8CpCount = a11y.offsets.utf8CpCount;
const utf8CpToByte = a11y.offsets.utf8CpToByte;

fn getContentsAt(
    accessible: *gtk.AccessibleText,
    offset: c_uint,
    granularity: gtk.AccessibleTextGranularity,
    out_start: *c_uint,
    out_end: *c_uint,
) callconv(.c) *glib.Bytes {
    const surface = gobject.ext.cast(Surface, accessible) orelse {
        out_start.* = 0;
        out_end.* = 0;
        return emptyBytes();
    };
    const self = surface.a11y();
    const text = self.refreshCache(surface) orelse {
        out_start.* = 0;
        out_end.* = 0;
        return emptyBytes();
    };

    // A terminal has no sentences or paragraphs distinct from its
    // visual rows, so both fold into `.line`. Unknown values (the
    // non-exhaustive `_`) get an empty range at the requested offset.
    const g: a11y.offsets.Granularity = switch (granularity) {
        .character => .character,
        .word => .word,
        .line, .paragraph, .sentence => .line,
        _ => {
            const text_cp_count: c_uint = @intCast(utf8CpCount(text));
            const off_cp = @min(offset, text_cp_count);
            out_start.* = off_cp;
            out_end.* = off_cp;
            return emptyBytes();
        },
    };

    const contents = a11y.offsets.contentsAt(text, offset, g);
    out_start.* = @intCast(contents.start_cp);
    out_end.* = @intCast(contents.end_cp);
    if (contents.bytes.len == 0) return emptyBytes();
    return bytesNulTerm(contents.bytes);
}

fn getCaretPosition(
    accessible: *gtk.AccessibleText,
) callconv(.c) c_uint {
    const surface = gobject.ext.cast(Surface, accessible) orelse return 0;
    const self = surface.a11y();
    _ = self.refreshCache(surface);
    return self.cached_cursor_offset;
}
