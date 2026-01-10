const std = @import("std");
const Allocator = std.mem.Allocator;
const glib = @import("glib");
const gobject = @import("gobject");

const Surface = @import("class/surface.zig").Surface;
const Window = @import("class/window.zig").Window;
const WeakRef = @import("weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_undo_stack);

/// Maximum number of undo entries. This is a reasonable limit that
/// provides enough undo history without excessive memory usage.
const MaxEntries = 16;

/// Maximum number of surfaces per undo entry. A tab can have many splits
/// but this is a reasonable limit.
pub const MaxSurfacesPerEntry = 32;

/// An undo stack that holds closed surfaces for a configurable time,
/// allowing the user to undo close operations. Similar to macOS
/// ExpiringUndoManager but implemented for GTK.
pub const ExpiringUndoStack = struct {
    const Self = @This();

    /// The type of close operation being undone.
    pub const UndoKind = enum {
        /// A single surface (split pane) was closed.
        split,
        /// An entire tab was closed (may contain multiple surfaces).
        tab,
    };

    /// An entry in the undo stack representing a close operation.
    pub const UndoEntry = struct {
        /// The kind of close operation.
        kind: UndoKind,
        /// Strong references to surfaces. These keep the surfaces alive.
        /// On restore, ownership transfers to the tree. On expiration, we unref.
        surfaces: [MaxSurfacesPerEntry]*Surface,
        /// Number of valid surfaces in the array.
        surface_count: usize,
        /// Weak reference to the window for restoration context.
        window_ref: WeakRef(Window),
        /// The tab index for restoration (if kind == .tab).
        tab_index: u32,
        /// The GLib timer source ID for expiration.
        timer_id: c_uint,
        /// When this entry was created (for logging/debugging).
        timestamp_ns: i128,
    };

    /// The undo stack entries. Newer entries are at lower indices.
    entries: [MaxEntries]?UndoEntry,

    /// Number of valid entries in the stack.
    len: usize,

    /// Timeout duration in milliseconds.
    timeout_ms: u32,

    /// Create a new ExpiringUndoStack with the given timeout.
    /// Timeout is in seconds (matching the config format).
    pub fn init(timeout_seconds: u32) Self {
        return .{
            .entries = [_]?UndoEntry{null} ** MaxEntries,
            .len = 0,
            .timeout_ms = timeout_seconds * std.time.ms_per_s,
        };
    }

    /// Clean up any remaining entries. This unrefs all held surfaces.
    pub fn deinit(self: *Self) void {
        for (&self.entries) |*entry_opt| {
            if (entry_opt.*) |*entry| {
                // Cancel the timer
                if (glib.Source.remove(entry.timer_id) == 0) {
                    log.warn("failed to remove timer for undo entry", .{});
                }
                // Unref all surfaces
                self.cleanupEntry(entry);
                entry_opt.* = null;
            }
        }
        self.len = 0;
    }

    /// Push a new undo entry onto the stack.
    /// The surfaces must already be ref'd by the caller. This takes ownership of those refs.
    pub fn push(
        self: *Self,
        kind: UndoKind,
        surfaces: []const *Surface,
        window: *Window,
        tab_index: u32,
    ) bool {
        if (surfaces.len == 0) return false;
        if (surfaces.len > MaxSurfacesPerEntry) {
            log.warn("too many surfaces for undo entry: {}", .{surfaces.len});
            return false;
        }

        // If stack is full, drop the oldest entry
        if (self.len >= MaxEntries) {
            self.dropOldest();
        }

        // Shift existing entries down
        var i: usize = self.len;
        while (i > 0) : (i -= 1) {
            self.entries[i] = self.entries[i - 1];
        }

        // Create timer for expiration
        const entry_ptr = &self.entries[0];
        const timer_id = glib.timeoutAdd(
            self.timeout_ms,
            onExpire,
            entry_ptr,
        );

        // Create the new entry at index 0
        var surface_array: [MaxSurfacesPerEntry]*Surface = undefined;
        for (surfaces, 0..) |s, idx| {
            surface_array[idx] = s;
        }

        self.entries[0] = .{
            .kind = kind,
            .surfaces = surface_array,
            .surface_count = surfaces.len,
            .window_ref = .empty,
            .tab_index = tab_index,
            .timer_id = timer_id,
            .timestamp_ns = std.time.nanoTimestamp(),
        };
        self.entries[0].?.window_ref.set(window);
        self.len += 1;

        log.debug("pushed undo entry: kind={s} surfaces={} tab_index={}", .{
            @tagName(kind),
            surfaces.len,
            tab_index,
        });

        return true;
    }

    /// Pop the most recent undo entry from the stack.
    /// Cancels the expiration timer. Caller takes ownership of surface refs.
    pub fn pop(self: *Self) ?UndoEntry {
        if (self.len == 0) return null;

        const entry = self.entries[0] orelse return null;

        // Cancel the timer - the entry is being consumed
        if (glib.Source.remove(entry.timer_id) == 0) {
            log.warn("failed to remove timer for popped entry", .{});
        }

        // Shift remaining entries up
        var i: usize = 0;
        while (i < self.len - 1) : (i += 1) {
            self.entries[i] = self.entries[i + 1];
        }
        self.entries[self.len - 1] = null;
        self.len -= 1;

        log.debug("popped undo entry: kind={s} surfaces={}", .{
            @tagName(entry.kind),
            entry.surface_count,
        });

        return entry;
    }

    /// Timer callback when an entry expires.
    fn onExpire(user_data: ?*anyopaque) callconv(.c) c_int {
        const entry_ptr: *?UndoEntry = @ptrCast(@alignCast(user_data));
        const entry = entry_ptr.* orelse return 0;

        log.debug("undo entry expired: kind={s} surfaces={}", .{
            @tagName(entry.kind),
            entry.surface_count,
        });

        // Unref all surfaces - this may destroy them if they're the last ref
        for (entry.surfaces[0..entry.surface_count]) |surface| {
            surface.as(gobject.Object).unref();
        }

        // Clear the entry
        entry_ptr.* = null;

        // Return 0 to not reschedule the timer
        return 0;
    }

    /// Drop the oldest entry (at highest index).
    fn dropOldest(self: *Self) void {
        if (self.len == 0) return;

        const idx = self.len - 1;
        if (self.entries[idx]) |*entry| {
            // Cancel timer
            if (glib.Source.remove(entry.timer_id) == 0) {
                log.warn("failed to remove timer for dropped entry", .{});
            }
            self.cleanupEntry(entry);
            self.entries[idx] = null;
            self.len -= 1;
        }
    }

    /// Clean up an entry by unrefing its surfaces.
    fn cleanupEntry(self: *Self, entry: *UndoEntry) void {
        _ = self;
        for (entry.surfaces[0..entry.surface_count]) |surface| {
            surface.as(gobject.Object).unref();
        }
    }

    /// Get the number of entries in the stack.
    pub fn count(self: *const Self) usize {
        return self.len;
    }

    /// Check if the stack is empty.
    pub fn isEmpty(self: *const Self) bool {
        return self.len == 0;
    }
};
