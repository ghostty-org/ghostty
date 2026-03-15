const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const popupmod = @import("../../apprt/popup.zig");
const configpkg = @import("../../config.zig");

const Window = @import("class/window.zig").Window;
const WeakRef = @import("weak_ref.zig").WeakRef;

const log = std.log.scoped(.popup_manager);

/// Manages popup terminal instances for the GTK apprt.
///
/// Each popup is identified by a profile name (e.g. "quick", "calc").
/// The manager tracks which windows exist for each profile and handles
/// the toggle/show/hide lifecycle.
pub const PopupManager = struct {
    alloc: Allocator,

    /// Popup profile names (owned copies from config).
    profile_names: std.ArrayListUnmanaged([:0]const u8) = .empty,

    /// Popup profile data, parallel to profile_names.
    profiles: std.ArrayListUnmanaged(popupmod.PopupProfile) = .empty,

    /// Tracked popup window instances. Each entry stores the owned name
    /// (sentinel-terminated) and a weak reference to the Window. We use a
    /// simple parallel-array approach to avoid hashmap key ownership complexity.
    /// WeakRef ensures we don't hold dangling pointers when windows are
    /// destroyed externally (e.g., user closes window, GTK shutdown order).
    window_names: std.ArrayListUnmanaged([:0]const u8) = .empty,
    window_refs: std.ArrayListUnmanaged(WeakRef(Window)) = .empty,

    pub fn init(alloc: Allocator) PopupManager {
        return .{
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *PopupManager) void {
        for (self.profile_names.items) |name| self.alloc.free(name);
        self.profile_names.deinit(self.alloc);
        self.profiles.deinit(self.alloc);

        for (self.window_names.items) |name| self.alloc.free(name);
        self.window_names.deinit(self.alloc);
        self.window_refs.deinit(self.alloc);
    }

    /// Load popup profiles from the config. This replaces any previously
    /// stored profiles. It does NOT destroy existing windows -- those will
    /// be lazily cleaned up on next toggle/show/hide.
    pub fn loadConfig(self: *PopupManager, config: *const configpkg.Config) void {
        // Free old name strings since we own them
        for (self.profile_names.items) |name| self.alloc.free(name);
        self.profile_names.clearRetainingCapacity();
        self.profiles.clearRetainingCapacity();

        for (config.popup.names.items, config.popup.profiles.items) |name, profile| {
            const duped = self.alloc.dupeZ(u8, name) catch |err| {
                log.warn("failed to duplicate popup profile name: {}", .{err});
                continue;
            };
            self.profile_names.append(self.alloc, duped) catch |err| {
                log.warn("failed to store popup profile name: {}", .{err});
                self.alloc.free(duped);
                continue;
            };
            self.profiles.append(self.alloc, profile) catch |err| {
                log.warn("failed to store popup profile: {}", .{err});
                const popped = self.profile_names.pop();
                self.alloc.free(popped);
                continue;
            };
        }

        log.debug("loaded {} popup profiles", .{self.profile_names.items.len});
    }

    /// Toggle a popup by name: create+show if not exists, show if hidden,
    /// hide if visible.
    pub fn toggle(self: *PopupManager, name: []const u8) bool {
        if (self.findValidWindow(name)) |win| {
            defer win.unref();
            const widget = win.as(gtk.Widget);
            if (widget.isVisible() != 0) {
                return self.hide(name);
            } else {
                widget.setVisible(1);
                gtk.Window.present(win.as(gtk.Window));
                return true;
            }
        }

        return self.createAndShow(name);
    }

    /// Show a popup by name: create+show if not exists, show if hidden,
    /// no-op if already visible.
    pub fn show(self: *PopupManager, name: []const u8) bool {
        if (self.findValidWindow(name)) |win| {
            defer win.unref();
            const widget = win.as(gtk.Widget);
            if (widget.isVisible() != 0) return true;
            widget.setVisible(1);
            gtk.Window.present(win.as(gtk.Window));
            return true;
        }

        return self.createAndShow(name);
    }

    /// Hide a popup by name. If persist=false in the profile, destroy
    /// the window instead of just hiding it.
    pub fn hide(self: *PopupManager, name: []const u8) bool {
        const idx = self.findWindowIndex(name) orelse return false;
        const win = self.window_refs.items[idx].get() orelse {
            // Window was destroyed externally, clean up the stale entry.
            self.removeWindowAt(idx);
            return false;
        };
        defer win.unref();

        // Check if the profile says to destroy on hide
        const profile = self.getProfile(name);
        if (profile) |p| {
            if (!p.persist) {
                win.as(gtk.Window).destroy();
                self.removeWindowAt(idx);
                return true;
            }
        }

        win.as(gtk.Widget).setVisible(0);
        return true;
    }

    /// Hide (or destroy) all popup windows. Called during quit.
    pub fn hideAll(self: *PopupManager) void {
        for (self.window_refs.items) |*ref| {
            if (ref.get()) |win| {
                defer win.unref();
                win.as(gtk.Window).destroy();
            }
        }
        for (self.window_names.items) |name| self.alloc.free(name);
        self.window_names.clearRetainingCapacity();
        self.window_refs.clearRetainingCapacity();
    }

    /// Create a new popup window and show it.
    fn createAndShow(self: *PopupManager, name: []const u8) bool {
        // Get the GIO application (which is our GhosttyApplication)
        const gio_app = gio.Application.getDefault() orelse {
            log.warn("no default application available for popup creation", .{});
            return false;
        };
        const gtk_app = gobject.ext.cast(gtk.Application, gio_app) orelse {
            log.warn("default application is not a GTK application", .{});
            return false;
        };

        // Verify the profile exists
        _ = self.getProfile(name) orelse {
            log.warn("no popup profile found for name '{s}'", .{name});
            return false;
        };

        // Allocate an owned sentinel-terminated copy of the name
        const name_z = self.alloc.dupeZ(u8, name) catch |err| {
            log.warn("failed to allocate popup profile name: {}", .{err});
            return false;
        };

        // Create a new window with is-popup=true
        const win = gobject.ext.newInstance(Window, .{
            .application = gtk_app,
            .@"is-popup" = true,
        });

        // Store the profile name on the window so surfaces can read it
        win.setPopupProfileName(name_z);

        // Track the window with a weak reference
        var weak_ref: WeakRef(Window) = .empty;
        weak_ref.set(win);

        self.window_names.append(self.alloc, name_z) catch |err| {
            log.warn("failed to track popup window name: {}", .{err});
            self.alloc.free(name_z);
            win.as(gtk.Window).destroy();
            return false;
        };
        self.window_refs.append(self.alloc, weak_ref) catch |err| {
            log.warn("failed to track popup window ref: {}", .{err});
            const popped_name = self.window_names.pop();
            self.alloc.free(popped_name);
            win.as(gtk.Window).destroy();
            return false;
        };

        // Bind config so window config stays in sync with app config
        _ = gobject.Object.bindProperty(
            gio_app.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        // Create initial tab
        win.newTabForWindow(null, .none);

        // Show the window
        gtk.Window.present(win.as(gtk.Window));

        return true;
    }

    // -- Internal helpers --

    /// Find a valid window by name. Returns a strong reference that the
    /// caller must release with unref() when done. Returns null if the
    /// window doesn't exist or was destroyed externally.
    fn findValidWindow(self: *PopupManager, name: []const u8) ?*Window {
        const idx = self.findWindowIndex(name) orelse return null;
        const win = self.window_refs.items[idx].get() orelse {
            // Window was destroyed externally, clean up the stale entry.
            self.removeWindowAt(idx);
            return null;
        };
        return win;
    }

    fn findWindowIndex(self: *const PopupManager, name: []const u8) ?usize {
        for (self.window_names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return null;
    }

    fn removeWindowAt(self: *PopupManager, idx: usize) void {
        const name = self.window_names.orderedRemove(idx);
        _ = self.window_refs.orderedRemove(idx);
        self.alloc.free(name);
    }

    fn getProfile(self: *const PopupManager, name: []const u8) ?popupmod.PopupProfile {
        for (self.profile_names.items, self.profiles.items) |n, p| {
            if (std.mem.eql(u8, n, name)) return p;
        }
        return null;
    }
};
