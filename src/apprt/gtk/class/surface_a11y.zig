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
const unicode = @import("../../../unicode/main.zig");
const scale_util = @import("../scale.zig");
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const CoreSurface = @import("../../../Surface.zig");

const log = std.log.scoped(.gtk_ghostty_surface_a11y);

/// The viewport snapshot AT reads are served from: text, cell widths
/// and caret. It is always exactly what clients have read or been told
/// about through change events, which makes it the baseline the next
/// change is diffed against. Between frames it does not move, so
/// offsets stay consistent across a multi-call read.
cache: a11y.text.Snapshot = .{},

/// Whether `cache` holds a snapshot. False until the first AT read.
cached: bool = false,

/// The next snapshot is built here and swapped into `cache` when it
/// differs, so neither allocates once grown to viewport size.
scratch: a11y.text.Snapshot = .{},

/// Latched on the first AT query, never cleared: GTK has no "the last
/// AT client went away" signal. Gates the per-frame change check.
active: bool = false,

/// Set when a frame could not be checked against the cache, so the
/// next read rebuilds it rather than trusting it.
cache_stale: bool = false,

/// The pending idle source that checks the last painted frame, if any.
check_source: ?c_uint = null,

/// True while change events are being emitted, during which GTK reads
/// the removed text back out of the cache.
emitting: bool = false,

/// When the renderer pushed the oldest frame GTK has not painted yet,
/// in `glib.getMonotonicTime` microseconds, or null if it painted them
/// all.
unpainted_since: ?i64 = null,

/// How long a pushed frame may wait for GTK to paint it before the
/// surface counts as not painted. GTK paints a frame within a display
/// refresh or two; a quarter of a second is far past any of that.
const unpainted_after_us = 250 * std.time.us_per_ms;

/// Must run before the surface is freed: the pending check holds a
/// plain pointer to it.
pub fn deinit(self: *A11y, alloc: Allocator) void {
    if (self.check_source) |id| {
        if (glib.Source.remove(id) == 0) {
            log.warn("unable to remove the a11y check source", .{});
        }
    }
    self.cache.deinit(alloc);
    self.scratch.deinit(alloc);
    self.* = .{};
}

/// Called by the surface after every rendered frame, from inside GTK's
/// paint: if an AT client has ever queried us, schedule a check of the
/// viewport against the cache, which emits change events for the
/// difference. The check runs from an idle callback right after the
/// paint, not inside it, and frames painted before it runs share it.
///
/// Narrower gates than `active` are wrong: focus would silence
/// unfocused splits, and `org.a11y.Status.IsEnabled` is a hint ATs
/// write, not proof one is listening. The latch costs one snapshot per
/// rendered frame (6.2us at 30x80, 16.8us at 60x200, per
/// `ghostty-bench +a11y-text --mode=text`); idle surfaces pay nothing.
pub fn frameRendered(self: *A11y, surface: *Surface) void {
    self.unpainted_since = null;
    if (!self.active or self.check_source != null) return;

    // Default priority, the same as the D-Bus traffic the events go
    // out with, so a busy bus cannot hold the check back the way it
    // would hold back a default-idle source.
    self.check_source = glib.idleAddFull(
        glib.PRIORITY_DEFAULT,
        checkFrame,
        surface,
        null,
    );
}

/// Called by the surface when the renderer pushes a new frame, on the
/// main thread. A window can stop being painted without GTK unmapping
/// anything or reporting it suspended (an X11 window unmapped by its
/// window manager, or covered on a compositor that does not say so);
/// the frames it is pushed and never paints are how that shows.
pub fn framePushed(self: *A11y) void {
    if (self.unpainted_since == null) self.unpainted_since = glib.getMonotonicTime();
}

/// Whether frames reach the screen, so the cache gets checked against
/// every change: GTK paints the surface and has not left a pushed frame
/// unpainted for long.
fn painted(self: *const A11y, surface: *Surface) bool {
    if (!surface.isPainted()) return false;
    const since = self.unpainted_since orelse return true;
    return glib.getMonotonicTime() - since < unpainted_after_us;
}

