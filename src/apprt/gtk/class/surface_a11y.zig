//! The Surface's GtkAccessibleText implementation and its state.
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

/// The snapshot AT clients read. It only changes when we also send
/// change events for it, so it is always what clients last saw, and the
/// next change is diffed against it.
cache: a11y.text.Snapshot = .{},

/// False until the first read.
cached: bool = false,

/// The next snapshot is built here and swapped into `cache`.
scratch: a11y.text.Snapshot = .{},

/// Set on the first AT read and never cleared, since GTK does not tell
/// us when clients go away. Frames are only checked while set.
active: bool = false,

/// A frame could not be checked, so the next read rebuilds the cache.
cache_stale: bool = false,

check_source: ?c_uint = null,

/// True while change events are sent. GTK reads the removed text from
/// the cache during that time.
emitting: bool = false,

/// When the oldest frame GTK has not painted yet was pushed, in
/// `glib.getMonotonicTime` microseconds.
unpainted_since: ?i64 = null,

/// After this long without painting a pushed frame, the surface counts
/// as not painted.
const unpainted_after_us = 250 * std.time.us_per_ms;

/// Must run before the surface is freed, since the pending check points
/// at it.
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

/// Called from GTK's paint after each frame. Schedules a check for
/// changes to send to AT clients. Frames painted before it runs share
/// one check.
///
/// The check runs on every surface, not just the focused one, so that
/// output in other splits is announced too.
pub fn frameRendered(self: *A11y, surface: *Surface) void {
    self.unpainted_since = null;
    if (!self.active or self.check_source != null) return;

    // The same priority as D-Bus, so a busy bus does not delay it.
    self.check_source = glib.idleAddFull(
        glib.PRIORITY_DEFAULT,
        checkFrame,
        surface,
        null,
    );
}

/// Called when the renderer pushes a frame. GTK can stop painting a
/// window without unmapping it, for example an X11 window unmapped by
/// the window manager. Frames that are pushed but not painted show that.
pub fn framePushed(self: *A11y) void {
    if (self.unpainted_since == null) self.unpainted_since = glib.getMonotonicTime();
}

/// Whether GTK paints our frames, so every change gets checked.
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

/// Slots left alone keep GTK's defaults: no selection, no attributes.
pub fn initAccessibleTextInterface(iface: *gtk.AccessibleTextInterface) callconv(.c) void {
    iface.f_get_contents = &getContents;
    iface.f_get_contents_at = &getContentsAt;
    iface.f_get_caret_position = &getCaretPosition;
    iface.f_get_extents = &getExtents;
    iface.f_get_offset = &getOffset;
}

/// The rect of a text range, in widget coordinates. Orca groups text
/// into lines by Y, so each row must have its own Y.
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

/// Device pixels per widget pixel. `core_surface.size` is in device
/// pixels and GTK wants widget pixels. This is the fractional scale the
/// render surface uses; `getScaleFactor` would round 1.25 up to 2.
fn deviceScale(surface: *Surface) f32 {
    return @floatCast(scale_util.widgetSurfaceScale(surface.as(gtk.Widget)));
}

/// The offset at a widget-space point; the inverse of `getExtents`.
/// Points outside the text give the nearest offset.
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

/// Only valid after `refreshCache` returned text.
fn cellWidths(self: *A11y) a11y.offsets.CellWidths {
    return self.cache.cellWidths();
}

fn caret(self: *A11y) c_uint {
    return @intCast(self.cache.caret);
}

/// The cached text, built first if needed.
fn refreshCache(self: *A11y, surface: *Surface) ?[]const u8 {
    self.active = true;

    // While events are sent, GTK reads the old text from the cache.
    if (self.emitting) return self.cache.text.items;

    // Rebuild when no frame check will keep the cache current. On a
    // surface GTK does not paint, every read rebuilds, and no events
    // are sent for it.
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

/// Build the snapshot under the renderer mutex. False on failure.
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

/// If the screen differs from the cache, make it the cache and send
/// events for the change. Orca reads a short insert as typed text, so
/// the events should cover only what changed.
fn notifyIfChanged(self: *A11y, surface: *Surface) void {
    // The first read sets the cache.
    if (!self.cached) return;

    const core_surface = surface.core() orelse return;
    if (!buildSnapshot(core_surface, &self.scratch)) {
        self.cache_stale = true;
        return;
    }

    if (self.scratch.eql(&self.cache)) return;
    const caret_changed = self.scratch.caret != self.cache.caret;

    // The swap below frees nothing, so these stay valid.
    const old_text = self.cache.text.items;
    const new_text = self.scratch.text.items;
    const change = textChange(old_text, new_text);
    const accessible = surface.as(gtk.AccessibleText);
    self.emitting = true;
    defer self.emitting = false;

    // GTK reads the removed text from the cache while sending the
    // remove, and the inserted text while sending the insert.
    if (change.remove) |r| gtk.AccessibleText.updateContents(accessible, .remove, r[0], r[1]);
    std.mem.swap(a11y.text.Snapshot, &self.cache, &self.scratch);
    if (change.insert) |r| gtk.AccessibleText.updateContents(accessible, .insert, r[0], r[1]);

    if (caret_changed) gtk.AccessibleText.updateCaretPosition(accessible);
}

/// Codepoint ranges for the events. The remove applies to the old text
/// and the insert to the text after the remove.
const TextChange = struct {
    remove: ?[2]c_uint = null,
    insert: ?[2]c_uint = null,
};

/// The events for the change from `old_text` to `new_text`. Keep in
/// step with `replayDiff` in `a11y/offsets.zig`, which tests them.
fn textChange(old_text: []const u8, new_text: []const u8) TextChange {
    const cp = struct {
        fn count(s: []const u8) c_uint {
            return @intCast(utf8CpCount(s));
        }
    }.count;

    switch (a11y.offsets.chooseDiff(old_text, new_text)) {
        .none => return .{},

        .shift_up => |k| {
            const tail_cp = cp(old_text[k..]);
            const new_end_cp = cp(new_text);
            return .{
                .remove = .{ 0, cp(old_text[0..k]) },
                .insert = if (new_end_cp > tail_cp) .{ tail_cp, new_end_cp } else null,
            };
        },

        // After the remove, the text is `new_text[j..]`.
        .shift_down => |j| {
            const kept_cp = cp(old_text[0 .. new_text.len - j]);
            const old_end_cp = cp(old_text);
            return .{
                .remove = if (old_end_cp > kept_cp) .{ kept_cp, old_end_cp } else null,
                .insert = .{ 0, cp(new_text[0..j]) },
            };
        },

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

    const byte_start = utf8CpToByte(text, @intCast(start));
    const byte_end = utf8CpToByte(text, @intCast(end));
    if (byte_start >= byte_end) return emptyBytes();

    return bytesNulTerm(text[byte_start..byte_end]);
}

fn emptyBytes() *glib.Bytes {
    return glib.Bytes.new("", 1);
}

/// GTK passes the bytes to `g_variant_new_string`, which needs a NUL
/// terminator and crashes on invalid UTF-8.
fn bytesNulTerm(slice: []const u8) *glib.Bytes {
    if (!std.unicode.utf8ValidateSlice(slice)) {
        log.warn("accessibility text is not valid UTF-8, ignoring", .{});
        return emptyBytes();
    }

    const alloc = Application.default().allocator();
    const buf = alloc.dupeSentinel(u8, slice, 0) catch return emptyBytes();
    defer alloc.free(buf);
    return glib.Bytes.new(buf.ptr, slice.len + 1);
}

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