fn checkFrame(ud: ?*anyopaque) callconv(.c) c_int {
    const surface: *Surface = @ptrCast(@alignCast(ud orelse return 0));
    const self = surface.a11y();
    self.check_source = null;
    self.notifyIfChanged(surface);
    return 0;
}

//---------------------------------------------------------------
// GtkAccessibleText interface implementation

/// Install the parts of GtkAccessibleText this surface implements.
/// Slots left alone keep GTK's `default_init` implementations, which
/// decline gracefully (no selection, no attributes).
pub fn initAccessibleTextInterface(iface: *gtk.AccessibleTextInterface) callconv(.c) void {
    // All of these exist in GTK 4.18, the oldest Ghostty runs against.
    iface.f_get_contents = &getContents;
    iface.f_get_contents_at = &getContentsAt;
    iface.f_get_caret_position = &getCaretPosition;
    iface.f_get_extents = &getExtents;
    iface.f_get_offset = &getOffset;
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
/// pixels, GTK accessibility coordinates are widget space. This is the
/// same (possibly fractional) surface scale the render surface sizes
/// itself with; the integer `getScaleFactor` rounds 1.25 up to 2. Not
/// `getContentScale`, which folds in the gtk-xft-dpi font scale.
fn deviceScale(surface: *Surface) f32 {
    return @floatCast(scale_util.widgetSurfaceScale(surface.as(gtk.Widget)));
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

/// Cell widths for the cached text, for converting between codepoint
/// offsets and grid positions. Only meaningful after `refreshCache` has
/// returned text.
fn cellWidths(self: *A11y) a11y.offsets.CellWidths {
    return self.cache.cellWidths();
}

/// The caret of the cached text, in codepoints.
fn caret(self: *A11y) c_uint {
    return @intCast(self.cache.caret);
}

/// Return the cached viewport text, building it first if there is none
/// yet. Deliberately not a TTL: that could refresh mid-read, shifting
/// offsets under the client. The text is one visual row per
/// `\n`-delimited line, including blank rows, so every row has a range
/// flat review can point at.
fn refreshCache(self: *A11y, surface: *Surface) ?[]const u8 {
    // Mark that an AT client is actively querying us.
    self.active = true;

    // Mid-emit, GTK reads the old text back out of the cache; it must
    // not move under it.
    if (self.emitting) return self.cache.text.items;

    // The first snapshot a client reads is the baseline change events
    // are diffed against. A stale one is rebuilt the same way: no frame
    // could check it, so the client gets what is on screen now. So is
    // the cache of a surface GTK does not paint: no frames means no
    // checks, so it would keep whatever the screen held when the
    // surface was hidden, while the terminal behind it moves on. Such a
    // surface pays a build per read; nothing is announced for it, the
    // client reads the change itself.
    if (!self.cached or self.cache_stale or
        (self.check_source == null and !self.painted(surface)))
    {
        const core_surface = surface.core() orelse return null;
        self.cached = buildSnapshot(core_surface, &self.cache);
        self.cache_stale = false;
        if (!self.cached) return null;
    }

    return self.cache.text.items;
}

/// Build the viewport snapshot of `core_surface` into `snap` under the
/// renderer mutex. False if it could not be built.
fn buildSnapshot(
    core_surface: *CoreSurface,
    snap: *a11y.text.Snapshot,
) bool {
    const alloc = Application.default().allocator();

    core_surface.renderer_state.mutex.lockUncancelable(global.io());
    defer core_surface.renderer_state.mutex.unlock(global.io());

    const screen: *terminal.Screen =
        core_surface.renderer_state.terminal.screens.active;

    a11y.text.build(alloc, snap, screen) catch |err| {
        log.warn("ax text build failed: {}", .{err});
        return false;
    };
    return true;
}

/// Build a snapshot of the viewport and, if the text or caret differ
/// from the cache, make it the cache and emit AT-SPI events for the
/// difference. The diff is the smallest remove/insert pair: firing
/// unconditionally would make an AT client restart reading on every
/// rendered frame, and Orca's terminal script classifies events by
/// `any_data` length, so a one-character insert reads as typing echo,
/// not command output.
///
/// One build per frame serves both the check and the cache, and since
/// the cache only ever changes here or on a client's own read, it is
/// always what the client last saw.
fn notifyIfChanged(self: *A11y, surface: *Surface) void {
    // Nothing read yet: the first read takes the baseline.
    if (!self.cached) return;

    const core_surface = surface.core() orelse return;
    if (!buildSnapshot(core_surface, &self.scratch)) {
        // The cache could not be checked against this frame, so a
        // read must not trust it.
        self.cache_stale = true;
        return;
    }

    if (self.scratch.eql(&self.cache)) return;
    const caret_changed = self.scratch.caret != self.cache.caret;

    // Both slices stay valid across the swap below: it exchanges the
    // two snapshots, it frees nothing.
    const old_text = self.cache.text.items;
    const new_text = self.scratch.text.items;
    const change = textChange(old_text, new_text);
    const accessible = surface.as(gtk.AccessibleText);
    self.emitting = true;
    defer self.emitting = false;

    // GTK's bridge fills a remove's `any_data` by reading the removed
    // range back out of us synchronously, so the cache still holds the
    // old text for it, and the new text for the insert.
    if (change.remove) |r| gtk.AccessibleText.updateContents(accessible, .remove, r[0], r[1]);
    std.mem.swap(a11y.text.Snapshot, &self.cache, &self.scratch);
    if (change.insert) |r| gtk.AccessibleText.updateContents(accessible, .insert, r[0], r[1]);

    if (caret_changed) gtk.AccessibleText.updateCaretPosition(accessible);
}

/// The AT-SPI events for a change of text, as codepoint ranges. The
/// remove is emitted against the old text, then the insert against the
/// new, so each range is valid in the text the client has at that time.
const TextChange = struct {
    remove: ?[2]c_uint = null,
    insert: ?[2]c_uint = null,
};

/// The events for the change from `old_text` to `new_text`.
/// `chooseDiff` owns the shape choice (pure arithmetic, unit-tested). A
/// line shift is a `.remove` at one end plus an `.insert` at the other,
/// matching what VTE exposes to Orca; a whole-viewport replacement
/// would be re-read in full on every scroll.
fn textChange(old_text: []const u8, new_text: []const u8) TextChange {
    const cp = struct {
        fn count(s: []const u8) c_uint {
            return @intCast(utf8CpCount(s));
        }
    }.count;

    switch (a11y.offsets.chooseDiff(old_text, new_text)) {
        .none => return .{},

        // Upward line shift: `.remove(0, K)` + `.insert(tail, |new|)`.
        // `k` is > 0 and lands on a `\n` boundary of `old`.
        .shift_up => |k| {
            const tail_cp = cp(old_text[k..]);
            const new_end_cp = cp(new_text);
            return .{
                .remove = .{ 0, cp(old_text[0..k]) },
                .insert = if (new_end_cp > tail_cp) .{ tail_cp, new_end_cp } else null,
            };
        },

        // Downward line shift (scrolling back through output):
        // `.remove(kept, |old|)` + `.insert(0, J)`. After the remove the
        // exposed text is exactly `new[j..]`, so the insert offset needs
        // no adjustment. `chooseDiff` guarantees
        // `old_text[0..kept] == new_text[j..]`.
        .shift_down => |j| {
            const kept_cp = cp(old_text[0 .. new_text.len - j]);
            const old_end_cp = cp(old_text);
            return .{
                .remove = if (old_end_cp > kept_cp) .{ kept_cp, old_end_cp } else null,
                .insert = .{ 0, cp(new_text[0..j]) },
            };
        },

        // One remove+insert pair covering the region between the common
        // prefix and the common suffix.
        .replace => |d| {
            const p = d.prefix_len;
            const s = d.suffix_len;
            const start_cp = cp(old_text[0..p]);
            return .{
                .remove = if (old_text.len - p - s != 0)
                    .{ start_cp, cp(old_text[0 .. old_text.len - s]) }
                else
                    null,
                .insert = if (new_text.len - p - s != 0)
                    .{ start_cp, cp(new_text[0 .. new_text.len - s]) }
                else
                    null,
            };
        },
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

// UTF-8 codepoint offset helpers; `unicode.utf8` owns the arithmetic
// and the tests that pin it down.
const utf8CpCount = unicode.utf8.cpCount;
const utf8CpToByte = unicode.utf8.cpToByte;

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
    return self.caret();
}
